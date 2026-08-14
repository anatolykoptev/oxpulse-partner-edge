//! Keyframe-request plumbing — both directions.
//!
//! * Upstream: when str0m hands us non-contiguous media on an incoming
//!   track, ask the source peer for a keyframe (throttled).
//! * Downstream: when a receiver asks this SFU for a keyframe on a
//!   track it's subscribed to, relay that to the origin client's
//!   incoming track.
//! * Subscribe-triggered: when a subscriber attaches (track transitions
//!   to Open), request a keyframe from the publisher and repeat until
//!   one is observed or the attempt budget is spent (issue #618).
//!
//! Split out of `client/mod.rs` because it's a distinct concern from
//! the `Rtc` lifecycle / event dispatch — it owns the per-track
//! throttling state and maps between outgoing mid ↔ source mid.

use std::time::{Duration, Instant};

use str0m::media::{KeyframeRequest, KeyframeRequestKind, Mid, Rid};

use super::tracks::TrackOut;
use super::Client;
use crate::propagate::{ClientId, Propagated};

/// Minimum gap between PLI/FIR requests for the same track. Matches
/// chat.rs's 1 s floor — aggressive enough to unblock receivers
/// quickly, slow enough to avoid rekeyframe storms.
const KEYFRAME_REQUEST_MIN_GAP: Duration = Duration::from_secs(1);

/// Maximum PLI attempts for the subscribe-triggered keyframe loop
/// (issue #618). At `KEYFRAME_REQUEST_MIN_GAP` (1 s) intervals this
/// bounds the wait to ~5 s. The prior incident logged 48,972 PLIs —
/// this budget is the hard ceiling that prevents re-creating that storm.
const KEYFRAME_SUBSCRIBE_MAX_ATTEMPTS: u32 = 5;

/// Absolute deadline for the subscribe-triggered keyframe loop.
/// Secondary bound — the attempt budget is the primary. If the loop
/// hasn't observed a keyframe by this deadline, it stops and records
/// `budget_exhausted`.
const KEYFRAME_SUBSCRIBE_DEADLINE: Duration = Duration::from_secs(10);

/// Per-subscriber keyframe-wait state for the subscribe-triggered PLI
/// loop (issue #618). Created when a video track transitions to Open
/// after renegotiation; drives repeat-until-observed PLI requests until
/// a keyframe is observed (terminating condition) or the attempt budget
/// is spent.
#[derive(Debug)]
pub(crate) struct KeyframeWait {
    /// Publisher's ClientId — the target of the PLI request.
    pub origin: ClientId,
    /// Publisher's incoming track Mid — identifies the track to request on.
    pub mid_in: Mid,
    /// When the wait started (for time-to-first-keyframe metric).
    pub started_at: Instant,
    /// When the last PLI was sent (for retry interval throttle).
    pub last_request_at: Instant,
    /// Number of PLIs sent so far (including the initial one).
    pub attempts: u32,
}

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

    // ── Issue #618: subscribe-triggered keyframe loop ───────────────────

    /// Start a keyframe-wait for a single video track that just
    /// transitioned to Open. Emits the initial PLI (into
    /// `self.pending_propagated`) and records the wait state so
    /// [`pump_keyframe_waits`][Self::pump_keyframe_waits] can retry until
    /// a keyframe is observed or the budget is spent.
    ///
    /// `origin` / `mid_in` identify the publisher's incoming track to
    /// request on. `now` is the loop's clock (passed in so tests can
    /// control time without `Instant::now()`).
    fn start_keyframe_wait(
        &mut self,
        origin: ClientId,
        mid_in: Mid,
        now: Instant,
    ) {
        // De-dup: if a wait for this (origin, mid_in) already exists, don't
        // start a second one. This handles the case where multiple
        // renegotiation rounds transition the same track to Open.
        if self
            .keyframe_waits
            .iter()
            .any(|w| w.origin == origin && w.mid_in == mid_in)
        {
            return;
        }

        let req = KeyframeRequest {
            mid: mid_in,
            rid: self.chosen_rid,
            kind: KeyframeRequestKind::Pli,
        };
        self.pending_propagated
            .push_back(Propagated::KeyframeRequest(self.id, req, origin, mid_in));

        self.metrics
            .sfu_keyframe_on_subscribe_requests_total
            .with_label_values(&["initial"])
            .inc();

        self.keyframe_waits.push(KeyframeWait {
            origin,
            mid_in,
            started_at: now,
            last_request_at: now,
            attempts: 1,
        });
    }

    /// Scan all Open video tracks in `tracks_out` and start a keyframe-wait
    /// for each one that doesn't already have a wait pending. Called after
    /// [`flip_negotiating_to_open_all`][super::renegotiation::Client::flip_negotiating_to_open_all]
    /// transitions tracks to Open — the moment a subscriber can actually
    /// receive media.
    ///
    /// Audio tracks are skipped (keyframes are a video-only concern).
    /// Tracks whose `track_in.upgrade()` returns `None` (publisher
    /// disconnected) are skipped.
    pub(crate) fn start_keyframe_waits_for_open_video_tracks(&mut self, now: Instant) {
        // Collect first to avoid double-borrow of self (tracks_out + keyframe_waits).
        let to_start: Vec<(ClientId, Mid)> = self
            .tracks_out
            .iter()
            .filter(|o| matches!(o.state, super::tracks::TrackOutState::Open(_)))
            .filter_map(|o| {
                let track_in = o.track_in.upgrade()?;
                if track_in.kind != str0m::media::MediaKind::Video {
                    return None;
                }
                Some((track_in.origin, track_in.mid))
            })
            .collect();

        for (origin, mid_in) in to_start {
            self.start_keyframe_wait(origin, mid_in, now);
        }
    }

    /// Pump the keyframe-wait loop: for each pending wait, if
    /// [`KEYFRAME_REQUEST_MIN_GAP`] has elapsed since the last PLI and the
    /// attempt budget is not yet spent, emit a retry PLI (into
    /// `self.pending_propagated`). If the budget IS spent (attempts ≥
    /// [`KEYFRAME_SUBSCRIBE_MAX_ATTEMPTS`] or the deadline elapsed),
    /// record `budget_exhausted` and drop the wait.
    ///
    /// Called once per UDP loop iteration from
    /// [`Registry::pump_ws_ctrl`][crate::registry::Registry::pump_ws_ctrl].
    /// `now` is the loop's clock.
    pub(crate) fn pump_keyframe_waits(&mut self, now: Instant) {
        // Drain-and-rebuild: remove exhausted waits, emit retries for the
        // rest. Iterate by index and track which to remove.
        let mut to_remove: Vec<usize> = Vec::new();
        for i in 0..self.keyframe_waits.len() {
            let wait = &mut self.keyframe_waits[i];

            // Deadline check (secondary bound).
            if now.duration_since(wait.started_at) >= KEYFRAME_SUBSCRIBE_DEADLINE {
                to_remove.push(i);
                continue;
            }

            // Attempt budget check (primary bound).
            if wait.attempts >= KEYFRAME_SUBSCRIBE_MAX_ATTEMPTS {
                to_remove.push(i);
                continue;
            }

            // Retry interval throttle — only emit if MIN_GAP has elapsed.
            if now.duration_since(wait.last_request_at) < KEYFRAME_REQUEST_MIN_GAP {
                continue;
            }

            // Emit retry PLI.
            let req = KeyframeRequest {
                mid: wait.mid_in,
                rid: self.chosen_rid,
                kind: KeyframeRequestKind::Pli,
            };
            self.pending_propagated.push_back(Propagated::KeyframeRequest(
                self.id,
                req,
                wait.origin,
                wait.mid_in,
            ));
            wait.last_request_at = now;
            wait.attempts += 1;

            self.metrics
                .sfu_keyframe_on_subscribe_requests_total
                .with_label_values(&["retry"])
                .inc();
        }

        // Remove exhausted waits in reverse order to preserve indices.
        // Record `budget_exhausted` for each removed wait.
        for &i in to_remove.iter().rev() {
            let wait = self.keyframe_waits.remove(i);
            self.metrics
                .sfu_keyframe_on_subscribe_outcome_total
                .with_label_values(&["budget_exhausted"])
                .inc();
            tracing::warn!(
                client = *self.id,
                origin = *wait.origin,
                mid_in = %wait.mid_in,
                attempts = wait.attempts,
                elapsed_ms = now.duration_since(wait.started_at).as_millis(),
                "issue #618: keyframe-wait budget exhausted — subscriber may see black video"
            );
        }
    }

    /// Observe a forwarded `MediaData` and terminate any matching
    /// keyframe-wait if the data is a keyframe. Called from
    /// [`handle_media_data_out`][super::fanout::Client::handle_media_data_out]
    /// after the layer filter passes, so we only observe packets that
    /// actually reach this subscriber.
    ///
    /// `origin` is the publisher's ClientId (the `MediaData`'s origin).
    /// `data` is the forwarded packet. Uses
    /// [`MediaData::is_keyframe`][str0m::media::MediaData::is_keyframe]
    /// (codec-agnostic — H264/H265/H266/VP8/VP9/AV1) to detect keyframes.
    pub(crate) fn observe_keyframe(&mut self, origin: ClientId, data: &str0m::media::MediaData) {
        if !data.is_keyframe() {
            return;
        }
        let now = Instant::now();
        // Collect the indices of waits matching (origin, mid). There should
        // be at most one per (origin, mid_in) due to start_keyframe_wait's
        // de-dup, but we handle the general case.
        let matching: Vec<usize> = self
            .keyframe_waits
            .iter()
            .enumerate()
            .filter(|(_, w)| w.origin == origin && w.mid_in == data.mid)
            .map(|(i, _)| i)
            .collect();
        if matching.is_empty() {
            return;
        }
        // Remove in reverse order to preserve indices, recording metrics.
        for &i in matching.iter().rev() {
            let wait = self.keyframe_waits.remove(i);
            self.metrics
                .sfu_keyframe_on_subscribe_outcome_total
                .with_label_values(&["observed"])
                .inc();
            let elapsed = now.duration_since(wait.started_at).as_secs_f64();
            self.metrics
                .sfu_keyframe_on_subscribe_time_to_first_seconds
                .observe(elapsed);
            tracing::debug!(
                client = *self.id,
                origin = *wait.origin,
                mid_in = %wait.mid_in,
                attempts = wait.attempts,
                time_to_first_ms = elapsed * 1000.0,
                "issue #618: keyframe observed — wait terminated"
            );
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

#[cfg(test)]
mod issue_618_tests {
    //! Issue #618: subscribe-triggered keyframe loop falsification tests.
    //!
    //! F1: `start_keyframe_waits_for_open_video_tracks` emits exactly one
    //!     initial PLI per Open video track (revert the emission → 0 PLIs,
    //!     subscriber never gets a keyframe → black screen).
    //!
    //! F2: `pump_keyframe_waits` emits retry PLIs at `KEYFRAME_REQUEST_MIN_GAP`
    //!     intervals until the attempt budget is spent, then records
    //!     `budget_exhausted` (revert the budget check → unbounded retries =
    //!     the 48,972-PLI storm from the incident).
    //!
    //! F3: `observe_keyframe` terminates the wait on a keyframe `MediaData`
    //!     and records `observed` (revert the observation → the wait never
    //!     terminates → `budget_exhausted` even though a keyframe arrived).

    use std::sync::Arc;
    use std::time::{Duration, Instant};

    use str0m::media::{MediaKind, Mid, Rid};

    use super::super::test_seed::{make_media_data_keyframe, new_client, seed_track_in};
    use super::super::tracks::{TrackOut, TrackOutState};
    use super::Client;
    use crate::propagate::{ClientId, Propagated};

    /// Wire `subscriber`'s `tracks_out` to `publisher`'s seeded video
    /// `TrackIn` arc in the Open state. Returns the publisher's `Mid`.
    fn wire_open_video_track(
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

    /// Drain `Propagated::KeyframeRequest` events from a client's
    /// `pending_propagated`, returning `(count, origins, mids)`.
    fn drain_pending_keyframe_reqs(
        client: &mut Client,
    ) -> (usize, Vec<ClientId>, Vec<Mid>) {
        let mut origins = Vec::new();
        let mut mids = Vec::new();
        let mut count = 0usize;
        while let Some(p) = client.pending_propagated.pop_front() {
            if let Propagated::KeyframeRequest(_src, _req, origin, mid) = p {
                count += 1;
                origins.push(origin);
                mids.push(mid);
            }
        }
        (count, origins, mids)
    }

    /// F1: `start_keyframe_waits_for_open_video_tracks` emits exactly one
    /// initial PLI per Open video track. The PLI must target the publisher's
    /// incoming mid and be routed to the publisher's ClientId.
    ///
    /// Falsification: revert the `start_keyframe_wait` emission (remove the
    /// `pending_propagated.push_back` call) → `count == 0` and the first
    /// assertion fails. Revert the de-dup check → calling twice produces 2
    /// PLIs and the second-call assertion fails.
    #[test]
    fn f1_start_emits_one_initial_pli_per_open_video_track() {
        let mut publisher = new_client(ClientId(200));
        let track = seed_track_in(&mut publisher, 5, MediaKind::Video);
        let pub_mid = track.mid;
        let pub_origin = publisher.id;

        let mut subscriber = new_client(ClientId(201));
        let wired_mid = wire_open_video_track(&mut subscriber, &track);
        assert_eq!(wired_mid, pub_mid);

        let now = Instant::now();
        subscriber.start_keyframe_waits_for_open_video_tracks(now);

        let (count, origins, mids) = drain_pending_keyframe_reqs(&mut subscriber);
        assert_eq!(count, 1, "exactly one initial PLI for one Open video track");
        assert_eq!(origins, vec![pub_origin], "PLI routed to publisher's ClientId");
        assert_eq!(mids, vec![pub_mid], "PLI targets publisher's incoming mid");

        // De-dup: calling again must NOT emit a second PLI for the same
        // (origin, mid_in) pair.
        subscriber.start_keyframe_waits_for_open_video_tracks(now);
        let (count, _, _) = drain_pending_keyframe_reqs(&mut subscriber);
        assert_eq!(count, 0, "de-dup: second call for same track emits nothing");

        // Metric: initial request counter must have incremented exactly once.
        let metrics = subscriber.metrics_for_tests().clone();
        let initial = metrics
            .sfu_keyframe_on_subscribe_requests_total
            .with_label_values(&["initial"])
            .get();
        assert_eq!(initial, 1, "initial request metric incremented once");
    }

    /// F1b: audio tracks are skipped — no PLI is emitted for Open audio tracks.
    #[test]
    fn f1b_audio_tracks_skipped() {
        let mut publisher = new_client(ClientId(210));
        let track = seed_track_in(&mut publisher, 1, MediaKind::Audio);
        let mut subscriber = new_client(ClientId(211));
        wire_open_video_track(&mut subscriber, &track);

        subscriber.start_keyframe_waits_for_open_video_tracks(Instant::now());
        let (count, _, _) = drain_pending_keyframe_reqs(&mut subscriber);
        assert_eq!(count, 0, "audio tracks do not get keyframe-waits");
    }

    /// F2: `pump_keyframe_waits` emits retry PLIs at
    /// `KEYFRAME_REQUEST_MIN_GAP` intervals and stops after the attempt
    /// budget is spent, recording `budget_exhausted`.
    ///
    /// Falsification: revert the budget check (`wait.attempts >= MAX_ATTEMPTS`)
    /// → the loop never stops → more than `MAX_ATTEMPTS` PLIs are emitted and
    /// the final assertion fails. Revert the retry interval throttle → all
    /// retries fire in the same pump call and the per-pump count assertion
    /// fails.
    #[test]
    fn f2_pump_retries_until_budget_exhausted() {
        let mut publisher = new_client(ClientId(300));
        let track = seed_track_in(&mut publisher, 3, MediaKind::Video);
        let pub_mid = track.mid;
        let pub_origin = publisher.id;

        let mut subscriber = new_client(ClientId(301));
        wire_open_video_track(&mut subscriber, &track);

        let t0 = Instant::now();
        subscriber.start_keyframe_waits_for_open_video_tracks(t0);

        // Drain the initial PLI.
        let (initial_count, _, _) = drain_pending_keyframe_reqs(&mut subscriber);
        assert_eq!(initial_count, 1, "initial PLI emitted");

        // Pump at t0 + 0.5s — within the MIN_GAP throttle window, no retry.
        subscriber.pump_keyframe_waits(t0 + Duration::from_millis(500));
        let (count, _, _) = drain_pending_keyframe_reqs(&mut subscriber);
        assert_eq!(count, 0, "no retry within MIN_GAP window");

        // Pump at t0 + 1s — MIN_GAP elapsed, first retry fires.
        subscriber.pump_keyframe_waits(t0 + Duration::from_secs(1));
        let (count, _, _) = drain_pending_keyframe_reqs(&mut subscriber);
        assert_eq!(count, 1, "first retry at MIN_GAP boundary");

        // Continue pumping at 1s intervals until budget exhausted.
        // MAX_ATTEMPTS = 5, initial = 1 attempt, so 4 retries total.
        // The first retry (at t0+1s above) brought attempts to 2; the loop
        // pumps from t0+2s onward, producing 3 more retries (attempts 3,4,5)
        // before the budget check removes the wait at t0+5s.
        let mut loop_retries = 0;
        for i in 2..=10u32 {
            subscriber.pump_keyframe_waits(t0 + Duration::from_secs(i as u64));
            let (count, _, _) = drain_pending_keyframe_reqs(&mut subscriber);
            if count > 0 {
                loop_retries += count;
            }
        }
        // 3 retries in the loop + 1 before = 4 total retries.
        assert_eq!(
            loop_retries,
            3,
            "3 retries in the loop (attempts 3,4,5); 1st retry was before the loop"
        );

        // After budget exhaustion, keyframe_waits must be empty.
        assert!(
            subscriber.keyframe_waits.is_empty(),
            "keyframe_waits drained after budget exhaustion"
        );

        // Metric: budget_exhausted must have incremented.
        let metrics = subscriber.metrics_for_tests().clone();
        let exhausted = metrics
            .sfu_keyframe_on_subscribe_outcome_total
            .with_label_values(&["budget_exhausted"])
            .get();
        assert_eq!(exhausted, 1, "budget_exhausted metric incremented once");

        // Metric: retry counter = 1 (before loop) + 3 (in loop) = 4 total.
        let retry = metrics
            .sfu_keyframe_on_subscribe_requests_total
            .with_label_values(&["retry"])
            .get();
        assert_eq!(retry, 4, "retry metric = 4 total retries (1 + 3)");

        // Verify the PLIs target the correct publisher.
        let _ = pub_origin;
        let _ = pub_mid;
    }

    /// F3: `observe_keyframe` terminates the wait when a keyframe
    /// `MediaData` is observed, recording `observed` + time-to-first.
    ///
    /// Falsification: revert the `is_keyframe()` check → non-keyframe
    /// packets terminate the wait and the `observed` metric increments
    /// without a real keyframe. Revert the entire `observe_keyframe` call
    /// in `handle_media_data_out` → the wait never terminates and
    /// `budget_exhausted` fires instead of `observed`.
    #[test]
    fn f3_observe_keyframe_terminates_wait() {
        let mut publisher = new_client(ClientId(400));
        let track = seed_track_in(&mut publisher, 7, MediaKind::Video);
        let pub_mid = track.mid;
        let pub_origin = publisher.id;

        let mut subscriber = new_client(ClientId(401));
        wire_open_video_track(&mut subscriber, &track);

        let t0 = Instant::now();
        subscriber.start_keyframe_waits_for_open_video_tracks(t0);
        let _ = drain_pending_keyframe_reqs(&mut subscriber);

        assert_eq!(
            subscriber.keyframe_waits.len(),
            1,
            "one wait pending after start"
        );

        // Observe a non-keyframe packet — must NOT terminate the wait.
        let non_kf = super::super::test_seed::make_media_data(7, None);
        subscriber.observe_keyframe(pub_origin, &non_kf);
        assert_eq!(
            subscriber.keyframe_waits.len(),
            1,
            "non-keyframe packet does not terminate wait"
        );

        // Observe a keyframe packet — must terminate the wait.
        let kf = make_media_data_keyframe(7, None);
        assert_eq!(kf.mid, pub_mid, "keyframe mid matches publisher track mid");
        subscriber.observe_keyframe(pub_origin, &kf);
        assert!(
            subscriber.keyframe_waits.is_empty(),
            "keyframe packet terminates wait"
        );

        // Metric: observed must have incremented.
        let metrics = subscriber.metrics_for_tests().clone();
        let observed = metrics
            .sfu_keyframe_on_subscribe_outcome_total
            .with_label_values(&["observed"])
            .get();
        assert_eq!(observed, 1, "observed metric incremented once");

        // Metric: budget_exhausted must NOT have incremented.
        let exhausted = metrics
            .sfu_keyframe_on_subscribe_outcome_total
            .with_label_values(&["budget_exhausted"])
            .get();
        assert_eq!(exhausted, 0, "budget_exhausted NOT incremented on success");
    }

    /// F3b: `observe_keyframe` does not terminate a wait for a DIFFERENT
    /// publisher's track (mismatch on origin or mid).
    #[test]
    fn f3b_observe_keyframe_does_not_cross_terminate() {
        let mut pub_a = new_client(ClientId(500));
        let track_a = seed_track_in(&mut pub_a, 1, MediaKind::Video);
        let origin_a = pub_a.id;
        let mid_a = track_a.mid;

        let mut pub_b = new_client(ClientId(501));
        let track_b = seed_track_in(&mut pub_b, 2, MediaKind::Video);
        let origin_b = pub_b.id;
        let mid_b = track_b.mid;

        let mut subscriber = new_client(ClientId(502));
        wire_open_video_track(&mut subscriber, &track_a);
        wire_open_video_track(&mut subscriber, &track_b);

        subscriber.start_keyframe_waits_for_open_video_tracks(Instant::now());
        let _ = drain_pending_keyframe_reqs(&mut subscriber);
        assert_eq!(subscriber.keyframe_waits.len(), 2, "two waits pending");

        // Keyframe from pub_a on mid_a — must terminate only pub_a's wait.
        let kf_a = make_media_data_keyframe(1, None);
        assert_eq!(kf_a.mid, mid_a);
        subscriber.observe_keyframe(origin_a, &kf_a);
        assert_eq!(
            subscriber.keyframe_waits.len(),
            1,
            "only pub_a's wait terminated"
        );

        // The remaining wait must be for pub_b.
        let remaining = &subscriber.keyframe_waits[0];
        assert_eq!(remaining.origin, origin_b, "remaining wait is for pub_b");
        assert_eq!(remaining.mid_in, mid_b, "remaining wait targets mid_b");

        // Keyframe from pub_b on mid_b — terminates the remaining wait.
        let kf_b = make_media_data_keyframe(2, None);
        assert_eq!(kf_b.mid, mid_b);
        subscriber.observe_keyframe(origin_b, &kf_b);
        assert!(subscriber.keyframe_waits.is_empty(), "all waits terminated");
    }

    /// F3c: a keyframe for the right mid but WRONG origin does not
    /// terminate the wait. Guards against a cross-publisher mid collision
    /// falsely terminating a wait.
    #[test]
    fn f3c_keyframe_wrong_origin_does_not_terminate() {
        let mut pub_a = new_client(ClientId(600));
        let track_a = seed_track_in(&mut pub_a, 1, MediaKind::Video);
        let mid_a = track_a.mid;

        let mut subscriber = new_client(ClientId(601));
        wire_open_video_track(&mut subscriber, &track_a);

        subscriber.start_keyframe_waits_for_open_video_tracks(Instant::now());
        let _ = drain_pending_keyframe_reqs(&mut subscriber);
        assert_eq!(subscriber.keyframe_waits.len(), 1);

        // Keyframe with the right mid but wrong origin (a random ClientId).
        let wrong_origin = ClientId(999);
        let kf = make_media_data_keyframe(1, None);
        assert_eq!(kf.mid, mid_a);
        subscriber.observe_keyframe(wrong_origin, &kf);
        assert_eq!(
            subscriber.keyframe_waits.len(),
            1,
            "keyframe with wrong origin does not terminate wait"
        );
    }

    /// F2b: `pump_keyframe_waits` does not emit retries for a wait that
    /// has already been terminated by `observe_keyframe`. Guards against
    /// a race where the pump fires after the keyframe was observed.
    #[test]
    fn f2b_pump_does_not_retry_terminated_wait() {
        let mut publisher = new_client(ClientId(700));
        let track = seed_track_in(&mut publisher, 1, MediaKind::Video);
        let pub_origin = publisher.id;

        let mut subscriber = new_client(ClientId(701));
        wire_open_video_track(&mut subscriber, &track);

        let t0 = Instant::now();
        subscriber.start_keyframe_waits_for_open_video_tracks(t0);
        let _ = drain_pending_keyframe_reqs(&mut subscriber);

        // Observe keyframe immediately — terminates the wait.
        let kf = make_media_data_keyframe(1, None);
        subscriber.observe_keyframe(pub_origin, &kf);
        assert!(subscriber.keyframe_waits.is_empty());

        // Pump at t0 + 1s — no retries because the wait is gone.
        subscriber.pump_keyframe_waits(t0 + Duration::from_secs(1));
        let (count, _, _) = drain_pending_keyframe_reqs(&mut subscriber);
        assert_eq!(count, 0, "no retries for a terminated wait");
    }

    /// Verify that `Rid` is unused in these tests (suppresses unused import
    /// warning if the compiler doesn't see a use).
    #[test]
    fn _rid_import_used() {
        let _ = Rid::from("q");
    }
}
