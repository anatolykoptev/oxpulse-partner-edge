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

// `Negotiating` and `Open` are unused in M1.2 because SDP renegotiation
// lives in the signaling layer (M2); `TrackOut::mid` already knows how
// to drop out of `ToOpen`. Keeping the variants so M2 can flip state
// without a churn commit.
#[allow(dead_code)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum TrackOutState {
    ToOpen,
    Negotiating(Mid),
    Open(Mid),
}

#[derive(Debug)]
pub(crate) struct TrackOut {
    pub track_in: Weak<TrackIn>,
    pub state: TrackOutState,
}

impl TrackOut {
    pub(crate) fn mid(&self) -> Option<Mid> {
        match self.state {
            TrackOutState::ToOpen => None,
            TrackOutState::Negotiating(m) | TrackOutState::Open(m) => Some(m),
        }
    }
}
