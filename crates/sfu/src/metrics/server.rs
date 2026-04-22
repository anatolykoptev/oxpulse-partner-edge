//! Metrics HTTP server — axum handler for `GET /metrics` (Prometheus
//! text format 0.0.4). Split from [`super`] because HTTP transport is
//! a distinct concern from the metric registry construction.

use std::sync::Arc;

use anyhow::Context;

use super::SfuMetrics;

/// Spawn the axum metrics HTTP server on `bind_addr` (e.g. `"0.0.0.0:9317"`).
/// Returns the [`tokio::task::JoinHandle`] so the caller can abort on shutdown.
pub fn spawn_metrics_server(
    bind_addr: String,
    metrics: Arc<SfuMetrics>,
) -> anyhow::Result<tokio::task::JoinHandle<()>> {
    use axum::routing::get;
    use axum::Router;
    use std::net::TcpListener;

    let listener =
        TcpListener::bind(&bind_addr).with_context(|| format!("bind metrics at {bind_addr}"))?;
    // Must set non-blocking before handing to tokio, regardless of whether
    // we are currently inside a runtime or not — `from_std` requires it.
    listener
        .set_nonblocking(true)
        .context("set_nonblocking for metrics listener")?;
    let tok_listener =
        tokio::net::TcpListener::from_std(listener).context("convert TcpListener to tokio")?;
    tracing::info!(%bind_addr, "SFU metrics server ready");

    let handle = tokio::spawn(async move {
        use axum::response::IntoResponse;
        let app = Router::new().route(
            "/metrics",
            get(move || {
                let m = metrics.clone();
                async move {
                    match m.encode_text() {
                        Ok(body) => (
                            axum::http::StatusCode::OK,
                            [(
                                axum::http::header::CONTENT_TYPE,
                                "text/plain; version=0.0.4",
                            )],
                            body,
                        )
                            .into_response(),
                        Err(e) => {
                            tracing::warn!(error = %e, "metrics encode failed");
                            (
                                axum::http::StatusCode::INTERNAL_SERVER_ERROR,
                                [(axum::http::header::CONTENT_TYPE, "text/plain")],
                                "encode failed".to_string(),
                            )
                                .into_response()
                        }
                    }
                }
            }),
        );
        if let Err(e) = axum::serve(tok_listener, app).await {
            tracing::warn!(error = %e, "metrics server exited");
        }
    });

    Ok(handle)
}
