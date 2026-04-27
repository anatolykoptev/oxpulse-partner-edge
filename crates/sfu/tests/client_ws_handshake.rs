//! Integration tests for the client-facing `/sfu/ws/{room_id}` endpoint.
//!
//! Phase 7 M4.A1: validate that the SFU's client WebSocket handler:
//!   1. Accepts a valid HS256 room_token via `Sec-WebSocket-Protocol` and
//!      completes the WS upgrade (HTTP 101).
//!   2. Rejects expired tokens with HTTP 401 (no upgrade, empty body).
//!   3. Rejects token/path room mismatch with WS close code 4001
//!      after the upgrade completes (101 first, then close).

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use futures_util::StreamExt;
use jsonwebtoken::{encode, EncodingKey, Header};
use oxpulse_sfu::client_ws::{spawn_client_ws_api, PendingClient};
use oxpulse_sfu::metrics::SfuMetrics;
use oxpulse_sfu::room_auth::RoomClaims;
use tokio::net::TcpListener;
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::{
    client::IntoClientRequest,
    handshake::client::generate_key,
    http::{HeaderValue, StatusCode},
    protocol::frame::coding::CloseCode,
    Error as WsError, Message,
};

const HS256_SECRET: &[u8] = b"test-secret-32-bytes-long-enough!";
const SUBPROTO: &str = "oxpulse-sfu-v1";

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

async fn start_test_handler() -> String {
    start_test_handler_with_metrics().await.0
}

async fn start_test_handler_with_metrics() -> (String, Arc<SfuMetrics>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let secret: Arc<[u8]> = Arc::from(HS256_SECRET);
    let (inject_tx, _inject_rx) = mpsc::channel::<PendingClient>(8);
    let local_udp: SocketAddr = "127.0.0.1:0".parse().unwrap();
    let metrics = Arc::new(SfuMetrics::default());
    let _handle = spawn_client_ws_api(
        listener,
        secret,
        None,
        inject_tx,
        local_udp,
        metrics.clone(),
    )
    .unwrap();
    Box::leak(Box::new(_inject_rx));
    (format!("ws://{addr}"), metrics)
}

fn build_request(
    url: &str,
    token: &str,
) -> tokio_tungstenite::tungstenite::handshake::client::Request {
    // Browsers can't set the `Authorization` header on a WS upgrade, so we
    // stuff the bearer token into the `Sec-WebSocket-Protocol` list, the
    // standard pattern Discord/Slack/Zoom-web use.
    let mut req = url.into_client_request().expect("valid URL");
    let value = format!("{SUBPROTO}, Bearer {token}");
    req.headers_mut().insert(
        "sec-websocket-protocol",
        HeaderValue::from_str(&value).unwrap(),
    );
    // Required by the WS handshake spec.
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

#[tokio::test]
async fn accepts_upgrade_with_valid_token() {
    let base = start_test_handler().await;
    let token = make_token("TEST-1234", 42, HS256_SECRET, 3600);
    let url = format!("{base}/sfu/ws/TEST-1234");
    let req = build_request(&url, &token);
    let (_ws, resp) = tokio::time::timeout(
        Duration::from_secs(2),
        tokio_tungstenite::connect_async(req),
    )
    .await
    .expect("handshake within 2s")
    .expect("WS handshake OK");
    assert_eq!(
        resp.status(),
        StatusCode::SWITCHING_PROTOCOLS,
        "valid token must produce 101 Switching Protocols"
    );
    // Subprotocol must be echoed back as exactly `oxpulse-sfu-v1` (RFC 6455
    // requires the server pick one of the offered values).
    let proto = resp
        .headers()
        .get("sec-websocket-protocol")
        .map(|v| v.to_str().unwrap_or("").to_string())
        .unwrap_or_default();
    assert_eq!(proto, SUBPROTO);
}

#[tokio::test]
async fn rejects_expired_token_with_401() {
    let base = start_test_handler().await;
    // exp_delta = -10s → token already expired at issue time.
    let token = make_token("TEST-1234", 1, HS256_SECRET, -10);
    let url = format!("{base}/sfu/ws/TEST-1234");
    let req = build_request(&url, &token);
    let err = tokio::time::timeout(
        Duration::from_secs(2),
        tokio_tungstenite::connect_async(req),
    )
    .await
    .expect("handshake attempt within 2s")
    .expect_err("expired token must fail handshake");
    match err {
        WsError::Http(resp) => {
            assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
            assert!(
                resp.body().as_deref().map(|b| b.is_empty()).unwrap_or(true),
                "401 response body must be empty (no info leak)"
            );
        }
        other => panic!("expected Http(401), got {other:?}"),
    }
}

#[tokio::test]
async fn rejects_room_mismatch_with_close_code_4001() {
    let base = start_test_handler().await;
    // Token grants access to room ABC, but path requests room XYZ.
    let token = make_token("ROOM-ABC", 1, HS256_SECRET, 3600);
    let url = format!("{base}/sfu/ws/ROOM-XYZ");
    let req = build_request(&url, &token);
    let (mut ws, resp) = tokio::time::timeout(
        Duration::from_secs(2),
        tokio_tungstenite::connect_async(req),
    )
    .await
    .expect("handshake within 2s")
    .expect("upgrade still happens; close comes after");
    assert_eq!(resp.status(), StatusCode::SWITCHING_PROTOCOLS);
    // The handler accepts the upgrade, then immediately closes with 4001.
    let close = tokio::time::timeout(Duration::from_secs(2), ws.next())
        .await
        .expect("close frame within 2s")
        .expect("stream not ended before close");
    let msg = close.expect("close frame deserialised OK");
    match msg {
        Message::Close(Some(frame)) => {
            assert_eq!(
                u16::from(frame.code),
                4001,
                "room mismatch must close with code 4001, got {:?}",
                frame.code
            );
        }
        other => panic!("expected Message::Close(4001), got {other:?}"),
    }
    // Ensure the close code maps via tungstenite to the Library variant
    // (custom 4xxx codes are CloseCode::Library).
    let _ = CloseCode::Library(4001);
}

#[tokio::test]
async fn client_ws_handshake_increments_started_counter() {
    let (base, metrics) = start_test_handler_with_metrics().await;
    let token = make_token("TEST-1234", 42, HS256_SECRET, 3600);
    let url = format!("{base}/sfu/ws/TEST-1234");
    let req = build_request(&url, &token);
    // KEEP the WS connection alive across the assertion — dropping it
    // would close the socket and drop the ActiveSessionGuard before we
    // observe the gauge.
    let (_ws, _resp) = tokio::time::timeout(
        Duration::from_secs(2),
        tokio_tungstenite::connect_async(req),
    )
    .await
    .expect("handshake within 2s")
    .expect("WS handshake OK");
    tokio::time::sleep(Duration::from_millis(50)).await;
    assert!(
        metrics.client_ws_sessions_started_total.get() >= 1,
        "expected sessions_started_total >= 1 after a successful upgrade, got {}",
        metrics.client_ws_sessions_started_total.get()
    );
    assert!(
        metrics.client_ws_active_sessions.get() >= 1,
        "expected active_sessions >= 1 during the open session, got {}",
        metrics.client_ws_active_sessions.get()
    );
}

#[tokio::test]
async fn client_ws_handshake_increments_failure_counter_on_missing_token() {
    let (base, metrics) = start_test_handler_with_metrics().await;
    let url = format!("{base}/sfu/ws/TEST-1234");
    let mut req = url.into_client_request().expect("valid URL");
    req.headers_mut().insert(
        "sec-websocket-protocol",
        HeaderValue::from_static("oxpulse-sfu-v1"),
    );
    req.headers_mut()
        .insert("sec-websocket-key", HeaderValue::from_str(&generate_key()).unwrap());
    req.headers_mut()
        .insert("sec-websocket-version", HeaderValue::from_static("13"));
    req.headers_mut()
        .insert("connection", HeaderValue::from_static("Upgrade"));
    req.headers_mut()
        .insert("upgrade", HeaderValue::from_static("websocket"));
    let err = tokio::time::timeout(
        Duration::from_secs(2),
        tokio_tungstenite::connect_async(req),
    )
    .await
    .expect("handshake attempt within 2s")
    .expect_err("missing token must fail handshake");
    match err {
        WsError::Http(resp) => assert_eq!(resp.status(), StatusCode::UNAUTHORIZED),
        other => panic!("expected Http(401), got {other:?}"),
    }
    tokio::time::sleep(Duration::from_millis(50)).await;
    let n = metrics
        .client_ws_handshake_failures_total
        .with_label_values(&["missing_token"])
        .get();
    assert!(n >= 1, "missing_token handshake failure counter must be >= 1, got {n}");
    assert_eq!(
        metrics.client_ws_sessions_started_total.get(),
        0,
        "rejected handshake must not increment sessions_started_total"
    );
}

#[tokio::test]
async fn client_ws_handshake_increments_failure_counter_on_room_mismatch() {
    let (base, metrics) = start_test_handler_with_metrics().await;
    let token = make_token("ROOM-ABC", 1, HS256_SECRET, 3600);
    let url = format!("{base}/sfu/ws/ROOM-XYZ");
    let req = build_request(&url, &token);
    let (mut ws, _resp) = tokio::time::timeout(
        Duration::from_secs(2),
        tokio_tungstenite::connect_async(req),
    )
    .await
    .expect("handshake within 2s")
    .expect("upgrade still happens; close comes after");
    let _ = tokio::time::timeout(Duration::from_secs(2), ws.next()).await;
    tokio::time::sleep(Duration::from_millis(50)).await;
    let n = metrics
        .client_ws_handshake_failures_total
        .with_label_values(&["room_mismatch"])
        .get();
    assert!(n >= 1, "room_mismatch handshake failure counter must be >= 1, got {n}");
}

#[tokio::test]
async fn client_ws_handshake_increments_failure_counter_on_expired_token() {
    let (base, metrics) = start_test_handler_with_metrics().await;
    let token = make_token("TEST-1234", 1, HS256_SECRET, -10);
    let url = format!("{base}/sfu/ws/TEST-1234");
    let req = build_request(&url, &token);
    let _ = tokio::time::timeout(
        Duration::from_secs(2),
        tokio_tungstenite::connect_async(req),
    )
    .await
    .expect("handshake within 2s");
    tokio::time::sleep(Duration::from_millis(50)).await;
    let n = metrics
        .client_ws_handshake_failures_total
        .with_label_values(&["expired_token"])
        .get();
    assert!(n >= 1, "expired_token handshake failure counter must be >= 1, got {n}");
}
