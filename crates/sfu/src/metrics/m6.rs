//! M6.1 observability metrics — group-call feature counters and histograms.
//!
//! Concern: metrics that expose group-call quality signals (layer transitions,
//! E2E handshake outcome, dominant-speaker hysteresis). Split from
//! [`super`] because these are a distinct observability concern from the
//! M1.5 core infrastructure metrics (clients, packets, BWE).
//!
//! All types are re-exported through [`super::SfuMetrics`]; callers never
//! import from this module directly.

use anyhow::Context;
use prometheus::{Histogram, HistogramOpts, IntCounter, IntCounterVec, Opts, Registry};

/// Construct and register the three M6.1 metrics onto `registry`.
///
/// Called once from [`super::SfuMetrics::new`] after the core metrics are
/// registered. Returns `(layer_transitions_total, e2e_handshake_failures_total,
/// dominant_speaker_hysteresis_ms)`.
pub(super) fn register(
    registry: &Registry,
) -> anyhow::Result<(IntCounterVec, IntCounter, Histogram)> {
    macro_rules! reg {
        ($m:expr) => {{
            let m = $m;
            registry
                .register(Box::new(m.clone()))
                .context("metric registration")?;
            m
        }};
    }

    // Simulcast layer *transitions* — fires only when `desired_layer` changes.
    // Labels: from (prev RID), to (new RID), peer (ClientId u64 as string).
    // Cardinality: from ∈ {q,h,f,other} × to ∈ {q,h,f,other} × peer;
    // peer series are scrubbed in `registry::bwe::reap_dead` on disconnect.
    let layer_transitions_total = reg!(IntCounterVec::new(
        Opts::new(
            "layer_transitions_total",
            "Simulcast layer transitions per subscriber (fires on desired_layer change only)",
        ),
        &["from", "to", "peer"],
    )
    .context("layer_transitions_total")?);

    // E2E handshake failure counter — wired but always 0 from the SFU.
    // The SFU forwards DC id:1 opaque; it cannot inspect encrypted epoch frames.
    // M6.3 will emit this count from the web client instead.
    // Kept here so dashboards/alerts can reference the metric name without
    // a schema migration when M6.3 lands.
    let e2e_handshake_failures_total = reg!(IntCounter::with_opts(Opts::new(
        "e2e_handshake_failures_total",
        "E2E key-exchange failures (SFU-side placeholder; always 0 — see M6.3 for client emission)",
    ))
    .context("e2e_handshake_failures_total")?);

    // Histogram of inter-speaker-change intervals (ms) as a proxy for the
    // hysteresis delay. Buckets: 0-10 s range with fine resolution at the low
    // end (mediasoup's C2 threshold is ~300 ms tick cadence).
    let dominant_speaker_hysteresis_ms = reg!(Histogram::with_opts(
        HistogramOpts::new(
            "dominant_speaker_hysteresis_ms",
            "Wall-clock interval between consecutive dominant-speaker changes (ms proxy for hysteresis)",
        )
        .buckets(vec![
            100.0, 300.0, 500.0, 1_000.0, 2_000.0, 5_000.0, 10_000.0, 30_000.0,
        ]),
    )
    .context("dominant_speaker_hysteresis_ms")?);

    Ok((
        layer_transitions_total,
        e2e_handshake_failures_total,
        dominant_speaker_hysteresis_ms,
    ))
}
