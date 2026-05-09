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

    // Brief poll — counter must stay 0 for 100 ms before we check.
    tokio::time::sleep(Duration::from_millis(100)).await;

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

// MINOR 4: existing sleep(50ms) calls replaced with inline poll-loops above.
