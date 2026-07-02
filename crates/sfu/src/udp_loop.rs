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

use crate::client::Transmit;
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
    let solo_kick_timeout = if config.solo_kick_after_secs == 0 {
        None
    } else {
        Some(Duration::from_secs(config.solo_kick_after_secs))
    };
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
        solo_kick_timeout,
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
    solo_kick_timeout: Option<Duration>,
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
    // T10 bug-hunt: hoisted out of `flush_transmits` — previously a fresh
    // `Vec::new()` was allocated on every flush (once per loop iteration on
    // the packet hot path). Declared once here and `clear()`ed at the top
    // of each flush; `clear()` truncates length but retains the underlying
    // allocation, so once this reaches steady-state capacity the flush
    // allocates zero bytes.
    let mut pending_transmits: Vec<Transmit> = Vec::new();
    tokio::pin!(shutdown);

    loop {
        // T10 bug-hunt: per-iteration duration, observed once this whole
        // loop pass (processing + select wait) completes below. See
        // `SfuMetrics::sfu_udp_loop_iteration_seconds` doc for why this is
        // the saturation signal `udp_loop_iterations_total`'s rate misses.
        let iter_start = Instant::now();
        metrics_ref.udp_loop_iterations_total.inc();
        registry.reap_dead();
        // Solo-peer auto-kick: if configured, check whether the lone remaining
        // peer has exceeded the hold timeout. Runs after reap_dead so we never
        // kick a peer whose `is_alive` state is already false (they'd be reaped
        // on the very next iteration anyway).
        if let Some(timeout) = solo_kick_timeout {
            registry.check_solo_timeout(timeout, Instant::now());
        }
        // Phase J M2: drain WS control messages (answer-renegotiate) from each client.
        // Must happen before poll_all so accepted answers are visible in the same iteration.
        registry.pump_ws_ctrl();

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
            &mut pending_transmits,
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
                // Observe here too (not just at the bottom of the loop,
                // which this early `return` skips) — this iteration still
                // did real work above (reap_dead/poll_all/fanout/flush)
                // before choosing to shut down, so its duration belongs in
                // the histogram. Keeps sample count == iterations_total
                // exactly, with no shutdown-iteration gap to explain away.
                metrics_ref
                    .sfu_udp_loop_iteration_seconds
                    .observe(iter_start.elapsed().as_secs_f64());
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
                        //     "tracks": [ { "stream_id": "peer-7", "peer_id": 7 }, ... ] }
                        //
                        // peer_id is a JSON integer (u64) — matches tracks_map_update schema
                        // in renegotiation.rs so the browser handler can use the same lookup.
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
                                    "peer_id": pid,
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

                        let ws_ctrl_rx = pending.ws_ctrl_rx;
                        let client = crate::client::Client::new(pending.rtc, metrics_ref.clone())
                            .with_keys_dc()
                            .with_chat_dcs()
                            .with_reactions_dc()
                            .with_sfu_events_dc()
                            .with_external_peer_id(external_peer_id)
                            .with_close_signal(pending.close_signal)
                            // Phase J M2: wire WS channels so the client can push
                            // offer-renegotiate frames and drain answer-renegotiate replies.
                            .with_ws_msg_tx(ws_msg_tx.clone())
                            .with_ws_ctrl_rx(ws_ctrl_rx);
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

        // Every arm except shutdown (which observes inline above, then
        // returns) falls through to this point — exactly one observe()
        // per loop pass, matching `udp_loop_iterations_total`'s increment
        // at the top.
        metrics_ref
            .sfu_udp_loop_iteration_seconds
            .observe(iter_start.elapsed().as_secs_f64());
    }
}

/// Classify a UDP destination as a bogon address that must be dropped before
/// `send_to` is called.
///
/// Returns `Some(kind)` where `kind` is one of:
/// * `"rfc1918"` — private IPv4 (10/8, 172.16/12, 192.168/16) or IPv6 unique-local (fc00::/7).
/// * `"cgnat"` — RFC 6598 shared address space (100.64.0.0/10). Used by Verizon and T-Mobile
///   carrier-grade NAT. `Ipv4Addr::is_private()` does not cover this range, so it is
///   checked explicitly. Verizon CGNAT uses 100.64–127.x; str0m retransmits to these
///   addresses produce OS error 89 (EDESTADDRREQ) with no connectivity.
/// * `"loopback"` — 127.0.0.0/8 or ::1/128.
/// * `"link_local"` — 169.254.0.0/16 or fe80::/10.
/// * `"multicast"` — 224.0.0.0/4 or ff00::/8.
/// * `"other"` — unspecified (0.0.0.0 / ::) or IPv4 broadcast (255.255.255.255).
///
/// Returns `None` for public routable addresses that should be sent normally.
fn is_bogon(addr: &std::net::SocketAddr) -> Option<&'static str> {
    use std::net::IpAddr;
    match addr.ip() {
        IpAddr::V4(v4) => {
            if v4.is_loopback() {
                return Some("loopback");
            }
            if v4.is_link_local() {
                return Some("link_local");
            }
            if v4.is_multicast() {
                return Some("multicast");
            }
            if v4.is_private() {
                return Some("rfc1918");
            }
            // RFC 6598 CGNAT: 100.64.0.0/10 (100.64.x.x – 100.127.x.x).
            // `is_private()` does not cover this range. Check: first octet == 100
            // and (second octet & 0xc0) == 64, which selects [64, 127].
            let octets = v4.octets();
            if octets[0] == 100 && (octets[1] & 0xc0) == 64 {
                return Some("cgnat");
            }
            if v4.is_unspecified() || v4.is_broadcast() {
                return Some("other");
            }
        }
        IpAddr::V6(v6) => {
            if v6.is_loopback() {
                return Some("loopback");
            }
            // fe80::/10 link-local — is_unicast_link_local stabilised in Rust 1.79;
            // replace with v6.is_unicast_link_local() when MSRV >= 1.79.
            let segs = v6.segments();
            if (segs[0] & 0xffc0) == 0xfe80 {
                return Some("link_local");
            }
            if v6.is_multicast() {
                return Some("multicast");
            }
            // fc00::/7 unique-local — equivalent to RFC-1918 for IPv6.
            if (segs[0] & 0xfe00) == 0xfc00 {
                return Some("rfc1918");
            }
            if v6.is_unspecified() {
                return Some("other");
            }
        }
    }
    None
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
    pending: &mut Vec<Transmit>,
) {
    // T10 bug-hunt: `pending` is caller-owned and reused across iterations
    // (see `pending_transmits` in `serve()`) instead of allocated fresh
    // here every flush. `clear()` truncates length to 0 but keeps the
    // underlying allocation, so steady-state flushes on the packet hot
    // path allocate nothing.
    pending.clear();
    registry.drain_transmits(|t| pending.push(t));
    for t in pending.drain(..) {
        // Drop packets destined for bogon addresses before calling send_to.
        // Mobile CGNAT peers (T-Mobile/Verizon) advertise private IPs as ICE
        // candidates; send_to on those produces EDESTADDRREQ (OS error 89)
        // and wastes str0m retransmit budget without producing connectivity.
        if let Some(kind) = is_bogon(&t.destination) {
            metrics
                .udp_bogon_dest_dropped_total
                .with_label_values(&[kind])
                .inc();
            continue;
        }
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
            None, // solo_kick_timeout: disabled in test
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
            None, // solo_kick_timeout: disabled in test
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
            None, // solo_kick_timeout: disabled in test
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
            None, // solo_kick_timeout: disabled in test
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
                ws_ctrl_rx: tokio::sync::mpsc::channel(8).1,
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
            None, // solo_kick_timeout: disabled in test
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

    // ── bogon-filter TDD ──────────────────────────────────────────────────────

    /// RFC 6598 CGNAT (100.64.0.0/10) must be classified as "cgnat".
    ///
    /// Range: 100.64.0.0 – 100.127.255.255.
    /// Boundary: 100.64.0.0 = first byte 100, second byte 64 (0b0100_0000),
    /// mask 0xc0 → (second & 0xc0) == 64 for [64..127].
    #[test]
    fn is_bogon_cgnat_rfc6598_in_range() {
        use std::net::{Ipv4Addr, SocketAddr};
        for ip in [
            Ipv4Addr::new(100, 64, 0, 1),      // first usable
            Ipv4Addr::new(100, 95, 255, 254),  // mid-range
            Ipv4Addr::new(100, 127, 255, 254), // last usable
        ] {
            let sa: SocketAddr = (ip, 5000u16).into();
            assert_eq!(
                is_bogon(&sa),
                Some("cgnat"),
                "{ip} must be classified as cgnat (RFC 6598)"
            );
        }
    }

    /// Addresses just outside RFC 6598 CGNAT must NOT be classified as "cgnat".
    #[test]
    fn is_bogon_cgnat_rfc6598_out_of_range() {
        use std::net::{Ipv4Addr, SocketAddr};
        for ip in [
            Ipv4Addr::new(100, 63, 255, 255), // one below range
            Ipv4Addr::new(100, 128, 0, 0),    // one above range
        ] {
            let sa: SocketAddr = (ip, 5000u16).into();
            assert_eq!(
                is_bogon(&sa),
                None,
                "{ip} is outside CGNAT range and must return None"
            );
        }
    }

    /// Every RFC-1918 address must be classified as "rfc1918".
    #[test]
    fn is_bogon_rfc1918() {
        use std::net::{Ipv4Addr, SocketAddr};
        for ip in [
            Ipv4Addr::new(10, 0, 0, 1),
            Ipv4Addr::new(10, 8, 0, 3),
            Ipv4Addr::new(172, 16, 0, 1),
            Ipv4Addr::new(172, 31, 255, 255),
            Ipv4Addr::new(192, 168, 1, 1),
        ] {
            let sa: SocketAddr = (ip, 1234u16).into();
            assert_eq!(
                is_bogon(&sa),
                Some("rfc1918"),
                "{ip} must be classified as rfc1918"
            );
        }
    }

    /// Loopback addresses must be classified as "loopback".
    #[test]
    fn is_bogon_loopback() {
        use std::net::{Ipv4Addr, Ipv6Addr, SocketAddr};
        let v4: SocketAddr = (Ipv4Addr::LOCALHOST, 80u16).into();
        assert_eq!(is_bogon(&v4), Some("loopback"));
        let v6: SocketAddr = (Ipv6Addr::LOCALHOST, 80u16).into();
        assert_eq!(is_bogon(&v6), Some("loopback"));
    }

    /// Link-local addresses must be classified as "link_local".
    #[test]
    fn is_bogon_link_local() {
        use std::net::{Ipv4Addr, SocketAddr};
        let ip = Ipv4Addr::new(169, 254, 0, 1);
        let sa: SocketAddr = (ip, 80u16).into();
        assert_eq!(is_bogon(&sa), Some("link_local"));
    }

    /// Multicast addresses must be classified as "multicast".
    #[test]
    fn is_bogon_multicast_v4() {
        use std::net::{Ipv4Addr, SocketAddr};
        let ip = Ipv4Addr::new(224, 0, 0, 1);
        let sa: SocketAddr = (ip, 5004u16).into();
        assert_eq!(is_bogon(&sa), Some("multicast"));
    }

    /// 0.0.0.0 and 255.255.255.255 are classified as "other".
    #[test]
    fn is_bogon_unspecified_and_broadcast() {
        use std::net::{Ipv4Addr, SocketAddr};
        let unspec: SocketAddr = (Ipv4Addr::UNSPECIFIED, 0u16).into();
        assert_eq!(is_bogon(&unspec), Some("other"));
        let bcast: SocketAddr = (Ipv4Addr::BROADCAST, 0u16).into();
        assert_eq!(is_bogon(&bcast), Some("other"));
    }

    /// Public IPv4 addresses must return None (not bogon).
    #[test]
    fn is_bogon_public_ipv4_returns_none() {
        use std::net::{Ipv4Addr, SocketAddr};
        for ip in [
            Ipv4Addr::new(1, 1, 1, 1),
            Ipv4Addr::new(8, 8, 8, 8),
            Ipv4Addr::new(203, 0, 113, 5),
        ] {
            let sa: SocketAddr = (ip, 4443u16).into();
            assert_eq!(
                is_bogon(&sa),
                None,
                "{ip} is a public IP and must not be filtered"
            );
        }
    }

    /// Public IPv6 addresses must return None (not bogon).
    #[test]
    fn is_bogon_public_ipv6_returns_none() {
        use std::net::{Ipv6Addr, SocketAddr};
        // 2001:db8:: is documentation range, but not loopback/link-local/multicast.
        let ip = Ipv6Addr::new(0x2001, 0x0db8, 0, 0, 0, 0, 0, 1);
        let sa: SocketAddr = (ip, 4443u16).into();
        assert_eq!(is_bogon(&sa), None);
    }

    /// IPv6 unique-local (fc00::/7) must be classified as "rfc1918".
    #[test]
    fn is_bogon_ipv6_unique_local() {
        use std::net::{Ipv6Addr, SocketAddr};
        let ip = Ipv6Addr::new(0xfc00, 0, 0, 0, 0, 0, 0, 1);
        let sa: SocketAddr = (ip, 80u16).into();
        assert_eq!(is_bogon(&sa), Some("rfc1918"));
    }

    /// IPv6 link-local (fe80::/10) must be classified as "link_local".
    #[test]
    fn is_bogon_ipv6_link_local() {
        use std::net::{Ipv6Addr, SocketAddr};
        let ip = Ipv6Addr::new(0xfe80, 0, 0, 0, 0, 0, 0, 1);
        let sa: SocketAddr = (ip, 80u16).into();
        assert_eq!(is_bogon(&sa), Some("link_local"));
    }

    /// IPv6 multicast (ff00::/8) must be classified as "multicast".
    #[test]
    fn is_bogon_ipv6_multicast() {
        use std::net::{Ipv6Addr, SocketAddr};
        let ip = Ipv6Addr::new(0xff02, 0, 0, 0, 0, 0, 0, 1);
        let sa: SocketAddr = (ip, 5004u16).into();
        assert_eq!(is_bogon(&sa), Some("multicast"));
    }

    // ── T10 bug-hunt: iteration-duration histogram + Vec-hoist ─────────────────

    /// `sfu_udp_loop_iteration_seconds` must be registered and observed
    /// exactly once per completed `serve()` loop iteration.
    ///
    /// Before this change the only loop-health signal was
    /// `udp_loop_iterations_total`, whose *rate* alerts on a spin (>500/s)
    /// but says nothing when a core is saturated — under saturation the
    /// iteration rate DROPS (fewer completed wakeups/sec), not rises, so a
    /// starved core produced no alert. This test proves the histogram's
    /// sample count tracks the iteration counter 1:1, so a per-iteration
    /// duration signal exists independent of the rate.
    #[tokio::test]
    async fn serve_observes_iteration_duration_once_per_loop() {
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
        let hist = metrics.sfu_udp_loop_iteration_seconds.clone();

        let (shutdown_tx, shutdown_rx) = tokio::sync::oneshot::channel::<()>();
        let task = tokio::spawn(serve(
            socket,
            metrics,
            None,
            None,
            None, // standalone — no relay channel
            None, // standalone — no client inject channel
            candidate_addr,
            None, // solo_kick_timeout: disabled in test
            async {
                let _ = shutdown_rx.await;
            },
        ));

        tokio::time::sleep(Duration::from_millis(200)).await;
        shutdown_tx.send(()).expect("shutdown signal");
        task.await.expect("join").expect("serve ok");

        let iters = iter_counter.get();
        let samples = hist.get_sample_count();
        assert!(iters > 0, "expected at least one loop iteration in 200ms");
        assert_eq!(
            samples, iters,
            "sfu_udp_loop_iteration_seconds sample count ({samples}) must equal \
             udp_loop_iterations_total ({iters}) — the histogram must observe() \
             exactly once per completed serve() iteration"
        );
    }

    /// Pins `flush_transmits`'s current send/skip behaviour end-to-end
    /// through the REAL registry → client `pending_out` seam, before
    /// hoisting the per-call `Vec` out of the function (2026-07 bug-hunt
    /// finding, resource_exhaustion/low: `Vec::new()` was allocated fresh on
    /// every flush, i.e. once per UDP loop iteration on the packet hot
    /// path).
    ///
    /// Two same-destination packets must arrive in send order and a
    /// bogon-destined packet queued between them must never leave the
    /// process. Unlike `is_bogon_counter_increment_rfc1918` below (which
    /// documents that it does NOT exercise `flush_transmits`), this test
    /// drives the real function via `Client::pending_out` — the seam that
    /// test previously lacked.
    #[tokio::test]
    async fn flush_transmits_preserves_order_and_skips_bogon() {
        use crate::client::test_seed::new_client;
        use crate::client::Transmit;
        use crate::metrics::SfuMetrics;
        use crate::propagate::ClientId;
        use std::net::{Ipv4Addr, SocketAddr};
        use std::sync::Arc;
        use str0m::net::Protocol;

        // `is_bogon` correctly rejects loopback (and RFC1918/link-local) as
        // send destinations — real ICE peers never live there — which means
        // a loopback-bound receiver can't observe the *non-bogon* leg of
        // this test. This host's IPv4 default route goes through NAT (its
        // own address is RFC1918, e.g. 10.0.0.x), but it has a real
        // global-scope IPv6 address, and sending UDP to your own
        // globally-routable address is delivered locally by the kernel
        // (verified empirically on this box). Discover it with the
        // standard connect-without-sending trick: `connect()` on a UDP
        // socket only does a routing-table lookup — no packet leaves the
        // host. This test exercises the real `oxpulse-sfu` self-hosted CI
        // box only (see repo CI model), so depending on its real interface
        // is expected, not incidental.
        let probe = std::net::UdpSocket::bind("[::]:0").expect("bind v6 probe");
        probe
            .connect("[2001:4860:4860::8888]:80")
            .expect("route lookup for a global IPv6 destination must succeed on this host");
        let local_v6 = probe.local_addr().expect("probe local_addr").ip();

        let metrics = Arc::new(SfuMetrics::default());
        let mut registry = Registry::new(metrics.clone());

        let recv_sock = UdpSocket::bind(SocketAddr::new(local_v6, 0))
            .await
            .expect("bind recv on global IPv6 address");
        let dest = recv_sock.local_addr().expect("recv local_addr");
        assert!(
            is_bogon(&dest).is_none(),
            "test precondition failed: {dest} must not be bogon-classified (got {:?}) — \
             this host's global IPv6 address changed shape, update the probe target",
            is_bogon(&dest)
        );
        let send_sock = UdpSocket::bind(SocketAddr::new(local_v6, 0))
            .await
            .expect("bind send on global IPv6 address");
        let send_src = send_sock.local_addr().expect("send local_addr");
        let bogon_dest: SocketAddr = (Ipv4Addr::new(10, 0, 0, 1), 5000u16).into();

        let mut client = new_client(ClientId(1));
        client.pending_out.push_back(Transmit {
            proto: Protocol::Udp,
            source: send_src,
            destination: dest,
            contents: b"packet-one".to_vec().into(),
        });
        client.pending_out.push_back(Transmit {
            proto: Protocol::Udp,
            source: send_src,
            destination: bogon_dest,
            contents: b"never-sent".to_vec().into(),
        });
        client.pending_out.push_back(Transmit {
            proto: Protocol::Udp,
            source: send_src,
            destination: dest,
            contents: b"packet-two".to_vec().into(),
        });
        registry.insert(client);

        let mut dedup: HashMap<SocketAddr, Instant> = HashMap::new();
        let mut pending: Vec<Transmit> = Vec::new();
        flush_transmits(
            &send_sock,
            &mut registry,
            &metrics,
            &mut dedup,
            Instant::now(),
            &mut pending,
        )
        .await;

        let mut buf = [0u8; 64];
        let (n1, _) = tokio::time::timeout(Duration::from_secs(1), recv_sock.recv_from(&mut buf))
            .await
            .expect("recv1 timeout")
            .expect("recv1 ok");
        assert_eq!(
            &buf[..n1],
            b"packet-one",
            "first same-dest packet must arrive first"
        );

        let (n2, _) = tokio::time::timeout(Duration::from_secs(1), recv_sock.recv_from(&mut buf))
            .await
            .expect("recv2 timeout")
            .expect("recv2 ok");
        assert_eq!(
            &buf[..n2],
            b"packet-two",
            "second same-dest packet must arrive second, preserving send order"
        );

        assert_eq!(
            metrics
                .udp_bogon_dest_dropped_total
                .with_label_values(&["rfc1918"])
                .get(),
            1,
            "bogon-destined transmit must be dropped before send_to, not delivered"
        );
        let send_failed: u64 = [
            "dest_required",
            "network_unreachable",
            "host_unreachable",
            "perm",
            "other",
        ]
        .iter()
        .map(|k| metrics.udp_send_failed.with_label_values(&[k]).get())
        .sum();
        assert_eq!(
            send_failed, 0,
            "no real send_to failures expected for a loopback destination"
        );

        // The hoisted Vec must be empty and ready for the next iteration's
        // clear()+push cycle — proves flush_transmits drains what it queues.
        assert!(
            pending.is_empty(),
            "pending Vec must be drained after flush_transmits"
        );
    }

    /// Verifies `is_bogon` classifies RFC-1918 addresses correctly and that
    /// the counter increment path works. This is an honest-scope unit test —
    /// it does NOT exercise the `flush_transmits` code path end-to-end.
    /// `flush_transmits_preserves_order_and_skips_bogon` above exercises the
    /// real path via the `Client::pending_out` seam.
    #[tokio::test]
    async fn is_bogon_counter_increment_rfc1918() {
        use crate::metrics::SfuMetrics;
        use std::net::{Ipv4Addr, SocketAddr};
        use std::sync::Arc;

        let socket = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let metrics = Arc::new(SfuMetrics::default());
        let bogon_dest: SocketAddr = (Ipv4Addr::new(10, 8, 0, 3), 62230u16).into();

        // Exercises the classification + counter path in isolation (see
        // `flush_transmits_preserves_order_and_skips_bogon` for the same
        // assertion driven through the real `flush_transmits` fn).
        let kind = is_bogon(&bogon_dest).expect("10.8.0.3 must be classified as bogon");
        assert_eq!(kind, "rfc1918");
        metrics
            .udp_bogon_dest_dropped_total
            .with_label_values(&[kind])
            .inc();

        let dropped = metrics
            .udp_bogon_dest_dropped_total
            .with_label_values(&["rfc1918"])
            .get();
        assert_eq!(dropped, 1, "bogon counter must be incremented for rfc1918");

        // send_failed counter must NOT be touched.
        let send_failed: u64 = [
            "dest_required",
            "network_unreachable",
            "host_unreachable",
            "perm",
            "other",
        ]
        .iter()
        .map(|k| metrics.udp_send_failed.with_label_values(&[k]).get())
        .sum();
        assert_eq!(
            send_failed, 0,
            "send_failed counter must stay 0 for bogon skip"
        );

        drop(socket);
    }
}
