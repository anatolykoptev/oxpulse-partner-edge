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
    /// Always 1 in M1.5 (single-room SFU). Reserved for M2+ multi-room.
    pub active_rooms: IntGauge,
    /// Current number of live clients.
    pub active_participants: IntGauge,
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
            "Currently active rooms (always 1 in M1.5)",
        ))
        .context("active_rooms")?);
        active_rooms.set(1);

        let active_participants = reg!(IntGauge::with_opts(Opts::new(
            "active_participants",
            "Live client count",
        ))
        .context("active_participants")?);

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

        Ok(Self {
            registry: Arc::new(registry),
            active_rooms,
            active_participants,
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
