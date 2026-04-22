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
        let Some(mut writer) = self.rtc.writer(mid_in) else {
            return;
        };
        if let Err(e) = writer.request_keyframe(req.rid, req.kind) {
            tracing::info!(client = *self.id, error = ?e, "request_keyframe failed");
        }
    }
}
