//! Async UDP socket loop — M1.2.
//!
//! Binds `SfuConfig.udp_port` on `SfuConfig.bind_address`, demuxes
//! incoming datagrams through the [`Registry`], flushes each client's
//! outbound queue back to the socket, and honors a shutdown future
//! so the caller can stop the loop cleanly.
//!
//! Two side-channels feed the loop:
//! * `relay_rx` — outbound cascade-relay clients (str0m as offerer);
//!   produced by `relay::client::connect_relay`.
//! * `client_inject_rx` — browser clients (str0m as answerer); produced
//!   by `client_ws::session::run` after an SDP exchange completes.
//!
//! Both produce a pre-ICE `Rtc` that the loop turns into a [`Client`]
//! and inserts into the registry — from there ICE/DTLS/SRTP flow
//! identically.
//!
//! [`Client`]: crate::client::Client

use std::collections::HashMap;
use std::future::Future;
use std::net::SocketAddr;
use std::time::{Duration, Instant};

use std::sync::Arc;

use anyhow::Context;
use tokio::net::UdpSocket;
use tokio::time::MissedTickBehavior;

use crate::config::SfuConfig;
use crate::metrics::SfuMetrics;
use crate::registry::Registry;
use dominant_speaker::TICK_INTERVAL;

/// Maximum UDP payload we expect to receive. The str0m `chat.rs`
/// example uses 2000 bytes which covers STUN / DTLS / SRTP with a
/// comfortable margin under the typical 1500-byte MTU.
const RECV_BUFFER_BYTES: usize = 2048;

/// Upper bound on how long the receive branch is allowed to park.
/// Keeps the str0m tick loop (which wants ~100ms granularity) from
/// starving when no datagrams arrive.
const MAX_SLEEP: Duration = Duration::from_millis(100);

/// Suppress repeated `udp send_to failed` WARNs for the same destination.
/// 10s matches a typical ICE candidate timeout so the window closes around
/// the same time the SFU would give up on that candidate anyway.
const SEND_FAIL_DEDUP_WINDOW: Duration = Duration::from_secs(10);

/// Receive on the channel if `Some`, otherwise wait forever. Used by `serve()`
/// to disable a `select!` arm whose `Option<Receiver>` is `None` — either
/// because the corresponding feature is disabled at startup, or because the
/// channel observed all senders dropped at runtime and was taken out.
///
/// Without this, polling a closed `Receiver` returns `Ready(None)` instantly
/// and forever, causing the select! loop to spin at 100% CPU. Observed in
/// prod on partner-edge-sfu v0.12.4 (3 days × 95% CPU, zero clients).
async fn recv_or_pending<T>(rx: Option<&mut tokio::sync::mpsc::Receiver<T>>) -> Option<T> {
    match rx {
        Some(rx) => rx.recv().await,
        None => std::future::pending().await,
    }
}

/// Run the SFU UDP loop until `shutdown` resolves. The bound
/// `SocketAddr` is not returned from here — tests that need it should
/// call [`bind`] and pass the resulting socket into [`serve`].
#[allow(clippy::too_many_arguments)]
pub async fn run_udp_loop<F>(
    config: SfuConfig,
    metrics: Arc<SfuMetrics>,
    relay_rx: Option<tokio::sync::mpsc::Receiver<crate::relay::client::PendingRelay>>,
    client_inject_rx: Option<tokio::sync::mpsc::Receiver<crate::client_ws::PendingClient>>,
    shutdown: F,
) -> anyhow::Result<()>
where
    F: Future<Output = ()>,
{
    let relay_auth_secret = config
        .relay_auth_secret
        .clone()
        .map(|v| Arc::from(v.as_slice()));
    let relay_signing_pubkey = config.sfu_signing_public_key.clone().map(Arc::new);
    let socket = bind(&config).await?;
    let local_addr = socket.local_addr().context("failed to read local_addr")?;
    // Compute the candidate address — same logic as main.rs M4.A6.
    // When the socket is bound to a wildcard address (0.0.0.0), str0m's ICE
    // agent would receive `destination=0.0.0.0:N` on every datagram, which
    // never matches the installed host candidate (`SFU_PUBLIC_IP:N`).  Pass
    // the real routable address so the ICE agent can match STUN requests to
    // the correct local candidate and generate binding responses.
    let candidate_addr = match config.public_ip {
        Some(ip) => std::net::SocketAddr::new(ip, local_addr.port()),
        None => local_addr,
    };
    serve(
        socket,
        metrics,
        relay_auth_secret,
        relay_signing_pubkey,
        relay_rx,
        client_inject_rx,
        candidate_addr,
        shutdown,
    )
    .await
}

/// Bind the UDP socket per `config`. Exposed so tests can observe the
/// resolved `local_addr` (critical when `udp_port = 0`).
pub async fn bind(config: &SfuConfig) -> anyhow::Result<UdpSocket> {
    let addr = format!("{}:{}", config.bind_address, config.udp_port);
    let socket = UdpSocket::bind(&addr)
        .await
        .with_context(|| format!("failed to bind UDP socket at {addr}"))?;
    let local = socket.local_addr().context("failed to read local_addr")?;
    tracing::info!(%local, "SFU starting — UDP listener ready");
    Ok(socket)
}

/// Drive the receive loop on an already-bound socket. Returns once
/// `shutdown` resolves or a fatal socket error occurs.
///
/// `candidate_addr` is the routable address that was installed as the SFU's
/// host candidate via `Rtc::add_local_candidate`.  It is used as the
/// `destination` field in every `Input::Receive` fed to str0m so that the
/// ICE agent can match incoming STUN binding requests against the known
/// local candidate.  When the socket is bound to a wildcard address
/// (`0.0.0.0:N`), `socket.local_addr()` returns that wildcard, which would
/// never equal the installed candidate (`SFU_PUBLIC_IP:N`), causing str0m to
/// silently discard all STUN requests and leaving ICE in the `checking`
/// state forever.  Callers must pass the same address that was given to
/// `Candidate::host()` — typically `host_candidate_addr` from `main.rs`.
#[allow(clippy::too_many_arguments)]
#[tracing::instrument(skip_all, name = "udp_loop.serve")]
pub async fn serve<F>(
    socket: UdpSocket,
    metrics: Arc<SfuMetrics>,
    relay_auth_secret: Option<Arc<[u8]>>,
    relay_signing_pubkey: Option<Arc<String>>,
    mut relay_rx: Option<tokio::sync::mpsc::Receiver<crate::relay::client::PendingRelay>>,
    mut client_inject_rx: Option<tokio::sync::mpsc::Receiver<crate::client_ws::PendingClient>>,
    candidate_addr: std::net::SocketAddr,
    shutdown: F,
) -> anyhow::Result<()>
where
    F: Future<Output = ()>,
{
    // Clone metrics before moving into Registry so relay injection can use it too.
    let metrics_ref = metrics.clone();
    let mut registry = Registry::with_relay_auth(metrics, relay_auth_secret, relay_signing_pubkey);
    let mut buf = vec![0u8; RECV_BUFFER_BYTES];
    // M1.4: ASO tick drives dominant-speaker election. Delay-on-miss so
    // a slow tick doesn't cause a burst of tick() calls.
    let mut aso_interval = tokio::time::interval(TICK_INTERVAL);
    aso_interval.set_missed_tick_behavior(MissedTickBehavior::Delay);
    // Per-destination dedup for send_to failures: first failure per dest per
    // SEND_FAIL_DEDUP_WINDOW emits a WARN; subsequent ones only bump the counter.
    let mut send_fail_dedup: HashMap<SocketAddr, Instant> = HashMap::new();
    tokio::pin!(shutdown);

    loop {
        metrics_ref.udp_loop_iterations_total.inc();
        registry.reap_dead();

        // Drain whatever str0m has ready to emit *before* waiting for
        // the next packet, so outbound bytes don't sit on clients
        // longer than one tick.
        let now = Instant::now();
        let deadline = registry.poll_all(now);
        registry.fanout_pending();
        flush_transmits(
            &socket,
            &mut registry,
            &metrics_ref,
            &mut send_fail_dedup,
            now,
        )
        .await;
        // Evict entries older than 6× window so the map can't grow unbounded
        // during crash-loop scenarios where many destinations stay unreachable.
        send_fail_dedup.retain(|_, t| now.duration_since(*t) < SEND_FAIL_DEDUP_WINDOW * 6);

        let sleep = deadline
            .saturating_duration_since(Instant::now())
            .max(Duration::from_millis(1))
            .min(MAX_SLEEP);

        tokio::select! {
            () = &mut shutdown => {
                tracing::info!("SFU shutting down — UDP loop stopping");
                return Ok(());
            }
            _ = tokio::time::sleep(sleep) => {
                registry.tick(Instant::now());
            }
            _ = aso_interval.tick() => {
                let now = Instant::now();

                registry.tick_active_speaker(now);
                // M6.2: update per-peer Prometheus score gauges and queue
                // TopSpeakers broadcast for delivery via DC id:3.
                registry.tick_speaker_scores();
                registry.emit_publisher_layer_hints();
            }
            recv = socket.recv_from(&mut buf) => {
                match recv {
                    Ok((n, src)) => {
                        // Pass `candidate_addr` as destination so str0m's ICE
                        // agent can match the incoming datagram against the
                        // installed host candidate.  Using `local` (the
                        // wildcard `0.0.0.0:N`) here causes str0m to discard
                        // every STUN binding request with a debug-level
                        // "Discarding STUN request on unknown interface" log —
                        // ICE then stays in `checking` state until timeout.
                        registry.handle_incoming(src, candidate_addr, &buf[..n]);
                    }
                    Err(e) => {
                        // Transient per-datagram errors shouldn't kill
                        // the loop; log and continue.
                        tracing::warn!(error = %e, "udp recv_from failed");
                    }
                }
            }
            maybe_relay = recv_or_pending(relay_rx.as_mut()) => {
                match maybe_relay {
                    Some(pending) => {
                        let room_id = pending.room_id.clone();
                        let client = crate::client::Client::new_outbound_relay(
                            pending,
                            metrics_ref.clone(),
                        );
                        registry.insert(client);
                        tracing::info!(%room_id, "cascade relay client injected into registry — ICE driven by main UDP loop");
                    }
                    None => {
                        // All senders dropped at runtime (typically: relay drain
                        // task panicked or exited). Switch the arm to `pending()`
                        // by taking the receiver out of the Option — `recv_or_pending`
                        // sees None next iteration and never resolves again.
                        metrics_ref.inject_channel_closed_total.with_label_values(&["relay"]).inc();
                        tracing::warn!("relay inject channel closed at runtime — arm disabled");
                        relay_rx = None;
                    }
                }
            }
            maybe_client = recv_or_pending(client_inject_rx.as_mut()) => {
                match maybe_client {
                    Some(pending) => {
                        let room_id = pending.room_id.clone();
                        let external_peer_id = pending.external_peer_id;
                        let ws_msg_tx = pending.ws_msg_tx.clone();

                        // Phase F2: build tracks_map from existing browser clients
                        // BEFORE registry.insert so the newcomer gets the complete
                        // picture of currently-publishing peers. Only browser clients
                        // carry an `external_peer_id`; relay clients are excluded.
                        // The JSON shape mirrors LiveKit's participantUpdate pattern:
                        //   { "type": "tracks_map",
                        //     "tracks": [ { "stream_id": "peer-7", "peer_id": "7" }, ... ] }
                        //
                        // `stream_id` matches the `a=msid:peer-N` value injected by
                        // `sdp_msid::inject_msid` so `sfuStreamBindMap.get(stream.id)`
                        // resolves on the first `pc.ontrack` call.
                        let tracks: Vec<serde_json::Value> = registry
                            .clients()
                            .iter()
                            .filter_map(|c| c.external_peer_id.map(|pid| {
                                serde_json::json!({
                                    "stream_id": format!("peer-{pid}"),
                                    "peer_id": pid.to_string(),
                                })
                            }))
                            .collect();
                        let has_peers = !tracks.is_empty();
                        let tracks_map_frame = serde_json::json!({
                            "type": "tracks_map",
                            "tracks": tracks,
                        }).to_string();
                        // try_send: non-blocking. The WS task may have already
                        // exited (peer left between inject and this arm firing);
                        // drop on full is safe — the client will fall back to
                        // the `peer_joined` signaling event for mapping.
                        let _ = ws_msg_tx.try_send(tracks_map_frame);
                        metrics_ref
                            .tracks_map_sent_total
                            .with_label_values(&[if has_peers { "true" } else { "false" }])
                            .inc();

                        // Late-join detection: emit a counter so operators can
                        // cross-reference with sfu_subscription_setup_total to
                        // confirm the wiring path fired for each publisher.
                        // If late_join fires but sfu_forward_decisions_total{dst=new_peer}
                        // stays 0 → subscription wired but no packets delivered
                        // (asymmetric forwarding bug, e.g. str0m subscription issue).
                        let late_join_action = if has_peers {
                            "tracks_map_sent"
                        } else {
                            "no_op_empty_room"
                        };
                        metrics_ref
                            .sfu_late_join_resync_total
                            .with_label_values(&["peer_joined_late", late_join_action])
                            .inc();

                        let client = crate::client::Client::new(pending.rtc, metrics_ref.clone())
                            .with_chat_dcs()
                            .with_external_peer_id(external_peer_id)
                            .with_close_signal(pending.close_signal);
                        registry.insert(client);
                        tracing::info!(%room_id, external_peer_id, has_peers,
                            "browser client injected into registry — tracks_map sent, ICE driven by main UDP loop");
                    }
                    None => {
                        metrics_ref.inject_channel_closed_total.with_label_values(&["client"]).inc();
                        tracing::warn!("client inject channel closed at runtime — arm disabled");
                        client_inject_rx = None;
                    }
                }
            }
        }
    }
}

/// Map an IO error to a stable metric label.
fn classify_send_error(e: &std::io::Error) -> &'static str {
    match e.raw_os_error() {
        Some(89) => "dest_required",        // Linux EDESTADDRREQ
        Some(101) => "network_unreachable", // ENETUNREACH
        Some(113) => "host_unreachable",    // EHOSTUNREACH
        Some(13) => "perm",                 // EACCES
        _ => "other",
    }
}

async fn flush_transmits(
    socket: &UdpSocket,
    registry: &mut Registry,
    metrics: &SfuMetrics,
    dedup: &mut HashMap<SocketAddr, Instant>,
    now: Instant,
) {
    let mut pending = Vec::new();
    registry.drain_transmits(|t| pending.push(t));
    for t in pending {
        if let Err(e) = socket.send_to(&t.contents, t.destination).await {
            let kind = classify_send_error(&e);
            metrics.udp_send_failed.with_label_values(&[kind]).inc();
            let should_log = match dedup.get(&t.destination) {
                Some(prev) if now.duration_since(*prev) < SEND_FAIL_DEDUP_WINDOW => false,
                _ => {
                    dedup.insert(t.destination, now);
                    true
                }
            };
            if should_log {
                tracing::warn!(
                    dest = %t.destination,
                    error = %e,
                    error_kind = kind,
                    "udp send_to failed (further failures to this dest suppressed for 10s)",
                );
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn bind_uses_ephemeral_port_when_zero() {
        let cfg = SfuConfig {
            udp_port: 0,
            ..SfuConfig::default()
        };
        let socket = bind(&cfg).await.expect("bind succeeds on 0.0.0.0:0");
        let got = socket.local_addr().expect("local_addr");
        assert_ne!(got.port(), 0, "kernel must assign a real ephemeral port");
    }

    #[tokio::test]
    async fn serve_accepts_external_metrics() {
        use crate::metrics::SfuMetrics;
        use std::sync::Arc;
        let cfg = SfuConfig {
            udp_port: 0,
            bind_address: "127.0.0.1".to_string(),
            ..SfuConfig::default()
        };
        let socket = bind(&cfg).await.expect("bind");
        let candidate_addr = socket.local_addr().expect("local_addr");
        let metrics = Arc::new(SfuMetrics::default());
        let (tx, rx) = tokio::sync::oneshot::channel::<()>();
        let handle = tokio::spawn(serve(
            socket,
            metrics,
            None,
            None,
            None,
            None,
            candidate_addr,
            async {
                let _ = rx.await;
            },
        ));
        tx.send(()).unwrap();
        handle.await.unwrap().unwrap();
    }

    /// Regression: standalone mode (no relay, no client_ws) used to feed
    /// `serve()` two channels whose only senders had already been dropped.
    /// `Receiver::recv()` then resolves to `Ready(None)` instantly and the
    /// `select!` loop spins at 100% CPU — observed on partner-edge-sfu
    /// v0.12.4 (3 days × 95% CPU, zero clients). The fix passes
    /// `Option<Receiver>` and substitutes `pending()` for `None`.
    ///
    /// Verifies low loop iteration count: at MAX_SLEEP=100ms the steady
    /// rate is ~10/s. A 200ms window must produce ≤ a few iterations,
    /// not the ~200k a tight loop would.
    #[tokio::test]
    async fn serve_idle_loop_rate_stays_within_max_sleep_budget() {
        use crate::metrics::SfuMetrics;
        use std::sync::Arc;

        let cfg = SfuConfig {
            udp_port: 0,
            bind_address: "127.0.0.1".to_string(),
            ..SfuConfig::default()
        };
        let socket = bind(&cfg).await.expect("bind");
        let candidate_addr = socket.local_addr().expect("local_addr");
        let metrics = Arc::new(SfuMetrics::default());
        let counter = metrics.udp_loop_iterations_total.clone();

        let (shutdown_tx, shutdown_rx) = tokio::sync::oneshot::channel::<()>();
        let task = tokio::spawn(serve(
            socket,
            metrics,
            None,
            None,
            None, // standalone — no relay channel
            None, // standalone — no client inject channel
            candidate_addr,
            async {
                let _ = shutdown_rx.await;
            },
        ));
        tokio::time::sleep(Duration::from_millis(200)).await;
        shutdown_tx.send(()).expect("shutdown signal");
        task.await.expect("join").expect("serve ok");

        let iters = counter.get();
        // 200ms / 100ms MAX_SLEEP = ~2 iterations expected, plus a couple
        // of ASO-tick-driven wakes (TICK_INTERVAL=300ms — usually 0). Cap
        // generously at 50 to absorb CI jitter; a real spin produces 10k+.
        assert!(
            iters < 50,
            "udp_loop_iterations_total={iters} — expected <50 in 200ms idle (spin regression)"
        );
    }

    /// Runtime-close path: when the relay producer task panics mid-flight,
    /// the inject channel's last sender drops. `serve()` must observe `None`,
    /// bump `inject_channel_closed_total{kind=relay}`, switch its receiver
    /// to `None`, and continue idling — not spin.
    #[tokio::test]
    async fn serve_handles_runtime_channel_close_without_spin() {
        use crate::metrics::SfuMetrics;
        use std::sync::Arc;

        let cfg = SfuConfig {
            udp_port: 0,
            bind_address: "127.0.0.1".to_string(),
            ..SfuConfig::default()
        };
        let socket = bind(&cfg).await.expect("bind");
        let candidate_addr = socket.local_addr().expect("local_addr");
        let metrics = Arc::new(SfuMetrics::default());
        let iter_counter = metrics.udp_loop_iterations_total.clone();
        let close_counter = metrics
            .inject_channel_closed_total
            .with_label_values(&["relay"]);

        let (relay_tx, relay_rx) =
            tokio::sync::mpsc::channel::<crate::relay::client::PendingRelay>(1);

        let (shutdown_tx, shutdown_rx) = tokio::sync::oneshot::channel::<()>();
        let task = tokio::spawn(serve(
            socket,
            metrics,
            None,
            None,
            Some(relay_rx),
            None,
            candidate_addr,
            async {
                let _ = shutdown_rx.await;
            },
        ));

        // Let serve see the channel as live, then close it (simulates spawn panic).
        tokio::time::sleep(Duration::from_millis(50)).await;
        drop(relay_tx);
        // Give serve one tick to observe the close and switch arm to pending().
        tokio::time::sleep(Duration::from_millis(150)).await;
        let iters_after_close = iter_counter.get();
        // Run another idle window and assert the rate dropped to ~MAX_SLEEP cadence.
        tokio::time::sleep(Duration::from_millis(200)).await;
        let iters_final = iter_counter.get();

        shutdown_tx.send(()).expect("shutdown signal");
        task.await.expect("join").expect("serve ok");

        assert_eq!(
            close_counter.get(),
            1,
            "close counter should fire exactly once"
        );
        let post_close_iters = iters_final - iters_after_close;
        assert!(
            post_close_iters < 50,
            "post-close iterations={post_close_iters} in 200ms — arm did not stop polling closed channel"
        );
    }

    #[tokio::test]
    async fn serve_injects_relay_client_from_channel() {
        use crate::relay::client::PendingRelay;
        use std::sync::Arc;
        use tokio::sync::mpsc;

        let cfg = SfuConfig {
            udp_port: 0,
            bind_address: "127.0.0.1".to_string(),
            ..SfuConfig::default()
        };
        let socket = bind(&cfg).await.unwrap();
        let candidate_addr = socket.local_addr().expect("local_addr");
        let metrics = Arc::new(crate::metrics::SfuMetrics::default());
        let (relay_tx, relay_rx) = mpsc::channel::<PendingRelay>(4);
        let (_client_tx, client_inject_rx) = mpsc::channel::<crate::client_ws::PendingClient>(4);
        let (shutdown_tx, shutdown_rx) = tokio::sync::oneshot::channel::<()>();

        // Build a PendingRelay with a real ChannelId
        let mut rtc = str0m::Rtc::new(std::time::Instant::now());
        let dc_id = rtc
            .direct_api()
            .create_data_channel(str0m::channel::ChannelConfig {
                label: "relay-inject-test".to_string(),
                ordered: true,
                reliability: str0m::channel::Reliability::Reliable,
                negotiated: Some(5),
                protocol: String::new(),
            });
        relay_tx
            .send(PendingRelay {
                rtc,
                room_id: "inject-test".to_string(),
                upstream_url: "wss://127.0.0.1:9999/ws/sfu/inject-test".to_string(),
                upstream_room_token: "tok".to_string(),
                dc_id,
            })
            .await
            .unwrap();
        drop(relay_tx);

        let metrics_clone = metrics.clone();
        let handle = tokio::spawn(serve(
            socket,
            metrics_clone,
            None,
            None,
            Some(relay_rx),
            Some(client_inject_rx),
            candidate_addr,
            async {
                let _ = shutdown_rx.await;
            },
        ));

        // Give serve() time to drain the relay_rx channel
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        let _ = shutdown_tx.send(());
        handle.await.unwrap().unwrap();

        // The relay client was inserted — active_participants should be 1
        assert_eq!(
            metrics.active_participants.get(),
            1,
            "relay client must be inserted into registry via relay_rx channel"
        );
    }

    /// Verify the dedup-window logic: simulating 5 send failures to the same
    /// destination must insert exactly 1 dedup entry and suppress logs for
    /// calls 2–5 within the window.
    ///
    /// Tests the dedup invariant directly (not via network I/O) because UDP
    /// `send_to` on Linux succeeds silently for unconnected sockets even when
    /// the remote port is closed — there is no synchronous ECONNREFUSED.
    #[tokio::test]
    async fn flush_transmits_dedup_one_entry_per_dest() {
        use crate::metrics::SfuMetrics;
        use std::collections::HashMap;
        use std::net::{Ipv4Addr, SocketAddr};

        let dest: SocketAddr = (Ipv4Addr::LOCALHOST, 1u16).into();
        let metrics = std::sync::Arc::new(SfuMetrics::default());
        let mut dedup: HashMap<SocketAddr, Instant> = HashMap::new();
        let now = Instant::now();

        // Simulate 5 send_to failures from flush_transmits logic.
        let mut logged_count = 0usize;
        for _ in 0..5 {
            let kind = "other"; // simulate classify_send_error result
            metrics.udp_send_failed.with_label_values(&[kind]).inc();
            let should_log = match dedup.get(&dest) {
                Some(prev) if now.duration_since(*prev) < SEND_FAIL_DEDUP_WINDOW => false,
                _ => {
                    dedup.insert(dest, now);
                    true
                }
            };
            if should_log {
                logged_count += 1;
            }
        }

        // All 5 failures must be counted.
        assert_eq!(
            metrics.udp_send_failed.with_label_values(&["other"]).get(),
            5,
            "all 5 send failures must be counted"
        );

        // Only the first failure should have triggered a log.
        assert_eq!(logged_count, 1, "only first failure per window must log");

        // Dedup map must have exactly 1 entry for the destination.
        assert_eq!(
            dedup.len(),
            1,
            "dedup map must hold exactly one entry per destination"
        );
        assert!(
            dedup.contains_key(&dest),
            "dedup entry must be for the target destination"
        );
    }

    #[tokio::test]
    async fn serve_injects_browser_client_from_channel() {
        use crate::client_ws::PendingClient;
        use std::sync::Arc;
        use tokio::sync::mpsc;

        let cfg = SfuConfig {
            udp_port: 0,
            bind_address: "127.0.0.1".to_string(),
            ..SfuConfig::default()
        };
        let socket = bind(&cfg).await.unwrap();
        let candidate_addr = socket.local_addr().expect("local_addr");
        let metrics = Arc::new(crate::metrics::SfuMetrics::default());
        let (_relay_tx, relay_rx) = mpsc::channel::<crate::relay::client::PendingRelay>(1);
        let (client_tx, client_inject_rx) = mpsc::channel::<PendingClient>(4);
        let (shutdown_tx, shutdown_rx) = tokio::sync::oneshot::channel::<()>();

        // Build a fresh str0m Rtc as if the SDP exchange had completed.
        let rtc = str0m::Rtc::new(std::time::Instant::now());
        let (close_tx, _close_rx) = tokio::sync::oneshot::channel();
        let (ws_msg_tx, _ws_msg_rx) = mpsc::channel::<String>(4);
        client_tx
            .send(PendingClient {
                rtc,
                room_id: "browser-inject-test".to_string(),
                external_peer_id: 99,
                close_signal: close_tx,
                ws_msg_tx,
            })
            .await
            .unwrap();
        drop(client_tx);

        let metrics_clone = metrics.clone();
        let handle = tokio::spawn(serve(
            socket,
            metrics_clone,
            None,
            None,
            Some(relay_rx),
            Some(client_inject_rx),
            candidate_addr,
            async {
                let _ = shutdown_rx.await;
            },
        ));

        // Give serve() time to drain the client_inject_rx channel.
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        let _ = shutdown_tx.send(());
        handle.await.unwrap().unwrap();

        // The browser client was inserted — active_participants should be 1.
        // Browser-origin is implied by-construction: `Client::new` defaults
        // `origin = ClientOrigin::Local` (vs `Client::new_outbound_relay` for
        // the relay path), and we never wired the relay channel.
        assert_eq!(
            metrics.active_participants.get(),
            1,
            "browser client must be inserted into registry via client_inject_rx"
        );
    }
}
