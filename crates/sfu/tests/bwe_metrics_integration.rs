//! M5.3 / M6.1 / F2b-2 integration tests: per-peer BWE + pacer + chat-relay label cardinality.
//!
//! Concern: verifies that `reap_dead` scrubs `peer_id`-labelled series from
//! `sfu_bandwidth_estimate_bps`, `sfu_pacer_layer_total`, (M6.1)
//! `sfu_layer_transitions_total`, and (F2b-2) `chat_relay_tx_bytes_total` /
//! `chat_relay_rx_bytes_total` so reconnect churn doesn't grow cardinality.
//!
//! Split from `metrics_integration.rs` when that file exceeded 200 lines after
//! M6.1 edge_id const-label additions.

use std::sync::Arc;
use std::time::Duration;

use oxpulse_sfu::client::test_seed::{new_client, new_client_with_reactions, seed_track_in};
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

/// F2b-2: `reap_dead` must drop `chat_relay_tx_bytes_total` and
/// `chat_relay_rx_bytes_total` series keyed by `client_id` so reconnect
/// churn doesn't grow label cardinality without bound.
///
/// Strategy: bump both counters for client 201 under the `data` and `ctrl` dc
/// labels, force-disconnect the client, call `reap_dead`, then assert both
/// series are absent from the scraped output.
#[tokio::test]
async fn reap_dead_drops_chat_relay_label_series() {
    let (port, _handle, metrics) = bind_metrics_server();
    tokio::time::sleep(Duration::from_millis(50)).await;

    // Directly increment the counters — no real DC write needed.
    metrics
        .chat_relay_tx_bytes_total
        .with_label_values(&["data", "201"])
        .inc_by(100);
    metrics
        .chat_relay_tx_bytes_total
        .with_label_values(&["ctrl", "201"])
        .inc_by(50);
    metrics
        .chat_relay_rx_bytes_total
        .with_label_values(&["data", "201"])
        .inc_by(200);
    metrics
        .chat_relay_rx_bytes_total
        .with_label_values(&["ctrl", "201"])
        .inc_by(30);

    // Pre-condition: client_id="201" series must be visible.
    let before = timeout(Duration::from_secs(3), scrape(port))
        .await
        .expect("scrape timeout")
        .expect("scrape ok");
    assert!(
        before.contains(r#"client_id="201""#),
        "chat_relay tx/rx series must exist before reap:\n{before}",
    );

    // Build a registry with the same metrics, insert a client, kill it, reap.
    let mut registry = Registry::new(metrics.clone());
    let client = oxpulse_sfu::client::test_seed::new_client(ClientId(201));
    registry.insert(client);
    registry.disconnect_client_for_tests(ClientId(201));
    registry.reap_dead_for_tests();

    // Post-condition: client_id="201" series must be gone.
    let after = timeout(Duration::from_secs(3), scrape(port))
        .await
        .expect("scrape timeout")
        .expect("scrape ok");
    // Stronger: assert each metric individually so a partial scrub regression
    // (only tx or only rx removed) is caught rather than masked by a substring match.
    let tx_lines: Vec<&str> = after
        .lines()
        .filter(|l| l.starts_with("sfu_chat_relay_tx_bytes_total"))
        .collect();
    let rx_lines: Vec<&str> = after
        .lines()
        .filter(|l| l.starts_with("sfu_chat_relay_rx_bytes_total"))
        .collect();
    assert!(
        !tx_lines.iter().any(|l| l.contains(r#"client_id="201""#)),
        "tx series should be scrubbed for client_id=201 after reap, got: {tx_lines:?}",
    );
    assert!(
        !rx_lines.iter().any(|l| l.contains(r#"client_id="201""#)),
        "rx series should be scrubbed for client_id=201 after reap, got: {rx_lines:?}",
    );
}

/// F2b-2: `evict_for_steal` must drop `chat_relay_tx_bytes_total` and
/// `chat_relay_rx_bytes_total` series keyed by `client_id` so session-
/// replace churn doesn't grow label cardinality without bound.
///
/// Strategy: bump both counters for a first client under the `data` and `ctrl`
/// dc labels, then insert a second client with the same `external_peer_id`,
/// which triggers `evict_for_steal` of the first. Assert that both series are
/// absent from the scraped output after the steal.
///
/// Mirrors `reap_dead_drops_chat_relay_label_series` but exercises the
/// `evict_for_steal` path so future divergence between the two scrub branches
/// is caught immediately.
#[tokio::test]
async fn evict_for_steal_drops_chat_relay_label_series() {
    let (port, _handle, metrics) = bind_metrics_server();
    tokio::time::sleep(Duration::from_millis(50)).await;

    // Build registry with the shared metrics instance.
    let mut registry = Registry::new(metrics.clone());

    // Insert the first client tagged with external_peer_id=42.
    // new_client assigns an internal ClientId; we need that id to bump metrics.
    let first = new_client(ClientId(500)).with_external_peer_id(42);
    let first_id = *first.id; // record before ownership moves into registry
    registry.insert(first);

    // Directly increment the chat_relay counters for the first client's
    // internal id — mirrors the approach in reap_dead_drops_chat_relay_label_series.
    let first_label = first_id.to_string();
    metrics
        .chat_relay_tx_bytes_total
        .with_label_values(&["data", &first_label])
        .inc_by(100);
    metrics
        .chat_relay_tx_bytes_total
        .with_label_values(&["ctrl", &first_label])
        .inc_by(50);
    metrics
        .chat_relay_rx_bytes_total
        .with_label_values(&["data", &first_label])
        .inc_by(200);
    metrics
        .chat_relay_rx_bytes_total
        .with_label_values(&["ctrl", &first_label])
        .inc_by(30);

    // Pre-condition: first client's label series must be visible.
    let before = timeout(Duration::from_secs(3), scrape(port))
        .await
        .expect("scrape timeout")
        .expect("scrape ok");
    assert!(
        before.contains(&format!(r#"client_id="{first_label}""#)),
        "chat_relay tx/rx series must exist before steal:\n{before}",
    );

    // Insert a second client with the same external_peer_id — this triggers
    // evict_for_steal of the first client inside Registry::insert.
    let second = new_client(ClientId(501)).with_external_peer_id(42);
    registry.insert(second);

    // Give the async scrub a moment to settle (mirrors reap test pattern).
    tokio::time::sleep(Duration::from_millis(50)).await;

    // Post-condition: first client's label series must be gone.
    let after = timeout(Duration::from_secs(3), scrape(port))
        .await
        .expect("scrape timeout")
        .expect("scrape ok");
    let tx_lines: Vec<&str> = after
        .lines()
        .filter(|l| l.starts_with("sfu_chat_relay_tx_bytes_total"))
        .collect();
    let rx_lines: Vec<&str> = after
        .lines()
        .filter(|l| l.starts_with("sfu_chat_relay_rx_bytes_total"))
        .collect();
    assert!(
        !tx_lines
            .iter()
            .any(|l| l.contains(&format!(r#"client_id="{first_label}""#))),
        "tx series should be scrubbed for client_id={first_label} after steal, got: {tx_lines:?}",
    );
    assert!(
        !rx_lines
            .iter()
            .any(|l| l.contains(&format!(r#"client_id="{first_label}""#))),
        "rx series should be scrubbed for client_id={first_label} after steal, got: {rx_lines:?}",
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
    for _ in 0..oxpulse_sfu_kit::bwe::UPGRADE_STREAK {
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

/// MINOR 5: `reap_dead` must decrement `chat_relay_active_channels{dc="reactions"}`
/// when a client that had its reactions DC gauge incremented (via Event::ChannelOpen)
/// is reaped, so reconnect churn doesn't monotonically inflate the gauge.
///
/// Strategy: directly increment the gauge (simulating the ChannelOpen inc path),
/// set `reactions_dc_opened = true` via test seam, force-disconnect, reap, assert
/// gauge is back to 0.
#[tokio::test]
async fn reap_dead_drops_reactions_dc_gauge() {
    let (port, _handle, metrics) = bind_metrics_server();
    tokio::time::sleep(Duration::from_millis(50)).await;

    // Directly bump the gauge — simulates what ChannelOpen does in dispatch.
    metrics
        .chat_relay_active_channels
        .with_label_values(&["reactions"])
        .inc();

    // Pre-condition: gauge must be 1.
    assert_eq!(
        metrics
            .chat_relay_active_channels
            .with_label_values(&["reactions"])
            .get(),
        1,
        "gauge must be 1 before reap"
    );

    // Build a registry with the shared metrics, insert a reactions-DC client,
    // mark reactions_dc_opened so reap knows to dec.
    let mut registry = Registry::new(metrics.clone());
    let mut client = new_client_with_reactions(ClientId(600));
    client.reactions_dc_opened = true;
    registry.insert(client);
    registry.disconnect_client_for_tests(ClientId(600));
    registry.reap_dead_for_tests();

    // Post-condition: gauge must be 0 (dec fired).
    assert_eq!(
        metrics
            .chat_relay_active_channels
            .with_label_values(&["reactions"])
            .get(),
        0,
        "chat_relay_active_channels{{dc=\"reactions\"}} must be 0 after reap"
    );
}

/// MINOR 5: `evict_for_steal` must decrement `chat_relay_active_channels{dc="reactions"}`
/// when it evicts a client whose reactions gauge was incremented.
///
/// Mirrors `reap_dead_drops_reactions_dc_gauge` but exercises the session-steal path.
#[tokio::test]
async fn evict_for_steal_drops_reactions_dc_gauge() {
    let (port, _handle, metrics) = bind_metrics_server();
    tokio::time::sleep(Duration::from_millis(50)).await;

    // Directly bump the gauge to simulate the ChannelOpen inc.
    metrics
        .chat_relay_active_channels
        .with_label_values(&["reactions"])
        .inc();

    let mut registry = Registry::new(metrics.clone());
    // Insert first client with external_peer_id=77 and reactions opened.
    let mut first = new_client_with_reactions(ClientId(700)).with_external_peer_id(77);
    first.reactions_dc_opened = true;
    let _first_id = *first.id;
    registry.insert(first);

    // Pre-condition: gauge is 1.
    assert_eq!(
        metrics
            .chat_relay_active_channels
            .with_label_values(&["reactions"])
            .get(),
        1,
        "gauge must be 1 before steal"
    );

    // Insert second client with same peer_id — triggers evict_for_steal of first.
    let second = new_client_with_reactions(ClientId(701)).with_external_peer_id(77);
    registry.insert(second);

    tokio::time::sleep(Duration::from_millis(50)).await;

    // Post-condition: gauge must be 0 (dec fired in evict_for_steal for first).
    // Note: second client's reactions DC gauge was not incremented (no ChannelOpen
    // fired in test — reactions_dc_opened is false), so net gauge = 1 - 1 = 0.
    assert_eq!(
        metrics
            .chat_relay_active_channels
            .with_label_values(&["reactions"])
            .get(),
        0,
        "chat_relay_active_channels{{dc=\"reactions\"}} must be 0 after steal"
    );
}
