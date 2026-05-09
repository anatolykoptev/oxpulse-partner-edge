//! M2 SDP renegotiation for outbound tracks.
//!
//! When a peer Y publishes, every other peer X receives a `handle_track_open`
//! call. In M1 this pushed `TrackOutState::ToOpen` and stopped — the fanout
//! writer gate (`o.mid()` returns `None`) meant SRTP never left the wire.
//!
//! M2 completes the state machine:
//! 1. `handle_track_open` → `start_renegotiation`: call `sdp_api().add_media`
//!    → get `(SdpOffer, SdpPendingOffer)` → send `offer-renegotiate` WS frame.
//! 2. Browser `answer-renegotiate` drains via `drain_ws_ctrl`.
//! 3. `accept_renegotiation_answer` calls `sdp_api().accept_answer` → str0m emits
//!    `Event::MediaAdded { direction: SendOnly }` → `dispatch.rs` flips to `Open(mid)`.
//! 4. `fanout.rs` `o.mid()` returns `Some(mid)` → `writer.write` fires → SRTP on wire.

use std::sync::Weak;

use str0m::change::SdpAnswer;
use str0m::media::{Direction, MediaKind};

use super::tracks::{TrackIn, TrackOut, TrackOutState};
use super::Client;
use crate::client_ws::WsClientCtrl;

impl Client {
    /// Register that another client opened a track we should mirror to this peer.
    ///
    /// ## Behaviour
    ///
    /// - **Relay / test clients** (`ws_msg_tx` is `None`): legacy path — push `ToOpen`
    ///   and stop. Fanout will no-op until M2 state is reached (or not, for relay edges
    ///   which renegotiate via their own signaling path).
    /// - **Browser clients** with no pending offer: call `start_renegotiation` immediately.
    /// - **Browser clients** with a pending offer: enqueue into `renegotiation_queue`
    ///   (str0m allows only one in-flight renegotiation per `Rtc`).
    pub fn handle_track_open(&mut self, track_in: Weak<TrackIn>) {
        if self.ws_msg_tx.is_none() {
            // Relay / test path: no WS channel, keep legacy ToOpen behaviour.
            self.tracks_out.push(TrackOut {
                track_in,
                state: TrackOutState::ToOpen,
            });
            return;
        }

        if self.pending_offer.is_some() {
            // One renegotiation already in flight — queue for sequential processing.
            self.renegotiation_queue.push_back(track_in);
            return;
        }

        self.start_renegotiation(track_in);
    }

    /// Initiate SDP renegotiation to add a new send-only m-line for `track_in`.
    ///
    /// Calls `sdp_api().add_media(kind, SendOnly)`, applies the change to get an
    /// `SdpOffer` + `SdpPendingOffer`, stores the pending offer, pushes the new
    /// `TrackOut` in `Negotiating(mid)` state, and sends `offer-renegotiate` to
    /// the browser via `ws_msg_tx`.
    ///
    /// No-ops if the `TrackIn` `Weak` has already been dropped (publisher left).
    fn start_renegotiation(&mut self, track_in: Weak<TrackIn>) {
        let Some(track_arc) = track_in.upgrade() else {
            // Publisher already left before we could negotiate; skip.
            return;
        };

        let kind = track_arc.kind;
        let origin = track_arc.origin;
        let stream_id = format!("peer-{}", *origin);

        // Block-scope the SdpApi borrow so the mutable borrow on `self.rtc` is released
        // before we access other self fields below.
        let (offer, pending) = {
            let mut api = self.rtc.sdp_api();
            let mid = api.add_media(kind, Direction::SendOnly, Some(stream_id), None, None);
            match api.apply() {
                Some((offer, pending)) => {
                    // Push the TrackOut in Negotiating state before releasing the borrow.
                    self.tracks_out.push(TrackOut {
                        track_in,
                        state: TrackOutState::Negotiating(mid),
                    });
                    self.metrics
                        .sfu_track_out_state_transitions_total
                        .with_label_values(&["to_open", "negotiating"])
                        .inc();
                    let kind_label = match kind {
                        MediaKind::Audio => "audio",
                        MediaKind::Video => "video",
                    };
                    self.metrics
                        .sfu_renegotiation_offers_sent_total
                        .with_label_values(&[kind_label])
                        .inc();
                    (offer, pending)
                }
                None => {
                    // apply() returned None — no changes were actually made (defensive).
                    tracing::warn!(client = *self.id, "M2: sdp_api().apply() returned None");
                    return;
                }
            }
        };

        self.pending_offer = Some(pending);

        // Send offer to browser WS. try_send: non-blocking; if channel full the peer
        // is lagging — drop the offer (it will be retried on next handle_track_open
        // since we haven't pushed it to the queue yet in this branch).
        // Find the mid from the track we just pushed (last entry).
        let mid_str = self.tracks_out.last()
            .and_then(|o| o.mid())
            .map(|m| m.to_string())
            .unwrap_or_default();

        let offer_frame = serde_json::json!({
            "type": "offer-renegotiate",
            "sdp": offer.to_sdp_string(),
            "mid": mid_str,
        })
        .to_string();

        if let Some(tx) = &self.ws_msg_tx {
            if tx.try_send(offer_frame).is_err() {
                tracing::warn!(client = *self.id,
                    "M2: ws_msg_tx full — offer-renegotiate dropped; \
                     browser may not receive the track");
            }
        }
    }

    /// Process a `answer-renegotiate` reply from the browser.
    ///
    /// Passes the answer to str0m via `sdp_api().accept_answer`. On success,
    /// str0m will emit `Event::MediaAdded { direction: SendOnly }` which
    /// `dispatch.rs` picks up to flip the `TrackOutState` to `Open(mid)`.
    ///
    /// After processing, drains one entry from `renegotiation_queue` (sequential
    /// offer pipeline — only one in-flight at a time per str0m contract).
    pub fn accept_renegotiation_answer(&mut self, sdp: &str) {
        let Some(pending) = self.pending_offer.take() else {
            tracing::warn!(client = *self.id,
                "M2: accept_renegotiation_answer called with no pending offer — ignoring");
            return;
        };

        let answer = match SdpAnswer::from_sdp_string(sdp) {
            Ok(a) => a,
            Err(e) => {
                tracing::warn!(client = *self.id, error = %e,
                    "M2: failed to parse renegotiation answer SDP");
                self.metrics
                    .sfu_renegotiation_answers_total
                    .with_label_values(&["err"])
                    .inc();
                return;
            }
        };

        if let Err(e) = self.rtc.sdp_api().accept_answer(pending, answer) {
            tracing::warn!(client = *self.id, error = %e,
                "M2: str0m rejected renegotiation answer");
            self.metrics
                .sfu_renegotiation_answers_total
                .with_label_values(&["err"])
                .inc();
            return;
        }

        self.metrics
            .sfu_renegotiation_answers_total
            .with_label_values(&["ok"])
            .inc();

        // Drain the next queued track open (sequential pipeline).
        if let Some(next) = self.renegotiation_queue.pop_front() {
            self.start_renegotiation(next);
        }
    }

    /// Drain all pending WS control messages from `ws_ctrl_rx`.
    ///
    /// Called by `Registry::pump_ws_ctrl` at the top of each UDP loop iteration.
    /// try_recv-based: never blocks. Processes `AnswerRenegotiate` by delegating
    /// to `accept_renegotiation_answer`.
    pub fn drain_ws_ctrl(&mut self) {
        // Collect messages first to avoid simultaneous mut borrow of self.ws_ctrl_rx
        // and self (via accept_renegotiation_answer).
        let mut messages: Vec<WsClientCtrl> = Vec::new();
        let mut channel_closed = false;
        if let Some(rx) = &mut self.ws_ctrl_rx {
            loop {
                match rx.try_recv() {
                    Ok(msg) => messages.push(msg),
                    Err(tokio::sync::mpsc::error::TryRecvError::Empty) => break,
                    Err(tokio::sync::mpsc::error::TryRecvError::Disconnected) => {
                        channel_closed = true;
                        break;
                    }
                }
            }
        } else {
            return; // No channel — relay / test client.
        }
        if channel_closed {
            self.ws_ctrl_rx = None;
        }
        for msg in messages {
            match msg {
                WsClientCtrl::AnswerRenegotiate { sdp, mid: _ } => {
                    // `mid` is for correlation logging only; str0m matches the answer
                    // against the single pending offer internally.
                    self.accept_renegotiation_answer(&sdp);
                }
            }
        }
    }
}
