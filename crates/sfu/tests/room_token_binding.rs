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

/// Install the strict process policy through the real `init_policy` path. All
/// tests in this binary want the same policy, so a repeat call is ignored.
fn install_strict_policy() {
    let _ = init_policy(
        RoomTokenPolicy::new(vec!["oxpulse-chat".into()], "oxpulse-sfu", true).unwrap(),
    );
}

async fn start() -> String {
    start_with(None).await
}

async fn start_with(signing_pubkey: Option<Arc<String>>) -> String {
    install_strict_policy();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let (tx, rx) = mpsc::channel::<PendingClient>(8);
    Box::leak(Box::new(rx));
    let _h = spawn_client_ws_api(
        listener,
        ClientWsApiConfig {
            secret: Arc::from(SECRET),
            signing_pubkey,
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

async fn handshake(url: &str, token: &str) -> Result<StatusCode, Box<WsError>> {
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
    .map_err(Box::new)
}

fn assert_401(r: Result<StatusCode, Box<WsError>>, what: &str) {
    match r.map_err(|e| *e) {
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

fn ed25519_pair() -> (String, String) {
    use ed25519_dalek::pkcs8::{spki::der::pem::LineEnding, EncodePrivateKey, EncodePublicKey};
    let key = ed25519_dalek::SigningKey::generate(&mut rand::rngs::OsRng);
    (
        key.to_pkcs8_pem(LineEnding::LF).unwrap().to_string(),
        key.verifying_key()
            .to_public_key_pem(LineEnding::LF)
            .unwrap(),
    )
}

fn ed_token(priv_pem: &str, iss: Option<&str>, aud: Option<&str>) -> String {
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
    let key = EncodingKey::from_ed_pem(priv_pem.as_bytes()).unwrap();
    encode(&Header::new(jsonwebtoken::Algorithm::EdDSA), &c, &key).unwrap()
}

/// The production verify path: with `SFU_SIGNING_PUBLIC_KEY` configured the
/// EdDSA verifier runs first. Guards `verify_room_token_ed25519` ignoring the
/// process policy (the HS256-only test above cannot see that).
#[tokio::test]
async fn eddsa_upgrade_enforces_issuer_audience_binding() {
    let (priv_pem, pub_pem) = ed25519_pair();
    let url = start_with(Some(Arc::new(pub_pem))).await;
    assert_401(
        handshake(
            &url,
            &ed_token(&priv_pem, Some("oxpulse-staging"), Some("oxpulse-sfu")),
        )
        .await,
        "eddsa foreign iss",
    );
    assert_401(
        handshake(&url, &ed_token(&priv_pem, Some("oxpulse-chat"), None)).await,
        "eddsa missing aud",
    );
    let ok = handshake(
        &url,
        &ed_token(&priv_pem, Some("oxpulse-chat"), Some("oxpulse-sfu")),
    )
    .await;
    assert_eq!(ok.unwrap(), StatusCode::SWITCHING_PROTOCOLS);
}
