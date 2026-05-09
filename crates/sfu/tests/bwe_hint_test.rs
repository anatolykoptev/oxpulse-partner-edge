//! Integration tests for `{"kind":"bwe-hint","from":"...","ts":...,"bps":...}`.
//!
//! Phase 2c — observability-only: the message is parsed, logged, and counted.
//! No SVC layer switching in v1.

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

    // Give the server a moment to process the frame.
    tokio::time::sleep(Duration::from_millis(50)).await;

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

    tokio::time::sleep(Duration::from_millis(50)).await;

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

    tokio::time::sleep(Duration::from_millis(50)).await;

    let counter_after = metrics
        .sfu_bwe_hint_received_total
        .with_label_values(&[&peer_id.to_string()])
        .get();
    assert_eq!(counter_after, 1, "valid follow-up bwe-hint must be counted");
}
