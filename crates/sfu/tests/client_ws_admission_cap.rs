//! Integration tests for the SFU_MAX_PARTICIPANTS admission cap on the
//! browser-facing `/sfu/ws/{room_id}` path.
//!
//! T9 (2026-07-01 bug-hunt, `federation-critical-surfaces`,
//! resource_exhaustion/high): the relay-dial path (`RELAY_MAX_CONCURRENT`
//! semaphore in `main.rs`) was already bounded, but `client_ws_upgrade`
//! admitted every valid-token WS upgrade unconditionally — `registry.insert`
//! and `client_ws_active_sessions` are pure gauges with no cap, so a burst of
//! valid tokens can drive the single-task udp_loop's O(N) demux (Escalation
//! #2, not this task) past its forwarding budget with no admission ceiling.
//!
//! RED before the fix: opening `SFU_MAX_PARTICIPANTS + 1` sessions admits
//! all of them (no 503, `sfu_admission_rejected_total` never increments)
//! because `client_ws_upgrade` had no admission gate.

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use jsonwebtoken::{encode, EncodingKey, Header};
use oxpulse_sfu::client_ws::{spawn_client_ws_api, PendingClient};
use oxpulse_sfu::metrics::SfuMetrics;
use oxpulse_sfu::room_auth::RoomClaims;
use serial_test::serial;
use tokio::net::TcpListener;
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::{
    client::IntoClientRequest,
    handshake::client::generate_key,
    http::{HeaderValue, StatusCode},
    Error as WsError,
};

const HS256_SECRET: &[u8] = b"test-secret-32-bytes-long-enough!";
const SUBPROTO: &str = "oxpulse-sfu-v1";
const ROOM_ID: &str = "ADMISSION-CAP-TEST";

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

async fn start_test_handler_with_metrics() -> (String, Arc<SfuMetrics>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let secret: Arc<[u8]> = Arc::from(HS256_SECRET);
    let (inject_tx, inject_rx) = mpsc::channel::<PendingClient>(64);
    let local_udp: SocketAddr = "127.0.0.1:0".parse().unwrap();
    let metrics = Arc::new(SfuMetrics::default());
    let _handle = spawn_client_ws_api(
        listener,
        secret,
        None,
        inject_tx,
        local_udp,
        metrics.clone(),
        0, // stats disabled in tests
    )
    .unwrap();
    // Nobody drains PendingClient in this test (no offer is ever sent so
    // nothing is injected) — leak the receiver so it doesn't drop and close
    // the channel out from under the server task.
    Box::leak(Box::new(inject_rx));
    (format!("ws://{addr}"), metrics)
}

/// Poll `client_ws_active_sessions` until it reaches `want` or the 2s
/// deadline elapses. `ActiveSessionGuard::new()` runs inside the spawned
/// `on_upgrade` future, which starts asynchronously after the 101 response
/// is already on the wire — so a fresh connect racing the guard's `.inc()`
/// needs a bounded wait, not a fixed sleep (this crate replaced flaky fixed
/// sleeps with poll-loops in the bwe-hint round-3 fix, see
/// `tests/bwe_hint_test.rs`).
async fn wait_for_active_sessions(metrics: &SfuMetrics, want: i64) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(2);
    while tokio::time::Instant::now() < deadline {
        if metrics.client_ws_active_sessions.get() >= want {
            return;
        }
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
    panic!(
        "client_ws_active_sessions never reached {want}, stuck at {}",
        metrics.client_ws_active_sessions.get()
    );
}

/// RED (T9 finding repro): with `SFU_MAX_PARTICIPANTS=2`, two sessions are
/// admitted (101) but the third gets a real HTTP 503 with no WS upgrade —
/// mirrors the existing `rejects_expired_token_with_401` assertion shape.
/// `sfu_admission_rejected_total{reason="at_capacity"}` must increment
/// exactly once, driven through the real `client_ws_upgrade` handler (not a
/// manual counter bump).
#[tokio::test]
#[serial]
async fn at_capacity_rejects_third_upgrade_with_503() {
    std::env::set_var("SFU_MAX_PARTICIPANTS", "2");
    let (base, metrics) = start_test_handler_with_metrics().await;

    let token1 = make_token(ROOM_ID, 1, HS256_SECRET, 3600);
    let url1 = format!("{base}/sfu/ws/{ROOM_ID}");
    let (ws1, resp1) = tokio::time::timeout(
        Duration::from_secs(2),
        tokio_tungstenite::connect_async(build_request(&url1, &token1)),
    )
    .await
    .expect("handshake 1 within 2s")
    .expect("session 1 must be admitted (under cap)");
    assert_eq!(resp1.status(), StatusCode::SWITCHING_PROTOCOLS);

    let token2 = make_token(ROOM_ID, 2, HS256_SECRET, 3600);
    let url2 = format!("{base}/sfu/ws/{ROOM_ID}");
    let (ws2, resp2) = tokio::time::timeout(
        Duration::from_secs(2),
        tokio_tungstenite::connect_async(build_request(&url2, &token2)),
    )
    .await
    .expect("handshake 2 within 2s")
    .expect("session 2 must be admitted (at cap)");
    assert_eq!(resp2.status(), StatusCode::SWITCHING_PROTOCOLS);

    // Deterministically wait for both ActiveSessionGuards to have run
    // before probing the boundary — this is the real gauge the admission
    // gate reads, not a test-side shadow counter.
    wait_for_active_sessions(&metrics, 2).await;

    let token3 = make_token(ROOM_ID, 3, HS256_SECRET, 3600);
    let url3 = format!("{base}/sfu/ws/{ROOM_ID}");
    let err = tokio::time::timeout(
        Duration::from_secs(2),
        tokio_tungstenite::connect_async(build_request(&url3, &token3)),
    )
    .await
    .expect("handshake 3 attempt within 2s")
    .expect_err("session 3 must be rejected at capacity — no WS upgrade");
    match err {
        WsError::Http(resp) => {
            assert_eq!(
                resp.status(),
                StatusCode::SERVICE_UNAVAILABLE,
                "at-capacity rejection must be a real HTTP 503, not a WS open+close"
            );
        }
        other => panic!("expected Http(503), got {other:?}"),
    }

    assert_eq!(
        metrics
            .sfu_admission_rejected_total
            .with_label_values(&["at_capacity"])
            .get(),
        1,
        "sfu_admission_rejected_total{{reason=at_capacity}} must increment exactly once"
    );

    // Sessions 1 and 2 (admitted under/at cap) must be unaffected by the
    // rejection of session 3 — keep them alive until here so the guard
    // doesn't decrement mid-assertion.
    drop(ws1);
    drop(ws2);
    std::env::remove_var("SFU_MAX_PARTICIPANTS");
}

/// Sessions strictly under the cap must be admitted unaffected, and the
/// at-capacity reject counter must stay at 0 — the positive-path
/// counterpart of `at_capacity_rejects_third_upgrade_with_503`.
#[tokio::test]
#[serial]
async fn under_cap_sessions_all_admitted() {
    std::env::set_var("SFU_MAX_PARTICIPANTS", "3");
    let (base, metrics) = start_test_handler_with_metrics().await;

    let mut sockets = Vec::new();
    for sub in 1..=3u64 {
        let token = make_token(ROOM_ID, sub, HS256_SECRET, 3600);
        let url = format!("{base}/sfu/ws/{ROOM_ID}");
        let handshake = tokio::time::timeout(
            Duration::from_secs(2),
            tokio_tungstenite::connect_async(build_request(&url, &token)),
        )
        .await
        .expect("handshake within 2s");
        let (ws, resp) = match handshake {
            Ok(pair) => pair,
            Err(e) => panic!("session {sub} must be admitted (at/under cap): {e}"),
        };
        assert_eq!(resp.status(), StatusCode::SWITCHING_PROTOCOLS);
        sockets.push(ws);
    }

    wait_for_active_sessions(&metrics, 3).await;

    assert_eq!(
        metrics
            .sfu_admission_rejected_total
            .with_label_values(&["at_capacity"])
            .get(),
        0,
        "no session under/at the cap should ever be counted as rejected"
    );

    drop(sockets);
    std::env::remove_var("SFU_MAX_PARTICIPANTS");
}
