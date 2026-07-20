//! Prometheus metrics for the SFU.
//!
//! One [`SfuMetrics`] per process, wrapped in [`Arc`] and threaded
//! through constructors (no global statics). Pattern mirrors
//! `crates/server/src/metrics.rs`.
//!
//! Concern-split:
//! * This module — [`SfuMetrics`] struct + core M1.5 registry construction.
//! * [`m6`] — M6.1 group-call observability metrics (layer transitions,
//!   E2E failure placeholder, dominant-speaker hysteresis histogram).
//! * [`server`] — HTTP transport (`GET /metrics`).
//!
//! M6.1 adds a per-edge `edge_id` const label from `SFU_EDGE_ID` env var
//! (default `"local"`). Applied at registry level — every scraped series
//! carries it automatically; differentiate edges in PromQL with
//! `{edge_id="ed-moscow-1"}`.

mod client_ws;
mod m6;
mod server;

pub use client_ws::close_code_label;
pub use server::spawn_metrics_server;

use std::collections::HashMap;
use std::sync::Arc;

use anyhow::Context;
use prometheus::{
    Encoder, GaugeVec, Histogram, HistogramOpts, IntCounter, IntCounterVec, IntGauge, IntGaugeVec,
    Opts, Registry, TextEncoder,
};

/// T4.3: `algorithm` label value for the Ed25519 (EdDSA) relay-JWT verify path.
pub const RELAY_JWT_ALG_EDDSA: &str = "eddsa";
/// T4.3: `algorithm` label value for the deprecated HS256 relay-JWT verify path
/// (the symmetric fallback the kill-switch can cut once EdDSA rollout completes).
pub const RELAY_JWT_ALG_HS256: &str = "hs256";

/// T8: `auth` label — relay API activated on the Ed25519 signing key ONLY
/// (`SFU_SIGNING_PUBLIC_KEY` set, no `RELAY_JWT_SECRET`). The canonical
/// federation path; the HS256 fallback is forced off in this mode.
pub const RELAY_AUTH_EDDSA: &str = "eddsa";
/// T8: `auth` label — relay API activated on the HS256 shared secret ONLY
/// (`RELAY_JWT_SECRET` set, no `SFU_SIGNING_PUBLIC_KEY`). Legacy symmetric path.
pub const RELAY_AUTH_HS256: &str = "hs256";
/// T8: `auth` label — relay API activated with BOTH credentials configured
/// (EdDSA primary + HS256 fallback available). The normal rollout state.
pub const RELAY_AUTH_BOTH: &str = "both";

/// All Prometheus handles for the SFU. Cheap to clone (all fields are
/// `Clone` — prometheus counters are reference-counted internally).
#[derive(Clone, Debug)]
pub struct SfuMetrics {
    pub registry: Arc<Registry>,
    /// 1 if the registry has at least one client, 0 otherwise. Single-room
    /// SFU semantics — wired by `Registry::insert` (set 1) and the
    /// eviction paths `reap_dead` / `evict_for_steal` (set 0 when empty).
    /// 2026-05-06 motherly1 outage post-mortem: previously `set(1)` at
    /// init and never updated, masking misconfigured deploys because no
    /// alert on this gauge could ever fire.
    pub active_rooms: IntGauge,
    /// Current number of live clients.
    pub active_participants: IntGauge,
    /// 1 if the browser-facing client_ws API is disabled at startup
    /// (e.g. `SIGNALING_SFU_SECRET` unset), 0 if active. 2026-05-06
    /// motherly1 outage post-mortem: previously the only signal of a
    /// disabled feature gate was a `tracing::info!` line, lost in
    /// normal-operation log streams. This gauge gives Prometheus a
    /// direct alertable signal for degraded state.
    ///
    /// Init value is **1** (disabled-until-proven-enabled): the metrics
    /// HTTP server is up before main.rs reaches the client_ws branch,
    /// so a racing scrape sees safe-pessimistic. main.rs flips to 0
    /// inside the `SIGNALING_SFU_SECRET` success arm.
    pub client_ws_disabled: IntGauge,
    /// Forwarded RTP packets, labelled by `kind` = audio | video | other.
    pub forwarded_packets_total: IntCounterVec,
    /// Layer selection events per simulcast tier, `layer` = q | h | f.
    pub layer_selection_total: IntCounterVec,
    /// Times the dominant speaker changed.
    pub dominant_speaker_changes_total: IntCounter,
    /// Client connect events.
    pub client_connect_total: IntCounter,
    /// Client disconnect events.
    pub client_disconnect_total: IntCounter,
    /// M5.3: current GCC bandwidth estimate per subscriber (bps).
    pub bandwidth_estimate_bps: IntGaugeVec,
    /// V0 (issue #2310): which ceiling term is currently *binding* the kit's
    /// `combined_bps` min()-chain. Label: `term` ∈
    /// `{delay, loss, native, googcc, client_hint}` — NO peer_id (federated
    /// edges: no per-client fingerprinting; only the registry-wide `edge_id`
    /// const label is inherited). Incremented once per subscriber per
    /// `update_pacer_layers` pass with the winning [`BindingTerm`], so a
    /// shaped-dip canary (V4) can read
    /// `rate(...{term="client_hint"}) / sum(rate(...))` staying ~1.0 as the
    /// "video pinned low, never recovers" signature. Aggregated across all
    /// subscribers by term only → 5 series/edge, no reap-scrub needed.
    ///
    /// Boot note: a fresh subscriber reports `term="delay"` until the first
    /// TWCC sample (delay and loss both boot at the same INITIAL_BITRATE_BPS
    /// and the kit's argmin keeps the earlier term on a tie) — expected noise,
    /// not a signal.
    pub combined_bps_binding_term: IntCounterVec,
    /// M5.3: pacer layer selections per subscriber and RID.
    pub pacer_layer_total: IntCounterVec,
    /// M6.1: simulcast layer transitions per subscriber (from/to/peer labels).
    pub layer_transitions_total: IntCounterVec,
    /// G4: keyframe requests emitted proactively when a subscriber's pacer
    /// switches it to a different simulcast layer (RID). Eliminates the
    /// decode-freeze the subscriber would otherwise hit while waiting for a
    /// reactive PLI or the publisher's next periodic keyframe — worst on
    /// slow/variable internet where the pacer switches exactly when the user
    /// can least afford a freeze. Label: `rid` (the TARGET layer requested),
    /// bounded to `q`/`h`/`f`/`other` — no `peer_id`, so no per-client
    /// cardinality and no reap_dead scrub needed (mirrors
    /// `layer_selection_total`'s label-only shape). Throttled per target RID
    /// by `KEYFRAME_REQUEST_MIN_GAP` in `client::keyframe`, so oscillation
    /// cannot storm the publisher.
    pub sfu_keyframe_on_switch_total: IntCounterVec,
    /// Task #18: pacer FSM advances skipped by the `SFU_PACER_FLOOR` min-tick
    /// floor. Label: `peer_id`. Only increments while the floor is enabled
    /// (`SFU_PACER_FLOOR=1`); always-zero on an edge with the flag off.
    /// Rising rate confirms the floor is throttling a fast `MediaData`
    /// cadence as designed. Scrubbed on disconnect alongside
    /// `pacer_layer_total` (see `Registry::reap_dead` / `evict_for_steal`).
    pub pacer_tick_throttled_total: IntCounterVec,
    /// M6.1: E2E handshake failures (SFU-side placeholder, always 0 — M6.3).
    pub e2e_handshake_failures_total: IntCounter,
    /// M6.1: histogram of inter-change intervals as dominant-speaker hysteresis proxy.
    pub dominant_speaker_hysteresis_ms: Histogram,
    /// M6.2: immediate-window audio activity score per peer (0.0 silent → 1.0 loudest).
    pub speaker_immediate: GaugeVec,
    /// M6.2: medium-window audio activity score per peer.
    pub speaker_medium: GaugeVec,
    /// M6.2: long-window audio activity score per peer.
    pub speaker_long: GaugeVec,
    // ── M4.B1 client_ws verification metrics ─────────────────────────────────
    /// Currently open client_ws sessions (incremented on session-open,
    /// decremented on session-close via [`ActiveSessionGuard`]).
    pub client_ws_active_sessions: IntGauge,
    /// Accepted upgrades (token verified, WS upgrade succeeded).
    pub client_ws_sessions_started_total: IntCounter,
    /// label: reason — `missing_token | expired_token | invalid_token |
    /// room_mismatch | other`. (`bad_subprotocol` is reserved but not
    /// currently emitted — handler accepts any subprotocol list as long
    /// as a `Bearer` entry is present.)
    pub client_ws_handshake_failures_total: IntCounterVec,
    /// label: outcome — `ok | parse_err | sdp_err | ice_err`.
    pub client_ws_offer_processed_total: IntCounterVec,
    /// Answer frames successfully sent to the browser.
    pub client_ws_answer_sent_total: IntCounter,
    /// label: close_code — bucketed via [`close_code_label`].
    pub client_ws_session_ended_total: IntCounterVec,
    /// Wall-clock duration of a client_ws session.
    pub client_ws_session_duration_seconds: Histogram,
    /// Phase A Task A1: count of older sessions evicted by a newer upgrade
    /// for the same `(room_id, peer_id)` (peer_id-keyed session steal).
    /// Incremented inside [`crate::registry::Registry::insert`] when a
    /// duplicate `external_peer_id` is detected.
    pub session_replaced_total: IntCounter,
    /// UDP `send_to` failures, labelled by `error_kind`.
    /// Incremented on every failure; only the first per destination per
    /// 10-second window emits a WARN (see `udp_loop::flush_transmits`).
    /// Exposed so task #28 can threshold on per-dest failure rate to drop
    /// dead ICE candidates without needing a separate map.
    pub udp_send_failed: IntCounterVec,
    /// label: peer_id — per-client snapshot of the running
    /// `Client::delivered_media_count` atomic counter, refreshed once
    /// per fanout pass. Diagnoses 'WS connected, ICE connected, but
    /// no media flowing' (mobile peers behind broken NAT, stuck codec
    /// init). Series scrubbed on `reap_dead` to keep peer_id
    /// cardinality bounded across reconnects.
    pub client_delivered_media_count: IntGaugeVec,
    /// UDP loop iterations. `rate(sfu_udp_loop_iterations_total[1m])` >> the
    /// expected ~10/s steady-state (driven by the 100ms wake) signals a
    /// select! arm spinning — typically a closed channel that wasn't
    /// `Option::None`'d out. Alert at >500/s sustained.
    pub udp_loop_iterations_total: IntCounter,
    /// 2026-07 bug-hunt (T10): wall-clock duration of one complete
    /// `udp_loop::serve` iteration — from the top of the `loop {}` through
    /// the `select!` branch that resolved it. `udp_loop_iterations_total`'s
    /// *rate* alone cannot see a saturated core: under contention the
    /// iteration RATE DROPS (fewer completed wakeups/sec) rather than
    /// rising, so the existing spin-detection alert (`rate > 500/s`) never
    /// fires. This histogram closes that gap — p99 climbing while the
    /// iteration rate stays flat or drops is the saturation signature.
    /// Buckets span sub-ms scheduling noise up to a few multiples of
    /// `MAX_SLEEP` (100ms) so the tail is visible without an overflow
    /// bucket swallowing it. Note: a fully idle loop (no clients, no
    /// packets) legitimately sits near the 100ms `MAX_SLEEP` ceiling every
    /// iteration, so the suggested `p99 > 50ms` warning threshold assumes a
    /// populated deployment — tune per-environment if idle-room alerting
    /// noise shows up.
    pub sfu_udp_loop_iteration_seconds: Histogram,
    /// One-shot counter for inject channels closing at runtime, label `kind`
    /// = `relay | client`. Should stay 0 in healthy operation; any non-zero
    /// reading means a producer task panicked or exited.
    pub inject_channel_closed_total: IntCounterVec,
    /// Phase 2b: bytes written to a peer's outbound chat-data / chat-ctrl
    /// DC. Labels: `dc` ∈ `{data, ctrl}`, `client_id` (subscriber that
    /// received the bytes). Source-of-truth for SFU chat-relay throughput
    /// dashboards.
    ///
    /// Cardinality note: `client_id` is unbounded in the long run as peers
    /// reconnect. `Registry::reap_dead` scrubs these series on disconnect
    /// (F2b-2), mirroring the `client_delivered_media_count` scrub.
    pub chat_relay_tx_bytes_total: IntCounterVec,
    /// Phase 2b: bytes ingested on the SFU edge's inbound chat-data /
    /// chat-ctrl DC. Labels: `dc` ∈ `{data, ctrl}`, `client_id` (origin).
    /// Currently incremented from the chat-relay handler before fanout
    /// (egress side); receive-path instrumentation lives at the str0m
    /// dispatch layer and can be extended to call this counter.
    pub chat_relay_rx_bytes_total: IntCounterVec,
    /// Phase 2b: chat-relay frames dropped at the SFU edge. Labels:
    /// `dc` ∈ `{data, ctrl}`, `reason` ∈
    /// `{channel_closed, write_err, no_channel, oversize}`.
    pub chat_relay_dropped_total: IntCounterVec,
    /// Phase 2b: number of currently-open per-peer chat-relay channels by
    /// `dc` ∈ `{data, ctrl}`. Bumped on `Client::with_chat_dcs`, decremented
    /// on disconnect. Labels: `dc` only (no `client_id`) — no per-client
    /// scrub required.
    pub chat_relay_active_channels: IntGaugeVec,

    // ── T4.3: relay-JWT verification path (silent_downgrade observability) ────
    /// Successful relay-JWT verifications on the relay `/relay/connect` and
    /// client-WS `/sfu/ws/{room_id}` handlers, split by which algorithm
    /// authenticated the token. Label: `algorithm` ∈ `{eddsa, hs256}`.
    ///
    /// `eddsa` is the preferred asymmetric path; `hs256` is the deprecated
    /// symmetric secret, reached either as the primary verifier (no EdDSA key
    /// configured) or via the EdDSA→HS256 rollout fallback. A sustained
    /// `{algorithm=hs256}` rate after EdDSA rollout is complete is the cutover
    /// signal (alert `warning`) and doubles as an HS256-secret-compromise
    /// indicator. The `SFU_RELAY_HS256_FALLBACK` kill-switch turns a fleet-wide
    /// zero-`hs256` observation into an enforced cutover.
    pub relay_jwt_verify_total: IntCounterVec,

    // ── T8: cascade-relay activation gate observability ──────────────────────
    /// Startup gauge — which credential activated the cascade-relay API, set
    /// once at boot. Label: `auth` ∈ `{eddsa, hs256, both}` = 1 for the active
    /// mode, 0 for the others; all three stay 0 when the relay API is disabled
    /// (standalone mode). Registered so a pure-Ed25519 mis-activation — the T8
    /// finding where the gate ignored `SFU_SIGNING_PUBLIC_KEY` and the relay
    /// never spawned — is directly alertable rather than silent.
    ///
    /// PromQL: `sfu_relay_api_enabled{auth="eddsa"} == 1` confirms the canonical
    /// federation path is live; `sum(sfu_relay_api_enabled) == 0` while cascade
    /// relay is expected fires the mis-activation alert.
    pub relay_api_enabled: IntGaugeVec,
    /// 1 if the vfm temporal-drop subsystem is compiled into this build
    /// (Dockerfile.sfu `--features vfm`); 0 otherwise. PromQL:
    /// `sfu_vfm_enabled == 1` confirms the G3 temporal-drop path is live
    /// post-deploy.
    pub vfm_enabled: IntGauge,

    // ── Phase 8 T10: voice DC relay metrics ──────────────────────────────────
    /// Phase 8 T10: bytes written to a subscriber's outbound voice DC.
    /// Label: `client_id` (subscriber). Scrubbed in `reap_dead` /
    /// `evict_for_steal` on disconnect (cardinality bound).
    pub voice_relay_tx_bytes_total: IntCounterVec,
    /// Phase 8 T10: bytes ingested on the SFU's inbound voice DC.
    /// Label: `client_id` (sender/origin). Scrubbed on disconnect.
    pub voice_relay_rx_bytes_total: IntCounterVec,
    /// Phase 8 T10: voice DC relay frames dropped at the SFU edge.
    /// Label: `reason` ∈ `{subscriber_dc_not_open, buffered_amount_too_high,
    /// frame_malformed, dc_closed, dc_send_failed}`.
    pub voice_relay_dropped: IntCounterVec,
    /// Phase 8 T10: gauge of currently-open voice DCs.
    /// Label: `dc=voice` (single value, matches chat-relay schema for
    /// label-cardinality scrub alignment on disconnect).
    pub voice_relay_active_channels: IntGaugeVec,

    // ── 2026-05-07 observability gap: ICE state coverage ─────────────────────
    /// All ICE connection state transitions per edge.
    ///
    /// Labels: `state` ∈ `{new, checking, connected, completed, disconnected, other}`.
    /// `other` collapses any future str0m variants so label cardinality stays
    /// bounded. Previously only `Disconnected` was handled (implicit in the
    /// `rtc.disconnect()` call); all other transitions were silent in Prometheus.
    ///
    /// Use `rate(sfu_ice_state_total{state="disconnected"}[5m]) > 0` for disconnect
    /// alerting; `state="checking"` rate = connection attempt rate.
    pub ice_state_total: IntCounterVec,

    // ── Phase C: SDP msid injection audit ────────────────────────────────────
    /// SDP answer m-line msid injection audit counter.
    ///
    /// `has_msid="true"` = at least one eligible m-line in the answer received
    /// `a=msid:peer-N` injection; `has_msid="false"` = no eligible m-lines were
    /// found (recvonly-only offer, or regression of the A1 msid-injection fix).
    ///
    /// Regression alert: `rate(sfu_sdp_msid_injected_total{has_msid="false"}[5m]) > 0`
    /// fires when someone reverts `inject_msid` or the SDP parser stops
    /// recognising sendonly/sendrecv directions — the `empty_stream` drop counter
    /// in oxpulse-chat would start rising within the same scrape window.
    pub sdp_msid_injected_total: IntCounterVec,

    // ── Phase F: tracks_map signaling ────────────────────────────────────────
    /// `tracks_map` WS messages sent to joining browser peers (Phase F2).
    ///
    /// A `tracks_map` message carries the stream_id→peer_id mapping for all
    /// currently-active publishers and is sent over the existing WS connection
    /// after the SDP answer. The client uses it to pre-populate `sfuStreamBindMap`
    /// so `pc.ontrack` can route tracks to the correct peer entry without a
    /// heuristic fallback.
    ///
    /// `has_peers="true"` = room had at least one active publisher when the
    /// newcomer joined; `has_peers="false"` = empty room (first joiner).
    pub tracks_map_sent_total: IntCounterVec,

    // ── SFU forwarding observability ─────────────────────────────────────────
    /// Per-RTP forward decision with per-peer breakdown.
    ///
    /// Labels:
    /// * `src_peer` — internal numeric id of the publishing peer.
    /// * `dst_peer` — internal numeric id of the subscribing peer.
    /// * `kind`     — `audio | video | other`.
    /// * `action`   — `forwarded | skipped_no_track | write_err`.
    ///
    /// Cardinality: peers × peers × 3 kinds × 3 actions. In a 6-peer room
    /// that is at most 6×6×3×3 = 324 series — well within Prometheus limits.
    /// Scrub `src_peer` / `dst_peer` series in `reap_dead` when peers disconnect
    /// to keep the long-run set bounded.
    pub sfu_forward_decisions_total: IntCounterVec,

    /// Subscription wiring events — one event per (publisher, subscriber) pair.
    ///
    /// Emitted by `Registry::insert` when existing publisher tracks are
    /// cross-advertised to a new peer via `handle_track_open`. A late joiner
    /// MUST produce exactly N events (one per existing publisher's track).
    ///
    /// Labels:
    /// * `publisher_peer` — internal id of the publisher.
    /// * `subscriber_peer` — internal id of the newcomer.
    /// * `result`          — `wired | no_track` (weak pointer upgrade outcome).
    pub sfu_subscription_setup_total: IntCounterVec,

    /// Late-join detection — emitted in `udp_loop::serve` when a new browser
    /// peer enters a room that already has active publishers.
    ///
    /// `count > 0` confirms detection fired; if `sfu_forward_decisions_total`
    /// still shows zero forwards for that subscriber → wiring bug elsewhere.
    ///
    /// Labels:
    /// * `trigger`       — `peer_joined_late` (room had publishers on join).
    /// * `action_taken`  — `tracks_map_sent | no_op_empty_room`.
    pub sfu_late_join_resync_total: IntCounterVec,

    /// str0m `poll_output` result distribution.
    ///
    /// Labels:
    /// * `peer_id` — internal numeric id.
    /// * `kind`    — `transmit | timeout | media_added | media_data |
    ///               keyframe_request | bwe | channel_data | other | error`.
    ///
    /// `rate(sfu_str0m_output_total{kind="error"}[1m]) > 0` fires when str0m
    /// rejects its own output — typically a misconfigured codec or lost ICE path.
    /// `transmit` rate ≈ outbound packet rate; sudden drop = forwarding stalled.
    pub sfu_str0m_output_total: IntCounterVec,
    // ── Phase J: M2 SDP renegotiation state-machine metrics ─────────────────
    /// State machine transitions for outbound track negotiation.
    ///
    /// Labels: `from` ∈ {to_open, negotiating}, `to` ∈ {negotiating, open}.
    /// Pre-touched: (to_open, negotiating) and (negotiating, open) so alert baseline=0 fires on deploy.
    /// Alert: zero rate(sfu_track_out_state_transitions_total{to="open"}[5m])
    /// after a group call with 2+ peers = M2 renegotiation stalled.
    pub sfu_track_out_state_transitions_total: IntCounterVec,
    /// Renegotiation offers sent from SFU to browser (new m-line per cross-advertised track).
    ///
    /// Labels: `kind` ∈ {audio, video}.
    /// Used to verify SFU actually triggers renegotiation for each publisher track.
    pub sfu_renegotiation_offers_sent_total: IntCounterVec,
    /// Renegotiation answer processing outcomes.
    ///
    /// Labels: `outcome` ∈ {ok, err}.
    /// `err` rising = browser sent malformed answer or str0m rejected it.
    pub sfu_renegotiation_answers_total: IntCounterVec,
    /// Successful SRTP wire writes after M2 renegotiation.
    ///
    /// Labels: `kind` ∈ {audio, video, other}.
    /// Pre-touched at startup. Distinct from forwarded_packets_total which increments
    /// before the mid() gate; this only fires when writer.write succeeds post-negotiation.
    pub sfu_wire_written_total: IntCounterVec,
    /// M2: renegotiation offers that could not be sent (WS channel full).
    ///
    /// Labels: kind in {audio, video}. Rising = browser peer lagging.
    /// The offer is rolled back; the track will retry on the next cycle.
    pub sfu_renegotiation_offers_dropped_total: IntCounterVec,
    /// M2: tracks_map_update frames dropped after a successful offer-renegotiate send.
    ///
    /// Labels: `reason` ∈ {ws_tx_full, channel_closed}.
    /// Non-zero = browser WS queue full at the time of emission; browser falls back
    /// to stream-id heuristic. Does NOT affect SRTP delivery.
    pub sfu_renegotiation_tracks_map_update_dropped_total: IntCounterVec,

    // ── str0m built-in stats (Finding 5: set_stats_interval) ─────────────────
    /// RTT per peer from `Event::PeerStats`. Labels: `peer_id`.
    /// Alert: sfu_peer_rtt_seconds > 0.2 → page on-call.
    pub peer_rtt_seconds: GaugeVec,
    /// Egress/ingress loss fraction per peer. Labels: `peer_id, direction` ∈ {egress, ingress}.
    pub peer_loss_fraction: GaugeVec,
    /// Bandwidth estimate (bps) per peer from `Event::PeerStats`. Labels: `peer_id`.
    pub peer_bandwidth_estimate_bps: GaugeVec,
    /// Jitter (RTP timestamp ticks) from remote receiver reports, per egress stream.
    /// Labels: `peer_id, mid`. Not converted to seconds: clock rate varies per codec
    /// and is not available at the dispatch layer without extra codec lookup.
    pub media_egress_jitter_ticks: GaugeVec,
    /// NAKs received by this egress stream (cumulative counter reset on reconnect).
    /// Labels: `peer_id, mid`.
    pub media_egress_nacks_received_total: IntCounterVec,
    /// FIR requests received by this egress stream. Labels: `peer_id, mid`.
    pub media_egress_firs_received_total: IntCounterVec,
    /// PLI requests received by this egress stream. Labels: `peer_id, mid`.
    pub media_egress_plis_received_total: IntCounterVec,
    /// Jitter (RTP timestamp ticks) reported by our RTCP RRs for each ingress stream.
    /// Labels: `peer_id, mid`.
    pub media_ingress_jitter_ticks: GaugeVec,

    // ── str0m issue #952: writer.write error discrimination ──────────────────
    /// Per-variant breakdown of `writer.write()` failures during RTP fanout.
    ///
    /// Labels: `kind` ∈ `{write_without_poll, other}`.
    ///
    /// `write_without_poll` matches `RtcError::WriteWithoutPoll` — consecutive
    /// calls to `write()` without an intervening `poll_output()`. Per str0m
    /// issue #952 (2026-05-05) this is the known cause of frozen video at
    /// ≥10 peers under load.
    ///
    /// Alert rule: `rate(sfu_writer_write_errors_total{kind="write_without_poll"}[5m]) > 0`
    /// → page on-call.
    pub sfu_writer_write_errors_total: IntCounterVec,

    // ── Solo-peer auto-kick ───────────────────────────────────────────────────
    /// Rooms closed because a lone peer was the only participant for longer
    /// than `SFU_SOLO_KICK_AFTER_SECS` (default 120 s). The peer's str0m
    /// connection is marked dead so the next `reap_dead` pass evicts it.
    ///
    /// Alert: `rate(sfu_solo_room_kicked_total[5m]) > 0` → lone-peer sessions
    /// are being cleaned up (informational) or possibly thrashing (if high).
    pub sfu_solo_room_kicked_total: IntCounter,

    // ── Phase 2c: client-to-SFU bandwidth hint ───────────────────────────────
    /// `{"kind":"bwe-hint","from":"<peer_uuid>","ts":<unix_ms>,"bps":<u64>}`
    /// frames received from browser clients over the WS control channel.
    ///
    /// Labels: `peer_id` — server-side numeric peer id (JWT `sub` claim).
    /// Cardinality is bounded to active peers; series materialise on first
    /// reception and are scrubbed via `reap_dead` / `evict_for_steal` on
    /// disconnect.
    ///
    /// v1 is observability-only: log INFO + bump counter. No SVC layer
    /// switching. Rising rate confirms client-side hint emission is wired;
    /// zero rate after feature flag enabled = hint not being sent.
    pub sfu_bwe_hint_received_total: IntCounterVec,

    // ── Phase 2c review fix: per-peer rate-gate throttle counter ────────────
    /// Counts bwe-hint frames that were silently dropped by the per-peer
    /// rate gate (10 hints/s cap). Labels: `peer_id`.
    /// Rising rate indicates a misbehaving or malicious client.
    pub sfu_bwe_hint_throttled_total: IntCounterVec,

    /// Process-level counter for mutex-poison recovery in the bwe-hint subsystem.
    ///
    /// Incremented whenever `scrub_hint_registry` or `hint_min_interval_ms`
    /// recovers from a poisoned mutex (no labels — per-process counter). A
    /// value > 0 indicates a thread panicked while holding a bwe-hint internal
    /// lock; data integrity was preserved via poison recovery but the event is
    /// worth alerting on in production.
    ///
    /// Alert: `sfu_bwe_hint_registry_mutex_poisoned_total > 0` → investigate
    /// thread panics in the bwe-hint rate-gate path.
    pub sfu_bwe_hint_registry_mutex_poisoned_total: IntCounter,

    /// Operator-visible gauge showing the configured minimum interval between
    /// accepted bwe-hint frames per peer (milliseconds).
    ///
    /// Set once at startup from `SFU_BWE_HINT_MIN_INTERVAL_MS` (default 100).
    /// Alerts and dashboards can compare this value against the observed
    /// throttle rate to detect misconfiguration or a default that's too tight.
    pub sfu_bwe_hint_rate_limit_min_interval_ms: IntGauge,

    // ── bogon ICE destination filter (mobile reliability) ────────────────────
    /// UDP transmits silently dropped because the destination is a bogon
    /// address (RFC-1918, loopback, link-local, multicast, other).
    ///
    /// Labels: `kind` ∈ `{rfc1918, loopback, link_local, multicast, other}`.
    ///
    /// Root cause: mobile carriers (T-Mobile/Verizon CGNAT) advertise private
    /// IPs (e.g. 10.8.0.3) as ICE candidates. str0m's `flush_transmits`
    /// previously called `send_to(10.8.0.3:…)` → OS error 89 EDESTADDRREQ,
    /// consuming retransmit budget without producing connectivity.
    ///
    /// Filter added 2026-05-09; see PR #fix/sfu-bogon-ice-filter.
    ///
    /// Alert: `rate(sfu_udp_bogon_dest_dropped_total[5m]) > 0` is normal on
    /// mobile-heavy rooms; spike above 100/s may indicate a peer advertising
    /// only bogon candidates (ICE failure scenario).
    pub udp_bogon_dest_dropped_total: IntCounterVec,

    // ── T9 (2026-07-01 bug-hunt): browser client_ws admission cap ────────────
    /// WS upgrades rejected at the `client_ws` admission gate, labelled by
    /// `reason`. Only `at_capacity` is emitted today (active sessions ≥
    /// [`crate::config::max_participants`]); the label stays open so a
    /// future admission-gate reason (e.g. a per-room cap) doesn't need a
    /// metric rename.
    ///
    /// Closes the gap the relay-dial path already closed with
    /// `RELAY_MAX_CONCURRENT` (`main.rs`'s semaphore on cascade-relay
    /// dials) — the browser-facing `client_ws_upgrade` path admitted every
    /// valid-token upgrade unconditionally, so a burst of valid tokens had
    /// no ceiling against the single-task `udp_loop`'s forwarding budget.
    ///
    /// Alert: `rate(sfu_sfu_admission_rejected_total[5m]) > 0` sustained →
    /// this node is at its participant cap; shard/route load away rather
    /// than raising the cap blindly (raising it revives the O(N) demux
    /// quadratic-cost risk — that redesign is a separate escalation, not
    /// this counter's job).
    pub sfu_admission_rejected_total: IntCounterVec,

    // ── T13 (2026-07-01 bug-hunt): cascade-relay connect outcome ─────────────
    /// Successful `connect_relay` calls from the cascade-relay retry loop —
    /// incremented on the first candidate in a `RelayTask`'s
    /// `upstream_candidates` list that completes the WS+SDP handshake.
    pub relay_connect_success_total: IntCounter,
    /// Cascade-relay tasks where every candidate in `upstream_candidates`
    /// failed or timed out (main.rs's `MAX_RELAY_CANDIDATES`-bounded retry
    /// loop). Previously only a `tracing::warn!` on exhaustion — a total
    /// upstream-hub outage dropped every room relay with zero Grafana
    /// signal (T13 2026-07-01 bug-hunt, dependency_block/medium).
    ///
    /// Alert: compare the rate of this counter against
    /// `relay_connect_success_total` per edge — a rising exhausted/success
    /// ratio flags a degraded or unreachable upstream hub.
    pub relay_candidate_exhausted_total: IntCounter,

    // ── G3 P0: Dependency Descriptor presence observability ──────────────────
    /// Count of forwarded RTP packets inspected for the AV1 Dependency
    /// Descriptor (DD) header extension, labelled by `present` ∈ `{true,
    /// false}`. `true` = the DD extension was present on the incoming packet
    /// (`MediaData.ext_vals.user_values.get::<DdPresent>()` was `Some`);
    /// `false` = it was absent.
    ///
    /// G3 P0 is observability-only: a rising `present="true"` rate confirms
    /// the str0m `ExtensionSerializer` seam + URI-rebind is delivering DD
    /// bytes to the fanout path, de-risking the P1 SVC layer-selection
    /// investment. NO packet is dropped and NO forwarding behaviour changes
    /// based on this counter. Bounded label (2 values) — no per-client
    /// cardinality, no reap scrub needed.
    pub sfu_dd_frames_total: IntCounterVec,

    // ── G3 P1: per-subscriber temporal-layer drop ───────────────────────────
    /// Count of forwarded RTP packets **dropped** by the G3 P1 temporal-layer
    /// filter, labelled by the packet's `temporal_id` ∈ `{"0","1","2","3plus"}`.
    /// A packet is dropped when its parsed DD `temporal_id` exceeds the
    /// subscriber's `max_vfm_temporal_layer` cap. The `3plus` label collapses
    /// all temporal_id ≥ 3 to keep label cardinality bounded (AV1 temporal
    /// layers in practice are 0..=2 for L1T3; higher is rare and would
    /// unbound the label if passed through verbatim).
    ///
    /// Decode-safety: dropping frames with `temporal_id > cap` is safe because
    /// in temporal SVC a frame at layer T references only frames at layer ≤ T
    /// (AV1 spec §3). The remaining stream is self-consistent and decodable.
    pub sfu_dd_temporal_drops_total: IntCounterVec,
}

impl SfuMetrics {
    pub fn new() -> anyhow::Result<Self> {
        // M6.1: per-edge const label from SFU_EDGE_ID (default "local").
        let edge_id = std::env::var("SFU_EDGE_ID").unwrap_or_else(|_| "local".to_string());
        let const_labels = HashMap::from([("edge_id".to_string(), edge_id)]);
        let registry = Registry::new_custom(Some("sfu".into()), Some(const_labels))
            .context("create registry")?;

        macro_rules! reg {
            ($m:expr) => {{
                let m = $m;
                registry
                    .register(Box::new(m.clone()))
                    .context("metric registration")?;
                m
            }};
        }

        let active_rooms = reg!(IntGauge::with_opts(Opts::new(
            "active_rooms",
            "1 if the SFU registry has at least one client, 0 otherwise. \
             Single-room SFU; wired by Registry::insert / reap_dead / \
             evict_for_steal. Defaults to 0 (registry starts empty).",
        ))
        .context("active_rooms")?);
        // Defaults to 0 (gauge zero-init). Do NOT set(1) here — the
        // 2026-05-06 motherly1 outage post-mortem identified the
        // hardcoded init value as a silent-fail trap that masked a
        // misconfigured client_ws gate for 8 weeks.

        let active_participants = reg!(IntGauge::with_opts(Opts::new(
            "active_participants",
            "Live client count",
        ))
        .context("active_participants")?);

        let client_ws_disabled = reg!(IntGauge::with_opts(Opts::new(
            "client_ws_disabled",
            "1 if browser WebSocket API is disabled at startup \
             (e.g. SIGNALING_SFU_SECRET unset), 0 if active",
        ))
        .context("client_ws_disabled")?);
        // Round-2 review fix: init to 1 (disabled-until-proven-enabled).
        // The metrics HTTP server starts very early in main(); the
        // client_ws bind happens dozens of awaits later (UDP bind, TLS,
        // listener bind). A Prometheus scrape that races startup would
        // otherwise see the false-clean default 0 for a deploy that's
        // actually disabled. main.rs flips this to 0 only inside the
        // `if let Some(secret_bytes)` success branch.
        client_ws_disabled.set(1);

        let forwarded_packets_total = reg!(IntCounterVec::new(
            Opts::new(
                "forwarded_packets_total",
                "Forwarded RTP packets by media kind"
            ),
            &["kind"],
        )
        .context("forwarded_packets_total")?);

        let layer_selection_total = reg!(IntCounterVec::new(
            Opts::new(
                "layer_selection_total",
                "Simulcast layer forwarding events by layer RID"
            ),
            &["layer"],
        )
        .context("layer_selection_total")?);

        // G4: keyframe-on-switch counter. Label `rid` only (the TARGET layer
        // requested) — bounded to q/h/f/other, no per-client cardinality.
        let sfu_keyframe_on_switch_total = reg!(IntCounterVec::new(
            Opts::new(
                "sfu_keyframe_on_switch_total",
                "Keyframe requests emitted proactively on subscriber simulcast \
                 layer switch (G4). Label: rid = target layer requested. \
                 Throttled per target RID by KEYFRAME_REQUEST_MIN_GAP."
            ),
            &["rid"],
        )
        .context("sfu_keyframe_on_switch_total")?);

        let dominant_speaker_changes_total = reg!(IntCounter::with_opts(Opts::new(
            "dominant_speaker_changes_total",
            "Times dominant speaker changed",
        ))
        .context("dominant_speaker_changes_total")?);

        let client_connect_total = reg!(IntCounter::with_opts(Opts::new(
            "client_connect_total",
            "Total clients connected",
        ))
        .context("client_connect_total")?);

        let client_disconnect_total = reg!(IntCounter::with_opts(Opts::new(
            "client_disconnect_total",
            "Total clients disconnected",
        ))
        .context("client_disconnect_total")?);

        let bandwidth_estimate_bps = reg!(IntGaugeVec::new(
            Opts::new(
                "bandwidth_estimate_bps",
                "GCC bandwidth estimate per subscriber in bits per second (M5.3)",
            ),
            &["peer_id"],
        )
        .context("bandwidth_estimate_bps")?);

        // V0 (issue #2310): binding-term of the kit's combined_bps min()-chain.
        // Label `term` only (no peer_id) — federated-safe, bounded to 5 series.
        let combined_bps_binding_term = reg!(IntCounterVec::new(
            Opts::new(
                "combined_bps_binding_term",
                "Which ceiling term is binding the kit combined_bps min()-chain \
                 (issue #2310 V0). Label: term ∈ {delay, loss, native, googcc, \
                 client_hint}. No peer_id (federated: no per-client fingerprint). \
                 Incremented per subscriber per update_pacer_layers pass. V4 reads \
                 rate(...{term=\"client_hint\"}) / sum(rate(...)) ~ 1.0 as the \
                 video-pinned-low-never-recovers signature.",
            ),
            &["term"],
        )
        .context("combined_bps_binding_term")?);
        // Pre-touch every term series (via the kit enum, so the vocabulary can
        // never drift) so alert rules + V4 see a baseline of 0 from startup.
        for term in oxpulse_sfu_kit::bwe::BindingTerm::ALL {
            let _ = combined_bps_binding_term
                .with_label_values(&[term.as_str()])
                .get();
        }

        let pacer_layer_total = reg!(IntCounterVec::new(
            Opts::new(
                "pacer_layer_total",
                "Pacer simulcast-layer selections per subscriber and RID (M5.3)",
            ),
            &["peer_id", "rid"],
        )
        .context("pacer_layer_total")?);

        // Task #18: SFU_PACER_FLOOR min-tick floor throttle counter.
        let pacer_tick_throttled_total = reg!(IntCounterVec::new(
            Opts::new(
                "pacer_tick_throttled_total",
                "Pacer FSM advances skipped by the SFU_PACER_FLOOR min-tick floor \
                 (task #18). Label: peer_id. Only increments while \
                 SFU_PACER_FLOOR=1; always-zero with the flag off. Scrubbed on \
                 disconnect alongside pacer_layer_total.",
            ),
            &["peer_id"],
        )
        .context("pacer_tick_throttled_total")?);

        let (
            layer_transitions_total,
            e2e_handshake_failures_total,
            dominant_speaker_hysteresis_ms,
            speaker_immediate,
            speaker_medium,
            speaker_long,
        ) = m6::register(&registry)?;

        let client_ws_metrics = client_ws::register(&registry)?;

        let udp_send_failed = reg!(IntCounterVec::new(
            Opts::new(
                "udp_send_failed_total",
                "UDP send_to failures by error kind (dest_required | network_unreachable | host_unreachable | perm | other)",
            ),
            &["error_kind"],
        )
        .context("udp_send_failed_total")?);

        let client_delivered_media_count = reg!(IntGaugeVec::new(
            Opts::new(
                "client_delivered_media_count",
                "Per-peer count of MediaData events fanned out to this client (snapshot of Client::delivered_media_count). Stuck at 0 after WS+ICE connected = forwarding broken.",
            ),
            &["peer_id"],
        )
        .context("client_delivered_media_count")?);

        let udp_loop_iterations_total = reg!(IntCounter::with_opts(Opts::new(
            "udp_loop_iterations_total",
            "UDP select! loop iteration count. Steady-state ~10/s (one wake per MAX_SLEEP=100ms). Sustained rate >>10/s = a select! arm is hot — typically a closed channel polled without an `if guard` or `Option::None` substitution. Alert: rate(sfu_udp_loop_iterations_total[1m]) > 500.",
        ))
        .context("udp_loop_iterations_total")?);

        // T10 bug-hunt: per-iteration duration. See field doc on
        // `SfuMetrics::sfu_udp_loop_iteration_seconds` for why this exists
        // alongside `udp_loop_iterations_total` (rate alone misses
        // saturation — the rate drops instead of rising).
        let sfu_udp_loop_iteration_seconds = reg!(Histogram::with_opts(
            HistogramOpts::new(
                "sfu_udp_loop_iteration_seconds",
                "Wall-clock duration of one udp_loop::serve select! loop iteration (processing + select wait). Suggested alert: warning on p99 > 0.05s.",
            )
            .buckets(vec![
                0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0,
            ]),
        )
        .context("sfu_udp_loop_iteration_seconds")?);

        let inject_channel_closed_total = reg!(IntCounterVec::new(
            Opts::new(
                "inject_channel_closed_total",
                "Inject channel observed all senders dropped at runtime. Should stay 0; non-zero = producer task panicked. Label `kind` = relay | client.",
            ),
            &["kind"],
        )
        .context("inject_channel_closed_total")?);
        // Preload both label values at 0 so the series exist from startup —
        // Prometheus IntCounterVec lazy-registers only on first .inc(), which
        // would mean the `SfuInjectChannelClosed` alert rule has no baseline
        // until something actually fires. Touching .get() materialises the
        // child without bumping the count.
        let _ = inject_channel_closed_total
            .with_label_values(&["relay"])
            .get();
        let _ = inject_channel_closed_total
            .with_label_values(&["client"])
            .get();

        // ── Phase 2b: chat-data + chat-ctrl relay metrics ─────────────────────
        let chat_relay_tx_bytes_total = reg!(IntCounterVec::new(
            Opts::new(
                "chat_relay_tx_bytes_total",
                "Phase 2b: bytes written to a peer's outbound chat-data / chat-ctrl DC. Labels: dc ∈ {data, ctrl}, client_id (subscriber).",
            ),
            &["dc", "client_id"],
        )
        .context("chat_relay_tx_bytes_total")?);

        let chat_relay_rx_bytes_total = reg!(IntCounterVec::new(
            Opts::new(
                "chat_relay_rx_bytes_total",
                "Phase 2b: bytes ingested on the SFU edge's inbound chat-data / chat-ctrl DC. Labels: dc ∈ {data, ctrl}, client_id (origin).",
            ),
            &["dc", "client_id"],
        )
        .context("chat_relay_rx_bytes_total")?);

        let chat_relay_dropped_total = reg!(IntCounterVec::new(
            Opts::new(
                "chat_relay_dropped_total",
                "Phase 2b: chat-relay frames dropped at the SFU edge. Labels: dc ∈ {data, ctrl}, reason ∈ {channel_closed, write_err, no_channel, oversize}.",
            ),
            &["dc", "reason"],
        )
        .context("chat_relay_dropped_total")?);
        // Pre-touch every (dc, reason) pair so the Prometheus alert rules
        // see a baseline of 0 instead of an absent series.
        for dc in ["data", "ctrl"] {
            for reason in ["channel_closed", "write_err", "no_channel", "oversize"] {
                let _ = chat_relay_dropped_total
                    .with_label_values(&[dc, reason])
                    .get();
            }
        }

        // T4.3: relay-JWT verify path, labeled by algorithm.
        let relay_jwt_verify_total = reg!(IntCounterVec::new(
            Opts::new(
                "relay_jwt_verify_total",
                "T4.3: successful relay-JWT verifications on the relay-connect and client-WS handlers. Label: algorithm ∈ {eddsa, hs256}. A sustained hs256 rate after EdDSA rollout is the cutover / secret-compromise signal.",
            ),
            &["algorithm"],
        )
        .context("relay_jwt_verify_total")?);
        // Pre-touch both algorithm series so the cutover alert evaluates a
        // baseline of 0 rather than an absent {algorithm=hs256} series.
        for algorithm in [RELAY_JWT_ALG_EDDSA, RELAY_JWT_ALG_HS256] {
            let _ = relay_jwt_verify_total.with_label_values(&[algorithm]).get();
        }

        // T8: cascade-relay activation-mode gauge. main.rs sets the active
        // mode's series to 1 once at boot after resolving the credentials.
        let relay_api_enabled = reg!(IntGaugeVec::new(
            Opts::new(
                "relay_api_enabled",
                "T8: cascade-relay API activation mode, set once at boot. \
                 Label: auth ∈ {eddsa, hs256, both} = 1 for the active credential, \
                 0 otherwise; all 0 = relay API disabled (standalone). A pure-Ed25519 \
                 deployment (auth=eddsa) is the canonical federation path.",
            ),
            &["auth"],
        )
        .context("relay_api_enabled")?);
        // Pre-touch all three modes so the mis-activation alert evaluates a
        // baseline of 0 instead of an absent series before main.rs sets one.
        for auth in [RELAY_AUTH_EDDSA, RELAY_AUTH_HS256, RELAY_AUTH_BOTH] {
            let _ = relay_api_enabled.with_label_values(&[auth]).get();
        }

        // G3 P3a: compiled-in build-flag gauge for the vfm temporal-drop
        // subsystem. A registered plain IntGauge always appears in
        // `gather()`, so it reports 0 from startup; set to 1 only when the
        // `vfm` feature is on so a prod build that compiled the drop path
        // out is directly alertable via `sfu_vfm_enabled == 0` instead of
        // being silent.
        let vfm_enabled = reg!(IntGauge::with_opts(Opts::new(
            "vfm_enabled",
            "1 if the vfm temporal-drop subsystem is compiled into this \
             build (Dockerfile.sfu --features vfm); 0 otherwise. PromQL: \
             sfu_vfm_enabled == 1 confirms the G3 temporal-drop path is \
             live post-deploy.",
        ))
        .context("vfm_enabled")?);
        #[cfg(feature = "vfm")]
        vfm_enabled.set(1);

        let chat_relay_active_channels = reg!(IntGaugeVec::new(
            Opts::new(
                "chat_relay_active_channels",
                "Phase 2b: per-edge gauge of open chat-relay channels. Labels: dc ∈ {data, ctrl}.",
            ),
            &["dc"],
        )
        .context("chat_relay_active_channels")?);
        let _ = chat_relay_active_channels
            .with_label_values(&["data"])
            .get();
        let _ = chat_relay_active_channels
            .with_label_values(&["ctrl"])
            .get();

        // ── Phase 8 T10: voice DC relay metrics ──────────────────────────────
        let voice_relay_tx_bytes_total = reg!(IntCounterVec::new(
            Opts::new(
                "voice_relay_tx_bytes_total",
                "Phase 8 T10: bytes written to a subscriber's outbound voice DC. \
                 Label: client_id (subscriber). Scrubbed on disconnect.",
            ),
            &["client_id"],
        )
        .context("voice_relay_tx_bytes_total")?);

        let voice_relay_rx_bytes_total = reg!(IntCounterVec::new(
            Opts::new(
                "voice_relay_rx_bytes_total",
                "Phase 8 T10: bytes ingested on the SFU inbound voice DC. \
                 Label: client_id (sender). Scrubbed on disconnect.",
            ),
            &["client_id"],
        )
        .context("voice_relay_rx_bytes_total")?);

        let voice_relay_dropped = reg!(IntCounterVec::new(
            Opts::new(
                "voice_relay_dropped_total",
                "Phase 8 T10: voice DC relay frames dropped at the SFU edge. \
                 Label: reason ∈ {subscriber_dc_not_open, buffered_amount_too_high, \
                 frame_malformed, dc_closed, dc_send_failed}.",
            ),
            &["reason"],
        )
        .context("voice_relay_dropped_total")?);
        // Pre-touch every reason label so alert rules see a baseline of 0
        // instead of an absent series. Label values are spec-mandated:
        // subscriber_dc_not_open / buffered_amount_too_high / frame_malformed
        // are from the original spec; dc_closed / dc_send_failed are
        // partner-edge additions for operational observability.
        for reason in [
            "subscriber_dc_not_open",
            "buffered_amount_too_high",
            "frame_malformed",
            "dc_closed",
            "dc_send_failed",
        ] {
            let _ = voice_relay_dropped.with_label_values(&[reason]).get();
        }

        let voice_relay_active_channels = reg!(IntGaugeVec::new(
            Opts::new(
                "voice_relay_active_channels",
                "Phase 8 T10: per-edge gauge of currently-open voice DCs. \
                 Label: dc=voice (single value, mirrors chat-relay schema).",
            ),
            &["dc"],
        )
        .context("voice_relay_active_channels")?);
        let _ = voice_relay_active_channels
            .with_label_values(&["voice"])
            .get();

        // ── 2026-05-07 observability gap: ICE state coverage ─────────────────
        let ice_state_total = reg!(IntCounterVec::new(
            Opts::new(
                "ice_state_total",
                "ICE connection state transitions per edge. \
                 Label: state ∈ {new, checking, connected, completed, disconnected, other}. \
                 Previously only Disconnected was handled in dispatch; all other \
                 transitions were silent in Prometheus (2026-05-07 metric coverage audit).",
            ),
            &["state"],
        )
        .context("ice_state_total")?);
        // Pre-touch all known label values so alert rules see a baseline of 0
        // from startup instead of an absent series.  `other` future-proofs
        // against new str0m variants without unbounded cardinality.
        for state in [
            "new",
            "checking",
            "connected",
            "completed",
            "disconnected",
            "other",
        ] {
            let _ = ice_state_total.with_label_values(&[state]).get();
        }

        // ── Phase C: SDP msid injection audit ────────────────────────────────
        let sdp_msid_injected_total = reg!(IntCounterVec::new(
            Opts::new(
                "sdp_msid_injected_total",
                "SDP answer m-line msid injection audit. \
                 has_msid=true = at least one eligible m-line got a=msid injected; \
                 has_msid=false = no eligible m-lines found (regression guard A1). \
                 Regression alert: rate(sfu_sdp_msid_injected_total{has_msid=\"false\"}[5m]) > 0.",
            ),
            &["has_msid"],
        )
        .context("sdp_msid_injected_total")?);
        // Pre-touch both label values so alert rules see a baseline of 0 at startup
        // and the series appear in /metrics before the first offer arrives.
        let _ = sdp_msid_injected_total.with_label_values(&["true"]).get();
        let _ = sdp_msid_injected_total.with_label_values(&["false"]).get();

        // ── Phase F: tracks_map signaling ────────────────────────────────────
        let tracks_map_sent_total = reg!(IntCounterVec::new(
            Opts::new(
                "tracks_map_sent_total",
                "Phase F2: tracks_map WS messages sent to joining browser peers. \
                 has_peers=true = room had active publishers; has_peers=false = first joiner.",
            ),
            &["has_peers"],
        )
        .context("tracks_map_sent_total")?);
        // Pre-touch both label values so alert rules see a baseline of 0 at startup.
        let _ = tracks_map_sent_total.with_label_values(&["true"]).get();
        let _ = tracks_map_sent_total.with_label_values(&["false"]).get();

        // ── SFU forwarding observability ─────────────────────────────────────
        let sfu_forward_decisions_total = reg!(IntCounterVec::new(
            Opts::new(
                "sfu_forward_decisions_total",
                "Per-RTP forward decision with src/dst/kind/action breakdown. \
                 action ∈ {forwarded, skipped_no_track, write_err}. \
                 Use this counter to diagnose asymmetric forwarding: if \
                 forwarded{dst=X}=0 while other dst peers are non-zero, the \
                 subscription wiring for peer X is broken.",
            ),
            &["src_peer", "dst_peer", "kind", "action"],
        )
        .context("sfu_forward_decisions_total")?);
        // No pre-touch: labels are dynamic (peer ids). Series materialize on
        // first packet — the forward-decision counter is a diagnostic tool, not
        // an alert-baseline counter.

        let sfu_subscription_setup_total = reg!(IntCounterVec::new(
            Opts::new(
                "sfu_subscription_setup_total",
                "Subscription wiring events emitted by Registry::insert. \
                 result ∈ {wired, no_track}. A late joiner must produce exactly \
                 N events (one per existing publisher's track); zero events means \
                 the cross-advertisement loop was skipped.",
            ),
            &["publisher_peer", "subscriber_peer", "result"],
        )
        .context("sfu_subscription_setup_total")?);

        let sfu_late_join_resync_total = reg!(IntCounterVec::new(
            Opts::new(
                "sfu_late_join_resync_total",
                "Late-join detection events from udp_loop::serve. \
                 trigger ∈ {peer_joined_late}. \
                 action_taken ∈ {tracks_map_sent, no_op_empty_room}. \
                 counter > 0 with zero sfu_forward_decisions_total{dst=peer} = \
                 wiring bug (subscription fired but no packets forwarded).",
            ),
            &["trigger", "action_taken"],
        )
        .context("sfu_late_join_resync_total")?);
        // Pre-touch the two expected combinations so alert rules see baseline 0.
        let _ = sfu_late_join_resync_total
            .with_label_values(&["peer_joined_late", "tracks_map_sent"])
            .get();
        let _ = sfu_late_join_resync_total
            .with_label_values(&["peer_joined_late", "no_op_empty_room"])
            .get();

        let sfu_str0m_output_total = reg!(IntCounterVec::new(
            Opts::new(
                "sfu_str0m_output_total",
                "str0m poll_output result distribution per peer. \
                 kind ∈ {transmit, timeout, media_added, media_data, \
                 keyframe_request, bwe, channel_data, other, error}. \
                 transmit rate ≈ outbound packet rate. \
                 rate(sfu_str0m_output_total{kind=\"error\"}[1m]) > 0 = str0m internal error.",
            ),
            &["peer_id", "kind"],
        )
        .context("sfu_str0m_output_total")?);
        // No pre-touch: peer_id labels are dynamic.

        // ── Phase J: M2 SDP renegotiation metrics ────────────────────────────
        let sfu_track_out_state_transitions_total = reg!(IntCounterVec::new(
            Opts::new(
                "sfu_track_out_state_transitions_total",
                "M2 renegotiation state-machine transitions. Labels: from, to. Alert on zero rate.",
            ),
            &["from", "to"],
        )
        .context("sfu_track_out_state_transitions_total")?);
        // Pre-touch the (negotiating, open) path so the alert baseline=0 fires immediately.
        let _ = sfu_track_out_state_transitions_total
            .with_label_values(&["negotiating", "open"])
            .get();
        let _ = sfu_track_out_state_transitions_total
            .with_label_values(&["to_open", "negotiating"])
            .get();

        let sfu_renegotiation_offers_sent_total = reg!(IntCounterVec::new(
            Opts::new(
                "sfu_renegotiation_offers_sent_total",
                "M2: renegotiation offers pushed from SFU to browser (per cross-advertised track). kind ∈ {audio, video}.",
            ),
            &["kind"],
        )
        .context("sfu_renegotiation_offers_sent_total")?);
        let _ = sfu_renegotiation_offers_sent_total
            .with_label_values(&["audio"])
            .get();
        let _ = sfu_renegotiation_offers_sent_total
            .with_label_values(&["video"])
            .get();

        let sfu_renegotiation_answers_total = reg!(IntCounterVec::new(
            Opts::new(
                "sfu_renegotiation_answers_total",
                "M2: renegotiation answer processing outcomes. outcome ∈ {ok, err, timeout, ws_closed, ctrl_tx_full, ctrl_tx_retry_ok, state_mismatch}. err rising = malformed browser answer or str0m rejection. state_mismatch = accept_answer Ok but no Negotiating TrackOut found. ctrl_tx_retry_ok = try_send failed but bounded retry send succeeded.",
            ),
            &["outcome"],
        )
        .context("sfu_renegotiation_answers_total")?);
        let _ = sfu_renegotiation_answers_total
            .with_label_values(&["ok"])
            .get();
        let _ = sfu_renegotiation_answers_total
            .with_label_values(&["err"])
            .get();
        let _ = sfu_renegotiation_answers_total
            .with_label_values(&["timeout"])
            .get();
        let _ = sfu_renegotiation_answers_total
            .with_label_values(&["ws_closed"])
            .get();
        let _ = sfu_renegotiation_answers_total
            .with_label_values(&["ctrl_tx_full"])
            .get();
        let _ = sfu_renegotiation_answers_total
            .with_label_values(&["ctrl_tx_retry_ok"])
            .get();
        let _ = sfu_renegotiation_answers_total
            .with_label_values(&["state_mismatch"])
            .get();

        let sfu_wire_written_total = reg!(IntCounterVec::new(
            Opts::new(
                "sfu_wire_written_total",
                "M2: successful SRTP writer.write() calls after renegotiation. kind ∈ {audio, video, other}. Non-zero only when TrackOutState::Open(mid) reached. Distinct from forwarded_packets_total which increments before the mid() gate.",
            ),
            &["kind"],
        )
        .context("sfu_wire_written_total")?);
        let _ = sfu_wire_written_total.with_label_values(&["audio"]).get();
        let _ = sfu_wire_written_total.with_label_values(&["video"]).get();
        let _ = sfu_wire_written_total.with_label_values(&["other"]).get();

        let sfu_renegotiation_offers_dropped_total = reg!(IntCounterVec::new(
            Opts::new(
                "sfu_renegotiation_offers_dropped_total",
                "M2: offer-renegotiate frames dropped because ws_msg_tx was full. kind in {audio, video}. Non-zero = browser peer lagging; state rolled back.",
            ),
            &["kind"],
        )
        .context("sfu_renegotiation_offers_dropped_total")?);
        let _ = sfu_renegotiation_offers_dropped_total
            .with_label_values(&["audio"])
            .get();
        let _ = sfu_renegotiation_offers_dropped_total
            .with_label_values(&["video"])
            .get();

        let sfu_renegotiation_tracks_map_update_dropped_total = reg!(IntCounterVec::new(
            Opts::new(
                "sfu_renegotiation_tracks_map_update_dropped_total",
                "M2: tracks_map_update frames dropped after offer-renegotiate. \
                 reason in {ws_tx_full, channel_closed}. Non-zero = browser WS queue congested; \
                 browser falls back to stream-id heuristic.",
            ),
            &["reason"],
        )
        .context("sfu_renegotiation_tracks_map_update_dropped_total")?);
        let _ = sfu_renegotiation_tracks_map_update_dropped_total
            .with_label_values(&["ws_tx_full"])
            .get();
        let _ = sfu_renegotiation_tracks_map_update_dropped_total
            .with_label_values(&["channel_closed"])
            .get();

        // ── str0m built-in stats (Finding 5: set_stats_interval) ─────────────
        let peer_rtt_seconds = reg!(GaugeVec::new(
            Opts::new(
                "peer_rtt_seconds",
                "RTT per peer from Event::PeerStats. \
                 Alert: sfu_peer_rtt_seconds > 0.2 → page on-call.",
            ),
            &["peer_id"],
        )
        .context("peer_rtt_seconds")?);

        let peer_loss_fraction = reg!(GaugeVec::new(
            Opts::new(
                "peer_loss_fraction",
                "Packet loss fraction per peer and direction \
                 (direction ∈ {egress, ingress}) from Event::PeerStats.",
            ),
            &["peer_id", "direction"],
        )
        .context("peer_loss_fraction")?);

        let peer_bandwidth_estimate_bps = reg!(GaugeVec::new(
            Opts::new(
                "peer_bandwidth_estimate_bps_str0m",
                "Bandwidth estimate (bps) from str0m Event::PeerStats bwe_tx field. \
                 Complements the GCC BWE gauge (bandwidth_estimate_bps). \
                 Labels: peer_id.",
            ),
            &["peer_id"],
        )
        .context("peer_bandwidth_estimate_bps_str0m")?);

        let media_egress_jitter_ticks = reg!(GaugeVec::new(
            Opts::new(
                "media_egress_jitter_ticks",
                "Jitter in RTP timestamp ticks from remote receiver reports \
                 (Event::MediaEgressStats.remote.jitter). Not converted to seconds \
                 because clock rate varies per codec and is not available at dispatch. \
                 Labels: peer_id, mid.",
            ),
            &["peer_id", "mid"],
        )
        .context("media_egress_jitter_ticks")?);

        let media_egress_nacks_received_total = reg!(IntCounterVec::new(
            Opts::new(
                "media_egress_nacks_received_total",
                "NAKs received by this egress stream from Event::MediaEgressStats. \
                 Labels: peer_id, mid.",
            ),
            &["peer_id", "mid"],
        )
        .context("media_egress_nacks_received_total")?);

        let media_egress_firs_received_total = reg!(IntCounterVec::new(
            Opts::new(
                "media_egress_firs_received_total",
                "FIR requests received per egress stream from Event::MediaEgressStats. \
                 Labels: peer_id, mid.",
            ),
            &["peer_id", "mid"],
        )
        .context("media_egress_firs_received_total")?);

        let media_egress_plis_received_total = reg!(IntCounterVec::new(
            Opts::new(
                "media_egress_plis_received_total",
                "PLI requests received per egress stream from Event::MediaEgressStats. \
                 Labels: peer_id, mid.",
            ),
            &["peer_id", "mid"],
        )
        .context("media_egress_plis_received_total")?);

        let media_ingress_jitter_ticks = reg!(GaugeVec::new(
            Opts::new(
                "media_ingress_jitter_ticks",
                "Jitter (RTP timestamp ticks) from our RTCP RRs per ingress stream \
                 (Event::MediaIngressStats). Labels: peer_id, mid.",
            ),
            &["peer_id", "mid"],
        )
        .context("media_ingress_jitter_ticks")?);

        // ── str0m issue #952: writer.write error discrimination ──────────────
        let sfu_writer_write_errors_total = reg!(IntCounterVec::new(
            Opts::new(
                "sfu_writer_write_errors_total",
                "writer.write() failures during RTP fanout, broken down by error variant. \
                 kind ∈ {write_without_poll, other}. \
                 write_without_poll = consecutive write() calls without poll_output() — \
                 known cause of frozen video at ≥10 peers (str0m issue #952, 2026-05-05). \
                 Alert: rate(sfu_writer_write_errors_total{kind=\"write_without_poll\"}[5m]) > 0.",
            ),
            &["kind"],
        )
        .context("sfu_writer_write_errors_total")?);
        // Pre-touch both label values so alert rules see a stable baseline of 0
        // from startup instead of an absent series.
        let _ = sfu_writer_write_errors_total
            .with_label_values(&["write_without_poll"])
            .get();
        let _ = sfu_writer_write_errors_total
            .with_label_values(&["other"])
            .get();

        // ── Solo-peer auto-kick ───────────────────────────────────────────────
        let sfu_solo_room_kicked_total = reg!(IntCounter::with_opts(Opts::new(
            "sfu_solo_room_kicked_total",
            "Rooms closed because the lone remaining peer exceeded the solo-hold timeout \
             (SFU_SOLO_KICK_AFTER_SECS, default 120 s). Peer is marked dead; \
             reap_dead evicts it on the next registry tick.",
        ))
        .context("sfu_solo_room_kicked_total")?);

        // ── Phase 2c: client-to-SFU bandwidth hint ───────────────────────────
        let sfu_bwe_hint_received_total = reg!(IntCounterVec::new(
            Opts::new(
                "sfu_bwe_hint_received_total",
                "bwe-hint frames received from browser clients over the WS control channel \
                 (Phase 2c). Label: peer_id (server-side numeric id, JWT sub claim). \
                 Cardinality bounded to active peers; scrubbed on disconnect. \
                 v1 observability-only — no SVC layer switching.",
            ),
            &["peer_id"],
        )
        .context("sfu_bwe_hint_received_total")?);
        // No pre-touch: peer_id labels are dynamic (one per active client).
        // Series materialise on first reception, mirroring client_delivered_media_count.

        let sfu_bwe_hint_throttled_total = reg!(IntCounterVec::new(
            Opts::new(
                "sfu_bwe_hint_throttled_total",
                "bwe-hint frames silently dropped by the per-peer rate gate \
                 (10 hints/s cap). Label: peer_id. Rising rate = misbehaving client. \
                 Scrubbed on disconnect alongside sfu_bwe_hint_received_total.",
            ),
            &["peer_id"],
        )
        .context("sfu_bwe_hint_throttled_total")?);

        let sfu_bwe_hint_registry_mutex_poisoned_total = reg!(IntCounter::with_opts(Opts::new(
            "sfu_bwe_hint_registry_mutex_poisoned_total",
            "Process-level count of mutex-poison recovery events in the bwe-hint subsystem \
             (scrub_hint_registry + hint_min_interval_ms override mutex). \
             A value > 0 means a thread panicked while holding a bwe-hint internal lock; \
             poison recovery preserved integrity. Alert on any non-zero value.",
        ))
        .context("sfu_bwe_hint_registry_mutex_poisoned_total")?);

        // Phase 2c round-3: operator-visible interval gauge. Published once at startup
        // via the shared `bwe_hint::hint_min_interval_ms()` so the gauge and the
        // session rate gate always read the same value (MAJOR divergence fix).
        let interval_ms: i64 = crate::bwe_hint::hint_min_interval_ms() as i64;
        let sfu_bwe_hint_rate_limit_min_interval_ms = reg!(IntGauge::with_opts(Opts::new(
            "sfu_bwe_hint_rate_limit_min_interval_ms",
            "Configured minimum interval between accepted bwe-hint frames per peer \
             (milliseconds). Set from SFU_BWE_HINT_MIN_INTERVAL_MS (default 100). \
             Compare against sfu_bwe_hint_throttled_total to detect misconfiguration.",
        ))
        .context("sfu_bwe_hint_rate_limit_min_interval_ms")?);
        sfu_bwe_hint_rate_limit_min_interval_ms.set(interval_ms);

        // ── bogon ICE destination filter ──────────────────────────────────────
        let udp_bogon_dest_dropped_total = reg!(IntCounterVec::new(
            Opts::new(
                "udp_bogon_dest_dropped_total",
                "UDP transmits dropped before send_to because the destination is a bogon address \
                 (RFC-1918 / RFC-6598 CGNAT / loopback / link-local / multicast / other). \
                 kind ∈ {rfc1918, cgnat, loopback, link_local, multicast, other}. \
                 Mobile CGNAT fix (2026-05-09): T-Mobile/Verizon phones advertise private IPs \
                 as ICE candidates; send_to on those produces EDESTADDRREQ (OS error 89). \
                 Alert: rate > 100/s sustained = peer advertising only bogon candidates.",
            ),
            &["kind"],
        )
        .context("udp_bogon_dest_dropped_total")?);
        // Pre-touch all label values so alert rules see a baseline of 0 at startup.
        for kind in [
            "rfc1918",
            "cgnat",
            "loopback",
            "link_local",
            "multicast",
            "other",
        ] {
            let _ = udp_bogon_dest_dropped_total
                .with_label_values(&[kind])
                .get();
        }

        // ── T9: browser client_ws admission cap ────────────────────────────────
        let sfu_admission_rejected_total = reg!(IntCounterVec::new(
            Opts::new(
                "sfu_admission_rejected_total",
                "client_ws WS upgrades rejected by the admission gate, by reason. \
                 reason=at_capacity: active_sessions >= SFU_MAX_PARTICIPANTS. \
                 T9 2026-07-01 bug-hunt (resource_exhaustion/high) — mirrors the \
                 relay-dial RELAY_MAX_CONCURRENT semaphore on the browser path.",
            ),
            &["reason"],
        )
        .context("sfu_admission_rejected_total")?);
        // Pre-touch so the alert baseline is 0 at startup, not absent.
        let _ = sfu_admission_rejected_total
            .with_label_values(&["at_capacity"])
            .get();

        // ── T13 (2026-07-01 bug-hunt): cascade-relay connect outcome ───────────
        let relay_connect_success_total = reg!(IntCounter::with_opts(Opts::new(
            "relay_connect_success_total",
            "Successful connect_relay calls from the cascade-relay retry loop \
             (first candidate to complete the WS+SDP handshake).",
        ))
        .context("relay_connect_success_total")?);

        let relay_candidate_exhausted_total = reg!(IntCounter::with_opts(Opts::new(
            "relay_candidate_exhausted_total",
            "Cascade-relay tasks where every upstream candidate failed or \
             timed out. T13 2026-07-01 bug-hunt (dependency_block/medium) — \
             previously only a tracing::warn! on exhaustion, invisible to \
             Grafana during a total upstream-hub outage.",
        ))
        .context("relay_candidate_exhausted_total")?);

        // G3 P0: Dependency Descriptor presence observability. Bounded label
        // (present=true/false). Pre-touch both values so the alert baseline
        // is 0 at startup, not absent — mirrors sdp_msid_injected_total.
        let sfu_dd_frames_total = reg!(IntCounterVec::new(
            Opts::new(
                "dd_frames_total",
                "Forwarded RTP packets inspected for the AV1 Dependency \
                 Descriptor (DD) header extension, by presence. G3 P0 \
                 observability-only — no packet is dropped based on this \
                 counter. present=true means the DD extension was parsed on \
                 the incoming packet (str0m ExtensionSerializer seam + \
                 URI-rebind delivered DD bytes to the fanout path)."
            ),
            &["present"],
        )
        .context("sfu_dd_frames_total")?);
        let _ = sfu_dd_frames_total.with_label_values(&["true"]).get();
        let _ = sfu_dd_frames_total.with_label_values(&["false"]).get();

        // G3 P1: temporal-layer drop counter. Bounded label (4 values:
        // 0/1/2/3plus). Pre-touch all so the baseline is 0 at startup.
        let sfu_dd_temporal_drops_total = reg!(IntCounterVec::new(
            Opts::new(
                "dd_temporal_drops_total",
                "Forwarded RTP packets dropped by the G3 P1 per-subscriber \
                 temporal-layer filter, by the packet's temporal_id. A packet \
                 is dropped when its parsed Dependency Descriptor temporal_id \
                 exceeds the subscriber's max_vfm_temporal_layer cap. \
                 Decode-safe: in temporal SVC a frame at layer T references \
                 only frames at layer <= T (AV1 spec sec 3), so dropping \
                 temporal_id > cap leaves a decodable lower-rate stream. \
                 Label 3plus collapses all temporal_id >= 3 to bound cardinality."
            ),
            &["temporal_id"],
        )
        .context("sfu_dd_temporal_drops_total")?);
        let _ = sfu_dd_temporal_drops_total.with_label_values(&["0"]).get();
        let _ = sfu_dd_temporal_drops_total.with_label_values(&["1"]).get();
        let _ = sfu_dd_temporal_drops_total.with_label_values(&["2"]).get();
        let _ = sfu_dd_temporal_drops_total
            .with_label_values(&["3plus"])
            .get();

        Ok(Self {
            registry: Arc::new(registry),
            active_rooms,
            active_participants,
            client_ws_disabled,
            forwarded_packets_total,
            layer_selection_total,
            sfu_keyframe_on_switch_total,
            dominant_speaker_changes_total,
            client_connect_total,
            client_disconnect_total,
            bandwidth_estimate_bps,
            combined_bps_binding_term,
            pacer_layer_total,
            layer_transitions_total,
            e2e_handshake_failures_total,
            dominant_speaker_hysteresis_ms,
            speaker_immediate,
            speaker_medium,
            speaker_long,
            client_ws_active_sessions: client_ws_metrics.active_sessions,
            client_ws_sessions_started_total: client_ws_metrics.sessions_started_total,
            client_ws_handshake_failures_total: client_ws_metrics.handshake_failures_total,
            client_ws_offer_processed_total: client_ws_metrics.offer_processed_total,
            client_ws_answer_sent_total: client_ws_metrics.answer_sent_total,
            client_ws_session_ended_total: client_ws_metrics.session_ended_total,
            client_ws_session_duration_seconds: client_ws_metrics.session_duration_seconds,
            session_replaced_total: client_ws_metrics.session_replaced_total,
            udp_send_failed,
            client_delivered_media_count,
            udp_loop_iterations_total,
            sfu_udp_loop_iteration_seconds,
            inject_channel_closed_total,
            chat_relay_tx_bytes_total,
            chat_relay_rx_bytes_total,
            chat_relay_dropped_total,
            chat_relay_active_channels,
            relay_jwt_verify_total,
            relay_api_enabled,
            vfm_enabled,
            voice_relay_tx_bytes_total,
            voice_relay_rx_bytes_total,
            voice_relay_dropped,
            voice_relay_active_channels,
            ice_state_total,
            sdp_msid_injected_total,
            tracks_map_sent_total,
            sfu_forward_decisions_total,
            sfu_subscription_setup_total,
            sfu_late_join_resync_total,
            sfu_str0m_output_total,
            sfu_track_out_state_transitions_total,
            sfu_renegotiation_offers_sent_total,
            sfu_renegotiation_answers_total,
            sfu_wire_written_total,
            sfu_renegotiation_offers_dropped_total,
            sfu_renegotiation_tracks_map_update_dropped_total,
            peer_rtt_seconds,
            peer_loss_fraction,
            peer_bandwidth_estimate_bps,
            media_egress_jitter_ticks,
            media_egress_nacks_received_total,
            media_egress_firs_received_total,
            media_egress_plis_received_total,
            media_ingress_jitter_ticks,

            sfu_writer_write_errors_total,
            sfu_solo_room_kicked_total,
            sfu_bwe_hint_received_total,
            sfu_bwe_hint_throttled_total,
            sfu_bwe_hint_registry_mutex_poisoned_total,
            sfu_bwe_hint_rate_limit_min_interval_ms,
            udp_bogon_dest_dropped_total,
            sfu_admission_rejected_total,
            relay_connect_success_total,
            relay_candidate_exhausted_total,
            pacer_tick_throttled_total,
            sfu_dd_frames_total,
            sfu_dd_temporal_drops_total,
        })
    }

    /// Encode the registry in Prometheus text format 0.0.4.
    pub fn encode_text(&self) -> anyhow::Result<String> {
        let mut buf = Vec::new();
        TextEncoder::new()
            .encode(&self.registry.gather(), &mut buf)
            .context("encode metrics")?;
        String::from_utf8(buf).context("utf8")
    }
}

impl Default for SfuMetrics {
    fn default() -> Self {
        Self::new().expect("SfuMetrics::new at startup")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Phase C: sdp_msid_injected_total is registered and both label values
    /// start at 0. The pre-touch in `new()` materialises the series so alert
    /// rules have a stable baseline before the first offer arrives.
    #[test]
    fn sdp_msid_injected_total_registered_and_baseline_zero() {
        let m = SfuMetrics::new().expect("metrics build");
        assert_eq!(
            m.sdp_msid_injected_total.with_label_values(&["true"]).get(),
            0,
            "has_msid=true must start at 0"
        );
        assert_eq!(
            m.sdp_msid_injected_total
                .with_label_values(&["false"])
                .get(),
            0,
            "has_msid=false must start at 0"
        );
        let text = m.encode_text().expect("encode metrics");
        assert!(
            text.contains("sfu_sdp_msid_injected_total"),
            "sfu_sdp_msid_injected_total must appear in /metrics output, got:\n{text}",
        );
    }

    /// SFU forwarding observability counters are registered and the
    /// late-join pre-touched label values start at 0.
    ///
    /// Dynamic-label counters (forward_decisions, subscription_setup,
    /// str0m_output) have no pre-touch, so they are absent from /metrics
    /// until first use. We verify them by inc-ing a test label pair and
    /// confirming (a) the counter was accepted without panicking and
    /// (b) the HELP line appears in the encoded text.
    #[test]
    fn sfu_forwarding_observability_counters_registered() {
        let m = SfuMetrics::new().expect("metrics build");

        // late_join pre-touch — static label combinations, must start at 0.
        assert_eq!(
            m.sfu_late_join_resync_total
                .with_label_values(&["peer_joined_late", "tracks_map_sent"])
                .get(),
            0,
            "late_join tracks_map_sent must start at 0"
        );
        assert_eq!(
            m.sfu_late_join_resync_total
                .with_label_values(&["peer_joined_late", "no_op_empty_room"])
                .get(),
            0,
            "late_join no_op_empty_room must start at 0"
        );

        // Dynamic counters: touch once to materialise the series, then read back.
        m.sfu_forward_decisions_total
            .with_label_values(&["1", "2", "audio", "forwarded"])
            .inc();
        assert_eq!(
            m.sfu_forward_decisions_total
                .with_label_values(&["1", "2", "audio", "forwarded"])
                .get(),
            1,
            "sfu_forward_decisions_total must accept labels and increment"
        );

        m.sfu_subscription_setup_total
            .with_label_values(&["1", "2", "wired"])
            .inc();
        assert_eq!(
            m.sfu_subscription_setup_total
                .with_label_values(&["1", "2", "wired"])
                .get(),
            1,
            "sfu_subscription_setup_total must accept labels and increment"
        );

        m.sfu_str0m_output_total
            .with_label_values(&["1", "transmit"])
            .inc();
        assert_eq!(
            m.sfu_str0m_output_total
                .with_label_values(&["1", "transmit"])
                .get(),
            1,
            "sfu_str0m_output_total must accept labels and increment"
        );

        // After materialisation, HELP lines must appear in encoded text.
        let text = m.encode_text().expect("encode metrics");
        assert!(
            text.contains("sfu_sfu_forward_decisions_total"),
            "sfu_forward_decisions_total must appear in /metrics after first inc, got:\n{text}",
        );
        assert!(
            text.contains("sfu_sfu_subscription_setup_total"),
            "sfu_subscription_setup_total must appear in /metrics after first inc, got:\n{text}",
        );
        assert!(
            text.contains("sfu_sfu_late_join_resync_total"),
            "sfu_late_join_resync_total must appear in /metrics (pre-touched), got:\n{text}",
        );
        assert!(
            text.contains("sfu_sfu_str0m_output_total"),
            "sfu_str0m_output_total must appear in /metrics after first inc, got:\n{text}",
        );
    }

    /// str0m issue #952: `sfu_writer_write_errors_total` is registered with
    /// both expected label values at 0 from startup (pre-touch).
    ///
    /// Validates Fix B: the metric is reachable in /metrics before any write
    /// error occurs so alert rules have a stable baseline.
    #[test]
    fn sfu_writer_write_errors_registered_and_baseline_zero() {
        let m = SfuMetrics::new().expect("metrics build");

        assert_eq!(
            m.sfu_writer_write_errors_total
                .with_label_values(&["write_without_poll"])
                .get(),
            0,
            "write_without_poll must start at 0"
        );
        assert_eq!(
            m.sfu_writer_write_errors_total
                .with_label_values(&["other"])
                .get(),
            0,
            "other must start at 0"
        );

        // Simulate WriteWithoutPoll dispatch: increment write_without_poll.
        m.sfu_writer_write_errors_total
            .with_label_values(&["write_without_poll"])
            .inc();
        assert_eq!(
            m.sfu_writer_write_errors_total
                .with_label_values(&["write_without_poll"])
                .get(),
            1,
            "write_without_poll must be 1 after one inc"
        );

        // Simulate other error: increment other.
        m.sfu_writer_write_errors_total
            .with_label_values(&["other"])
            .inc();
        assert_eq!(
            m.sfu_writer_write_errors_total
                .with_label_values(&["other"])
                .get(),
            1,
            "other must be 1 after one inc"
        );

        let text = m.encode_text().expect("encode metrics");
        assert!(
            text.contains("sfu_sfu_writer_write_errors_total"),
            "sfu_writer_write_errors_total must appear in /metrics output, got:\n{text}",
        );
    }

    /// Incident 2026-05-06: `active_rooms` was `set(1)` at registry init
    /// and never updated. Reviewer surfaced the hardcoded-constant gauge
    /// in the post-mortem bundle. Default must now be 0 — actual room
    /// presence is wired by `Registry::insert` / `reap_dead` /
    /// `evict_for_steal`.
    #[test]
    fn active_rooms_defaults_to_zero() {
        let m = SfuMetrics::new().expect("metrics build");
        assert_eq!(
            m.active_rooms.get(),
            0,
            "active_rooms must default to 0 — single-room SFU sets it to 1 \
             only when first client is inserted; the legacy hardcoded set(1) \
             at init masked feature-gate misconfigurations (see 2026-05-06 \
             motherly1 outage post-mortem)."
        );
    }

    /// Incident 2026-05-06: `SIGNALING_SFU_SECRET` was missing in compose
    /// for 8 weeks; only signal was a `tracing::info!` line. New gauge
    /// `sfu_client_ws_disabled` (0 active / 1 disabled) lets Prometheus
    /// alert on degraded state directly.
    ///
    /// Round-2 review fix: default to **1 (disabled)** so any /metrics
    /// scrape that races container startup before main.rs reaches the
    /// `client_ws` branch sees the safe-pessimistic state, not a
    /// false-clean 0. main.rs flips to 0 only inside the
    /// `if let Some(secret_bytes)` success arm.
    #[test]
    fn client_ws_disabled_gauge_defaults_to_one_and_is_in_registry() {
        let m = SfuMetrics::new().expect("metrics build");
        assert_eq!(
            m.client_ws_disabled.get(),
            1,
            "client_ws_disabled must default to 1 (disabled-until-proven-enabled) \
             so /metrics scrapes that race container startup observe the \
             safe-pessimistic state. main.rs flips to 0 only inside the \
             SIGNALING_SFU_SECRET success branch."
        );

        let text = m.encode_text().expect("encode metrics");
        assert!(
            text.contains("sfu_client_ws_disabled"),
            "sfu_client_ws_disabled must be reachable via /metrics scrape, \
             got:\n{text}",
        );
    }

    /// G3 P3a: the `vfm` temporal-drop subsystem is compiled into the prod
    /// image only when `Dockerfile.sfu` builds `oxpulse-sfu` with
    /// `--features vfm`. This test is itself `#[cfg(feature = "vfm")]`-gated:
    /// under a featureless build (CI's `cargo test --workspace`) the `set(1)`
    /// is compiled out, so the gauge stays 0 and this assert would be wrong to
    /// run — the gate compiles the test out there. CI's
    /// `cargo test -p oxpulse-sfu --features test-utils,vfm` job exercises it.
    /// A 0 under the feature means the gauge was not registered, not set under
    /// the cfg, or the field was dropped from the struct — all of which would
    /// silently hide a prod build that compiled the drop path out.
    #[cfg(feature = "vfm")]
    #[test]
    fn sfu_vfm_enabled_gauge_reads_one_when_feature_is_on() {
        let m = SfuMetrics::new().expect("metrics build");
        assert_eq!(
            m.vfm_enabled.get(),
            1,
            "vfm_enabled must read 1 when the vfm feature is compiled in. A 0 \
             means the G3 temporal-drop path is compiled out of this build or \
             the gauge was not set under #[cfg(feature = \"vfm\")] in \
             SfuMetrics::new."
        );

        let text = m.encode_text().expect("encode metrics");
        assert!(
            text.contains("sfu_vfm_enabled"),
            "sfu_vfm_enabled must be reachable via /metrics scrape, \
             got:\n{text}",
        );
    }
}
