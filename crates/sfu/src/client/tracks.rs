//! Track-side data types for the SFU.
//!
//! These describe what a peer is publishing (`TrackIn*`) or receiving
//! from someone else (`TrackOut*`). Kept in their own module so
//! `client/mod.rs` can focus on the `Rtc`-driven state machine.

use std::sync::{Arc, Weak};
use std::time::Instant;

use str0m::media::{MediaKind, Mid};

use crate::propagate::ClientId;

/// An incoming track advertised by a client. The originating client
/// owns the strong `Arc`, every other client keeps a `Weak`.
#[derive(Debug)]
pub struct TrackIn {
    pub origin: ClientId,
    pub mid: Mid,
    pub kind: MediaKind,
}

#[derive(Debug)]
pub(crate) struct TrackInEntry {
    pub id: Arc<TrackIn>,
    pub last_keyframe_request: Option<Instant>,
}

/// State machine for an outbound (subscriber-side) track entry.
///
/// ## Transitions (Phase J — M2 SDP renegotiation)
///
/// ```text
/// ToOpen ──[handle_track_open, ws_msg_tx present]──► Negotiating(Mid)
///    ↑                                                      │
///    │  (ws_msg_tx absent — relay/test)            str0m Event::MediaAdded
///    │                                              { direction: SendOnly }
///    │                                                      │
///    └──────────────────────────────────── ◄──── Open(Mid) ◄┘
/// ```
///
/// `mid()` returns `None` for `ToOpen` (no m-line allocated yet) and for
/// `Negotiating` (offer sent, awaiting browser answer — not safe to write SRTP).
/// Returns `Some(mid)` only for `Open`. The `fanout.rs` `writer.write` path
/// is gated on `o.mid()` — packets only reach the wire once the state is `Open`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TrackOutState {
    /// m-line not yet allocated. Default state for relay/test clients that
    /// have no WS channel to drive renegotiation, or while waiting for a
    /// prior renegotiation to complete (queued).
    ToOpen,
    /// SDP offer sent to browser; waiting for the `answer-renegotiate` reply.
    Negotiating(Mid),
    /// m-line negotiated and open; `writer.write` is live.
    Open(Mid),
}

#[derive(Debug)]
pub struct TrackOut {
    pub track_in: Weak<TrackIn>,
    pub state: TrackOutState,
}

impl TrackOut {
    pub fn mid(&self) -> Option<Mid> {
        match self.state {
            TrackOutState::ToOpen | TrackOutState::Negotiating(_) => None,
            TrackOutState::Open(m) => Some(m),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    fn make_mid(tag: u8) -> Mid {
        Mid::from(&*format!("m{tag}"))
    }

    fn make_track_out(state: TrackOutState) -> TrackOut {
        let origin = crate::propagate::ClientId(99);
        let track_in = Arc::new(TrackIn {
            origin,
            mid: make_mid(1),
            kind: MediaKind::Video,
        });
        TrackOut {
            track_in: Arc::downgrade(&track_in),
            state,
        }
    }

    /// `mid()` returns `None` for `ToOpen` — no m-line allocated yet.
    #[test]
    fn mid_returns_none_for_to_open() {
        let o = make_track_out(TrackOutState::ToOpen);
        assert!(o.mid().is_none(), "ToOpen must return None from mid()");
    }

    /// `mid()` returns `None` for `Negotiating` — the m-line is allocated but
    /// not yet confirmed by the browser's answer. Fanout gates on `mid()` so
    /// un-answered tracks do not attempt SRTP writes.
    #[test]
    fn mid_returns_none_for_negotiating() {
        let mid = make_mid(7);
        let o = make_track_out(TrackOutState::Negotiating(mid));
        assert!(o.mid().is_none(), "Negotiating(mid) must return None from mid()");
    }

    /// `mid()` returns the wrapped Mid for `Open`.
    #[test]
    fn mid_returns_some_for_open() {
        let mid = make_mid(3);
        let o = make_track_out(TrackOutState::Open(mid));
        assert_eq!(o.mid(), Some(mid), "Open(mid) must return Some(mid)");
    }

    /// State transition: Negotiating(mid) → Open(mid) — the core M2 flip.
    /// Simulates what dispatch.rs does on Event::MediaAdded { direction: SendOnly }.
    #[test]
    fn track_out_state_transitions_to_open() {
        let mid = make_mid(5);
        let mut o = make_track_out(TrackOutState::Negotiating(mid));

        // Simulate the dispatch.rs transition.
        if let TrackOutState::Negotiating(neg_mid) = o.state {
            o.state = TrackOutState::Open(neg_mid);
        }

        assert_eq!(
            o.state,
            TrackOutState::Open(mid),
            "state must be Open(mid) after transition"
        );
        assert_eq!(
            o.mid(),
            Some(mid),
            "mid() must return Some(mid) after Open transition"
        );
    }

    /// Ensures `Negotiating(mid_a)` does NOT transition when `mid_b` matches —
    /// guards against off-by-one in the dispatch loop.
    #[test]
    fn state_transition_requires_matching_mid() {
        let mid_a = make_mid(1);
        let mid_b = make_mid(2);
        let mut o = make_track_out(TrackOutState::Negotiating(mid_a));

        // Simulate dispatch loop: only flip when the incoming mid matches.
        if let TrackOutState::Negotiating(neg_mid) = o.state {
            if neg_mid == mid_b {
                o.state = TrackOutState::Open(neg_mid);
            }
        }

        assert_eq!(
            o.state,
            TrackOutState::Negotiating(mid_a),
            "state must NOT change when mid_b != mid_a"
        );
    }
}
