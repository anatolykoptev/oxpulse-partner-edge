//! SEC-CR-011 call-site coverage: the browser `/sfu/ws/{room_id}` upgrade must
//! enforce the iss/aud binding policy installed at startup (`init_policy`).
//! This is a dedicated test binary because the policy is process-wide.

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use jsonwebtoken::{encode, EncodingKey, Header};
use oxpulse_sfu::client_ws::{spawn_client_ws_api, ClientWsApiConfig, PendingClient};
use oxpulse_sfu::metrics::SfuMetrics;
use oxpulse_sfu::room_auth::{init_policy, RoomTokenPolicy};
use tokio::net::TcpListener;
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::{
    client::IntoClientRequest,
    handshake::client::generate_key,
    http::{HeaderValue, StatusCode},
    Error as WsError,
};

const SECRET: &[u8] = b"test-secret-32-bytes-long-enough!";

fn token(iss: Option<&str>, aud: Option<&str>) -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs();
    let mut c = serde_json::json!({"sub": 1, "room": "ROOM-1", "iat": now, "exp": now + 600});
    if let Some(i) = iss {
        c["iss"] = i.into();
    }
    if let Some(a) = aud {
        c["aud"] = a.into();
    }
    encode(&Header::default(), &c, &EncodingKey::from_secret(SECRET)).unwrap()
}

async fn start() -> String {
    init_policy(RoomTokenPolicy::new(vec!["oxpulse-chat".into()], "oxpulse-sfu", true).unwrap())
        .unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let (tx, rx) = mpsc::channel::<PendingClient>(8);
    Box::leak(Box::new(rx));
    let _h = spawn_client_ws_api(
        listener,
        ClientWsApiConfig {
            secret: Arc::from(SECRET),
            signing_pubkey: None,
            client_inject_tx: tx,
            local_udp_addr: "127.0.0.1:0".parse::<SocketAddr>().unwrap(),
            additional_host_candidates: Vec::new(),
            metrics: Arc::new(SfuMetrics::default()),
            stats_interval_secs: 0,
            hs256_fallback_enabled: true,
        },
    )
    .unwrap();
    format!("ws://{addr}/sfu/ws/ROOM-1")
}

async fn handshake(url: &str, token: &str) -> Result<StatusCode, WsError> {
    let mut req = url.into_client_request().unwrap();
    req.headers_mut().insert(
        "sec-websocket-protocol",
        HeaderValue::from_str(&format!("oxpulse-sfu-v1, Bearer {token}")).unwrap(),
    );
    req.headers_mut().insert(
        "sec-websocket-key",
        HeaderValue::from_str(&generate_key()).unwrap(),
    );
    tokio::time::timeout(
        Duration::from_secs(2),
        tokio_tungstenite::connect_async(req),
    )
    .await
    .expect("handshake within 2s")
    .map(|(_ws, resp)| resp.status())
}

fn assert_401(r: Result<StatusCode, WsError>, what: &str) {
    match r {
        Err(WsError::Http(resp)) => assert_eq!(resp.status(), StatusCode::UNAUTHORIZED, "{what}"),
        other => panic!("{what}: expected Http(401), got {other:?}"),
    }
}

#[tokio::test]
async fn upgrade_enforces_issuer_audience_binding() {
    let url = start().await;
    assert_401(
        handshake(&url, &token(Some("oxpulse-staging"), Some("oxpulse-sfu"))).await,
        "foreign iss",
    );
    assert_401(
        handshake(&url, &token(Some("oxpulse-chat"), Some("other"))).await,
        "wrong aud",
    );
    assert_401(
        handshake(&url, &token(Some("oxpulse-chat"), None)).await,
        "missing aud",
    );
    assert_401(
        handshake(&url, &token(None, None)).await,
        "unbound legacy token",
    );
    // Positive control: the correctly bound token upgrades.
    let ok = handshake(&url, &token(Some("oxpulse-chat"), Some("oxpulse-sfu"))).await;
    assert_eq!(ok.unwrap(), StatusCode::SWITCHING_PROTOCOLS);
}
