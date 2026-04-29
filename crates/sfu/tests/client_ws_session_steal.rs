//! Integration tests for SFU session-steal — Phase A Task A1.
//!
//! Live-debugged 2026-04-28: peer_id=2 in room MTBX-6732 opened TWO
//! `/sfu/ws` upgrades 144 ms apart. The SFU's `Registry::insert`
//! accepted both silently. The second one timed out at 15s with
//! `bad offer` (close 4002), and the client's `onError` callback
//! poisoned the primary session's UI state.
//!
//! Defense: when a duplicate upgrade arrives for an already-registered
//! `(room_id, peer_id)`, the older session is signaled to close with
//! WS code 4031 (session replaced), evicted from the registry, and
//! the newer session adopts the slot. This is the canonical
//! idempotent-sign-in pattern (Discord, Daily, Zoom).

use std::sync::Arc;
use std::time::{Duration, Instant};

use futures_util::{SinkExt, StreamExt};
use jsonwebtoken::{encode, EncodingKey, Header};
use oxpulse_sfu::client_ws::{spawn_client_ws_api, PendingClient};
use oxpulse_sfu::metrics::SfuMetrics;
use oxpulse_sfu::room_auth::RoomClaims;
use serde_json::Value;
use str0m::media::{Direction, MediaKind};
use tokio::net::TcpListener;
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::{
    client::IntoClientRequest, handshake::client::generate_key, http::HeaderValue, Message,
};

const HS256_SECRET: &[u8] = b"test-secret-32-bytes-long-enough!";
const SUBPROTO: &str = "oxpulse-sfu-v1";
const ROOM_ID: &str = "STEAL-TEST";

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

fn build_browser_offer() -> (String, str0m::change::SdpPendingOffer, str0m::Rtc) {
    let mut rtc = str0m::Rtc::new(Instant::now());
    let mut changes = rtc.sdp_api();
    changes.add_media(MediaKind::Audio, Direction::RecvOnly, None, None, None);
    changes.add_media(MediaKind::Video, Direction::RecvOnly, None, None, None);
    let (offer, pending) = changes.apply().expect("sdp_api produced an offer");
    let sdp = offer.to_sdp_string();
    (sdp, pending, rtc)
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

/// Spin up the WS handler + UDP serve loop end-to-end so that
/// `Registry::insert` actually fires when a `PendingClient` is queued.
/// Returns the WS base URL, the SfuMetrics handle, and a shutdown
/// signal sender + the serve task's JoinHandle.
async fn start_full_pipeline() -> (
    String,
    Arc<SfuMetrics>,
    tokio::sync::oneshot::Sender<()>,
    tokio::task::JoinHandle<anyhow::Result<()>>,
) {
    use oxpulse_sfu::config::SfuConfig;
    use oxpulse_sfu::udp_loop;

    let cfg = SfuConfig {
        udp_port: 0,
        bind_address: "127.0.0.1".to_string(),
        ..SfuConfig::default()
    };
    let socket = udp_loop::bind(&cfg).await.unwrap();
    let local_udp = socket.local_addr().unwrap();

    let metrics = Arc::new(SfuMetrics::default());
    let (relay_tx, relay_rx) = mpsc::channel::<oxpulse_sfu::relay::client::PendingRelay>(1);
    drop(relay_tx);
    let (client_inject_tx, client_inject_rx) = mpsc::channel::<PendingClient>(8);

    let ws_listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let ws_addr = ws_listener.local_addr().unwrap();
    let secret: Arc<[u8]> = Arc::from(HS256_SECRET);
    let _ws_handle = spawn_client_ws_api(
        ws_listener,
        secret,
        None,
        client_inject_tx.clone(),
        local_udp,
        metrics.clone(),
    )
    .unwrap();
    drop(client_inject_tx);

    let (shutdown_tx, shutdown_rx) = tokio::sync::oneshot::channel::<()>();
    let serve_handle = tokio::spawn(udp_loop::serve(
        socket,
        metrics.clone(),
        None,
        None,
        relay_rx,
        client_inject_rx,
        async {
            let _ = shutdown_rx.await;
        },
    ));

    (
        format!("ws://{ws_addr}"),
        metrics,
        shutdown_tx,
        serve_handle,
    )
}

/// Drive an offer/answer over an upgraded WS. Returns the answer SDP.
async fn complete_handshake(
    ws: &mut tokio_tungstenite::WebSocketStream<
        tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
    >,
) -> String {
    let (offer_sdp, _pending, _rtc) = build_browser_offer();
    ws.send(Message::Text(
        serde_json::json!({"kind":"offer","sdp":offer_sdp})
            .to_string()
            .into(),
    ))
    .await
    .unwrap();
    let answer_msg = tokio::time::timeout(Duration::from_millis(500), ws.next())
        .await
        .expect("answer arrives")
        .expect("stream open")
        .expect("frame OK");
    let answer_text = match answer_msg {
        Message::Text(t) => t,
        other => panic!("expected text answer, got {other:?}"),
    };
    let v: Value = serde_json::from_str(answer_text.as_str()).unwrap();
    v["sdp"].as_str().expect("answer.sdp").to_string()
}

/// Wait for `metrics.active_participants` to reach `target` (or timeout).
async fn wait_active(metrics: &SfuMetrics, target: i64, max_ms: u64) -> i64 {
    let mut got = metrics.active_participants.get();
    for _ in 0..(max_ms / 5) {
        got = metrics.active_participants.get();
        if got == target {
            return got;
        }
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
    got
}

/// Wait for an `IntCounter` to reach `target` (or timeout). Polls every 5ms.
async fn wait_metric_ge(metric: &prometheus::IntCounter, target: u64, max_ms: u64) -> u64 {
    for _ in 0..(max_ms / 5) {
        let got = metric.get();
        if got >= target {
            return got;
        }
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
    metric.get()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn duplicate_upgrade_replaces_older_session() {
    let (base, metrics, shutdown_tx, serve_handle) = start_full_pipeline().await;
    const PEER_ID: u64 = 42;
    let token = make_token(ROOM_ID, PEER_ID, HS256_SECRET, 3600);
    let url = format!("{base}/sfu/ws/{ROOM_ID}");

    // 1. Dial WS A and complete the SDP handshake.
    let req_a = build_request(&url, &token);
    let (mut ws_a, _resp) = tokio::time::timeout(
        Duration::from_secs(2),
        tokio_tungstenite::connect_async(req_a),
    )
    .await
    .expect("ws A handshake within 2s")
    .expect("ws A handshake OK");
    let answer_a = complete_handshake(&mut ws_a).await;
    assert!(answer_a.contains("v=0"), "WS A must receive a real answer");

    // Wait for WS A to land in registry.
    let n = wait_active(&metrics, 1, 500).await;
    assert_eq!(n, 1, "WS A must be in the registry (got {n})");

    // 2. Dial WS B with the same peer_id and complete its handshake.
    let req_b = build_request(&url, &token);
    let (mut ws_b, _resp) = tokio::time::timeout(
        Duration::from_secs(2),
        tokio_tungstenite::connect_async(req_b),
    )
    .await
    .expect("ws B handshake within 2s")
    .expect("ws B handshake OK");
    let answer_b = complete_handshake(&mut ws_b).await;
    assert!(answer_b.contains("v=0"), "WS B must receive a real answer");

    // 3. WS A must observe a Close(4031) frame ("session replaced").
    //    Allow up to 2s for the steal-signal → close-frame round-trip.
    let close_a = tokio::time::timeout(Duration::from_secs(2), ws_a.next())
        .await
        .expect("WS A must receive Close within 2s")
        .expect("WS A stream not ended before close")
        .expect("WS A close frame deserialised OK");
    match close_a {
        Message::Close(Some(frame)) => {
            assert_eq!(
                u16::from(frame.code),
                4031,
                "WS A must close with 4031 session_replaced, got {:?}",
                frame.code
            );
        }
        other => panic!("expected Close(4031) on WS A, got {other:?}"),
    }

    // 4. Registry holds exactly one client with peer_id=42 — that is,
    //    `active_participants` is back at 1 (B replaced A). Allow up to
    //    500ms for eviction to settle.
    let n_after = wait_active(&metrics, 1, 500).await;
    assert_eq!(
        n_after, 1,
        "after steal, registry must hold exactly 1 client (got {n_after})"
    );

    // Clean shutdown.
    let _ = shutdown_tx.send(());
    let _ = serve_handle.await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn duplicate_upgrade_increments_metric() {
    let (base, metrics, shutdown_tx, serve_handle) = start_full_pipeline().await;
    const PEER_ID: u64 = 77;
    let token = make_token(ROOM_ID, PEER_ID, HS256_SECRET, 3600);
    let url = format!("{base}/sfu/ws/{ROOM_ID}");

    let before = metrics.session_replaced_total.get();

    // First session.
    let req_a = build_request(&url, &token);
    let (mut ws_a, _resp) = tokio::time::timeout(
        Duration::from_secs(2),
        tokio_tungstenite::connect_async(req_a),
    )
    .await
    .unwrap()
    .unwrap();
    let _ = complete_handshake(&mut ws_a).await;
    assert_eq!(wait_active(&metrics, 1, 500).await, 1);

    // Second session — triggers the steal.
    let req_b = build_request(&url, &token);
    let (mut ws_b, _resp) = tokio::time::timeout(
        Duration::from_secs(2),
        tokio_tungstenite::connect_async(req_b),
    )
    .await
    .unwrap()
    .unwrap();
    let _ = complete_handshake(&mut ws_b).await;

    // Poll the metric directly rather than waiting on WS A's close frame as a
    // proxy: under CPU pressure the close-frame round-trip can exceed 2s, but
    // the metric increment happens earlier on the SFU side.
    let after = wait_metric_ge(&metrics.session_replaced_total, before + 1, 2000).await;
    assert_eq!(
        after,
        before + 1,
        "sfu_session_replaced_total must increment by exactly 1 (before={before}, after={after})"
    );

    let _ = shutdown_tx.send(());
    let _ = serve_handle.await;
}
