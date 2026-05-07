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
use tokio::sync::oneshot;

use oxpulse_sfu_kit::ClientOrigin;

use crate::metrics::SfuMetrics;
use crate::propagate::ClientId;

/// Reason a per-connection session is being closed. Carried over the
/// `Client::close_signal` channel so the WS task can translate the
/// reason into the right WebSocket close code and tracing label.
///
/// Phase A Task A1 introduces the channel pipeline; today only
/// [`CloseReason::SessionReplaced`] actually fires (registry steal).
/// `PeerLeft` and `ServerShutdown` are reserved for future tasks that
/// need server-initiated closes for non-steal reasons.
#[derive(Debug, Clone, Copy)]
pub enum CloseReason {
    /// A newer `/sfu/ws` upgrade arrived for the same `(room_id, peer_id)`.
    /// The older session must release the slot — closes with WS code 4031.
    SessionReplaced,
    /// Reserved: server is gracefully removing this peer (e.g. moderator
    /// kick). Maps to WS close code 4002 today; will get its own code
    /// when the kick path lands.
    PeerLeft,
    /// Reserved: SFU process is shutting down. Maps to WS close code 1001
    /// (Going Away).
    ServerShutdown,
}

impl CloseReason {
    /// WS close code emitted on the wire when this reason fires.
    pub fn ws_close_code(self) -> u16 {
        match self {
            CloseReason::SessionReplaced => 4031,
            CloseReason::PeerLeft => 4002,
            CloseReason::ServerShutdown => 1001,
        }
    }

    /// Stable label used in metrics / tracing fields. Matches
    /// `client_ws_session_ended_total{close_code=...}` bucketing where
    /// applicable.
    pub fn as_label(self) -> &'static str {
        match self {
            CloseReason::SessionReplaced => "session_replaced",
            CloseReason::PeerLeft => "peer_left",
            CloseReason::ServerShutdown => "server_shutdown",
        }
    }
}

pub mod chat;
pub mod construct;
pub mod dc;
pub mod dispatch;
pub mod fanout;
pub mod keyframe;
pub mod layer;
#[cfg(any(test, feature = "test-utils"))]
pub mod test_seed;
pub mod tracks;
pub mod voice;

pub use voice::VOICE_FRAME_MAX_BYTES;

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
    /// Test-only: capture of the most-recently formatted active-speaker
    /// payload (the JSON string written to DC id:3) plus the [`Instant`] at
    /// which it was captured. Populated by [`fanout::handle_active_speaker_changed`]
    /// BEFORE the `rtc.channel()` lookup so unit tests can assert wire format
    /// without a live DTLS pipeline. Capture is parallel to (not a replacement
    /// for) the `delivered_active_speaker` counter; both fields share the same
    /// gate. The mutex is uncontended in tests (single-threaded fanout per
    /// registry) — chose [`std::sync::Mutex`] over `AtomicPtr` to keep the
    /// (String, Instant) tuple ergonomic and to mirror crate style. Released
    /// builds elide this field entirely.
    #[cfg(any(test, feature = "test-utils"))]
    pub(crate) last_active_speaker_payload: std::sync::Mutex<Option<(String, std::time::Instant)>>,
    /// Pre-negotiated DC id:3 (`sfu-active-speaker`). Allocated at
    /// construction via `direct_api().create_data_channel(...)` with
    /// `negotiated: Some(3)` so the client side's
    /// `pc.createDataChannel('sfu-active-speaker', { negotiated: true, id: 3 })`
    /// lines up. We push `{"type":"active_speaker","peerId":<u64>}` whenever
    /// the room-level `ActiveSpeakerChanged` fires.
    pub(crate) active_speaker_cid: str0m::channel::ChannelId,
    /// Phase 2b: pre-negotiated DC id:4 (`chat-data`,
    /// `negotiated: Some(4), ordered: true, reliability: Reliable`).
    /// SFU terminates the SCTP association and re-emits per-peer; this
    /// is the channel handle used by [`Client::handle_chat_data_out`] to
    /// write fanned-out chat envelopes to *this* subscriber.
    ///
    /// `None` until [`Client::with_chat_dcs`] is called. Cascade relay
    /// clients skip that step because `relay/client.rs` already pre-opens
    /// SCTP stream id 5 as `sfu-relay-source` on the outbound rtc, so a
    /// second create on id 5 would panic.
    pub(crate) chat_data_cid: Option<str0m::channel::ChannelId>,
    /// Phase 2b: pre-negotiated DC id:5 (`chat-ctrl`,
    /// `negotiated: Some(5), ordered: false, reliability:
    /// MaxRetransmits{0}`). Best-effort drop-on-loss leg for typing /
    /// presence / BWE-hint frames; HOL-isolated from `chat-data`.
    /// `None` until [`Client::with_chat_dcs`] is called.
    pub(crate) chat_ctrl_cid: Option<str0m::channel::ChannelId>,
    /// Phase 8 T10: pre-negotiated DC id:6 (`voice`,
    /// `negotiated: Some(6), ordered: false, reliability:
    /// MaxPacketLifetime{200ms}`). Unordered unreliable leg for voice
    /// relay frames (Mediasoup pattern). `None` until
    /// [`Client::with_voice_dc`] is called. Browser construction sites
    /// chain `Client::new(...).with_chat_dcs().with_voice_dc(200)`;
    /// relay clients skip it (no voice relay on cascade edges).
    pub(crate) voice_data_cid: Option<str0m::channel::ChannelId>,
    /// For outbound relay clients: the DC message to send once Event::Connected fires.
    /// Tuple: (dc_id, upstream_url, room_token). Cleared after send in dispatch.rs.
    /// None for browser clients and inbound relay clients (they *receive* relay_source).
    pub(crate) relay_source_pending: Option<(str0m::channel::ChannelId, String, String)>,
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
    /// Ed25519 public key (PEM) for verifying EdDSA-signed room tokens (Phase 2).
    /// When set, EdDSA verification is preferred over HS256.
    /// Loaded from SFU_SIGNING_PUBLIC_KEY at startup.
    pub(crate) relay_signing_pubkey: Option<Arc<String>>,
    /// RFC 9626 VFM temporal-layer cap for this subscriber.
    /// Packets at a temporal layer higher than this are dropped before
    /// forwarding. `u8::MAX` means "no cap" (forward all layers).
    #[cfg(feature = "vfm")]
    pub(crate) max_vfm_temporal_layer: u8,
    /// External peer identifier from the room JWT's `sub` claim. Used by
    /// [`crate::registry::Registry::insert`] to detect duplicate upgrades
    /// for the same `(room_id, peer_id)` and trigger a session steal
    /// (Phase A Task A1). `None` for relay-origin clients — they live in a
    /// separate identity namespace and are not subject to peer-id steal.
    pub(crate) external_peer_id: Option<u64>,
    /// Set by [`crate::registry::Registry::insert`] when this session must
    /// yield to a newer one for the same `external_peer_id`. The WS task
    /// selects on the receiver and translates the [`CloseReason`] into a
    /// WebSocket close frame. `None` for relay-origin clients (no WS task
    /// to wake up) and consumed (`take()`) on first send.
    pub(crate) close_signal: Option<oneshot::Sender<CloseReason>>,
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

    /// Test-only accessor for this client's `SfuMetrics` registry.
    /// Phase 2b integration tests sum per-client `chat_relay_*` series
    /// across the in-process Registry to verify fanout shape without a
    /// live DTLS / SCTP pipeline.
    #[cfg(any(test, feature = "test-utils"))]
    pub fn metrics_for_tests(&self) -> &Arc<SfuMetrics> {
        &self.metrics
    }

    /// `ActiveSpeakerChanged` events delivered to *this* client.
    /// Test-only, gated with `delivered_active_speaker` itself.
    #[cfg(any(test, feature = "test-utils"))]
    pub fn delivered_active_speaker_count(&self) -> u64 {
        self.delivered_active_speaker.load(Ordering::Relaxed)
    }

    /// Test-only: clone the most-recent `active_speaker` JSON payload that
    /// was formatted for this client, along with the [`Instant`] at which
    /// fanout captured it. Returns `None` if no `ActiveSpeakerChanged` has
    /// been delivered to this client yet. Used by integration tests to
    /// assert wire format and cross-client isolation timing without a live
    /// DTLS pipeline (capture happens BEFORE the `rtc.channel()` early-return).
    #[cfg(any(test, feature = "test-utils"))]
    pub fn last_active_speaker_payload(&self) -> Option<(String, std::time::Instant)> {
        self.last_active_speaker_payload
            .lock()
            .ok()
            .and_then(|guard| guard.clone())
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
