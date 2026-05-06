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
    Encoder, GaugeVec, Histogram, IntCounter, IntCounterVec, IntGauge, IntGaugeVec, Opts, Registry,
    TextEncoder,
};

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
    /// M5.3: pacer layer selections per subscriber and RID.
    pub pacer_layer_total: IntCounterVec,
    /// M6.1: simulcast layer transitions per subscriber (from/to/peer labels).
    pub layer_transitions_total: IntCounterVec,
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
        // Default 0 (active). main.rs flips to 1 on the degraded path
        // (SIGNALING_SFU_SECRET missing) and explicitly sets 0 when the
        // client_ws task spawns successfully.

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

        let pacer_layer_total = reg!(IntCounterVec::new(
            Opts::new(
                "pacer_layer_total",
                "Pacer simulcast-layer selections per subscriber and RID (M5.3)",
            ),
            &["peer_id", "rid"],
        )
        .context("pacer_layer_total")?);

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

        Ok(Self {
            registry: Arc::new(registry),
            active_rooms,
            active_participants,
            client_ws_disabled,
            forwarded_packets_total,
            layer_selection_total,
            dominant_speaker_changes_total,
            client_connect_total,
            client_disconnect_total,
            bandwidth_estimate_bps,
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
            inject_channel_closed_total,
            chat_relay_tx_bytes_total,
            chat_relay_rx_bytes_total,
            chat_relay_dropped_total,
            chat_relay_active_channels,
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
    #[test]
    fn client_ws_disabled_gauge_defaults_to_zero_and_is_in_registry() {
        let m = SfuMetrics::new().expect("metrics build");
        assert_eq!(
            m.client_ws_disabled.get(),
            0,
            "client_ws_disabled must default to 0 (active) so the series \
             exists from startup and main.rs can flip to 1 only on the \
             degraded path."
        );

        let text = m.encode_text().expect("encode metrics");
        assert!(
            text.contains("sfu_client_ws_disabled"),
            "sfu_client_ws_disabled must be reachable via /metrics scrape, \
             got:\n{text}",
        );
    }
}
