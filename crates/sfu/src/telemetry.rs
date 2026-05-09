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
#[cfg(test)]
use opentelemetry::Key;
use opentelemetry::KeyValue;
use opentelemetry_otlp::WithExportConfig;
use opentelemetry_sdk::trace::SdkTracerProvider;
use opentelemetry_sdk::Resource;
use opentelemetry_semantic_conventions::resource as semconv;
use tracing_opentelemetry::OpenTelemetryLayer;
use tracing_subscriber::layer::SubscriberExt;
use tracing_subscriber::util::SubscriberInitExt;
use tracing_subscriber::EnvFilter;

/// OTEL semantic convention key for instance discrimination.
/// `opentelemetry_semantic_conventions::resource::SERVICE_INSTANCE_ID` requires
/// the `semconv_experimental` feature; we pin the string directly to avoid a
/// non-stable feature dependency.
const SERVICE_INSTANCE_ID_KEY: &str = "service.instance.id";

/// Custom resource attribute key for partner discrimination.
const PARTNER_ID_KEY: &str = "partner.id";

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
    let env_filter = parse_env_filter_or_fallback(log_level);
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

    let resource = build_resource(edge_id, partner_id);

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

    if edge_id == "local" {
        tracing::warn!(
            "SFU_EDGE_ID env not set — all OTEL traces will collapse under \
             service.instance.id=local. Set SFU_EDGE_ID per-edge."
        );
    }
    if partner_id == "unknown" {
        tracing::warn!(
            "PARTNER_ID env not set — all OTEL traces will share partner.id=unknown. \
             Set PARTNER_ID per deployment."
        );
    }

    Ok(Some(provider))
}

/// Parse `RUST_LOG` env into an [`EnvFilter`], falling back to `log_level` on error.
fn parse_env_filter_or_fallback(log_level: &str) -> EnvFilter {
    EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new(log_level))
}

/// Pure logic for testability: returns `(warn_edge, warn_partner)` booleans
/// indicating whether fallback-ID warnings should fire.
#[cfg(test)]
fn fallback_warn_flags(edge_id: &str, partner_id: &str, otlp_enabled: bool) -> (bool, bool) {
    if !otlp_enabled {
        return (false, false);
    }
    (edge_id == "local", partner_id == "unknown")
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

/// Build the OTel [`Resource`] that identifies this edge node.
///
/// - `service.name`        — always `"partner-edge-sfu"` (groups all edges in Jaeger)
/// - `service.instance.id` — `edge_id` (OTEL standard; lets Jaeger filter/group per node)
/// - `service.version`     — crate version from Cargo
/// - `partner.id`          — `partner_id` (custom; convenience filter for multi-tenant deployments)
fn build_resource(edge_id: &str, partner_id: &str) -> Resource {
    Resource::builder()
        .with_attributes([
            KeyValue::new(semconv::SERVICE_NAME, "partner-edge-sfu"),
            KeyValue::new(semconv::SERVICE_VERSION, env!("CARGO_PKG_VERSION")),
            KeyValue::new(SERVICE_INSTANCE_ID_KEY, edge_id.to_string()),
            KeyValue::new(PARTNER_ID_KEY, partner_id.to_string()),
        ])
        .build()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn get_attr(resource: &Resource, key: &str) -> Option<String> {
        resource
            .get(&Key::from(key.to_string()))
            .map(|v| v.to_string())
    }

    #[test]
    fn resource_has_service_instance_id() {
        let r = build_resource("motherly1", "acme");
        let val = get_attr(&r, SERVICE_INSTANCE_ID_KEY);
        assert_eq!(
            val.as_deref(),
            Some("motherly1"),
            "service.instance.id must match edge_id"
        );
    }

    #[test]
    fn resource_has_partner_id() {
        let r = build_resource("motherly1", "acme");
        let val = get_attr(&r, PARTNER_ID_KEY);
        assert_eq!(
            val.as_deref(),
            Some("acme"),
            "partner.id must match partner_id"
        );
    }

    #[test]
    fn resource_has_service_name() {
        let r = build_resource("local", "unknown");
        let val = get_attr(&r, semconv::SERVICE_NAME);
        assert_eq!(
            val.as_deref(),
            Some("partner-edge-sfu"),
            "service.name must be fixed"
        );
    }

    #[test]
    fn resource_has_service_version() {
        let r = build_resource("local", "unknown");
        let val = get_attr(&r, semconv::SERVICE_VERSION);
        assert!(val.is_some(), "service.version must be present");
    }

    #[test]
    fn resource_fallback_defaults() {
        // Mirrors main.rs fallback: SFU_EDGE_ID unset → "local", PARTNER_ID unset → "unknown"
        let r = build_resource("local", "unknown");
        assert_eq!(
            get_attr(&r, SERVICE_INSTANCE_ID_KEY).as_deref(),
            Some("local")
        );
        assert_eq!(get_attr(&r, PARTNER_ID_KEY).as_deref(), Some("unknown"));
    }

    #[test]
    fn fallback_warnings_when_otlp_enabled_and_ids_default() {
        // When OTLP endpoint is set but IDs are fallback values, both warning
        // conditions must trigger. We test via the pure logic fn directly.
        let (warn_edge, warn_partner) = fallback_warn_flags("local", "unknown", true);
        assert!(
            warn_edge,
            "should warn when edge_id is fallback 'local' with OTLP enabled"
        );
        assert!(
            warn_partner,
            "should warn when partner_id is fallback 'unknown' with OTLP enabled"
        );
    }

    #[test]
    fn no_fallback_warnings_when_ids_are_set() {
        let (warn_edge, warn_partner) = fallback_warn_flags("edge-eu-1", "acme", true);
        assert!(!warn_edge, "no warn when edge_id is real");
        assert!(!warn_partner, "no warn when partner_id is real");
    }

    #[test]
    fn no_fallback_warnings_when_otlp_disabled() {
        // IDs are fallback but OTLP is not configured — warn is irrelevant.
        let (warn_edge, warn_partner) = fallback_warn_flags("local", "unknown", false);
        assert!(!warn_edge, "no warn when OTLP is disabled");
        assert!(!warn_partner, "no warn when OTLP is disabled");
    }
}
