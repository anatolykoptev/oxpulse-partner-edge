//! M5.3 / M6.1 integration tests: per-peer BWE + pacer label cardinality.
//!
//! Concern: verifies that `reap_dead` scrubs `peer_id`-labelled series from
//! `sfu_bandwidth_estimate_bps`, `sfu_pacer_layer_total`, and (M6.1)
//! `sfu_layer_transitions_total` so reconnect churn doesn't grow cardinality.
//!
//! Split from `metrics_integration.rs` when that file exceeded 200 lines after
//! M6.1 edge_id const-label additions.

use std::sync::Arc;
use std::time::Duration;

use oxpulse_sfu::client::test_seed::{new_client, seed_track_in};
use oxpulse_sfu::metrics::{spawn_metrics_server, SfuMetrics};
use oxpulse_sfu::{ClientId, Registry};
use str0m::media::MediaKind;
use tokio::time::timeout;

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

#[tokio::test]
async fn reap_dead_scrubs_per_peer_bwe_labels() {
    // M5.3 regression + M6.1 layer_transitions_total: reap_dead must remove
    // all per-peer label series for dead clients to prevent cardinality growth.
    let (port, _handle, metrics) = bind_metrics_server();
    tokio::time::sleep(Duration::from_millis(50)).await;

    let mut registry = Registry::new(metrics.clone());

    let mut a = new_client(ClientId(200));
    let _arc = seed_track_in(&mut a, 1, MediaKind::Video);
    registry.insert(a);
    let b = new_client(ClientId(201));
    registry.insert(b);

    registry.cap_subscriber_bandwidth_for_tests(ClientId(201), 200_000);
    registry.drive_subscriber_bandwidth_for_tests(ClientId(201), 200_000);
    registry.force_pacer_refresh_for_tests(ClientId(200));

    // Baseline: both label series present for B (201).
    // M6.1: edge_id const label appended — match metric name + peer_id value.
    let before = timeout(Duration::from_secs(3), scrape(port))
        .await
        .expect("scrape timeout")
        .expect("scrape ok");
    assert!(
        before.contains("sfu_bandwidth_estimate_bps") && before.contains(r#"peer_id="201""#),
        "subscriber BWE label present before reap:\n{before}",
    );
    assert!(
        before.contains("sfu_pacer_layer_total") && before.contains(r#"peer_id="201""#),
        "subscriber pacer label present before reap:\n{before}",
    );

    // Kill B and reap.
    registry.disconnect_client_for_tests(ClientId(201));
    registry.reap_dead_for_tests();

    // After reap: B's series must be absent regardless of label ordering.
    let after = timeout(Duration::from_secs(3), scrape(port))
        .await
        .expect("scrape timeout")
        .expect("scrape ok");
    assert!(
        !after.contains(r#"peer_id="201""#),
        "dead subscriber per-peer labels must be scrubbed after reap:\n{after}",
    );
}

#[tokio::test]
async fn layer_transitions_total_increments_on_layer_change() {
    // M6.1: verify sfu_layer_transitions_total fires when a subscriber's
    // chosen simulcast layer changes between pacer refresh calls.
    //
    // Strategy: subscriber starts at LOW (default). Drive native estimate to
    // 2 Mbps and refresh UPGRADE_CONSECUTIVE times so the pacer accumulates a
    // promotion streak.
    //
    // Why the asserted transition is q→h (not q→f):
    //   The pacer alone WOULD jump directly to f after a streak — `tier_for_budget`
    //   returns HIGH for budget ≥ F_FLOOR_BPS (1.5 Mbps), and after
    //   UPGRADE_CONSECUTIVE matching observations the pacer sets `current = target`
    //   directly (no stair-step in `pacer.rs::preferred_rid`).
    //   BUT `update_pacer_layers` in `bwe.rs` then conservatively caps the
    //   pacer's choice with GoogCC's `preferred_rid`. GoogCC's AimdController
    //   starts at the kit-default initial rate (~500 kbps), which corresponds
    //   to MEDIUM. The conservative-merge picks `min(pacer, googcc) = h`.
    //   Hence the observable transition lands at h, not f.
    //   If the kit's GoogCC initial rate is ever raised above F_FLOOR_BPS,
    //   this test will need to be updated (the q→h assertion would silently
    //   become q→f).
    let (port, _handle, metrics) = bind_metrics_server();
    tokio::time::sleep(Duration::from_millis(50)).await;

    let mut registry = Registry::new(metrics.clone());

    // A publishes video; B subscribes.
    let mut a = new_client(ClientId(300));
    let _arc = seed_track_in(&mut a, 1, MediaKind::Video);
    registry.insert(a);
    let b = new_client(ClientId(301));
    registry.insert(b);

    // First refresh: bandwidth not yet estimated — pacer stays at LOW (q).
    registry.force_pacer_refresh_for_tests(ClientId(300));

    // Drive B's bandwidth well above the HIGH tier floor (1.5 Mbps).
    registry.drive_subscriber_bandwidth_for_tests(ClientId(301), 2_000_000);

    // Pacer requires UPGRADE_CONSECUTIVE consecutive observations of the same
    // upgrade target before promoting; refresh that many times so q→h fires.
    for _ in 0..oxpulse_sfu::pacer::UPGRADE_CONSECUTIVE {
        registry.force_pacer_refresh_for_tests(ClientId(300));
    }

    let body = timeout(Duration::from_secs(3), scrape(port))
        .await
        .expect("scrape timeout")
        .expect("scrape ok");

    assert!(
        body.contains("sfu_layer_transitions_total")
            && body.contains(r#"from="q""#)
            && body.contains(r#"to="h""#),
        "layer transition q→h counter present:\n{body}",
    );
}
