use std::net::SocketAddr;
use std::sync::Arc;

use tokio::signal;

use anyhow::Context;
use oxpulse_sfu::{
    client_ws::{spawn_client_ws_api, ClientWsApiConfig, PendingClient},
    metrics::spawn_metrics_server,
    relay::{
        client::{connect_relay, PendingRelay},
        handler::{spawn_relay_api, RelayApiState, SeenJtis},
        task::RelayTask,
    },
    telemetry, udp_loop, SfuConfig, SfuMetrics,
};

/// Per-candidate connect timeout for the relay failover loop.
/// A dark/filtered hub can hang TCP connect (~75 s) or the SDP-answer recv indefinitely.
/// 8 s bounds the entire per-candidate attempt (TCP + WS upgrade + SDP answer).
const RELAY_CANDIDATE_CONNECT_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(8);

/// Maximum concurrent relay dial tasks (SEC-CR-003).
/// Each task can run up to MAX_RELAY_CANDIDATES (8) × RELAY_CANDIDATE_CONNECT_TIMEOUT (8 s)
/// = 64 s of blocking I/O. Without a cap, a burst of distinct-jti tokens spawns unbounded
/// concurrent tasks and saturates available ports / Tokio I/O threads.
/// 16 is enough for realistic burst (typical deployment: 1–4 relay rooms active).
/// Backpressure is observable via `relay_sem_full` warn logs.
const RELAY_MAX_CONCURRENT: usize = 16;

/// Attempt each candidate URL in `candidates`, in order, stopping at the
/// first candidate that completes `connect_relay`'s WS+SDP handshake.
/// Extracted out of the relay-task spawn below so tests can drive this
/// retry loop through the real `connect_relay` network path instead of
/// re-implementing it.
///
/// T13 (2026-07-01 bug-hunt, dependency_block/medium): increments
/// `metrics.relay_connect_success_total` on the first successful candidate,
/// or `metrics.relay_candidate_exhausted_total` once every candidate has
/// failed or timed out — previously this branch only emitted a
/// `tracing::warn!`, invisible to Grafana during a total upstream-hub
/// outage.
async fn relay_connect_failover(
    candidates: &[String],
    token: &str,
    host_candidate_addr: SocketAddr,
    room: String,
    stats_interval_secs: u64,
    metrics: &SfuMetrics,
) -> Option<PendingRelay> {
    let mut last_err: Option<anyhow::Error> = None;
    for candidate in candidates {
        match tokio::time::timeout(
            RELAY_CANDIDATE_CONNECT_TIMEOUT,
            connect_relay(
                candidate,
                token,
                host_candidate_addr,
                room.clone(),
                stats_interval_secs,
            ),
        )
        .await
        {
            Ok(Ok(pending)) => {
                metrics.relay_connect_success_total.inc();
                return Some(pending);
            }
            Ok(Err(e)) => {
                tracing::warn!(
                    upstream = %candidate, room_id = %room, error = %e,
                    "relay candidate failed, trying next"
                );
                last_err = Some(e);
            }
            Err(_elapsed) => {
                tracing::warn!(
                    upstream = %candidate, room_id = %room,
                    timeout_s = RELAY_CANDIDATE_CONNECT_TIMEOUT.as_secs(),
                    "relay candidate timed out, trying next"
                );
                last_err = Some(anyhow::anyhow!(
                    "connect timed out after {:?}",
                    RELAY_CANDIDATE_CONNECT_TIMEOUT
                ));
            }
        }
    }
    // All candidates exhausted.
    metrics.relay_candidate_exhausted_total.inc();
    if let Some(e) = last_err {
        tracing::warn!(error = %e, room_id = %room, "relay connection failed — all candidates exhausted");
    }
    None
}

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
    // T8: the relay API activates when EITHER RELAY_JWT_SECRET (legacy HS256) OR
    // SFU_SIGNING_PUBLIC_KEY (the canonical Ed25519 federation path) is set — a
    // pure-Ed25519 deployment emits no RELAY_JWT_SECRET, so gating on the secret
    // alone left the federation activation path unreachable. When neither is set,
    // the SFU runs in standalone mode (no cascade relay). See relay::activation.
    let relay_secret_opt = std::env::var("RELAY_JWT_SECRET").ok();
    let activation = oxpulse_sfu::relay::activation::compute_relay_activation(
        relay_secret_opt.as_deref(),
        config.sfu_signing_public_key.as_deref(),
        config.relay_hs256_fallback_enabled,
    )?;
    let relay_enabled = activation.enabled;

    // T8: publish the activation mode once at boot so a pure-Ed25519
    // mis-activation (relay silently disabled) is directly alertable.
    if let Some(mode) = activation.auth_mode {
        metrics.relay_api_enabled.with_label_values(&[mode]).set(1);
    }
    if !relay_enabled {
        tracing::info!(
            "relay API disabled (standalone mode): neither RELAY_JWT_SECRET nor \
             SFU_SIGNING_PUBLIC_KEY is set"
        );
    }

    // Ed25519 public key for verifying relay JWTs (preferred over HS256).
    // Clone before spawn_relay_api consumes it — serve() needs it too.
    let relay_signing_pubkey = config
        .sfu_signing_public_key
        .as_ref()
        .map(|s| Arc::new(s.clone()));

    let (mut relay_rx, relay_handle) = if relay_enabled {
        // T8: activation.secret is a real Arc<[u8]> even on a pure-Ed25519
        // deployment (empty then) — no unwrap()/panic on a missing HS256 secret.
        let relay_secret = activation.secret.clone();
        // Use relay_api_bind_addr() so SFU_RELAY_API_BIND can scope the relay
        // socket to the AWG mesh on partner-edge deployments (audit 2026-05-21).
        let relay_addr = format!("{}:{}", config.relay_api_bind_addr(), config.relay_api_port);
        let relay_listener = tokio::net::TcpListener::bind(&relay_addr)
            .await
            .with_context(|| format!("bind relay API on {relay_addr}"))?;
        let (relay_tx, relay_rx_inner) = tokio::sync::mpsc::channel::<RelayTask>(16);
        let seen_jtis: SeenJtis =
            std::sync::Arc::new(std::sync::Mutex::new(std::collections::HashMap::new()));
        let handle = spawn_relay_api(
            relay_listener,
            RelayApiState {
                secret: relay_secret,
                signing_public_key: relay_signing_pubkey.clone(),
                task_tx: relay_tx,
                seen_jtis,
                metrics: metrics.clone(),
                // T8: forced off on a pure-Ed25519 deployment (no HS256 secret)
                // so an empty-secret HS256 verify can never fire.
                hs256_fallback_enabled: activation.hs256_fallback_effective,
            },
        )?;
        tracing::info!(
            addr = %relay_addr,
            auth = activation.auth_mode.unwrap_or("none"),
            "relay API listening"
        );
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

    // OCI-hairpin fix (2026-07-11) — advertise the node's PRIVATE IP as an
    // ADDITIONAL host candidate alongside `host_candidate_addr`. On providers
    // with no NAT hairpin (Oracle Cloud), a co-located coturn cannot deliver
    // relayed media to the SFU's public candidate (the packet leaves via the
    // gateway and never returns), so relay-forced group calls fail ICE with
    // `no_pair`. The private candidate lets the co-located coturn relay to the
    // SFU entirely on private addressing. Shares the same kernel-assigned port
    // (the SFU listens on a single `0.0.0.0:port` socket, reachable via both
    // IPs). Deduped against the primary so a node whose SFU_LOCAL_IP is unset
    // or equal to the primary advertises the primary candidate only.
    let additional_host_candidates = config.additional_host_candidates(host_candidate_addr);
    if let Some(addr) = additional_host_candidates.first() {
        tracing::info!(
            %addr, primary = %host_candidate_addr,
            "SFU advertising additional private host candidate (SFU_LOCAL_IP, OCI-hairpin fix)"
        );
    }

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
            ClientWsApiConfig {
                secret: secret_arc,
                signing_pubkey: relay_signing_pubkey.clone(),
                client_inject_tx,
                local_udp_addr: host_candidate_addr,
                additional_host_candidates,
                metrics: metrics.clone(),
                stats_interval_secs: config.stats_interval_secs,
                hs256_fallback_enabled: config.relay_hs256_fallback_enabled,
            },
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

        // SEC-CR-003: Semaphore bounding concurrent relay dial tasks.
        // Each task may block up to MAX_RELAY_CANDIDATES × RELAY_CANDIDATE_CONNECT_TIMEOUT
        // (8 candidates × 8 s = 64 s). Without a cap, a burst of N distinct-jti tokens
        // spawns N concurrent tasks and saturates ports / Tokio I/O threads.
        // Permit is acquired BEFORE the inner spawn so backpressure is applied before
        // the task is created — not inside it. The permit is held for the task's lifetime.
        // Bound is load-observable: `relay_sem_full` warn log fires on saturation.
        let relay_sem = std::sync::Arc::new(tokio::sync::Semaphore::new(RELAY_MAX_CONCURRENT));

        // Drain relay task channel — spawn a WebRTC relay client for each accepted task.
        // Each spawned task does WS connect + SDP offer/answer then sends PendingRelay
        // to relay_inject_tx so the main UDP loop registers it in the Registry.
        // relay_inject_tx is moved into the spawn task and lives as long as it does;
        // serve() observes a runtime close (None on recv) only if the spawn panics.
        let stats_interval_secs = config.stats_interval_secs;
        // T13: cloned once for the outer drain task; cloned again per-task
        // below (relay_metrics.clone()) since `metrics` itself is moved into
        // udp_loop::serve() further down main().
        let relay_metrics = metrics.clone();
        tokio::spawn(async move {
            while let Some(task) = relay_rx.recv().await {
                let candidates = task.upstream_candidates.clone();
                let token = task.upstream_room_token.clone();
                let room = task.room_id.clone();
                let tx = relay_inject_tx.clone();
                let task_metrics = relay_metrics.clone();
                // Acquire semaphore permit before spawning — enforces the concurrency cap.
                // acquire_owned() returns Err only if the semaphore is closed; closing
                // happens only when relay_sem is dropped (i.e. this outer task exits),
                // so the error branch is effectively unreachable during normal operation.
                let permit = match relay_sem.clone().acquire_owned().await {
                    Ok(p) => p,
                    Err(_) => {
                        tracing::warn!(
                            room_id = %room,
                            "relay semaphore closed — skipping relay task"
                        );
                        continue;
                    }
                };
                tokio::spawn(async move {
                    let _permit = permit; // dropped (released) when this task ends
                                          // B0: iterate signed candidates in order; first success wins.
                                          // Invariant: select_candidates() guarantees non-empty before enqueue.
                    debug_assert!(
                        !candidates.is_empty(),
                        "relay task enqueued with no candidates"
                    );
                    // T13: relay_connect_failover increments
                    // relay_connect_success_total / relay_candidate_exhausted_total
                    // on the two respective outcomes.
                    if let Some(pending) = relay_connect_failover(
                        &candidates,
                        &token,
                        host_candidate_addr,
                        room.clone(),
                        stats_interval_secs,
                        &task_metrics,
                    )
                    .await
                    {
                        let upstream = pending.upstream_url.clone();
                        if let Err(e) = tx.send(pending).await {
                            tracing::warn!(
                                error = %e, room_id = %room,
                                "relay inject channel closed — relay Rtc dropped"
                            );
                        } else {
                            tracing::info!(room_id = %room, upstream = %upstream, "relay handshake complete, PendingRelay sent to registry");
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

// T13 (2026-07-01 bug-hunt, dependency_block/medium): the cascade-relay
// candidate-failover loop lived inline in the relay task spawn above with no
// counter — a total upstream-hub outage (every candidate failing) produced
// only a `tracing::warn!`, invisible to Grafana. These tests drive the real
// `relay_connect_failover` helper (extracted from that loop, called by
// main() above) through the real `connect_relay` network path — a refused
// TCP port for the exhaustion case, and a real str0m answerer for the
// success case — rather than re-implementing the retry logic in the test.
#[cfg(test)]
mod relay_connect_failover_tests {
    use super::*;

    use futures_util::{SinkExt, StreamExt};
    use str0m::change::SdpOffer;
    use tokio_tungstenite::tungstenite::Message;

    /// Spins up a plain-WS (no TLS) fake upstream bound to the box's real
    /// AWG mesh interface (`10.9.0.2`, mesh-allow-listed by
    /// `relay::allowlist::is_allowed_upstream`) that completes the real
    /// `connect_relay` join -> offer -> answer handshake using str0m as the
    /// answerer (`accept_offer`, the same entry point
    /// `client_ws/session.rs` uses server-side). Returns `Some(ws-url)` the
    /// `RelayTask` candidate would carry, or `None` on a host without the AWG
    /// mesh interface (see the bind below).
    async fn spawn_fake_upstream_success() -> Option<String> {
        // A plaintext `ws://` upstream is allow-listed ONLY inside the AWG mesh
        // subnet (10.9.0.0/24): connect_relay's SSRF guard
        // (`relay::allowlist::is_allowed_upstream`) rejects bare `ws://` to
        // loopback, so exercising the success path genuinely requires a mesh
        // bind (a loopback bind would be refused by the guard, not connect).
        // Hosts without the mesh interface (e.g. GitHub-hosted CI runners) fail
        // to bind 10.9.0.2 with EADDRNOTAVAIL — return `None` so the caller
        // skips the mesh-only success assertion instead of panicking. The
        // portable exhaustion case (wss://127.0.0.1 refused) still gates on
        // every host.
        let listener = match tokio::net::TcpListener::bind("10.9.0.2:0").await {
            Ok(l) => l,
            Err(e) => {
                eprintln!(
                    "spawn_fake_upstream_success: cannot bind AWG mesh interface 10.9.0.2 \
                     ({e}) — no mesh on this host; skipping the plaintext-ws success-counter \
                     assertion (the exhaustion case still runs)"
                );
                return None;
            }
        };
        let port = listener.local_addr().expect("local_addr").port();
        tokio::spawn(async move {
            let (stream, _) = match listener.accept().await {
                Ok(v) => v,
                Err(_) => return,
            };
            let mut ws = match tokio_tungstenite::accept_async(stream).await {
                Ok(v) => v,
                Err(_) => return,
            };
            let mut offer_sdp: Option<String> = None;
            while let Some(Ok(msg)) = ws.next().await {
                let Message::Text(text) = msg else {
                    continue;
                };
                let v: serde_json::Value = match serde_json::from_str(text.as_str()) {
                    Ok(v) => v,
                    Err(_) => continue,
                };
                if v["type"] == "signal" {
                    if let Some(payload) = v["payload"].as_object() {
                        if payload.get("type").and_then(|t| t.as_str()) == Some("offer") {
                            offer_sdp = payload
                                .get("sdp")
                                .and_then(|s| s.as_str())
                                .map(|s| s.to_string());
                            break;
                        }
                    }
                }
            }
            let Some(offer_sdp) = offer_sdp else {
                return;
            };
            let Ok(offer) = SdpOffer::from_sdp_string(&offer_sdp) else {
                return;
            };
            let mut answerer = str0m::Rtc::new(std::time::Instant::now());
            let Ok(answer) = answerer.sdp_api().accept_offer(offer) else {
                return;
            };
            let answer_payload = serde_json::json!({
                "type": "signal",
                "payload": { "type": "answer", "sdp": answer.to_sdp_string() }
            })
            .to_string();
            let _ = ws.send(Message::Text(answer_payload.into())).await;
        });
        Some(format!("ws://10.9.0.2:{port}/relay"))
    }

    #[tokio::test]
    async fn increments_success_counter_on_first_working_candidate() {
        let Some(upstream) = spawn_fake_upstream_success().await else {
            // No AWG mesh interface on this host (see spawn_fake_upstream_success)
            // — the mesh-only plaintext-ws success path can't run here. Its
            // portable counterpart, increments_exhausted_counter_when_all_candidates_fail
            // (wss://127.0.0.1 refused), still gates this module in CI.
            return;
        };
        let metrics = Arc::new(SfuMetrics::default());
        let candidates = vec![upstream];

        let result = relay_connect_failover(
            &candidates,
            "test-token",
            "127.0.0.1:0".parse().unwrap(),
            "test-room".to_string(),
            0,
            &metrics,
        )
        .await;

        assert!(
            result.is_some(),
            "relay_connect_failover must return Some(PendingRelay) when a candidate succeeds"
        );
        assert_eq!(
            metrics.relay_connect_success_total.get(),
            1,
            "relay_connect_success_total must increment on a successful candidate"
        );
        assert_eq!(
            metrics.relay_candidate_exhausted_total.get(),
            0,
            "exhausted counter must NOT fire when a candidate succeeded"
        );
    }

    #[tokio::test]
    async fn increments_exhausted_counter_when_all_candidates_fail() {
        let metrics = Arc::new(SfuMetrics::default());
        // Refused ports on an allow-listed host -- same pattern as
        // relay/client.rs's connect_relay_refused_port_returns_err_quickly.
        let candidates = vec![
            "wss://127.0.0.1:1/ws/call/r".to_string(),
            "wss://127.0.0.1:2/ws/call/r".to_string(),
        ];

        let result = relay_connect_failover(
            &candidates,
            "test-token",
            "127.0.0.1:0".parse().unwrap(),
            "test-room".to_string(),
            0,
            &metrics,
        )
        .await;

        assert!(
            result.is_none(),
            "relay_connect_failover must return None when every candidate fails"
        );
        assert_eq!(
            metrics.relay_candidate_exhausted_total.get(),
            1,
            "relay_candidate_exhausted_total must increment once all candidates are exhausted"
        );
        assert_eq!(
            metrics.relay_connect_success_total.get(),
            0,
            "success counter must NOT fire when every candidate failed"
        );
    }
}
