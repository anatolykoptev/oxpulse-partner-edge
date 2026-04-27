use std::sync::Arc;

use tokio::signal;
use tracing_subscriber::EnvFilter;

use anyhow::Context;
use oxpulse_sfu::{
    client_ws::{spawn_client_ws_api, PendingClient},
    metrics::spawn_metrics_server,
    relay::{
        client::connect_relay,
        handler::{spawn_relay_api, SeenJtis},
        task::RelayTask,
    },
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

    // M4.A6 - parse_public_ip_env() emitted any warning *before* the
    // subscriber was initialized, so re-check here for visibility.
    if let Ok(raw) = std::env::var("SFU_PUBLIC_IP") {
        if !raw.is_empty() && config.public_ip.is_none() {
            tracing::warn!(
                value = %raw,
                "SFU_PUBLIC_IP is set but did not parse as an IP address \
            falling back to the bind address for host candidates. \
            Off-box browsers will fail ICE."
            );
        }
    }

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
    // RELAY_JWT_SECRET is optional: if absent, the relay API is disabled and the
    // SFU operates in standalone mode (no cascade relay). Set it to enable relay.
    let relay_secret_opt = std::env::var("RELAY_JWT_SECRET").ok();
    let relay_enabled = match &relay_secret_opt {
        None => {
            tracing::info!("RELAY_JWT_SECRET not set — relay API disabled (standalone mode)");
            false
        }
        Some(s) if s == "change-me-in-production" => {
            anyhow::bail!(
                "RELAY_JWT_SECRET is the documented placeholder value — set a random secret of at least 32 bytes. \
                 Generate one with: openssl rand -hex 32"
            );
        }
        Some(s) if s.len() < 32 => {
            anyhow::bail!(
                "RELAY_JWT_SECRET is too short ({} bytes) — minimum 32 bytes required",
                s.len()
            );
        }
        Some(_) => true,
    };

    // Ed25519 public key for verifying relay JWTs (preferred over HS256).
    // Clone before spawn_relay_api consumes it — serve() needs it too.
    let relay_signing_pubkey = config
        .sfu_signing_public_key
        .as_ref()
        .map(|s| Arc::new(s.clone()));

    let (mut relay_rx, relay_handle) = if relay_enabled {
        let relay_secret = Arc::<[u8]>::from(relay_secret_opt.unwrap().into_bytes());
        let relay_addr = format!("{}:{}", config.bind_address, config.relay_api_port);
        let relay_listener = tokio::net::TcpListener::bind(&relay_addr)
            .await
            .with_context(|| format!("bind relay API on {relay_addr}"))?;
        let (relay_tx, relay_rx_inner) = tokio::sync::mpsc::channel::<RelayTask>(16);
        let seen_jtis: SeenJtis =
            std::sync::Arc::new(std::sync::Mutex::new(std::collections::HashSet::new()));
        let handle = spawn_relay_api(
            relay_listener,
            relay_secret,
            relay_signing_pubkey.clone(),
            relay_tx,
            seen_jtis,
        )?;
        tracing::info!(addr = %relay_addr, "relay API listening");
        (relay_rx_inner, Some(handle))
    } else {
        // Create a permanently-closed channel so the drain task exits immediately.
        let (relay_tx, relay_rx_inner) = tokio::sync::mpsc::channel::<RelayTask>(1);
        drop(relay_tx);
        (relay_rx_inner, None)
    };

    // Bind the UDP socket early so relay tasks AND the client_ws session
    // can use the real local address as their host candidate. Previously
    // run_udp_loop() bound internally; now we bind here and pass the
    // socket.
    let socket = udp_loop::bind(&config).await?;
    let local_addr = socket.local_addr().context("get UDP local_addr")?;
    tracing::info!(%local_addr, "SFU UDP socket bound");

    // Phase 7 M4.A6 — host candidate address.
    //
    // The bind address is typically `0.0.0.0:N`, which is unroutable
    // from off-box browsers and breaks ICE in production. When
    // `SFU_PUBLIC_IP` is set we override the candidate IP to the node's
    // public IP while keeping the kernel-assigned port. When unset we
    // fall back to `local_addr` (the historical behavior), so dev/test
    // on loopback keeps working.
    let host_candidate_addr = match config.public_ip {
        Some(ip) => {
            let addr = std::net::SocketAddr::new(ip, local_addr.port());
            tracing::info!(
                %addr, bind = %local_addr,
                "SFU host candidate uses SFU_PUBLIC_IP override (M4.A6)"
            );
            addr
        }
        None => {
            if local_addr.ip().is_unspecified() {
                tracing::warn!(
                    bind = %local_addr,
                    "SFU_PUBLIC_IP not set and bind address is wildcard \
                host candidate is unroutable from off-box browsers. \
                Set SFU_PUBLIC_IP=<node-public-ip> in the env to fix off-box ICE."
                );
            } else {
                tracing::info!(%local_addr, "SFU host candidate uses bind address (no SFU_PUBLIC_IP override)");
            }
            local_addr
        }
    };

    // Channel for injecting browser clients (post-SDP) from the
    // client_ws session into the main UDP loop. Mirrors `relay_inject_*`
    // below — same pattern, different producer.
    let (client_inject_tx, client_inject_rx) = tokio::sync::mpsc::channel::<PendingClient>(32);

    // Phase 7 M4.A1 — client-facing WebSocket API at /sfu/ws/{room_id}.
    // Browsers connect here directly with a room JWT in the
    // Sec-WebSocket-Protocol header. The endpoint is enabled when
    // SIGNALING_SFU_SECRET is configured (HS256 verifier) — without a
    // secret there is no way to authenticate browsers, so we refuse to
    // expose an unauthenticated entry point.
    let client_ws_handle = if let Some(secret_bytes) = config.relay_auth_secret.as_ref() {
        let client_ws_addr = format!("{}:{}", config.bind_address, config.client_ws_port);
        let client_ws_listener = tokio::net::TcpListener::bind(&client_ws_addr)
            .await
            .with_context(|| format!("bind client_ws API on {client_ws_addr}"))?;
        let secret_arc: Arc<[u8]> = Arc::from(secret_bytes.as_slice());
        let handle = spawn_client_ws_api(
            client_ws_listener,
            secret_arc,
            relay_signing_pubkey.clone(),
            client_inject_tx.clone(),
            host_candidate_addr,
        )?;
        tracing::info!(addr = %client_ws_addr, "client_ws API listening (Phase 7 M4.A1+M4.A2)");
        Some(handle)
    } else {
        tracing::info!(
            "SIGNALING_SFU_SECRET not set — client_ws API disabled \
             (Phase 7 M4.A1 requires HS256 secret for browser auth)"
        );
        None
    };
    // Drop the spare sender so the client_inject channel closes when the
    // client_ws task exits and no PendingClient is in flight.
    drop(client_inject_tx);

    // HMAC secret for authenticating relay-injected clients inside the Registry.
    let relay_auth_secret = config
        .relay_auth_secret
        .clone()
        .map(|v| Arc::from(v.as_slice()));

    // Channel for injecting pre-connected relay Rtc instances into the Registry.
    // The relay drain task (below) sends PendingRelay here after SDP exchange.
    // serve() drains this in its select! loop and calls registry.insert().
    let (relay_inject_tx, relay_inject_rx) =
        tokio::sync::mpsc::channel::<oxpulse_sfu::relay::client::PendingRelay>(32);

    // Drain relay task channel — spawn a WebRTC relay client for each accepted task.
    // Each spawned task does WS connect + SDP offer/answer then sends PendingRelay
    // to relay_inject_tx so the main UDP loop registers it in the Registry.
    let relay_inject_tx_clone = relay_inject_tx.clone();
    tokio::spawn(async move {
        while let Some(task) = relay_rx.recv().await {
            let url = task.upstream_url.clone();
            let token = task.upstream_room_token.clone();
            let room = task.room_id.clone();
            let tx = relay_inject_tx_clone.clone();
            tokio::spawn(async move {
                match connect_relay(&url, &token, host_candidate_addr, room.clone()).await {
                    Ok(pending) => {
                        if let Err(e) = tx.send(pending).await {
                            tracing::warn!(
                                error = %e, room_id = %room,
                                "relay inject channel closed — relay Rtc dropped"
                            );
                        } else {
                            tracing::info!(room_id = %room, "relay handshake complete, PendingRelay sent to registry");
                        }
                    }
                    Err(e) => {
                        tracing::warn!(error = %e, room_id = %room, "relay connection failed")
                    }
                }
            });
        }
    });
    // Drop the original sender so the channel closes when all relay tasks are done.
    drop(relay_inject_tx);

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
    // Pass relay_inject_rx so serve() can inject relay clients into the Registry,
    // and client_inject_rx so serve() can inject browser clients post-SDP.
    let result = udp_loop::serve(
        socket,
        metrics,
        relay_auth_secret,
        relay_signing_pubkey,
        relay_inject_rx,
        client_inject_rx,
        shutdown,
    )
    .await;

    // Stop the metrics, relay API, and client_ws API servers.
    metrics_handle.abort();
    if let Some(h) = relay_handle {
        h.abort();
    }
    if let Some(h) = client_ws_handle {
        h.abort();
    }

    result
}
