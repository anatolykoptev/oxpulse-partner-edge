//! Integration tests for the client-facing WS session — Phase 7 M4.A2.
//!
//! These tests cover the full path from "WS upgrade complete" through
//! the SDP offer/answer exchange to "browser client present in the
//! Registry". They use the same in-process style as
//! `relay_media_e2e.rs`: spawn the WS handler on an ephemeral port,
//! drive it from the test task with a real `tokio_tungstenite` client.
//!
//! Browser-origin assertion is **by-construction**:
//! `Client::new(rtc, metrics)` defaults `origin = ClientOrigin::Local`,
//! and `Client::new_outbound_relay` is the only other constructor — we
//! don't wire the relay channel, so a `+1` on `active_participants`
//! must be a browser client.

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
const ROOM_ID: &str = "M4A2-TEST";

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

/// Build a browser-side str0m offerer that requests recvonly audio +
/// recvonly video (mirroring the spike's `pc.addTransceiver("audio", {
/// direction: "recvonly" })` style). Returns `(offer_sdp, pending,
/// rtc)`.
///
/// Using str0m as the offerer (instead of hand-crafting SDP) is the
/// pattern from `relay/client.rs:connect_relay` and gives us a real
/// `accept_answer` round-trip if a follow-up test wants to assert ICE
/// negotiation actually starts.
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

/// Spin up the WS handler on an ephemeral port + the inject channel.
/// Returns the WS base URL, the inject `Receiver`, and the spawned task
/// handle. Bind addr `127.0.0.1:0` is the host candidate the handler
/// will install on the str0m answerer — there's no UDP loop in this
/// test, so we never actually drive ICE; we only assert the SDP
/// exchange completes and a `PendingClient` lands in the channel.
async fn start_handler() -> (
    String,
    mpsc::Receiver<PendingClient>,
    tokio::task::JoinHandle<()>,
) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let secret: Arc<[u8]> = Arc::from(HS256_SECRET);
    let (inject_tx, inject_rx) = mpsc::channel::<PendingClient>(8);
    let local_udp = "127.0.0.1:0".parse().unwrap();
    let handle = spawn_client_ws_api(listener, secret, None, inject_tx, local_udp).unwrap();
    (format!("ws://{addr}"), inject_rx, handle)
}

#[tokio::test]
async fn offer_returns_answer_and_injects_pending_client() {
    let (base, mut inject_rx, _handle) = start_handler().await;
    let token = make_token(ROOM_ID, 7, HS256_SECRET, 3600);
    let url = format!("{base}/sfu/ws/{ROOM_ID}");
    let req = build_request(&url, &token);

    let (mut ws, _resp) = tokio::time::timeout(
        Duration::from_secs(2),
        tokio_tungstenite::connect_async(req),
    )
    .await
    .expect("ws handshake within 2s")
    .expect("ws handshake OK");

    let (offer_sdp, pending_offer, mut offerer_rtc) = build_browser_offer();
    let frame = serde_json::json!({ "kind": "offer", "sdp": offer_sdp }).to_string();
    ws.send(Message::Text(frame.into()))
        .await
        .expect("send offer");

    // Server should reply with an answer in well under 1s.
    let answer_msg = tokio::time::timeout(Duration::from_millis(500), ws.next())
        .await
        .expect("answer arrives within 500ms")
        .expect("ws stream not closed")
        .expect("answer frame deserialised OK");
    let answer_text = match answer_msg {
        Message::Text(t) => t,
        other => panic!("expected text answer frame, got {other:?}"),
    };
    let v: Value = serde_json::from_str(answer_text.as_str()).expect("answer is JSON");
    assert_eq!(v["kind"].as_str(), Some("answer"), "kind must be 'answer'");
    let answer_sdp = v["sdp"].as_str().expect("answer.sdp present");
    assert!(
        answer_sdp.contains("v=0"),
        "answer SDP must look like SDP, got prefix: {:?}",
        &answer_sdp[..answer_sdp.len().min(40)]
    );
    assert!(
        answer_sdp.contains("a=rtcp-mux"),
        "answer SDP must include rtcp-mux"
    );

    // PendingClient must arrive on the inject channel.
    //
    // M4.A2-followup race fix (`session::run` step 5 reordered ahead of
    // step 6): the production motivation is UDP — as soon as the
    // browser observes the answer SDP, it sends STUN to the SFU's UDP
    // socket. Those datagrams reach the registry on a separate task
    // (`udp_loop::serve`'s `socket.recv_from` arm) and were getting
    // logged as `no client accepts udp datagram` for every packet that
    // arrived before the `client_inject_rx` arm pulled the
    // `PendingClient` off the channel. The reorder closes that
    // window.
    //
    // We can't deterministically observe the *pre-fix* race in this
    // harness — both sends complete sub-ms with no real network in
    // between, so `try_recv` here would also succeed pre-fix. The
    // assertion is therefore documentation of the post-fix invariant
    // (queued before answer fully read by test), not a red→green
    // proof. The genuine red→green proof is by code inspection of the
    // two-statement reorder in `session::run`.
    let pending = inject_rx
        .try_recv()
        .expect("PendingClient must be queued by the time the WS answer reaches the offerer");
    assert_eq!(pending.external_peer_id, 7);
    assert_eq!(pending.room_id, ROOM_ID);

    // Apply the answer back at the SAME offerer — proves the SDP is
    // syntactically valid str0m output that a real browser-style
    // offerer could consume, and that MIDs/transport line up. This is
    // the spike's "answer applied" step (offerer-side, not answerer).
    // We don't drive ICE here; that requires the UDP loop and is
    // covered by `end_to_end_browser_client_lands_in_registry` below.
    let answer_parsed = str0m::change::SdpAnswer::from_sdp_string(answer_sdp)
        .expect("str0m can parse its own answer");
    offerer_rtc
        .sdp_api()
        .accept_answer(pending_offer, answer_parsed)
        .expect("offerer accepts the SFU's answer");
}

#[tokio::test]
async fn malformed_first_frame_closes_with_4002() {
    let (base, _inject_rx, _handle) = start_handler().await;
    let token = make_token(ROOM_ID, 8, HS256_SECRET, 3600);
    let url = format!("{base}/sfu/ws/{ROOM_ID}");
    let req = build_request(&url, &token);

    let (mut ws, _resp) = tokio::time::timeout(
        Duration::from_secs(2),
        tokio_tungstenite::connect_async(req),
    )
    .await
    .expect("ws handshake within 2s")
    .expect("ws handshake OK");

    // Send something that isn't a valid offer frame.
    ws.send(Message::Text("not-json".to_string().into()))
        .await
        .expect("send bad frame");

    // Expect a Close frame with our application code 4002 (BAD_OFFER).
    let close = tokio::time::timeout(Duration::from_secs(2), ws.next())
        .await
        .expect("close within 2s")
        .expect("stream not ended before close")
        .expect("close frame deserialised OK");
    match close {
        Message::Close(Some(frame)) => {
            assert_eq!(
                u16::from(frame.code),
                4002,
                "bad first frame must close with code 4002, got {:?}",
                frame.code
            );
        }
        other => panic!("expected Close(4002), got {other:?}"),
    }
}

#[tokio::test]
async fn wrong_kind_first_frame_closes_with_4002() {
    let (base, _inject_rx, _handle) = start_handler().await;
    let token = make_token(ROOM_ID, 9, HS256_SECRET, 3600);
    let url = format!("{base}/sfu/ws/{ROOM_ID}");
    let req = build_request(&url, &token);

    let (mut ws, _resp) = tokio::time::timeout(
        Duration::from_secs(2),
        tokio_tungstenite::connect_async(req),
    )
    .await
    .unwrap()
    .unwrap();

    // Send a JSON frame with a non-offer kind.
    ws.send(Message::Text(
        serde_json::json!({"kind":"ice","candidate":"foo"})
            .to_string()
            .into(),
    ))
    .await
    .unwrap();

    let close = tokio::time::timeout(Duration::from_secs(2), ws.next())
        .await
        .expect("close within 2s")
        .expect("stream not ended")
        .expect("frame OK");
    match close {
        Message::Close(Some(frame)) => assert_eq!(u16::from(frame.code), 4002),
        other => panic!("expected Close(4002), got {other:?}"),
    }
}

/// In-process end-to-end variant: drive a real `udp_loop::serve` task
/// alongside the WS handler and assert the browser client lands in the
/// Registry (visible via `metrics.active_participants`).
#[tokio::test]
async fn end_to_end_browser_client_lands_in_registry() {
    use oxpulse_sfu::config::SfuConfig;
    use oxpulse_sfu::udp_loop;

    // 1. Bind the UDP socket the SFU will use for media.
    let cfg = SfuConfig {
        udp_port: 0,
        bind_address: "127.0.0.1".to_string(),
        ..SfuConfig::default()
    };
    let socket = udp_loop::bind(&cfg).await.unwrap();
    let local_udp = socket.local_addr().unwrap();

    // 2. Wire metrics + inject channels.
    let metrics = Arc::new(SfuMetrics::default());
    let (relay_tx, relay_rx) = mpsc::channel::<oxpulse_sfu::relay::client::PendingRelay>(1);
    drop(relay_tx);
    let (client_inject_tx, client_inject_rx) = mpsc::channel::<PendingClient>(8);

    // 3. Spawn the WS API (sends PendingClient into client_inject_tx).
    let ws_listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let ws_addr = ws_listener.local_addr().unwrap();
    let secret: Arc<[u8]> = Arc::from(HS256_SECRET);
    let _ws_handle = spawn_client_ws_api(
        ws_listener,
        secret,
        None,
        client_inject_tx.clone(),
        local_udp,
    )
    .unwrap();
    drop(client_inject_tx);

    // 4. Spawn the UDP serve loop.
    let metrics_clone = metrics.clone();
    let (shutdown_tx, shutdown_rx) = tokio::sync::oneshot::channel::<()>();
    let serve_handle = tokio::spawn(udp_loop::serve(
        socket,
        metrics_clone,
        None,
        None,
        relay_rx,
        client_inject_rx,
        async {
            let _ = shutdown_rx.await;
        },
    ));

    // 5. Browser side: connect WS, send offer, await answer.
    let token = make_token(ROOM_ID, 42, HS256_SECRET, 3600);
    let url = format!("ws://{ws_addr}/sfu/ws/{ROOM_ID}");
    let req = build_request(&url, &token);
    let (mut ws, _resp) = tokio_tungstenite::connect_async(req).await.unwrap();

    let (offer_sdp, _pending, _rtc) = build_browser_offer();
    ws.send(Message::Text(
        serde_json::json!({"kind":"offer","sdp":offer_sdp})
            .to_string()
            .into(),
    ))
    .await
    .unwrap();

    // Wait for the answer.
    let _answer = tokio::time::timeout(Duration::from_millis(500), ws.next())
        .await
        .expect("answer arrives")
        .expect("stream open")
        .expect("frame OK");

    // 6. Poll the metric — the registry inserts asynchronously when
    //    serve()'s select! arm yields. Allow up to 200ms.
    let mut got = 0;
    for _ in 0..40 {
        got = metrics.active_participants.get();
        if got >= 1 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
    assert!(
        got >= 1,
        "browser client must land in registry (active_participants={got})"
    );

    // 7. Clean shutdown.
    let _ = shutdown_tx.send(());
    let _ = serve_handle.await;
}
