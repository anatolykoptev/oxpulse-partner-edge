//! Cross-client propagated events.
//!
//! Ported from [`str0m/examples/chat.rs`][chat] `enum Propagated`. Kept
//! to a pure data-types module so `client.rs` and `registry.rs` can
//! depend on it without circling back through each other.
//!
//! Only events that fan out between clients live here. Outbound UDP
//! `Transmit`s are held on the `Client` and drained by the registry —
//! they never propagate, so modelling them here would be misleading.
//!
//! [chat]: https://github.com/algesten/str0m/blob/0.18.0/examples/chat.rs

use std::ops::Deref;
use std::sync::Weak;
use std::time::Instant;

use str0m::media::{KeyframeRequest, MediaData, Mid};

use crate::client::TrackIn;

/// Monotonic per-process identifier for a connected peer. Chat.rs uses
/// the exact same shape.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ClientId(pub u64);

impl Deref for ClientId {
    type Target = u64;
    fn deref(&self) -> &Self::Target {
        &self.0
    }
}

/// Events the registry propagates between clients. `Noop` / `Timeout`
/// carry no client id and are consumed inside the registry's poll loop.
#[allow(clippy::large_enum_variant)]
#[derive(Debug)]
pub enum Propagated {
    /// Nothing to do.
    Noop,

    /// Client's poll returned this as its next wake-up deadline.
    Timeout(Instant),

    /// A new incoming track is open on the originating client and
    /// should be advertised to every other client.
    TrackOpen(ClientId, Weak<TrackIn>),

    /// Media payload the originating client received, to be forwarded
    /// to every other client.
    MediaData(ClientId, MediaData),

    /// A keyframe request that must reach the origin of the outgoing
    /// track. `origin_client` is the *source* client the request is
    /// aimed at; `origin_mid` is the mid on that source.
    KeyframeRequest(ClientId, KeyframeRequest, ClientId, Mid),

    /// Dominant-speaker election changed. Emitted by the registry's
    /// periodic ASO tick. The `peer_id` is a bare `u64` (mediasoup's
    /// observer API shape) rather than a `ClientId`, so the fanout
    /// skip-self logic compares against `*client.id` inline — see
    /// [`crate::fanout::fanout`] and
    /// [`crate::client::fanout::Client::handle_active_speaker_changed`].
    /// `confidence` is the C2 margin from `rust-dominant-speaker` v0.3
    /// (`SpeakerChange::c2_margin`); `0.0` for bootstrap elections.
    ActiveSpeakerChanged { peer_id: u64, confidence: f64 },

    /// str0m's own GCC estimate for this subscriber's downlink, in
    /// bits per second. Sunk into
    /// [`oxpulse_sfu_kit::bwe::estimator::BandwidthEstimator::record_native_estimate`]
    /// as a ceiling on our own estimate. Never fans out to other
    /// clients — consumed entirely inside the registry.
    BandwidthEstimate(ClientId, u64),

    /// Browser-reported bandwidth budget from DC id:2 (`sfu-budget`,
    /// negotiated, unordered). Payload is `{ type: "budget", bps: N }`.
    /// Sunk into
    /// [`oxpulse_sfu_kit::bwe::estimator::BandwidthEstimator::record_client_hint`]
    /// as an additional ceiling. Never fans out to other clients.
    ClientBudgetHint(ClientId, u64),
}

impl Propagated {
    /// Which client produced the event, if any. Used by the registry
    /// to skip the originator during fanout.
    pub fn client_id(&self) -> Option<ClientId> {
        match self {
            Propagated::TrackOpen(c, _)
            | Propagated::MediaData(c, _)
            | Propagated::KeyframeRequest(c, _, _, _)
            | Propagated::BandwidthEstimate(c, _)
            | Propagated::ClientBudgetHint(c, _) => Some(*c),
            // ActiveSpeakerChanged has no originating ClientId — the
            // fanout skip rule uses `peer_id == *client.id` directly.
            Propagated::Noop | Propagated::Timeout(_) | Propagated::ActiveSpeakerChanged { .. } => {
                None
            }
        }
    }
}
