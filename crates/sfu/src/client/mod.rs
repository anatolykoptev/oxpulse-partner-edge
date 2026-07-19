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
use std::sync::Arc;

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
pub mod keys;
pub mod layer;
pub mod renegotiation;
#[cfg(any(test, feature = "test-utils"))]
pub mod test_seed;
pub mod tracks;
pub mod voice;

pub use voice::VOICE_FRAME_MAX_BYTES;

use tracks::TrackInEntry;
pub use tracks::{TrackIn, TrackOut, TrackOutState};

/// Outbound UDP datagram produced by a client's str0m state.
pub type Transmit = str0m::net::Transmit;

#[derive(Debug)]
pub struct Client {
    pub id: ClientId,
    pub(crate) rtc: Rtc,
    pub(crate) tracks_in: Vec<TrackInEntry>,
    pub tracks_out: Vec<TrackOut>,
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
    /// Post-layer-filter forwarded-media counter.
    /// Increments only when `writer.write` succeeds (SRTP actually sent on wire).
    /// See also: `layer_passed` for tests that verify fanout dispatch pre-write.
    pub(crate) delivered_media: AtomicU64,
    /// Test-only: count of packets that passed the M1.3/M5.3 layer filter
    /// and reached the mid-gate check (before writer.write). Distinct from
    /// `delivered_media` which only increments on successful wire delivery.
    /// Used by fanout integration tests that run on unnegotiated Rtc instances
    /// where writer.write never fires — they verify dispatch semantics, not wire.
    #[cfg(any(test, feature = "test-utils"))]
    pub(crate) layer_passed: AtomicU64,
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
    /// KX fix: pre-negotiated DC id:1 (`sframe-keys`, ordered, reliable).
    /// SFrame key-exchange identity frames from one peer are relayed to
    /// every other peer so their `peerIndexMap` stays populated and
    /// `epochInstalled` flips `true`. `None` until
    /// [`Client::with_keys_dc`] is called; relay clients skip it.
    pub(crate) keys_dc_cid: Option<str0m::channel::ChannelId>,
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
    /// Pre-negotiated DC id:7 (`reactions-group`,
    /// `negotiated: Some(7), ordered: true, reliability:
    /// MaxPacketLifetime{1000ms}`). Used by the browser to deliver
    /// reaction bursts (hearts, emoji) fan-out via the SFU. Opened by
    /// [`Client::with_reactions_dc`]; browser side sets
    /// `{ negotiated: true, id: 7, label: "reactions-group" }`.
    /// `None` until `with_reactions_dc()` is called; relay clients skip it.
    pub(crate) reactions_dc_cid: Option<str0m::channel::ChannelId>,
    /// True once `Event::ChannelOpen` fires for the reactions DC (id:7).
    /// The `chat_relay_active_channels{dc="reactions"}` gauge is incremented
    /// in dispatch when this transitions false→true and decremented in
    /// `reap_dead` / `evict_for_steal` only when this is true. Prevents:
    /// (a) phantom gauge inflation for v0.12.22 browsers that open the DC
    ///     at construction but never complete SCTP DCEP before disconnecting,
    /// (b) double-dec when both paths see `reactions_dc_cid.is_some()` — the
    ///     flag is the single authoritative "was gauge incremented?" gate.
    pub reactions_dc_opened: bool,
    /// Phase 2c: pre-negotiated DC id:8 (`sfu-events`,
    /// `negotiated: Some(8), ordered: false, reliability:
    /// MaxRetransmits{0}`). SFU-originated event broadcasts (peer-suspended
    /// tier changes). Browsers MUST NOT write here; write attempts are
    /// dropped with a warning in dc.rs. `None` until
    /// [`Client::with_sfu_events_dc`] is called. Relay clients skip it.
    pub(crate) sfu_events_cid: Option<str0m::channel::ChannelId>,
    /// Phase 2c: last pacer tier emitted for this peer. Used by
    /// `registry::bwe::update_pacer_layers` to emit `PeerSuspended` only on
    /// state transitions, not on every pacer tick. `None` = never emitted
    /// (initial state; first non-VideoMax tier always emits).
    pub(crate) last_emitted_tier: Option<crate::propagate::SuspendTier>,
    /// Phase 2c: transient tier from the current pacer tick's `PacerAction`.
    /// Set by `pacer_select_layer` inside `client::fanout`; consumed and
    /// cleared by `registry::bwe::update_pacer_layers` on the same tick.
    /// `None` if the pacer had `NoChange` / `RestoreAudio` / catch-all this tick.
    pub(crate) pending_tier_emit: Option<crate::propagate::SuspendTier>,
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
    /// `SFU_RELAY_HS256_FALLBACK` kill-switch (Task 7). When `false`, a
    /// relay_source roomToken that fails EdDSA verification is rejected
    /// instead of being re-verified under HS256 — closing the forged-token
    /// gap once EdDSA rollout is complete. Defaults `true` (fail-safe,
    /// matches `config.rs`'s `parse_hs256_fallback_env` default); overwritten
    /// from `Registry`'s copy at `insert()` time.
    pub(crate) relay_hs256_fallback_enabled: bool,
    /// Test-only: override the value returned by `ch.buffered_amount()` in
    /// `handle_voice_data_out`. Necessary because str0m's SCTP association is
    /// not live in unit tests — `buffered_amount()` always returns 0 without a
    /// real DTLS handshake, so the backpressure branch can never be reached
    /// via the real path. Set via [`Client::set_buffered_amount_for_tests`].
    #[cfg(any(test, feature = "test-utils"))]
    pub(crate) buffered_amount_override: Option<usize>,
    /// RFC 9626 VFM temporal-layer cap for this subscriber.
    /// Packets at a temporal layer higher than this are dropped before
    /// forwarding. `u8::MAX` means "no cap" (forward all layers).
    #[cfg(feature = "vfm")]
    pub(crate) max_vfm_temporal_layer: u8,
    /// Phase J M2: WS outbound channel for sending offer-renegotiate JSON to browser.
    /// `None` for relay/test clients (no WS session).
    pub(crate) ws_msg_tx: Option<tokio::sync::mpsc::Sender<String>>,
    /// Phase J M2: WS inbound channel for receiving answer-renegotiate from browser.
    /// `None` for relay/test clients.
    pub(crate) ws_ctrl_rx: Option<tokio::sync::mpsc::Receiver<crate::client_ws::WsClientCtrl>>,
    /// Phase J M2: in-flight SDP renegotiation offer. Single-slot — str0m allows
    /// only one pending offer per Rtc. A second `handle_track_open` while this is
    /// `Some` enqueues into `renegotiation_queue` instead.
    pub(crate) pending_offer: Option<str0m::change::SdpPendingOffer>,
    /// Phase J M2: queued track opens deferred while a renegotiation is in-flight.
    pub(crate) renegotiation_queue: std::collections::VecDeque<std::sync::Weak<TrackIn>>,
    /// Phase J M2: when the current renegotiation offer was sent. Used to
    /// detect no-answer timeouts (>10 s). Cleared on `accept_renegotiation_answer`.
    pub(crate) pending_offer_at: Option<std::time::Instant>,
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
    /// Per-subscriber hysteretic layer selector (Phase B kit migration).
    ///
    /// Migrated from the registry-level [] hash map
    /// (Phase B — consume oxpulse-sfu-kit v0.11). Each client owns its
    /// SubscriberPacer instance so lifecycle (drop-on-disconnect) is
    /// automatic and the registry needs no separate cleanup path.
    pub(crate) pacer: oxpulse_sfu_kit::SubscriberPacer,
    /// ADR-13-style min-tick floor state (task #18), behind `SFU_PACER_FLOOR`.
    /// Last `Instant` this subscriber's pacer FSM was actually advanced by
    /// `registry::bwe::update_pacer_layers`. `None` means never advanced
    /// (first tick always runs). Mirrors
    /// `oxpulse_sfu_kit::client::Client::last_pacer_drive`, which this fork's
    /// separate `Client` type does not inherit (fork-collapse verdict).
    pub(crate) last_pacer_tick: Option<std::time::Instant>,
}

impl Client {
    /// This subscriber's desired simulcast layer.
    pub fn desired_layer(&self) -> Rid {
        self.desired_layer
    }

    /// ADR-13-style min-tick floor (task #18): `true` at most once per
    /// `min_interval` per subscriber. `registry::bwe::update_pacer_layers`
    /// calls this before advancing the pacer FSM so a burst of below-100ms
    /// ticks can't collapse `SUSPEND_STREAK`'s intended debounce window.
    /// Mirrors `oxpulse_sfu_kit::client::accessors::Client::pacer_tick_ready`
    /// exactly (same semantics), reimplemented here because this fork's
    /// `Client` is a distinct type from the kit's (fork-collapse verdict).
    pub(crate) fn pacer_tick_ready(
        &mut self,
        now: std::time::Instant,
        min_interval: std::time::Duration,
    ) -> bool {
        match self.last_pacer_tick {
            Some(last) if now.saturating_duration_since(last) < min_interval => false,
            _ => {
                self.last_pacer_tick = Some(now);
                true
            }
        }
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

    /// Packets that reached wire delivery (writer.write returned Ok).
    /// Zero for test clients on unnegotiated Rtc — use `layer_passed_count` in tests.
    pub fn delivered_media_count(&self) -> u64 {
        self.delivered_media.load(Ordering::Relaxed)
    }

    /// Test-only: packets that passed the M1.3/M5.3 layer filter (before writer.write).
    /// Use instead of `delivered_media_count` in tests that run on unnegotiated Rtc.
    #[cfg(any(test, feature = "test-utils"))]
    pub fn layer_passed_count(&self) -> u64 {
        self.layer_passed.load(Ordering::Relaxed)
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

    /// Phase 2c: write a SFU-originated event frame to the `sfu-events` DC
    /// (id:8). Called by `crate::fanout::fanout` for `Propagated::PeerSuspended`.
    ///
    /// No-op when `sfu_events_cid` is `None` (relay clients that skipped
    /// `with_sfu_events_dc`). Frames larger than `sfu_events::MAX_FRAME_SIZE`
    /// are dropped with a warning. Write errors are warned, not panicked.
    pub fn handle_sfu_event_out(&mut self, payload: &[u8]) {
        let Some(cid) = self.sfu_events_cid else {
            return;
        };
        if payload.len() > crate::sfu_events::MAX_FRAME_SIZE {
            tracing::warn!(
                client = *self.id,
                len = payload.len(),
                "sfu-events: frame too large, dropping"
            );
            return;
        }
        let Some(mut ch) = self.rtc.channel(cid) else {
            // DC was opened but Rtc::channel returned None -- DTLS closed it.
            return;
        };
        if let Err(e) = ch.write(false, payload) {
            tracing::warn!(
                client = *self.id,
                error = %e,
                "sfu-events: DC write failed"
            );
        }
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

    /// Drain queued outbound datagrams. Registry calls this after each
    /// poll cycle to hand bytes to the tokio socket.
    pub fn drain_pending_out(&mut self) -> std::collections::vec_deque::Drain<'_, Transmit> {
        self.pending_out.drain(..)
    }
}
