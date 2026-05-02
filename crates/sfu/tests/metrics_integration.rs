//! M1.5 integration tests: UDP-loop smoke, Prometheus scrape, shutdown.
//!
//! `udp_loop_serves_with_registry_and_shuts_down` — existing UDP smoke
//! test, moved here because it exercises async runtime + serve(), which
//! is the same concern as the metrics HTTP tests below.
//!
//! `metrics_track_client_and_packet_counts` — scrapes `/metrics` after
//! 2 clients join + a MediaData forward; asserts counters are present.
//!
//! `shutdown_stops_metrics_server` — binds metrics on a random port,
//! hits it, triggers SFU shutdown, verifies connection refused within 2s.

use std::sync::Arc;
use std::time::Duration;

use oxpulse_sfu::client::test_seed::{make_media_data, new_client, seed_track_in};
use oxpulse_sfu::metrics::{spawn_metrics_server, SfuMetrics};
use oxpulse_sfu::{udp_loop, ClientId, Propagated, Registry, SfuConfig};
use str0m::media::MediaKind;
// Note: seed_track_in used in metrics_track_client_and_packet_counts below.
use tokio::net::UdpSocket;
use tokio::sync::oneshot;
use tokio::time::timeout;

// ── helpers ──────────────────────────────────────────────────────────────────

/// Bind a metrics server on 127.0.0.1:0 and return (port, handle, metrics).
///
/// We pre-bind with port 0 to get an ephemeral port, then pass the
/// *same* address (with the resolved port) to `spawn_metrics_server`
/// using `SO_REUSEADDR` semantics. On Linux the OS keeps the port
/// reserved until the new bind succeeds, so there is no race window.
fn bind_metrics_server() -> (u16, tokio::task::JoinHandle<()>, Arc<SfuMetrics>) {
    use std::net::TcpListener;
    let probe = TcpListener::bind("127.0.0.1:0").expect("probe bind");
    let port = probe.local_addr().expect("local_addr").port();
    drop(probe);
    let metrics = Arc::new(SfuMetrics::default());
    let handle = spawn_metrics_server(format!("127.0.0.1:{port}"), metrics.clone()).expect("spawn");
    (port, handle, metrics)
}

async fn scrape(port: u16) -> reqwest::Result<String> {
    reqwest::get(format!("http://127.0.0.1:{port}/metrics"))
        .await?
        .text()
        .await
}

// ── tests ─────────────────────────────────────────────────────────────────────

#[tokio::test]
async fn udp_loop_serves_with_registry_and_shuts_down() {
    let cfg = SfuConfig {
        udp_port: 0,
        bind_address: "127.0.0.1".to_string(),
        ..SfuConfig::default()
    };

    let server_sock = udp_loop::bind(&cfg).await.expect("bind");
    let local = server_sock.local_addr().expect("local_addr");
    let metrics = Arc::new(SfuMetrics::default());

    let (tx, rx) = oneshot::channel::<()>();
    let (_relay_tx, relay_rx) = tokio::sync::mpsc::channel(1);
    let (_client_tx, client_inject_rx) =
        tokio::sync::mpsc::channel::<oxpulse_sfu::client_ws::PendingClient>(1);
    let handle = tokio::spawn(async move {
        udp_loop::serve(
            server_sock,
            metrics,
            None,
            None,
            Some(relay_rx),
            Some(client_inject_rx),
            async {
                let _ = rx.await;
            },
        )
        .await
    });

    let client = UdpSocket::bind("127.0.0.1:0").await.expect("client bind");
    client
        .send_to(b"stun-probe-no-match", local)
        .await
        .expect("send");

    tokio::time::sleep(Duration::from_millis(50)).await;
    tx.send(()).expect("shutdown");

    let out = timeout(Duration::from_secs(2), handle)
        .await
        .expect("loop terminates")
        .expect("task did not panic");
    out.expect("serve returned Ok");
}

#[tokio::test]
async fn metrics_track_client_and_packet_counts() {
    let (port, _handle, metrics) = bind_metrics_server();

    // Give the server a moment to accept connections.
    tokio::time::sleep(Duration::from_millis(50)).await;

    // Build a registry wired to the same metrics instance.
    let mut registry = Registry::new(metrics.clone());

    // Insert 2 clients.
    let mut a = new_client(ClientId(100));
    let _track = seed_track_in(&mut a, 1, MediaKind::Video);
    registry.insert(a);
    let b = new_client(ClientId(101));
    registry.insert(b);

    // Forward one video packet (RID=q — matches B's default LOW layer).
    let prop = Propagated::MediaData(
        ClientId(100),
        make_media_data(1, Some(oxpulse_sfu::client::layer::LOW)),
    );
    registry.fanout_for_tests(&prop);

    // Scrape and assert counters.
    let body = timeout(Duration::from_secs(3), scrape(port))
        .await
        .expect("scrape timeout")
        .expect("scrape ok");

    assert!(
        body.contains("sfu_client_connect_total"),
        "connect counter present:\n{body}"
    );
    assert!(
        body.contains("sfu_active_participants"),
        "participants gauge present:\n{body}"
    );
    // M6.1: const label edge_id is appended to all label-sets, so exact
    // bracket strings no longer work. Match on the metric name + key label
    // value as a substring — ordering within {} is not guaranteed by prometheus 0.13.
    assert!(
        body.contains(r#"sfu_forwarded_packets_total"#) && body.contains(r#"kind="video""#),
        "forwarded video counter present:\n{body}",
    );
    assert!(
        body.contains(r#"sfu_layer_selection_total"#) && body.contains(r#"layer="q""#),
        "layer q counter present:\n{body}",
    );

    // Numeric assertions: 2 connects, active_participants = 2, ≥1 forwarded video.
    // Use contains-based line matching since labels now include edge_id.
    for line in body.lines() {
        if line.starts_with("sfu_client_connect_total{") {
            let v: f64 = line.split_whitespace().nth(1).unwrap().parse().unwrap();
            assert!(v >= 2.0, "client_connect_total ≥ 2, got {v}");
        }
        if line.starts_with("sfu_active_participants{") {
            let v: f64 = line.split_whitespace().nth(1).unwrap().parse().unwrap();
            assert_eq!(v, 2.0, "active_participants = 2, got {v}");
        }
        if line.contains(r#"sfu_forwarded_packets_total"#) && line.contains(r#"kind="video""#) {
            let v: f64 = line.split_whitespace().nth(1).unwrap().parse().unwrap();
            assert!(v >= 1.0, "forwarded video ≥ 1, got {v}");
        }
    }
}

#[tokio::test]
async fn shutdown_stops_metrics_server() {
    let (port, handle, _metrics) = bind_metrics_server();
    tokio::time::sleep(Duration::from_millis(50)).await;

    // Should succeed before shutdown.
    scrape(port).await.expect("scrape before shutdown");

    // Abort the metrics server task (simulates shutdown).
    handle.abort();
    tokio::time::sleep(Duration::from_millis(200)).await;

    // Should fail (connection refused) after abort.
    let result = timeout(Duration::from_secs(2), scrape(port)).await;
    match result {
        Ok(Err(_)) => {} // connection refused — expected
        Ok(Ok(_)) => panic!("metrics server still responding after shutdown"),
        Err(_) => panic!("scrape timed out instead of failing fast"),
    }
}
