//! Per-peer state machine wrapping a str0m [`Rtc`] instance. Ported
//! from [`str0m/examples/chat.rs`][chat] minus SDP signaling (M2) and
//! plus per-subscriber simulcast layer selection (M1.3; see [`layer`]).
//! Outbound UDP is parked on `pending_out`; the registry drains it
//! between polls (str0m is sync, runloop is tokio). Submodules:
//! [`keyframe`], [`fanout`], [`layer`], [`tracks`], [`test_seed`],
//! [`dispatch`] (str0m Output/Event routing),
//! [`dc`] (M5.4.1 DC id:2 budget-hint ingestion).
//!
//! [chat]: https://github.com/algesten/str0m/blob/0.18.0/examples/chat.rs

use std::collections::{HashSet, VecDeque};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Weak};

use str0m::media::Rid;
use str0m::{Input, Rtc};

use oxpulse_sfu_kit::ClientOrigin;

use crate::metrics::SfuMetrics;
use crate::propagate::ClientId;

pub mod construct;
pub mod dc;
pub mod dispatch;
pub mod fanout;
pub mod keyframe;
pub mod layer;
#[cfg(any(test, feature = "test-utils"))]
pub mod test_seed;
pub mod tracks;

pub use tracks::TrackIn;
use tracks::{TrackInEntry, TrackOut, TrackOutState};

/// Outbound UDP datagram produced by a client's str0m state.
pub type Transmit = str0m::net::Transmit;

#[derive(Debug)]
pub struct Client {
    pub id: ClientId,
    pub(crate) rtc: Rtc,
    pub(crate) tracks_in: Vec<TrackInEntry>,
    pub(crate) tracks_out: Vec<TrackOut>,
    /// Last rid actually forwarded to this peer. `None` = no simulcast yet.
    pub(crate) chosen_rid: Option<Rid>,
    /// Preferred simulcast layer (default [`layer::LOW`]).
    pub(crate) desired_layer: Rid,
    /// Simulcast RIDs this peer has been observed *publishing* —
    /// populated on every incoming `MediaData` in dispatch's
    /// `track_in_media`. Consumed by
    /// [`crate::registry::Registry::update_pacer_layers`] as the
    /// "active simulcast layers" set for pacer input. Without this, a
    /// screenshare publisher sending only `q` would still be treated as
    /// if `[q, h, f]` were available and subscribers with spare budget
    /// would ask for `f` — every incoming `q` packet then gets dropped
    /// by the M1.3 layer filter. Empty ⇒ bootstrap / non-simulcast;
    /// callers treat empty as "full ladder available".
    pub(crate) active_rids: HashSet<Rid>,
    /// Outbound datagrams pending flush by the registry.
    pub(crate) pending_out: VecDeque<Transmit>,
    /// Prometheus handles (M1.5). Shared with Registry.
    pub(crate) metrics: Arc<SfuMetrics>,
    /// Post-layer-filter forwarded-media counter (read by integration tests).
    pub(crate) delivered_media: AtomicU64,
    /// Test-only: count of `ActiveSpeakerChanged` deliveries (skip-self check).
    #[cfg(any(test, feature = "test-utils"))]
    pub(crate) delivered_active_speaker: AtomicU64,
    /// Pre-negotiated DC id:3 (`sfu-active-speaker`). Allocated at
    /// construction via `direct_api().create_data_channel(...)` with
    /// `negotiated: Some(3)` so the client side's
    /// `pc.createDataChannel('sfu-active-speaker', { negotiated: true, id: 3 })`
    /// lines up. We push `{"type":"active_speaker","peerId":<u64>}` whenever
    /// the room-level `ActiveSpeakerChanged` fires.
    pub(crate) active_speaker_cid: str0m::channel::ChannelId,
    /// Connection origin — [`oxpulse_sfu_kit::ClientOrigin::Local`] for
    /// direct browser peers; [`oxpulse_sfu_kit::ClientOrigin::RelayFromSfu`]
    /// for cascade relay nodes. Set via [`Client::set_origin`] after `insert()`
    /// when the DC relay_source handshake is confirmed. Governs speaker
    /// election exclusion and upstream keyframe routing.
    pub(crate) origin: ClientOrigin,
    /// Shared secret for verifying relay_source room tokens issued by oxpulse-chat.
    /// When set, relay_source DataChannel messages MUST include a verified roomToken.
    /// Loaded from SIGNALING_SFU_SECRET at startup.
    pub(crate) relay_auth_secret: Option<Arc<[u8]>>,
    /// RFC 9626 VFM temporal-layer cap for this subscriber.
    /// Packets at a temporal layer higher than this are dropped before
    /// forwarding. `u8::MAX` means "no cap" (forward all layers).
    #[cfg(feature = "vfm")]
    pub(crate) max_vfm_temporal_layer: u8,
}

impl Client {
    /// This subscriber's desired simulcast layer.
    pub fn desired_layer(&self) -> Rid {
        self.desired_layer
    }

    /// Whether this client is an upstream SFU relay (connected as a cascade
    /// relay node, not a direct browser/device). Relay clients are excluded
    /// from speaker election and keyframe requests are routed upstream rather
    /// than back to the relay connection.
    pub fn is_relay(&self) -> bool {
        matches!(self.origin, ClientOrigin::RelayFromSfu(_))
    }

    /// Set the connection origin. Call immediately after `Registry::insert`
    /// when the relay handshake is confirmed via DataChannel. Relay clients are
    /// retroactively removed from speaker detection via
    /// `Registry::mark_relay_source`.
    pub fn set_origin(&mut self, origin: ClientOrigin) {
        self.origin = origin;
    }

    /// Set this subscriber's desired simulcast layer. Takes effect on
    /// the next forwarded packet; no SDP renegotiation required.
    pub fn set_desired_layer(&mut self, rid: Rid) {
        self.desired_layer = rid;
        // Invalidate the cached layer so keyframe requests don't target
        // the old RID until we actually forward a packet in the new layer.
        self.chosen_rid = None;
    }

    /// Set the RFC 9626 VFM temporal-layer cap for this subscriber.
    /// Packets at a temporal layer higher than `max` will be dropped by the
    /// VFM filter before forwarding. Pass `u8::MAX` to disable the cap.
    #[cfg(feature = "vfm")]
    pub fn set_max_vfm_temporal_layer(&mut self, max: u8) {
        self.max_vfm_temporal_layer = max;
    }

    /// Simulcast RIDs the peer has been observed publishing. Built up
    /// incrementally by dispatch's `track_in_media`; empty until the
    /// first video packet lands. Callers treating this as the "available
    /// layers" input to the pacer should fall back to the full ladder
    /// (`[LOW, MEDIUM, HIGH]`) when this returns empty — otherwise the
    /// pre-feedback boot window would pick audio-only / nothing.
    pub fn active_rids(&self) -> Vec<Rid> {
        self.active_rids.iter().copied().collect()
    }

    /// Forwarded `MediaData` events delivered to *this* client.
    pub fn delivered_media_count(&self) -> u64 {
        self.delivered_media.load(Ordering::Relaxed)
    }

    /// `ActiveSpeakerChanged` events delivered to *this* client.
    /// Test-only, gated with `delivered_active_speaker` itself.
    #[cfg(any(test, feature = "test-utils"))]
    pub fn delivered_active_speaker_count(&self) -> u64 {
        self.delivered_active_speaker.load(Ordering::Relaxed)
    }

    pub fn is_alive(&self) -> bool {
        self.rtc.is_alive()
    }

    /// str0m demux probe — see chat.rs.
    pub fn accepts(&self, input: &Input) -> bool {
        self.rtc.accepts(input)
    }

    /// Feed a demuxed UDP datagram (or timeout) into str0m.
    pub fn handle_input(&mut self, input: Input) {
        if !self.rtc.is_alive() {
            return;
        }
        if let Err(e) = self.rtc.handle_input(input) {
            tracing::warn!(client = *self.id, error = ?e, "client disconnected on handle_input");
            self.rtc.disconnect();
        }
    }

    /// Register that another client opened a track we should mirror
    /// out to this peer.
    pub fn handle_track_open(&mut self, track_in: Weak<TrackIn>) {
        self.tracks_out.push(TrackOut {
            track_in,
            state: TrackOutState::ToOpen,
        });
    }

    /// Drain queued outbound datagrams. Registry calls this after each
    /// poll cycle to hand bytes to the tokio socket.
    pub fn drain_pending_out(&mut self) -> std::collections::vec_deque::Drain<'_, Transmit> {
        self.pending_out.drain(..)
    }
}
