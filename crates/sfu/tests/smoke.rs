//! M1.1 smoke test. Verifies that:
//!   1. `SfuConfig::default()` is sane.
//!   2. The UDP loop actually binds on port 0, accepts a datagram,
//!      and shuts down cleanly on a oneshot trigger.

use std::time::Duration;

use std::sync::Arc;

use oxpulse_sfu::metrics::SfuMetrics;
use oxpulse_sfu::{udp_loop, SfuConfig};
use tokio::net::UdpSocket;
use tokio::sync::oneshot;
use tokio::time::timeout;

#[test]
fn default_config_is_sensible() {
    let cfg = SfuConfig::default();
    assert!(cfg.udp_port > 0);
    assert!(cfg.metrics_port > 0);
    assert_ne!(cfg.udp_port, cfg.metrics_port);
    assert!(!cfg.bind_address.is_empty());
    assert!(!cfg.log_level.is_empty());
}

#[tokio::test]
async fn udp_loop_binds_receives_and_shuts_down() {
    let cfg = SfuConfig {
        udp_port: 0,
        bind_address: "127.0.0.1".to_string(),
        ..SfuConfig::default()
    };

    let server_sock = udp_loop::bind(&cfg).await.expect("bind succeeds");
    let local = server_sock.local_addr().expect("local_addr");
    assert_ne!(local.port(), 0);

    let metrics = Arc::new(SfuMetrics::default());
    let (tx, rx) = oneshot::channel::<()>();
    let (_, relay_rx) = tokio::sync::mpsc::channel(1);
    let handle = tokio::spawn(async move {
        udp_loop::serve(server_sock, metrics, None, None, relay_rx, async {
            let _ = rx.await;
        })
        .await
    });

    let client = UdpSocket::bind("127.0.0.1:0").await.expect("client bind");
    client
        .send_to(b"hello-sfu", local)
        .await
        .expect("send succeeds");

    // Give the loop a moment to process the datagram.
    tokio::time::sleep(Duration::from_millis(50)).await;

    tx.send(()).expect("shutdown signal delivered");
    let result = timeout(Duration::from_secs(2), handle)
        .await
        .expect("loop terminates within timeout")
        .expect("task did not panic");
    result.expect("serve returned Ok");
}
