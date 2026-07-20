//! Keyframe-request plumbing — both directions.
//!
//! * Upstream: when str0m hands us non-contiguous media on an incoming
//!   track, ask the source peer for a keyframe (throttled).
//! * Downstream: when a receiver asks this SFU for a keyframe on a
//!   track it's subscribed to, relay that to the origin client's
//!   incoming track.
//!
//! Split out of `client/mod.rs` because it's a distinct concern from
//! the `Rtc` lifecycle / event dispatch — it owns the per-track
//! throttling state and maps between outgoing mid ↔ source mid.

use std::time::{Duration, Instant};

use str0m::media::{KeyframeRequest, KeyframeRequestKind, Mid, Rid};

use super::tracks::TrackOut;
use super::Client;
use crate::propagate::Propagated;

/// Minimum gap between PLI/FIR requests for the same track. Matches
/// chat.rs's 1 s floor — aggressive enough to unblock receivers
/// quickly, slow enough to avoid rekeyframe storms.
const KEYFRAME_REQUEST_MIN_GAP: Duration = Duration::from_secs(1);

impl Client {
    /// Upstream: politely ask the source to cut a keyframe, but not
    /// more than once per [`KEYFRAME_REQUEST_MIN_GAP`].
    pub(super) fn request_keyframe_throttled(
        &mut self,
        mid: Mid,
        rid: Option<Rid>,
        kind: KeyframeRequestKind,
    ) {
        let Some(mut writer) = self.rtc.writer(mid) else {
            return;
        };
        let Some(entry) = self.tracks_in.iter_mut().find(|t| t.id.mid == mid) else {
            return;
        };
        if entry
            .last_keyframe_request
            .map(|t| t.elapsed() < KEYFRAME_REQUEST_MIN_GAP)
            .unwrap_or(false)
        {
            return;
        }
        let _ = writer.request_keyframe(rid, kind);
        entry.last_keyframe_request = Some(Instant::now());
    }

    /// G4: proactively request a keyframe on the TARGET simulcast layer
    /// when this subscriber's pacer switches it to a different RID, so the
    /// subscriber's decoder gets a keyframe for the new layer immediately
    /// instead of freezing until a reactive PLI (visible stutter) or the
    /// publisher's next periodic keyframe. Worst on slow/variable internet
    /// where the pacer switches layers exactly when the user can least
    /// afford a freeze.
    ///
    /// Emits one [`Propagated::KeyframeRequest`] per video publisher this
    /// subscriber is subscribed to (a layer switch applies to every video
    /// track the subscriber receives). The request is routed by the
    /// registry's fanout to the publisher's [`Client::handle_keyframe_request`],
    /// which calls `writer.request_keyframe(Some(rid), Pli)` on the
    /// publisher's incoming track — the same str0m API the upstream path
    /// uses.
    ///
    /// Throttle: per-target-RID, mirroring
    /// [`request_keyframe_throttled`]'s per-track `last_keyframe_request`
    /// pattern but keyed by the TARGET RID (stored in
    /// `last_switch_keyframe_request`). A rapid up/down oscillation
    /// (low→high→low→high) cannot storm the publisher: each RID is
    /// independently gated by [`KEYFRAME_REQUEST_MIN_GAP`], so the second
    /// HIGH within 1 s is suppressed while a switch to a *different* RID
    /// (e.g. MEDIUM) within the same window still fires. Per-subscriber
    /// (not per-publisher): the switch is a subscriber-side event and one
    /// keyframe on a given RID refreshes all subscribers of that layer.
    ///
    /// Only call this on an ACTUAL layer change (target RID differs from
    /// the previously-desired RID), not on every pacer tick — the caller
    /// (`registry::bwe::update_pacer_layers`) gates on `prev != chosen`.
    pub(crate) fn emit_keyframe_on_layer_switch(
        &mut self,
        new_rid: Rid,
        out: &mut std::collections::VecDeque<Propagated>,
    ) {
        // Per-target-RID throttle — mirrors request_keyframe_throttled's
        // elapsed < MIN_GAP check. A second switch to the SAME RID within
        // the window is suppressed; a switch to a DIFFERENT RID fires.
        if let Some(last) = self.last_switch_keyframe_request.get(&new_rid) {
            if last.elapsed() < KEYFRAME_REQUEST_MIN_GAP {
                return;
            }
        }
        self.last_switch_keyframe_request
            .insert(new_rid, Instant::now());

        // Observability: mirror the existing metrics pattern. Label `rid`
        // only (bounded to q/h/f/other — no per-client cardinality).
        let rid_label = if new_rid == super::layer::LOW {
            "q"
        } else if new_rid == super::layer::MEDIUM {
            "h"
        } else if new_rid == super::layer::HIGH {
            "f"
        } else {
            "other"
        };
        self.metrics
            .sfu_keyframe_on_switch_total
            .with_label_values(&[rid_label])
            .inc();

        // Emit one request per video publisher this subscriber is
        // subscribed to. Keyframes are a video-only concern; audio tracks
        // are skipped. `track_in.upgrade()` being None means the publisher
        // already disconnected — skip silently.
        for o in &self.tracks_out {
            let Some(track_in) = o.track_in.upgrade() else {
                continue;
            };
            if track_in.kind != str0m::media::MediaKind::Video {
                continue;
            }
            let req = KeyframeRequest {
                mid: track_in.mid,
                rid: Some(new_rid),
                kind: KeyframeRequestKind::Pli,
            };
            out.push_back(Propagated::KeyframeRequest(
                self.id,
                req,
                track_in.origin,
                track_in.mid,
            ));
        }
    }

    /// Downstream: a subscriber's decoder is stalled and wants a
    /// keyframe on one of our outgoing tracks. Translate to a request
    /// aimed at the source client's incoming track.
    pub(super) fn incoming_keyframe_req(&self, mut req: KeyframeRequest) -> Propagated {
        let Some(track_out): Option<&TrackOut> =
            self.tracks_out.iter().find(|t| t.mid() == Some(req.mid))
        else {
            return Propagated::Noop;
        };
        let Some(track_in) = track_out.track_in.upgrade() else {
            return Propagated::Noop;
        };
        req.rid = self.chosen_rid;
        Propagated::KeyframeRequest(self.id, req, track_in.origin, track_in.mid)
    }

    /// Terminal handler for a propagated keyframe request: if this
    /// client actually owns an incoming track matching `mid_in`, pass
    /// the request through to str0m's writer.
    pub fn handle_keyframe_request(&mut self, req: KeyframeRequest, mid_in: Mid) {
        if !self.tracks_in.iter().any(|i| i.id.mid == mid_in) {
            return;
        }
        // Test-only: record the request's target RID before the writer
        // lookup (which no-ops on unnegotiated Rtc in tests). This is the
        // only observable signal that a Propagated::KeyframeRequest reached
        // the publisher in the unit/integration test path.
        #[cfg(any(test, feature = "test-utils"))]
        {
            if let Ok(mut g) = self.keyframe_requests_received.lock() {
                g.push(req.rid);
            }
        }
        let Some(mut writer) = self.rtc.writer(mid_in) else {
            return;
        };
        if let Err(e) = writer.request_keyframe(req.rid, req.kind) {
            tracing::info!(client = *self.id, error = ?e, "request_keyframe failed");
        }
    }
}

#[cfg(test)]
mod tests {
    //! G4: keyframe-on-layer-switch unit tests.
    //!
    //! Falsification: every assertion below relies on
    //! [`Client::emit_keyframe_on_layer_switch`] emitting a
    //! [`Propagated::KeyframeRequest`] with the TARGET RID and on the
    //! per-target-RID throttle suppressing a same-RID repeat within
    //! [`KEYFRAME_REQUEST_MIN_GAP`]. Revert the emission loop → the first
    //! assertion fails (no events). Revert the throttle check → the
    //! same-RID-within-window assertion fails (2 events instead of 1).

    use std::collections::VecDeque;
    use std::sync::Arc;

    use str0m::media::{MediaKind, Mid, Rid};

    use super::super::layer::{HIGH, LOW, MEDIUM};
    use super::super::test_seed::{new_client, seed_track_in};
    use super::super::tracks::{TrackOut, TrackOutState};
    use super::Client;
    use crate::propagate::{ClientId, Propagated};

    /// Wire `subscriber`'s `tracks_out` to `publisher`'s seeded video
    /// `TrackIn` arc, mirroring what `handle_track_open` does in
    /// production. Returns the publisher's `Mid` for assertions.
    fn wire_video_track(
        subscriber: &mut Client,
        publisher_track: &Arc<super::super::tracks::TrackIn>,
    ) -> Mid {
        let mid = publisher_track.mid;
        subscriber.tracks_out.push(TrackOut {
            track_in: Arc::downgrade(publisher_track),
            state: TrackOutState::Open(mid),
        });
        mid
    }

    /// Drain the [`Propagated::KeyframeRequest`] events from `out`,
    /// returning `(count, rids, source_ids, mids)`.
    fn drain_keyframe_reqs(
        out: &mut VecDeque<Propagated>,
    ) -> (usize, Vec<Option<Rid>>, Vec<ClientId>, Vec<Mid>) {
        let mut rids = Vec::new();
        let mut sources = Vec::new();
        let mut mids = Vec::new();
        let mut count = 0usize;
        while let Some(p) = out.pop_front() {
            if let Propagated::KeyframeRequest(_src, req, origin, mid) = p {
                count += 1;
                rids.push(req.rid);
                sources.push(origin);
                mids.push(mid);
            }
        }
        (count, rids, sources, mids)
    }

    #[test]
    fn layer_switch_emits_one_keyframe_request_on_target_rid() {
        // Publisher A publishes a video track; subscriber B is subscribed.
        let mut a = new_client(ClientId(100));
        let track_a = seed_track_in(&mut a, 7, MediaKind::Video);
        let pub_mid = track_a.mid;
        let mut b = new_client(ClientId(101));
        let wired_mid = wire_video_track(&mut b, &track_a);
        assert_eq!(wired_mid, pub_mid, "wired mid matches publisher track mid");

        let mut out: VecDeque<Propagated> = VecDeque::new();
        b.emit_keyframe_on_layer_switch(HIGH, &mut out);
        let (count, rids, sources, mids) = drain_keyframe_reqs(&mut out);
        assert_eq!(count, 1, "exactly one keyframe request on switch");
        assert_eq!(rids, vec![Some(HIGH)], "targets the NEW rid (HIGH)");
        assert_eq!(sources, vec![ClientId(100)], "routed to publisher A");
        assert_eq!(mids, vec![pub_mid], "targets publisher's incoming mid");
    }

    #[test]
    fn second_switch_to_same_rid_within_throttle_window_is_suppressed() {
        let mut a = new_client(ClientId(110));
        let track_a = seed_track_in(&mut a, 1, MediaKind::Video);
        let mut b = new_client(ClientId(111));
        wire_video_track(&mut b, &track_a);

        let mut out: VecDeque<Propagated> = VecDeque::new();
        b.emit_keyframe_on_layer_switch(HIGH, &mut out);
        let (count, _, _, _) = drain_keyframe_reqs(&mut out);
        assert_eq!(count, 1, "first switch fires");

        // Second switch to the SAME RID within the 1 s throttle window —
        // must NOT produce a second request (no keyframe-request storm on
        // rapid up/down oscillation).
        b.emit_keyframe_on_layer_switch(HIGH, &mut out);
        let (count, _, _, _) = drain_keyframe_reqs(&mut out);
        assert_eq!(count, 0, "same-RID repeat within window is throttled");
    }

    #[test]
    fn switch_to_different_rid_within_window_fires() {
        let mut a = new_client(ClientId(120));
        let track_a = seed_track_in(&mut a, 1, MediaKind::Video);
        let mut b = new_client(ClientId(121));
        wire_video_track(&mut b, &track_a);

        let mut out: VecDeque<Propagated> = VecDeque::new();
        b.emit_keyframe_on_layer_switch(HIGH, &mut out);
        let (count, rids, _, _) = drain_keyframe_reqs(&mut out);
        assert_eq!(count, 1);
        assert_eq!(rids, vec![Some(HIGH)]);

        // Switch to a DIFFERENT RID within the window — the per-target-RID
        // throttle must NOT suppress it (the subscriber needs a keyframe on
        // the new layer; HIGH's keyframe does not help a MEDIUM decoder).
        b.emit_keyframe_on_layer_switch(MEDIUM, &mut out);
        let (count, rids, _, _) = drain_keyframe_reqs(&mut out);
        assert_eq!(count, 1, "different-RID switch within window fires");
        assert_eq!(rids, vec![Some(MEDIUM)]);
    }

    #[test]
    fn audio_tracks_are_skipped() {
        // A publishes an AUDIO track; B is subscribed. A layer switch must
        // NOT emit a keyframe request — keyframes are a video-only concern.
        let mut a = new_client(ClientId(130));
        let track_a = seed_track_in(&mut a, 1, MediaKind::Audio);
        let mut b = new_client(ClientId(131));
        wire_video_track(&mut b, &track_a);

        let mut out: VecDeque<Propagated> = VecDeque::new();
        b.emit_keyframe_on_layer_switch(LOW, &mut out);
        let (count, _, _, _) = drain_keyframe_reqs(&mut out);
        assert_eq!(count, 0, "audio tracks do not get keyframe requests");
    }

    #[test]
    fn switch_with_no_subscribed_video_publishers_emits_nothing() {
        // B is subscribed to no one — a layer switch must not panic and
        // must emit nothing.
        let mut b = new_client(ClientId(140));
        let mut out: VecDeque<Propagated> = VecDeque::new();
        b.emit_keyframe_on_layer_switch(HIGH, &mut out);
        let (count, _, _, _) = drain_keyframe_reqs(&mut out);
        assert_eq!(count, 0, "no video publishers → no requests");
    }
}
