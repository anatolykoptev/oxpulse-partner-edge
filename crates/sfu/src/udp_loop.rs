//! Async UDP socket loop — M1.2.
//!
//! Binds `SfuConfig.udp_port` on `SfuConfig.bind_address`, demuxes
//! incoming datagrams through the [`Registry`], flushes each client's
//! outbound queue back to the socket, and honors a shutdown future
//! so the caller can stop the loop cleanly.
//!
//! Client registration (SDP offer/answer, ICE, TURN bridging) is the
//! signaling layer's job in M2; until then the registry starts empty
//! and the loop's demux branch simply logs `no client accepts`.

use std::future::Future;
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

/// Run the SFU UDP loop until `shutdown` resolves. The bound
/// `SocketAddr` is not returned from here — tests that need it should
/// call [`bind`] and pass the resulting socket into [`serve`].
pub async fn run_udp_loop<F>(
    config: SfuConfig,
    metrics: Arc<SfuMetrics>,
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
    serve(
        socket,
        metrics,
        relay_auth_secret,
        relay_signing_pubkey,
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
pub async fn serve<F>(
    socket: UdpSocket,
    metrics: Arc<SfuMetrics>,
    relay_auth_secret: Option<Arc<[u8]>>,
    relay_signing_pubkey: Option<Arc<String>>,
    shutdown: F,
) -> anyhow::Result<()>
where
    F: Future<Output = ()>,
{
    let local = socket.local_addr().context("failed to read local_addr")?;
    let mut registry = Registry::with_relay_auth(metrics, relay_auth_secret, relay_signing_pubkey);
    let mut buf = vec![0u8; RECV_BUFFER_BYTES];
    // M1.4: ASO tick drives dominant-speaker election. Delay-on-miss so
    // a slow tick doesn't cause a burst of tick() calls.
    let mut aso_interval = tokio::time::interval(TICK_INTERVAL);
    aso_interval.set_missed_tick_behavior(MissedTickBehavior::Delay);
    tokio::pin!(shutdown);

    loop {
        registry.reap_dead();

        // Drain whatever str0m has ready to emit *before* waiting for
        // the next packet, so outbound bytes don't sit on clients
        // longer than one tick.
        let deadline = registry.poll_all(Instant::now());
        registry.fanout_pending();
        flush_transmits(&socket, &mut registry).await;

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
                        registry.handle_incoming(src, local, &buf[..n]);
                    }
                    Err(e) => {
                        // Transient per-datagram errors shouldn't kill
                        // the loop; log and continue.
                        tracing::warn!(error = %e, "udp recv_from failed");
                    }
                }
            }
        }
    }
}

async fn flush_transmits(socket: &UdpSocket, registry: &mut Registry) {
    let mut pending = Vec::new();
    registry.drain_transmits(|t| pending.push(t));
    for t in pending {
        if let Err(e) = socket.send_to(&t.contents, t.destination).await {
            tracing::warn!(
                dest = %t.destination,
                error = %e,
                "udp send_to failed",
            );
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
        let metrics = Arc::new(SfuMetrics::default());
        let (tx, rx) = tokio::sync::oneshot::channel::<()>();
        let handle = tokio::spawn(serve(socket, metrics, None, None, async {
            let _ = rx.await;
        }));
        tx.send(()).unwrap();
        handle.await.unwrap().unwrap();
    }
}
