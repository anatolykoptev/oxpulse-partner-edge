use std::sync::Arc;

use tokio::signal;
use tracing_subscriber::EnvFilter;

use oxpulse_sfu::{metrics::spawn_metrics_server, udp_loop, SfuConfig, SfuMetrics};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let config = SfuConfig::from_env();

    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new(&config.log_level)),
        )
        .init();

    #[cfg(unix)]
    let mut sigterm = signal::unix::signal(signal::unix::SignalKind::terminate())
        .expect("failed to install SIGTERM handler at startup");

    // Shared metrics instance — registry and UDP loop both hold a clone.
    let metrics = Arc::new(SfuMetrics::new()?);

    // Spawn the Prometheus HTTP server on metrics_port.
    let metrics_addr = format!("{}:{}", config.bind_address, config.metrics_port);
    let metrics_handle = spawn_metrics_server(metrics_addr, metrics.clone())?;

    // Shutdown future: resolves on SIGINT or SIGTERM.
    let shutdown = async move {
        #[cfg(unix)]
        tokio::select! {
            res = signal::ctrl_c() => match res {
                Ok(()) => tracing::info!("received SIGINT"),
                Err(e) => tracing::error!(error = %e, "ctrl_c handler failed"),
            },
            _ = sigterm.recv() => tracing::info!("received SIGTERM"),
        }

        #[cfg(not(unix))]
        match signal::ctrl_c().await {
            Ok(()) => tracing::info!("received SIGINT"),
            Err(e) => tracing::error!(error = %e, "ctrl_c handler failed"),
        }
    };

    // Run the UDP loop — blocks until shutdown fires.
    let result = udp_loop::run_udp_loop(config, metrics, shutdown).await;

    // Stop the metrics server.
    metrics_handle.abort();

    result
}
