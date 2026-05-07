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

    /// Top-K speakers by medium-window score, broadcast to all clients on
    /// DC id:3 (`sfu-active-speaker`) on every 300ms ASO tick. Payload:
    /// `{"type":"top_speakers","peerIds":[<u64>, ...]}`.
    TopSpeakers(Vec<u64>),

    /// Codec capability hint emitted when a peer joins. Signals that this
    /// SFU supports Opus RED and DRED. Application-level — the SFU fanout
    /// logs it and does nothing else.
    AudioCodecHint {
        peer_id: u64,
        opus_red: bool,
        opus_dred: bool,
    },

    /// Subscriber requested a maximum RFC 9626 VFM temporal layer.
    /// Payload: `{ "type": "max_temporal_layer", "vfm": N }`.
    /// Consumed in the registry; calls `Client::set_max_vfm_temporal_layer`
    /// on the subscriber. Never fans out to other clients.
    #[cfg(feature = "vfm")]
    VfmLayerCap(ClientId, u8),

    /// Dynacast hint: the maximum simulcast layer any subscriber of this
    /// publisher currently wants. Emitted by
    /// `Registry::emit_publisher_layer_hints` on the 300 ms speaker tick.
    /// Applications may forward this to the publisher via signalling to let
    /// it stop encoding unneeded layers.
    PublisherLayerHint {
        /// The publisher whose encoding may be reduced.
        publisher_id: ClientId,
        /// Highest simulcast layer any subscriber currently wants.
        max_rid: str0m::media::Rid,
    },

    /// Mark this client as a relay connection from an upstream SFU edge.
    /// Received via DataChannel (`relay_source` message type) from the relay
    /// client itself. `upstream_url` identifies the upstream SFU for logging
    /// and routing. Consumed inside `Registry::fanout_pending`; never fans out.
    MarkRelaySource(ClientId, String),

    /// A keyframe request that originated on a relay-connected track and must
    /// be forwarded upstream to the source SFU rather than sent back to the
    /// relay connection. Consumed by the signalling layer; never fans out
    /// peer-to-peer inside this SFU instance.
    UpstreamKeyframeRequest {
        source_relay_id: ClientId,
        req: str0m::media::KeyframeRequest,
        source_mid: str0m::media::Mid,
    },

    /// A Dynacast (simulcast layer) hint that must be forwarded upstream to
    /// the source SFU so it can adjust the relay's send layer. Consumed by
    /// the signalling layer; never fans out peer-to-peer.
    PublisherLayerHintForUpstream {
        publisher_relay_id: ClientId,
        max_rid: str0m::media::Rid,
    },

    /// Phase 2b: payload received on the pre-negotiated `chat-data` DC
    /// (id:4, ordered, reliable). Fanned out by [`crate::fanout::fanout`]
    /// to every other client via `Client::handle_chat_data_out`. Server
    /// terminates the SCTP association and re-emits per-peer (LiveKit /
    /// Mediasoup pattern); raw chunk relay across associations is
    /// architecturally impossible. The first tuple element is the origin
    /// client (used for skip-self in fanout); the second is the opaque
    /// AEAD-sealed envelope from the client wire codec.
    ChatData(ClientId, Vec<u8>),

    /// Phase 2b: payload received on the pre-negotiated `chat-ctrl` DC
    /// (id:5, unordered, `MaxRetransmits{0}`). Same fanout shape as
    /// [`Propagated::ChatData`] but routed via `handle_chat_ctrl_out`.
    /// `MaxRetransmits{0}` semantics on str0m 0.18 (`src/sctp/mod.rs:187-200`)
    /// — best-effort drop-on-loss on each leg, app-TTL drop is the
    /// secondary safety net.
    ChatCtrl(ClientId, Vec<u8>),

    /// Phase 8 T10: payload received on the pre-negotiated `voice` DC
    /// (id:6, unordered, `MaxPacketLifetime{200ms}`). Mediasoup-pattern
    /// relay: inbound voice frame from sender SCTP → broadcast to all
    /// subscribers' outbound voice DCs. Skip-self and DC-not-open guards
    /// mirror the chat-data relay path.
    VoiceData(ClientId, Vec<u8>),
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
            | Propagated::ClientBudgetHint(c, _)
            | Propagated::ChatData(c, _)
            | Propagated::ChatCtrl(c, _)
            | Propagated::VoiceData(c, _) => Some(*c),
            #[cfg(feature = "vfm")]
            Propagated::VfmLayerCap(c, _) => Some(*c),
            Propagated::PublisherLayerHint { publisher_id, .. } => Some(*publisher_id),
            // ActiveSpeakerChanged has no originating ClientId — the
            // fanout skip rule uses `peer_id == *client.id` directly.
            // TopSpeakers and AudioCodecHint are broadcast / application-level —
            // they have no skip-origin semantics.
            Propagated::Noop
            | Propagated::Timeout(_)
            | Propagated::ActiveSpeakerChanged { .. }
            | Propagated::TopSpeakers(_)
            | Propagated::AudioCodecHint { .. }
            // Relay-source events are consumed inside the registry/signalling
            // layer, never fanned out peer-to-peer.
            | Propagated::MarkRelaySource(..)
            | Propagated::UpstreamKeyframeRequest { .. }
            | Propagated::PublisherLayerHintForUpstream { .. } => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chat_data_client_id_returns_origin() {
        let cid = ClientId(7);
        let p = Propagated::ChatData(cid, b"hello".to_vec());
        assert_eq!(p.client_id(), Some(cid));
    }

    #[test]
    fn chat_ctrl_client_id_returns_origin() {
        let cid = ClientId(11);
        let p = Propagated::ChatCtrl(cid, b"typing".to_vec());
        assert_eq!(p.client_id(), Some(cid));
    }
}
