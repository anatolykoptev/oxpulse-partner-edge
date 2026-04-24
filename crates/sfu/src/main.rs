use std::sync::Arc;

use tokio::signal;
use tracing_subscriber::EnvFilter;

use anyhow::Context;
use oxpulse_sfu::{
    metrics::spawn_metrics_server,
    relay::{client::connect_relay, handler::{spawn_relay_api, SeenJtis}, task::RelayTask},
    udp_loop, SfuConfig, SfuMetrics,
};

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

    // FIPS 140-3 compile-time check.
    // aws-lc-rs with `features = ["fips"]` uses aws-lc-fips-sys (NIST validated).
    // No runtime enable() call needed — FIPS mode is fully compile-time.
    if config.fips_mode {
        #[cfg(feature = "fips")]
        tracing::info!("FIPS 140-3 mode ACTIVE — binary compiled with aws-lc-fips-sys");
        #[cfg(not(feature = "fips"))]
        anyhow::bail!(
            "SFU_FIPS=1 requires binary compiled with --features fips. \
             Rebuild: CARGO_BUILD_JOBS=2 cargo build --release --features fips"
        );
    }

    // Shared metrics instance — registry and UDP loop both hold a clone.
    let metrics = Arc::new(SfuMetrics::new()?);

    // Spawn the Prometheus HTTP server on metrics_port.
    let metrics_addr = format!("{}:{}", config.bind_address, config.metrics_port);
    let metrics_handle = spawn_metrics_server(metrics_addr, metrics.clone())?;

    // Relay API -- JWT-authenticated POST /relay/connect for cascade relay setup.
    let relay_secret_str = std::env::var("RELAY_JWT_SECRET").map_err(|_| {
        anyhow::anyhow!(
            "RELAY_JWT_SECRET environment variable is required — see README.md for setup instructions"
        )
    })?;
    if relay_secret_str == "change-me-in-production" {
        anyhow::bail!(
            "RELAY_JWT_SECRET is the documented placeholder value — set a random secret of at least 32 bytes. \
             Generate one with: openssl rand -hex 32"
        );
    }
    if relay_secret_str.len() < 32 {
        anyhow::bail!(
            "RELAY_JWT_SECRET is too short ({} bytes) — minimum 32 bytes required",
            relay_secret_str.len()
        );
    }
    let relay_secret = Arc::<[u8]>::from(relay_secret_str.into_bytes());

    let relay_addr = format!("{}:{}", config.bind_address, config.relay_api_port);
    let relay_listener = tokio::net::TcpListener::bind(&relay_addr)
        .await
        .with_context(|| format!("bind relay API on {relay_addr}"))?;
    let (relay_tx, mut relay_rx) = tokio::sync::mpsc::channel::<RelayTask>(16);
    let seen_jtis: SeenJtis = std::sync::Arc::new(std::sync::Mutex::new(std::collections::HashSet::new()));
    // Ed25519 public key for verifying relay JWTs (preferred over HS256).
    let relay_signing_pubkey = config.sfu_signing_public_key
        .as_ref()
        .map(|s| Arc::new(s.clone()));

    let relay_handle = spawn_relay_api(relay_listener, relay_secret, relay_signing_pubkey, relay_tx, seen_jtis)?;
    tracing::info!(addr = %relay_addr, "relay API listening");

    // Drain relay task channel — spawn a WebRTC relay client for each task.
    tokio::spawn(async move {
        while let Some(task) = relay_rx.recv().await {
            let url = task.upstream_url.clone();
            let token = task.upstream_room_token.clone();
            let room_id = task.room_id.clone();
            tokio::spawn(async move {
                // local_udp_addr will come from SfuConfig in a follow-up task.
                // 0.0.0.0:0 is a placeholder; ICE will not complete until this
                // is wired to the actual public UDP port.
                let local_addr: std::net::SocketAddr = "0.0.0.0:0".parse().unwrap();
                if let Err(e) = connect_relay(&url, &token, local_addr).await {
                    tracing::warn!(error = %e, %room_id, "relay connection failed");
                }
            });
        }
    });

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

    // Stop the metrics server and relay API server.
    metrics_handle.abort();
    relay_handle.abort();

    result
}
