//! OpenTelemetry / Jaeger distributed-tracing pipeline.
//!
//! Opt-in via `OTEL_EXPORTER_OTLP_ENDPOINT` env. Empty / unset = no exporter
//! is created and the SFU runs with the `tracing-subscriber` stdout layer
//! exclusively (zero perf overhead beyond the existing span construction
//! that `#[instrument]` already does, which is itself a no-op when the
//! global subscriber has no layer that consumes it).
//!
//! Why OTLP/gRPC and not Jaeger-native:
//!   The Jaeger collector advertises `COLLECTOR_OTLP_ENABLED=true` on
//!   :4317 (gRPC) and :4318 (HTTP). The native `jaeger-client-rust`
//!   crates are deprecated upstream — opentelemetry maintainers point all
//!   integrations at OTLP. Same wire format that Tempo / Honeycomb /
//!   Datadog accept, so the only thing that changes if we switch backend
//!   is the env var.
//!
//! What gets sampled:
//!   We default to AlwaysOn — the SFU's cardinality is bounded
//!   (1 room × N peers × edge count, typical N ≤ 32) so the trace volume
//!   is fine without head-based sampling. Switch via OTEL_TRACES_SAMPLER
//!   env if a partner reports cost pressure on the collector side.

use anyhow::Context;
use opentelemetry::global;
use opentelemetry::trace::TracerProvider as _;
use opentelemetry::KeyValue;
use opentelemetry_otlp::WithExportConfig;
use opentelemetry_sdk::trace::SdkTracerProvider;
use opentelemetry_sdk::Resource;
use opentelemetry_semantic_conventions::resource as semconv;
use tracing_opentelemetry::OpenTelemetryLayer;
use tracing_subscriber::layer::SubscriberExt;
use tracing_subscriber::util::SubscriberInitExt;
use tracing_subscriber::EnvFilter;

/// Initialise tracing-subscriber with the stdout layer plus, when configured,
/// the OTLP layer that ships spans to Jaeger / OTel Collector.
///
/// `edge_id` is attached as a Resource attribute so spans group by edge in
/// the Jaeger UI without needing per-span labels.
///
/// Returns the `SdkTracerProvider` so the caller can call `shutdown()` on
/// graceful exit (flush in-flight spans). When OTLP is disabled, returns
/// `None` and the caller has nothing to clean up.
pub fn init(
    log_level: &str,
    edge_id: &str,
    partner_id: &str,
) -> anyhow::Result<Option<SdkTracerProvider>> {
    let env_filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new(log_level));
    let stdout_layer = tracing_subscriber::fmt::layer();

    let endpoint = std::env::var("OTEL_EXPORTER_OTLP_ENDPOINT").unwrap_or_default();
    if endpoint.is_empty() {
        // No exporter — only the stdout layer.
        tracing_subscriber::registry()
            .with(env_filter)
            .with(stdout_layer)
            .init();
        return Ok(None);
    }

    let resource = Resource::builder()
        .with_attributes([
            KeyValue::new(semconv::SERVICE_NAME, "partner-edge-sfu"),
            KeyValue::new(semconv::SERVICE_VERSION, env!("CARGO_PKG_VERSION")),
            KeyValue::new("edge_id", edge_id.to_string()),
            KeyValue::new("partner_id", partner_id.to_string()),
        ])
        .build();

    let exporter = opentelemetry_otlp::SpanExporter::builder()
        .with_tonic()
        .with_endpoint(&endpoint)
        .build()
        .context("build OTLP exporter")?;

    let provider = SdkTracerProvider::builder()
        .with_resource(resource)
        .with_batch_exporter(exporter)
        .build();

    let tracer = provider.tracer("partner-edge-sfu");
    global::set_tracer_provider(provider.clone());

    let otel_layer = OpenTelemetryLayer::new(tracer);

    tracing_subscriber::registry()
        .with(env_filter)
        .with(stdout_layer)
        .with(otel_layer)
        .init();

    tracing::info!(%endpoint, "OTLP trace exporter initialised");
    Ok(Some(provider))
}

/// Flush in-flight spans and tear down the exporter. Call on graceful exit
/// (after the UDP loop returns). Safe to call when `init` returned `None`.
pub fn shutdown(provider: Option<SdkTracerProvider>) {
    if let Some(p) = provider {
        if let Err(e) = p.shutdown() {
            tracing::warn!(error = %e, "OTLP trace provider shutdown failed");
        }
    }
}
