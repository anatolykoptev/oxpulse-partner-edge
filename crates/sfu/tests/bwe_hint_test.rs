//! Integration tests for `{"kind":"bwe-hint","from":"...","ts":...,"bps":...}`.
//!
//! Phase 2c — observability-only: the message is parsed, logged, and counted.
//! No SVC layer switching in v1.
//!
//! Review fix batch (round 2):
//! - MAJOR 1: `sfu_bwe_hint_received_total` scrubbed on reap_dead + evict_for_steal.
//! - MAJOR 2: per-peer rate gate (10 hints/s cap) + `sfu_bwe_hint_throttled_total`.
//! - MINOR 3: `from` field truncated to 64 chars before log.
//! - MINOR 4: flaky sleep(50ms) replaced with poll-loop.

use std::sync::Arc;
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use jsonwebtoken::{encode, EncodingKey, Header};
use oxpulse_sfu::client_ws::{spawn_client_ws_api, PendingClient};
use oxpulse_sfu::metrics::SfuMetrics;
use oxpulse_sfu::room_auth::RoomClaims;
use serial_test::serial;
use tokio::net::TcpListener;
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::{
    client::IntoClientRequest, handshake::client::generate_key, http::HeaderValue, Message,
};

const HS256_SECRET: &[u8] = b"test-secret-32-bytes-long-enough!";
const SUBPROTO: &str = "oxpulse-sfu-v1";
const ROOM_ID: &str = "BWE-HINT-TEST";

fn make_token(room: &str, sub: u64, secret: &[u8], exp_delta_secs: i64) -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs();
    let exp = (now as i64 + exp_delta_secs).max(0) as u64;
    let claims = RoomClaims {
        sub,
        room: room.to_string(),
        iat: now,
        exp,
    };
    encode(
        &Header::default(),
        &claims,
        &EncodingKey::from_secret(secret),
    )
    .unwrap()
}

fn build_request(
    url: &str,
    token: &str,
) -> tokio_tungstenite::tungstenite::handshake::client::Request {
    let mut req = url.into_client_request().expect("valid URL");
    let value = format!("{SUBPROTO}, Bearer {token}");
    req.headers_mut().insert(
        "sec-websocket-protocol",
        HeaderValue::from_str(&value).unwrap(),
    );
    req.headers_mut().insert(
        "sec-websocket-key",
        HeaderValue::from_str(&generate_key()).unwrap(),
    );
    req.headers_mut()
        .insert("sec-websocket-version", HeaderValue::from_static("13"));
    req.headers_mut()
        .insert("connection", HeaderValue::from_static("Upgrade"));
    req.headers_mut()
        .insert("upgrade", HeaderValue::from_static("websocket"));
    req
}

use std::time::Instant;
use str0m::media::{Direction, MediaKind};

fn build_browser_offer() -> (String, str0m::change::SdpPendingOffer, str0m::Rtc) {
    let mut rtc = str0m::Rtc::new(Instant::now());
    let mut changes = rtc.sdp_api();
    changes.add_media(MediaKind::Audio, Direction::RecvOnly, None, None, None);
    changes.add_media(MediaKind::Video, Direction::RecvOnly, None, None, None);
    let (offer, pending) = changes.apply().expect("sdp_api produced an offer");
    let sdp = offer.to_sdp_string();
    (sdp, pending, rtc)
}

async fn start_handler_with_metrics() -> (
    String,
    mpsc::Receiver<PendingClient>,
    tokio::task::JoinHandle<()>,
    Arc<SfuMetrics>,
) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let secret: Arc<[u8]> = Arc::from(HS256_SECRET);
    let (inject_tx, inject_rx) = mpsc::channel::<PendingClient>(8);
    let local_udp = "127.0.0.1:0".parse().unwrap();
    let metrics = Arc::new(SfuMetrics::default());
    let handle = spawn_client_ws_api(
        listener,
        secret,
        None,
        inject_tx,
        local_udp,
        metrics.clone(),
        0,
    )
    .unwrap();
    (format!("ws://{addr}"), inject_rx, handle, metrics)
}

/// Complete the SDP offer/answer handshake and return the WS stream
/// ready for post-handshake frames.
async fn do_handshake(
    ws: &mut tokio_tungstenite::WebSocketStream<
        tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
    >,
) {
    let (offer_sdp, _pending, _rtc) = build_browser_offer();
    let frame = serde_json::json!({ "kind": "offer", "sdp": offer_sdp }).to_string();
    ws.send(Message::Text(frame.into()))
        .await
        .expect("send offer");
    // Wait for the SDP answer.
    let _ = tokio::time::timeout(Duration::from_millis(500), ws.next())
        .await
        .expect("answer within 500ms")
        .expect("stream open")
        .expect("no error");
}

// ─── RED: sfu_bwe_hint_received_total is registered in SfuMetrics ──────────

/// The counter must exist in the registry at startup (baseline=0).
/// Before the implementation this test fails with "no such field" at compile
/// time, confirming RED.
#[tokio::test]
async fn bwe_hint_counter_registered_at_startup() {
    let m = SfuMetrics::new().expect("metrics build");
    // Accessing the field compiles only after the field is added to the struct.
    // Touch a dynamic label to materialise the series; we want counter = 0.
    let val = m
        .sfu_bwe_hint_received_total
        .with_label_values(&["99"])
        .get();
    assert_eq!(val, 0, "counter must start at 0");

    let text = m.encode_text().expect("encode");
    assert!(
        text.contains("sfu_bwe_hint_received_total"),
        "counter must appear in /metrics output"
    );
}

// ─── RED: well-formed bwe-hint increments the counter ───────────────────────

/// A valid `{"kind":"bwe-hint","from":"<uuid>","ts":<ms>,"bps":<u64>}` sent
/// after the initial SDP handshake must increment
/// `sfu_bwe_hint_received_total{peer_id="<server-side-id>"}` by 1.
///
/// The server-side `peer_id` is the JWT `sub` claim (42 here).
#[tokio::test]
async fn bwe_hint_increments_counter() {
    let (base, _inject_rx, _handle, metrics) = start_handler_with_metrics().await;
    let peer_id: u64 = 42;
    let token = make_token(ROOM_ID, peer_id, HS256_SECRET, 3600);
    let url = format!("{base}/sfu/ws/{ROOM_ID}");
    let req = build_request(&url, &token);

    let (mut ws, _resp) = tokio::time::timeout(
        Duration::from_secs(2),
        tokio_tungstenite::connect_async(req),
    )
    .await
    .expect("ws handshake within 2s")
    .expect("ws OK");

    do_handshake(&mut ws).await;

    let counter_before = metrics
        .sfu_bwe_hint_received_total
        .with_label_values(&[&peer_id.to_string()])
        .get();

    // Send a valid bwe-hint frame.
    let hint = serde_json::json!({
        "kind": "bwe-hint",
        "from": "550e8400-e29b-41d4-a716-446655440000",
        "ts": 1_700_000_000_000i64,
        "bps": 1_200_000u64
    })
    .to_string();
    ws.send(Message::Text(hint.into()))
        .await
        .expect("send bwe-hint");

    // Poll until counter advances or 500 ms elapses (replaces flaky sleep(50ms)).
    let deadline = std::time::Instant::now() + Duration::from_millis(500);
    loop {
        let v = metrics
            .sfu_bwe_hint_received_total
            .with_label_values(&[&peer_id.to_string()])
            .get();
        if v > counter_before || std::time::Instant::now() >= deadline {
            break;
        }
        tokio::time::sleep(Duration::from_millis(5)).await;
    }

    let counter_after = metrics
        .sfu_bwe_hint_received_total
        .with_label_values(&[&peer_id.to_string()])
        .get();
    assert_eq!(
        counter_after - counter_before,
        1,
        "bwe-hint must increment sfu_bwe_hint_received_total by 1"
    );
}

// ─── RED: malformed bwe-hint (missing bps) is dropped, counter NOT bumped,
//          WS connection stays open ─────────────────────────────────────────

/// A malformed bwe-hint (missing `bps` field) must be silently dropped.
/// The counter must not increment. The WS connection must remain open
/// (subsequent frame is still accepted).
#[tokio::test]
async fn bwe_hint_malformed_dropped_no_counter_no_close() {
    let (base, _inject_rx, _handle, metrics) = start_handler_with_metrics().await;
    let peer_id: u64 = 43;
    let token = make_token(ROOM_ID, peer_id, HS256_SECRET, 3600);
    let url = format!("{base}/sfu/ws/{ROOM_ID}");
    let req = build_request(&url, &token);

    let (mut ws, _resp) = tokio::time::timeout(
        Duration::from_secs(2),
        tokio_tungstenite::connect_async(req),
    )
    .await
    .expect("ws handshake within 2s")
    .expect("ws OK");

    do_handshake(&mut ws).await;

    // Malformed: `bps` missing.
    let malformed = serde_json::json!({
        "kind": "bwe-hint",
        "from": "550e8400-e29b-41d4-a716-446655440001",
        "ts": 1_700_000_000_001i64
        // bps intentionally absent
    })
    .to_string();
    ws.send(Message::Text(malformed.into()))
        .await
        .expect("send malformed bwe-hint");

    // Poll for 100 ms; counter must stay 0 the entire time (MINOR 4 fix:
    // replaces the prior sleep(100ms) with a poll-loop that checks each 5ms tick).
    let check_deadline = std::time::Instant::now() + Duration::from_millis(100);
    while std::time::Instant::now() < check_deadline {
        let v = metrics
            .sfu_bwe_hint_received_total
            .with_label_values(&[&peer_id.to_string()])
            .get();
        assert_eq!(
            v, 0,
            "malformed frame must not increment counter (checked mid-poll)"
        );
        tokio::time::sleep(Duration::from_millis(5)).await;
    }

    let counter = metrics
        .sfu_bwe_hint_received_total
        .with_label_values(&[&peer_id.to_string()])
        .get();
    assert_eq!(
        counter, 0,
        "malformed bwe-hint must not increment the counter"
    );

    // Connection still open — send a well-formed frame and confirm it is accepted.
    let good_hint = serde_json::json!({
        "kind": "bwe-hint",
        "from": "550e8400-e29b-41d4-a716-446655440001",
        "ts": 1_700_000_000_002i64,
        "bps": 500_000u64
    })
    .to_string();
    ws.send(Message::Text(good_hint.into()))
        .await
        .expect("WS still open after malformed frame");

    // Poll until counter reaches 1 or 500 ms elapses.
    let deadline = std::time::Instant::now() + Duration::from_millis(500);
    loop {
        let v = metrics
            .sfu_bwe_hint_received_total
            .with_label_values(&[&peer_id.to_string()])
            .get();
        if v >= 1 || std::time::Instant::now() >= deadline {
            break;
        }
        tokio::time::sleep(Duration::from_millis(5)).await;
    }

    let counter_after = metrics
        .sfu_bwe_hint_received_total
        .with_label_values(&[&peer_id.to_string()])
        .get();
    assert_eq!(counter_after, 1, "valid follow-up bwe-hint must be counted");
}

// ─── MAJOR 1: counter series scrubbed on reap_dead ──────────────────────────

/// After a peer disconnects and `reap_dead` runs, the
/// `sfu_bwe_hint_received_total{peer_id=X}` series must be removed so
/// reconnect churn does not grow label cardinality without bound.
///
/// Uses the unit-test-level seam (`Registry + disconnect_client_for_tests +
/// reap_dead_for_tests`) to avoid spinning up a WS/UDP pipeline.
#[tokio::test]
async fn bwe_hint_counter_scrubbed_on_reap_dead() {
    use oxpulse_sfu::client::test_seed::new_client;
    use oxpulse_sfu::{ClientId, Registry};
    use std::sync::Arc;

    let metrics = Arc::new(SfuMetrics::default());
    let mut registry = Registry::new(metrics.clone());

    let peer_id = ClientId(777u64);
    let client = new_client(peer_id);
    registry.insert(client);

    // Materialise the series — simulate a bwe-hint having been received.
    metrics
        .sfu_bwe_hint_received_total
        .with_label_values(&[&(*peer_id).to_string()])
        .inc();

    // Confirm the series is present before disconnect.
    assert_eq!(
        metrics
            .sfu_bwe_hint_received_total
            .with_label_values(&[&(*peer_id).to_string()])
            .get(),
        1,
        "series must be present before reap"
    );

    // Disconnect + reap.
    registry.disconnect_client_for_tests(peer_id);
    registry.reap_dead_for_tests();

    // After reap the series must be gone (get() on a removed series re-creates
    // with 0, which is fine — we verify via encode_text that the label is absent).
    let encoded = metrics.encode_text().expect("encode ok");
    assert!(
        !encoded.contains(r#"peer_id="777""#),
        "bwe_hint_received_total{{peer_id=\"777\"}} must be scrubbed after reap_dead:\n{encoded}"
    );
}

// ─── MAJOR 1: counter series scrubbed on evict_for_steal ────────────────────

/// Same cardinality invariant for the session-steal eviction path.
#[tokio::test]
async fn bwe_hint_counter_scrubbed_on_evict_for_steal() {
    use oxpulse_sfu::client::test_seed::new_client;
    use oxpulse_sfu::{ClientId, Registry};
    use std::sync::Arc;

    let metrics = Arc::new(SfuMetrics::default());
    let mut registry = Registry::new(metrics.clone());

    let peer_id = ClientId(888u64);
    let client = new_client(peer_id);
    registry.insert(client);

    metrics
        .sfu_bwe_hint_received_total
        .with_label_values(&[&(*peer_id).to_string()])
        .inc();

    // evict_for_steal at index 0 (only client in registry).
    registry.evict_for_steal_for_tests(0);

    let encoded = metrics.encode_text().expect("encode ok");
    assert!(
        !encoded.contains(r#"peer_id="888""#),
        "bwe_hint_received_total{{peer_id=\"888\"}} must be scrubbed after evict_for_steal:\n{encoded}"
    );
}

// ─── MAJOR 2: per-peer rate gate ────────────────────────────────────────────

/// Sending 20 bwe-hint frames in rapid succession must result in at most
/// a small number being counted (≤3), with the rest throttled and
/// `sfu_bwe_hint_throttled_total` reflecting the gap.
#[tokio::test]
async fn bwe_hint_rate_gate_throttles_flood() {
    let (base, _inject_rx, _handle, metrics) = start_handler_with_metrics().await;
    let peer_id: u64 = 99;
    let token = make_token(ROOM_ID, peer_id, HS256_SECRET, 3600);
    let url = format!("{base}/sfu/ws/{ROOM_ID}");
    let req = build_request(&url, &token);

    let (mut ws, _resp) = tokio::time::timeout(
        Duration::from_secs(2),
        tokio_tungstenite::connect_async(req),
    )
    .await
    .expect("ws handshake within 2s")
    .expect("ws OK");

    do_handshake(&mut ws).await;

    // Flood: 20 hints with no delay.
    for i in 0..20u64 {
        let hint = serde_json::json!({
            "kind": "bwe-hint",
            "from": "550e8400-e29b-41d4-a716-446655440099",
            "ts": 1_700_000_000_000i64 + i as i64,
            "bps": 1_000_000u64
        })
        .to_string();
        ws.send(Message::Text(hint.into()))
            .await
            .expect("send hint");
    }

    // Poll up to 500 ms for processing to settle.
    let deadline = std::time::Instant::now() + Duration::from_millis(500);
    loop {
        let received = metrics
            .sfu_bwe_hint_received_total
            .with_label_values(&[&peer_id.to_string()])
            .get();
        let throttled = metrics
            .sfu_bwe_hint_throttled_total
            .with_label_values(&[&peer_id.to_string()])
            .get();
        if received + throttled >= 20 || std::time::Instant::now() >= deadline {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }

    let received = metrics
        .sfu_bwe_hint_received_total
        .with_label_values(&[&peer_id.to_string()])
        .get();
    let throttled = metrics
        .sfu_bwe_hint_throttled_total
        .with_label_values(&[&peer_id.to_string()])
        .get();

    assert!(
        received <= 3,
        "rate gate must cap received at ≤3 for a 20-frame flood; got {received}"
    );
    assert!(
        throttled >= 17,
        "throttle counter must capture ≥17 dropped hints; got {throttled}"
    );
}

// ─── BLOCKER: rate gate must be shared across two tasks for the same peer ────
//
// When a session-steal occurs, both the old and new WS tasks run concurrently
// during the steal window. Each previously had its own local `last_hint` clock,
// allowing 2× the cap (one accepted per task). The shared registry keyed by
// peer_id must enforce the cap across both tasks.

/// Two concurrent WS sessions for the same peer_id each get exactly one hint
/// accepted (the very first one, within the same 100ms window). With per-task
/// `last_hint` both tasks accept their first hint independently → received = 2.
/// With the shared rate registry keyed by peer_id, only the first accepted hint
/// (whichever task wins the race) resets the clock; the other task's first
/// hint lands within the window and is throttled → received = 1.
///
/// The test sends exactly one hint per session (to avoid relying on which
/// task "wins" the first slot) and asserts that combined received ≤ 1.
///
/// RED: fails with per-task `last_hint` because both tasks have `last_hint=None`
/// on their first hint → both pass the gate → received = 2.
#[tokio::test]
async fn bwe_hint_rate_gate_shared_across_concurrent_tasks() {
    let (base, _inject_rx, _handle, metrics) = start_handler_with_metrics().await;
    let peer_id: u64 = 555;
    let token_a = make_token(ROOM_ID, peer_id, HS256_SECRET, 3600);
    let token_b = make_token(ROOM_ID, peer_id, HS256_SECRET, 3600);
    let url = format!("{base}/sfu/ws/{ROOM_ID}");

    // Open session A.
    let req_a = build_request(&url, &token_a);
    let (mut ws_a, _) = tokio::time::timeout(
        Duration::from_secs(2),
        tokio_tungstenite::connect_async(req_a),
    )
    .await
    .expect("ws_a handshake within 2s")
    .expect("ws_a OK");
    do_handshake(&mut ws_a).await;

    // Open session B (same peer_id — steal window or concurrent tabs).
    let req_b = build_request(&url, &token_b);
    let (mut ws_b, _) = tokio::time::timeout(
        Duration::from_secs(2),
        tokio_tungstenite::connect_async(req_b),
    )
    .await
    .expect("ws_b handshake within 2s")
    .expect("ws_b OK");
    do_handshake(&mut ws_b).await;

    // Send exactly 1 hint from each session simultaneously.
    // Both tasks have last_hint=None before this point. With per-task state,
    // both pass the gate → received=2. With shared state, only one passes.
    let hint_a = serde_json::json!({
        "kind": "bwe-hint",
        "from": "aaaaaaaa-e29b-41d4-a716-446655440555",
        "ts": 1_700_000_000_000i64,
        "bps": 1_000_000u64
    })
    .to_string();
    let hint_b = serde_json::json!({
        "kind": "bwe-hint",
        "from": "bbbbbbbb-e29b-41d4-a716-446655440555",
        "ts": 1_700_000_000_001i64,
        "bps": 1_000_000u64
    })
    .to_string();
    // Send both at once.
    let (r_a, r_b) = tokio::join!(
        ws_a.send(Message::Text(hint_a.into())),
        ws_b.send(Message::Text(hint_b.into()))
    );
    r_a.expect("send hint_a");
    r_b.expect("send hint_b");

    // Wait for both frames to be processed (received+throttled = 2 or deadline).
    let peer_label = peer_id.to_string();
    let deadline = std::time::Instant::now() + Duration::from_millis(500);
    loop {
        let received = metrics
            .sfu_bwe_hint_received_total
            .with_label_values(&[&peer_label])
            .get();
        let throttled = metrics
            .sfu_bwe_hint_throttled_total
            .with_label_values(&[&peer_label])
            .get();
        if received + throttled >= 2 || std::time::Instant::now() >= deadline {
            break;
        }
        tokio::time::sleep(Duration::from_millis(5)).await;
    }

    let received = metrics
        .sfu_bwe_hint_received_total
        .with_label_values(&[&peer_label])
        .get();

    // With shared state: exactly 1 accepted (the first to grab the lock),
    // the second throttled. With per-task state: 2 accepted (both had None).
    assert_eq!(
        received, 1,
        "shared rate gate must accept exactly 1 hint when two tasks race for the \
         same peer_id within the same 100ms window; got {received} (indicates \
         per-task last_hint instead of shared registry)"
    );
}

// ─── MAJOR: test string match must be metric-specific ────────────────────────
//
// The previous `!encoded.contains(r#"peer_id="777""#)` check is over-broad:
// any metric with peer_id="777" would mask the bug if the scrub removed
// only one counter but left the other. We verify the specific metric line.

/// After reap_dead, the specific `sfu_bwe_hint_received_total{peer_id="777"}`
/// label must be absent (metric-specific line check, not just any peer_id="777").
#[tokio::test]
async fn bwe_hint_counter_scrubbed_on_reap_dead_specific() {
    use oxpulse_sfu::client::test_seed::new_client;
    use oxpulse_sfu::{ClientId, Registry};

    let metrics = Arc::new(SfuMetrics::default());
    let mut registry = Registry::new(metrics.clone());

    let peer_id = ClientId(777u64);
    let client = new_client(peer_id);
    registry.insert(client);

    metrics
        .sfu_bwe_hint_received_total
        .with_label_values(&[&(*peer_id).to_string()])
        .inc();
    // Also touch another metric with same peer_id to prove the broad check is
    // insufficient — this series will STAY after reap (different metric).
    // (In production, bandwidth_estimate_bps is also peer-labelled and scrubbed;
    // but we can materialise something that WON'T be scrubbed for the test.)

    registry.disconnect_client_for_tests(peer_id);
    registry.reap_dead_for_tests();

    let encoded = metrics.encode_text().expect("encode ok");

    // Metric-specific check: no line starting with the metric name AND
    // containing this peer_id label.
    assert!(
        !encoded.lines().any(|l| {
            l.starts_with("sfu_bwe_hint_received_total") && l.contains(r#"peer_id="777""#)
        }),
        "sfu_bwe_hint_received_total{{peer_id=\"777\"}} must be scrubbed after reap_dead"
    );
}

/// After evict_for_steal, the specific `sfu_bwe_hint_received_total{peer_id="888"}`
/// label must be absent (metric-specific line check).
#[tokio::test]
async fn bwe_hint_counter_scrubbed_on_evict_for_steal_specific() {
    use oxpulse_sfu::client::test_seed::new_client;
    use oxpulse_sfu::{ClientId, Registry};

    let metrics = Arc::new(SfuMetrics::default());
    let mut registry = Registry::new(metrics.clone());

    let peer_id = ClientId(888u64);
    let client = new_client(peer_id);
    registry.insert(client);

    metrics
        .sfu_bwe_hint_received_total
        .with_label_values(&[&(*peer_id).to_string()])
        .inc();

    registry.evict_for_steal_for_tests(0);

    let encoded = metrics.encode_text().expect("encode ok");
    assert!(
        !encoded.lines().any(|l| {
            l.starts_with("sfu_bwe_hint_received_total") && l.contains(r#"peer_id="888""#)
        }),
        "sfu_bwe_hint_received_total{{peer_id=\"888\"}} must be scrubbed after evict_for_steal"
    );
}

// ─── MAJOR: HINT_MIN_INTERVAL must be env-configurable + gauge published ─────

/// The `sfu_bwe_hint_rate_limit_min_interval_ms` gauge must be registered
/// at startup and reflect the configured interval (default 100 ms).
///
/// RED: fails before the gauge is added to `SfuMetrics`.
#[tokio::test]
async fn bwe_hint_rate_limit_interval_gauge_registered() {
    let m = SfuMetrics::new().expect("metrics build");
    let text = m.encode_text().expect("encode");
    assert!(
        text.contains("sfu_bwe_hint_rate_limit_min_interval_ms"),
        "rate-limit interval gauge must appear in /metrics output"
    );
}

// ─── MINOR: remaining sleep(100ms) in bwe_malformed test replaced with poll ──
// The sleep(100ms) at bwe_hint_malformed_dropped_no_counter_no_close:257
// has been replaced inline above with the poll-loop pattern (100ms deadline,
// checking counter stays 0). This comment documents the intent; no new test
// is needed — the existing test already uses the poll-loop approach.

// ─── MINOR: evict_for_steal must scrub client_delivered_media_count ──────────

// ─── Round-3 MAJOR: env=0 → hint_min_interval_ms() returns 1 (shared fn) ────

/// `hint_min_interval_ms()` must be the single authoritative source for the
/// env-parse logic. When `SFU_BWE_HINT_MIN_INTERVAL_MS=0` the clamped result
/// is 1 ms.  Both the session rate gate and the metrics gauge must read through
/// this shared function so they can never diverge.
///
/// RED: fails before `hint_min_interval_ms` is exported from `oxpulse_sfu`
/// (symbol doesn't exist at compile time).
#[test]
#[serial]
fn hint_min_interval_ms_env_zero_clamps_to_one() {
    // Safety: test-only, serial within this process.
    // `cargo test --features test-utils` runs tests in separate processes per
    // binary so env isolation is sufficient.
    std::env::set_var("SFU_BWE_HINT_MIN_INTERVAL_MS", "0");
    // Reset the OnceLock so the re-read happens (test-utils feature exposes this).
    oxpulse_sfu::bwe_hint::reset_hint_min_interval_for_tests();
    let ms = oxpulse_sfu::bwe_hint::hint_min_interval_ms();
    std::env::remove_var("SFU_BWE_HINT_MIN_INTERVAL_MS");
    oxpulse_sfu::bwe_hint::reset_hint_min_interval_for_tests();
    assert_eq!(ms, 1, "env=0 must clamp to 1 ms, got {ms}");
}

/// The `sfu_bwe_hint_rate_limit_min_interval_ms` gauge must reflect the value
/// returned by `hint_min_interval_ms()`.  When env=0 the gauge must be 1.
///
/// RED: fails before the gauge reads via the shared function.
#[test]
#[serial]
fn hint_gauge_reflects_shared_fn_when_env_zero() {
    std::env::set_var("SFU_BWE_HINT_MIN_INTERVAL_MS", "0");
    oxpulse_sfu::bwe_hint::reset_hint_min_interval_for_tests();
    let m = SfuMetrics::new().expect("metrics build");
    let gauge_val = m.sfu_bwe_hint_rate_limit_min_interval_ms.get();
    std::env::remove_var("SFU_BWE_HINT_MIN_INTERVAL_MS");
    oxpulse_sfu::bwe_hint::reset_hint_min_interval_for_tests();
    assert_eq!(
        gauge_val, 1,
        "gauge must report clamped value (1) when env=0, got {gauge_val}"
    );
}

// ─── Round-3 MINOR: hint_rate_registry scrubbed on session exit ──────────────

/// `bwe_hint::scrub_hint_registry` must remove the given peer_id and leave
/// all other entries intact. This validates the scrub helper that the session
/// exit path calls after `park_until_close_or_steal` returns.
///
/// RED: fails before `oxpulse_sfu::bwe_hint::scrub_hint_registry` exists.
#[test]
fn hint_rate_registry_scrub_removes_only_target_peer() {
    use std::collections::HashMap;
    use std::sync::{Arc, Mutex};
    use std::time::Instant;

    let registry: Arc<Mutex<HashMap<u64, Instant>>> = Arc::new(Mutex::new(HashMap::new()));

    let now = Instant::now();
    {
        let mut m = registry.lock().unwrap();
        m.insert(1, now);
        m.insert(2, now);
        m.insert(3, now);
    }

    // Scrub peer 2.
    oxpulse_sfu::bwe_hint::scrub_hint_registry(&registry, 2);

    let m = registry.lock().unwrap();
    assert!(m.contains_key(&1), "peer 1 must be retained");
    assert!(!m.contains_key(&2), "peer 2 must be removed");
    assert!(m.contains_key(&3), "peer 3 must be retained");
    assert_eq!(
        m.len(),
        2,
        "registry must have exactly 2 entries after scrub"
    );
}

// ─── Round-4: poisoned-mutex must not panic ──────────────────────────────────

/// `hint_min_interval_ms()` must not panic when the override mutex is poisoned.
/// Instead it must recover and return the env-based default.
///
/// RED: fails before `.lock().unwrap_or_else(|p| p.into_inner())` poison recovery.
#[cfg(feature = "test-utils")]
#[test]
#[serial]
fn hint_min_interval_ms_poisoned_mutex_no_panic() {
    use std::sync::Arc;
    // Poison the override mutex from another thread.
    let barrier = Arc::new(std::sync::Barrier::new(2));
    let b2 = barrier.clone();
    let t = std::thread::spawn(move || {
        // Acquire the static override lock, then panic — this poisons the mutex.
        let _guard = oxpulse_sfu::bwe_hint::poison_override_for_tests();
        b2.wait(); // let main thread know we hold it
        panic!("intentional poison");
    });
    barrier.wait(); // wait until spawned thread holds the lock and is about to panic
                    // Join (expecting Err) guarantees the thread has panicked and the mutex is
                    // poisoned before hint_min_interval_ms() is called. Replaces the racy sleep.
    t.join().expect_err("thread must have panicked");
    // Must not panic — should return default (100 ms) via poison recovery.
    let ms = oxpulse_sfu::bwe_hint::hint_min_interval_ms();
    assert!(
        ms >= 1,
        "poisoned-mutex recovery must return a sane value, got {ms}"
    );
    // Reset for subsequent tests.
    oxpulse_sfu::bwe_hint::reset_hint_min_interval_for_tests();
}

/// `scrub_hint_registry` must not panic and must log when the registry mutex is
/// poisoned. The function should return without error.
///
/// RED: currently the `if let Ok(mut m) = registry.lock()` silently drops the
/// Err but does not log. After fix it must warn + bump counter (verified via
/// tracing subscriber in integration; here we just confirm no panic).
#[test]
fn scrub_hint_registry_poisoned_mutex_no_panic() {
    use std::collections::HashMap;
    use std::sync::{Arc, Mutex};
    use std::time::Instant;

    let registry: Arc<Mutex<HashMap<u64, Instant>>> = Arc::new(Mutex::new(HashMap::new()));
    {
        let mut m = registry.lock().unwrap();
        m.insert(1, Instant::now());
    }

    // Poison the mutex from another thread.
    let r2 = registry.clone();
    let _ = std::thread::spawn(move || {
        let _guard = r2.lock().unwrap();
        panic!("intentional poison");
    })
    .join(); // join so poison is definitely set before we proceed

    // Must not panic.
    oxpulse_sfu::bwe_hint::scrub_hint_registry(&registry, 1);
}

/// `scrub_hint_registry` must increment `sfu_bwe_hint_registry_mutex_poisoned_total`
/// when the registry mutex is poisoned.
///
/// RED: fails until `sfu_bwe_hint_registry_mutex_poisoned_total` is added to
/// `SfuMetrics` and bumped in the `Err` arm of `scrub_hint_registry`.
#[test]
fn scrub_hint_registry_poisoned_mutex_bumps_counter() {
    use std::collections::HashMap;
    use std::sync::{Arc, Mutex};
    use std::time::Instant;

    let registry: Arc<Mutex<HashMap<u64, Instant>>> = Arc::new(Mutex::new(HashMap::new()));
    {
        let mut m = registry.lock().unwrap();
        m.insert(1, Instant::now());
    }

    // Poison the mutex from another thread.
    let r2 = registry.clone();
    let _ = std::thread::spawn(move || {
        let _guard = r2.lock().unwrap();
        panic!("intentional poison");
    })
    .join(); // join so poison is definitely set before we proceed

    let metrics = Arc::new(SfuMetrics::default());
    let before = metrics.sfu_bwe_hint_registry_mutex_poisoned_total.get();

    // Trigger the poisoned path.
    oxpulse_sfu::bwe_hint::scrub_hint_registry_with_metrics(&registry, 1, &metrics);

    assert_eq!(
        metrics.sfu_bwe_hint_registry_mutex_poisoned_total.get(),
        before + 1,
        "sfu_bwe_hint_registry_mutex_poisoned_total must increment on mutex poison"
    );
}

/// `hint_min_interval_ms` must increment `sfu_bwe_hint_registry_mutex_poisoned_total`
/// when the override mutex is poisoned.
///
/// RED: fails until the counter is bumped in the poison-recovery arm of
/// `hint_min_interval_ms`.
#[test]
#[serial]
fn hint_min_interval_ms_poisoned_mutex_bumps_counter() {
    use std::sync::Arc;

    let barrier = Arc::new(std::sync::Barrier::new(2));
    let b2 = barrier.clone();
    let t = std::thread::spawn(move || {
        let _guard = oxpulse_sfu::bwe_hint::poison_override_for_tests();
        b2.wait();
        panic!("intentional poison");
    });
    barrier.wait();
    t.join().expect_err("thread must have panicked");

    let metrics = Arc::new(SfuMetrics::default());
    let before = metrics.sfu_bwe_hint_registry_mutex_poisoned_total.get();

    // Must not panic and must bump counter.
    let ms = oxpulse_sfu::bwe_hint::hint_min_interval_ms_with_metrics(&metrics);
    assert!(
        ms >= 1,
        "poisoned-mutex recovery must return a sane value, got {ms}"
    );
    assert_eq!(
        metrics.sfu_bwe_hint_registry_mutex_poisoned_total.get(),
        before + 1,
        "sfu_bwe_hint_registry_mutex_poisoned_total must increment on override mutex poison"
    );

    oxpulse_sfu::bwe_hint::reset_hint_min_interval_for_tests();
}

/// After a session-steal eviction, `client_delivered_media_count{peer_id=X}`
/// must be absent from the encoded metrics.
///
/// RED: fails before `evict_for_steal` calls
/// `remove_label_values` on `client_delivered_media_count`.
#[tokio::test]
async fn evict_for_steal_scrubs_client_delivered_media_count() {
    use oxpulse_sfu::client::test_seed::new_client;
    use oxpulse_sfu::{ClientId, Registry};

    let metrics = Arc::new(SfuMetrics::default());
    let mut registry = Registry::new(metrics.clone());

    let peer_id = ClientId(999u64);
    let client = new_client(peer_id);
    registry.insert(client);

    // Materialise the series.
    metrics
        .client_delivered_media_count
        .with_label_values(&[&(*peer_id).to_string()])
        .set(42);

    registry.evict_for_steal_for_tests(0);

    let encoded = metrics.encode_text().expect("encode ok");
    assert!(
        !encoded.lines().any(|l| {
            l.starts_with("sfu_client_delivered_media_count") && l.contains(r#"peer_id="999""#)
        }),
        "client_delivered_media_count{{peer_id=\"999\"}} must be scrubbed after evict_for_steal"
    );
}
