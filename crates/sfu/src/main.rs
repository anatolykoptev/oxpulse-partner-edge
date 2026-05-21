use std::sync::Arc;

use tokio::signal;

use anyhow::Context;
use oxpulse_sfu::{
    client_ws::{spawn_client_ws_api, PendingClient},
    metrics::spawn_metrics_server,
    relay::{
        client::connect_relay,
        handler::{spawn_relay_api, SeenJtis},
        task::RelayTask,
    },
    telemetry, udp_loop, SfuConfig, SfuMetrics,
};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let config = SfuConfig::from_env();

    // edge_id / partner_id are read directly from env so they reach the OTLP
    // resource attributes — config.rs doesn't expose them yet (and we don't
    // want to add fields there for one consumer).
    let edge_id = std::env::var("SFU_EDGE_ID").unwrap_or_else(|_| "local".to_string());
    let partner_id = std::env::var("PARTNER_ID").unwrap_or_else(|_| "unknown".to_string());
    let trace_provider =
        telemetry::init(&config.log_level, &edge_id, &partner_id).context("init telemetry")?;

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
    // Use metrics_bind_addr() so SFU_METRICS_BIND can scope the /metrics socket
    // to the AWG mesh on partner-edge deployments (audit 2026-05-21).
    let metrics_addr = format!("{}:{}", config.metrics_bind_addr(), config.metrics_port);
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
        // Use relay_api_bind_addr() so SFU_RELAY_API_BIND can scope the relay
        // socket to the AWG mesh on partner-edge deployments (audit 2026-05-21).
        let relay_addr = format!("{}:{}", config.relay_api_bind_addr(), config.relay_api_port);
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

    // Phase 7 M4.A1 — client-facing WebSocket API at /sfu/ws/{room_id}.
    // Browsers connect here directly with a room JWT in the
    // Sec-WebSocket-Protocol header. The endpoint is enabled when
    // SIGNALING_SFU_SECRET is configured (HS256 verifier) — without a
    // secret there is no way to authenticate browsers, so we refuse to
    // expose an unauthenticated entry point.
    //
    // The inject channel is created **only** when the feature is enabled,
    // so `serve()` receives `Option::None` in standalone mode and never
    // polls a closed receiver (which would spin the select! loop).
    let (client_inject_rx, client_ws_handle) = if let Some(secret_bytes) =
        config.relay_auth_secret.as_ref()
    {
        let (client_inject_tx, client_inject_rx) = tokio::sync::mpsc::channel::<PendingClient>(32);
        // Use client_ws_bind_addr() so SFU_CLIENT_WS_BIND can scope the client-WS
        // socket to the docker bridge IP on partner-edge deployments
        // (caddy reverse-proxies via host.docker.internal:8920). Audit 2026-05-21.
        let client_ws_addr = format!("{}:{}", config.client_ws_bind_addr(), config.client_ws_port);
        let client_ws_listener = tokio::net::TcpListener::bind(&client_ws_addr)
            .await
            .with_context(|| format!("bind client_ws API on {client_ws_addr}"))?;
        let secret_arc: Arc<[u8]> = Arc::from(secret_bytes.as_slice());
        let handle = spawn_client_ws_api(
            client_ws_listener,
            secret_arc,
            relay_signing_pubkey.clone(),
            client_inject_tx,
            host_candidate_addr,
            metrics.clone(),
            config.stats_interval_secs,
        )?;
        // Round-2 review fix: gauge defaults to 1 (disabled) in
        // SfuMetrics::new() so /metrics scrapes that race container
        // startup see the safe-pessimistic state. Flip to 0 here, only
        // after the client_ws listener has actually bound.
        metrics.client_ws_disabled.set(0);
        tracing::info!(addr = %client_ws_addr, "client_ws API listening (Phase 7 M4.A1+M4.A2)");
        (Some(client_inject_rx), Some(handle))
    } else {
        // Bump the gauge BEFORE the warn log so any /metrics scrape that
        // races the startup banner already sees the degraded state.
        // 2026-05-06 motherly1 outage post-mortem — info! was lost in
        // normal-operation log streams for 8 weeks; warn! plus gauge
        // makes the misconfiguration alertable.
        metrics.client_ws_disabled.set(1);
        tracing::warn!(
            "SIGNALING_SFU_SECRET not set — client_ws API disabled \
             (Phase 7 M4.A1 requires HS256 secret for browser auth). \
             Browser-side group calls will fail. Set the secret in \
             docker-compose.yml.tpl under sfu service environment."
        );
        (None, None)
    };

    // HMAC secret for authenticating relay-injected clients inside the Registry.
    let relay_auth_secret = config
        .relay_auth_secret
        .clone()
        .map(|v| Arc::from(v.as_slice()));

    // Channel for injecting pre-connected relay Rtc instances into the Registry.
    // Created **only** when relay is enabled — same Option<Receiver> pattern as
    // client_inject above. In standalone mode `serve()` receives None and the
    // relay arm of select! is replaced by `pending()`, so no spin.
    let relay_inject_rx = if relay_enabled {
        let (relay_inject_tx, relay_inject_rx) =
            tokio::sync::mpsc::channel::<oxpulse_sfu::relay::client::PendingRelay>(32);

        // Drain relay task channel — spawn a WebRTC relay client for each accepted task.
        // Each spawned task does WS connect + SDP offer/answer then sends PendingRelay
        // to relay_inject_tx so the main UDP loop registers it in the Registry.
        // relay_inject_tx is moved into the spawn task and lives as long as it does;
        // serve() observes a runtime close (None on recv) only if the spawn panics.
        let stats_interval_secs = config.stats_interval_secs;
        tokio::spawn(async move {
            while let Some(task) = relay_rx.recv().await {
                let url = task.upstream_url.clone();
                let token = task.upstream_room_token.clone();
                let room = task.room_id.clone();
                let tx = relay_inject_tx.clone();
                tokio::spawn(async move {
                    match connect_relay(
                        &url,
                        &token,
                        host_candidate_addr,
                        room.clone(),
                        stats_interval_secs,
                    )
                    .await
                    {
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
        Some(relay_inject_rx)
    } else {
        None
    };

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
    // Pass host_candidate_addr so the loop can correctly demux STUN binding
    // requests — str0m's ICE agent matches incoming STUN on the destination
    // address, which must equal the installed local candidate (M4.A6 fix).
    let solo_kick_timeout = if config.solo_kick_after_secs == 0 {
        None
    } else {
        Some(std::time::Duration::from_secs(config.solo_kick_after_secs))
    };
    let result = udp_loop::serve(
        socket,
        metrics,
        relay_auth_secret,
        relay_signing_pubkey,
        relay_inject_rx,
        client_inject_rx,
        host_candidate_addr,
        solo_kick_timeout,
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

    // Flush in-flight spans before exit. No-op when OTLP wasn't configured.
    telemetry::shutdown(trace_provider);

    result
}
