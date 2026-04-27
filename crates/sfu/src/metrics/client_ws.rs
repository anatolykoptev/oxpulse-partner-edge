//! M4.B1 client_ws verification metrics — Phase 7 SFU group-call cutover.
//!
//! Concern: counters/gauges/histogram for the browser-facing
//! `/sfu/ws/{room_id}` WebSocket pipeline (handshake → SDP → media). Split
//! from [`super::m6`] because client_ws is a distinct surface (relay path
//! has its own seam) and the failure modes are dial-side rather than
//! group-call observability.
//!
//! `edge_id` is NOT registered as a per-counter label — the parent registry
//! is constructed with `Registry::new_custom(Some("sfu"), {edge_id=...})`,
//! so every series here picks up `sfu_*{edge_id="..."}` automatically and
//! adding the label twice would produce duplicate-label series.
//!
//! Reused from [`super::SfuMetrics`]; callers never import from here directly.

use anyhow::Context;
use prometheus::{Histogram, HistogramOpts, IntCounter, IntCounterVec, IntGauge, Opts, Registry};

/// Bundle returned by [`register`].
pub(super) struct ClientWsMetrics {
    pub active_sessions: IntGauge,
    pub sessions_started_total: IntCounter,
    /// labels: reason — bounded set, see `handshake_failure_reason` in
    /// `client_ws::handler` for the closed enum of values.
    pub handshake_failures_total: IntCounterVec,
    /// labels: outcome ∈ {ok, parse_err, sdp_err, ice_err}.
    pub offer_processed_total: IntCounterVec,
    pub answer_sent_total: IntCounter,
    /// labels: close_code ∈ {"1000","1001","4001","4002","4003","other"}.
    pub session_ended_total: IntCounterVec,
    pub session_duration_seconds: Histogram,
}

/// Construct and register the client_ws metrics onto the SFU registry.
pub(super) fn register(registry: &Registry) -> anyhow::Result<ClientWsMetrics> {
    macro_rules! reg {
        ($m:expr) => {{
            let m = $m;
            registry
                .register(Box::new(m.clone()))
                .context("metric registration")?;
            m
        }};
    }

    let active_sessions = reg!(IntGauge::with_opts(Opts::new(
        "client_ws_active_sessions",
        "Currently open client_ws sessions (M4.A1 browser dial path)",
    ))
    .context("client_ws_active_sessions")?);

    let sessions_started_total = reg!(IntCounter::with_opts(Opts::new(
        "client_ws_sessions_started_total",
        "Accepted client_ws upgrades (token verified + WS upgrade succeeded)",
    ))
    .context("client_ws_sessions_started_total")?);

    let handshake_failures_total = reg!(IntCounterVec::new(
        Opts::new(
            "client_ws_handshake_failures_total",
            "client_ws upgrade rejections by reason (pre-session)",
        ),
        &["reason"],
    )
    .context("client_ws_handshake_failures_total")?);

    let offer_processed_total = reg!(IntCounterVec::new(
        Opts::new(
            "client_ws_offer_processed_total",
            "Outcomes of SDP offer processing inside the client_ws session",
        ),
        &["outcome"],
    )
    .context("client_ws_offer_processed_total")?);

    let answer_sent_total = reg!(IntCounter::with_opts(Opts::new(
        "client_ws_answer_sent_total",
        "client_ws answer frames successfully sent to the browser",
    ))
    .context("client_ws_answer_sent_total")?);

    let session_ended_total = reg!(IntCounterVec::new(
        Opts::new(
            "client_ws_session_ended_total",
            "client_ws session terminations by close code",
        ),
        &["close_code"],
    )
    .context("client_ws_session_ended_total")?);

    // Buckets sized for video calls: short-lived rejections (<5s),
    // typical exchanges (5-30s SDP), and full call durations.
    let session_duration_seconds = reg!(Histogram::with_opts(
        HistogramOpts::new(
            "client_ws_session_duration_seconds",
            "Wall-clock duration of a client_ws session from upgrade-accepted to close",
        )
        .buckets(vec![
            1.0, 5.0, 30.0, 60.0, 300.0, 1_800.0, 3_600.0,
        ]),
    )
    .context("client_ws_session_duration_seconds")?);

    Ok(ClientWsMetrics {
        active_sessions,
        sessions_started_total,
        handshake_failures_total,
        offer_processed_total,
        answer_sent_total,
        session_ended_total,
        session_duration_seconds,
    })
}

/// Map an arbitrary close code to a bounded label string. Codes outside
/// the known set collapse to `"other"` to keep label cardinality bounded
/// (per-design rule: never let unbounded values flow into Prometheus
/// labels).
pub fn close_code_label(code: u16) -> &'static str {
    match code {
        1000 => "1000",
        1001 => "1001",
        4001 => "4001",
        4002 => "4002",
        4003 => "4003",
        _ => "other",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use prometheus::Registry;

    #[test]
    fn close_code_label_buckets_known_codes() {
        assert_eq!(close_code_label(1000), "1000");
        assert_eq!(close_code_label(4001), "4001");
        assert_eq!(close_code_label(4003), "4003");
    }

    #[test]
    fn close_code_label_unknown_collapses_to_other() {
        assert_eq!(close_code_label(0), "other");
        assert_eq!(close_code_label(1006), "other");
        assert_eq!(close_code_label(4999), "other");
    }

    #[test]
    fn register_succeeds_on_fresh_registry() {
        let registry = Registry::new();
        let m = register(&registry).expect("register must succeed");
        // Smoke: counters/gauge are usable.
        m.active_sessions.inc();
        m.sessions_started_total.inc();
        m.handshake_failures_total
            .with_label_values(&["other"])
            .inc();
        assert_eq!(m.active_sessions.get(), 1);
        assert_eq!(m.sessions_started_total.get(), 1);
    }
}
