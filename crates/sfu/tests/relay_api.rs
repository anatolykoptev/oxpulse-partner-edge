//! Integration tests for the relay HTTP API.

use oxpulse_sfu::metrics::SfuMetrics;
use oxpulse_sfu::relay::handler::{spawn_relay_api, RelayApiState, SeenJtis};
use oxpulse_sfu::relay::task::RelayTask;
use oxpulse_sfu::relay::types::{RelayConnectRequest, RelayConnectResponse};
use oxpulse_sfu::relay::{now_unix_secs, RelayJwt};
use reqwest::Client;
use std::sync::Arc;
use std::time::Duration;
use tokio::net::TcpListener;
use tokio::sync::mpsc;

async fn start_test_api(secret: Arc<[u8]>) -> (String, mpsc::Receiver<RelayTask>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let (tx, rx) = mpsc::channel::<RelayTask>(8);
    let seen_jtis: SeenJtis = Arc::new(std::sync::Mutex::new(std::collections::HashMap::new()));
    let metrics = Arc::new(SfuMetrics::default());
    spawn_relay_api(
        listener,
        RelayApiState {
            secret,
            signing_public_key: None,
            task_tx: tx,
            seen_jtis,
            metrics,
            hs256_fallback_enabled: true,
        },
    )
    .unwrap();
    (format!("http://{addr}"), rx)
}

/// Start the relay API with `signing_public_key = Some(..)` — the normal install
/// state where SFU_SIGNING_PUBLIC_KEY (EdDSA) AND the HS256 secret are both set.
async fn start_test_api_with_pubkey(
    secret: Arc<[u8]>,
    pubkey: Arc<String>,
) -> (String, mpsc::Receiver<RelayTask>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let (tx, rx) = mpsc::channel::<RelayTask>(8);
    let seen_jtis: SeenJtis = Arc::new(std::sync::Mutex::new(std::collections::HashMap::new()));
    let metrics = Arc::new(SfuMetrics::default());
    spawn_relay_api(
        listener,
        RelayApiState {
            secret,
            signing_public_key: Some(pubkey),
            task_tx: tx,
            seen_jtis,
            metrics,
            hs256_fallback_enabled: true,
        },
    )
    .unwrap();
    (format!("http://{addr}"), rx)
}

/// Generate an Ed25519 public-key PEM (the SFU_SIGNING_PUBLIC_KEY value) whose
/// matching private key is discarded — the EdDSA verifier can only ever fail to
/// match an HS256-signed token, exercising the fallback path.
fn generate_ed25519_pubkey_pem() -> String {
    use ed25519_dalek::pkcs8::EncodePublicKey;
    use ed25519_dalek::SigningKey;
    use pkcs8::LineEnding;
    let key = SigningKey::generate(&mut rand::rngs::OsRng);
    key.verifying_key()
        .to_public_key_pem(LineEnding::LF)
        .unwrap()
}

fn make_token(secret: &[u8], room_id: &str) -> String {
    let now = now_unix_secs();
    RelayJwt {
        room_id: room_id.to_string(),
        upstream_url: "wss://localhost/ws/sfu/test".to_string(),
        upstream_room_token: "tok".to_string(),
        iat: now,
        exp: now + 60,
        jti: uuid_v4_simple(),
        upstream_candidates: vec![],
    }
    .sign(secret)
    .unwrap()
}

fn uuid_v4_simple() -> String {
    // Minimal deterministic unique ID for tests — not a real UUID.
    format!(
        "test-jti-{}",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .subsec_nanos()
    )
}

#[tokio::test]
async fn relay_connect_accepts_valid_jwt() {
    let secret: Arc<[u8]> = Arc::from(b"test-secret".as_slice());
    let (base, mut rx) = start_test_api(Arc::clone(&secret)).await;
    let token = make_token(&secret, "room-abc");
    let resp: RelayConnectResponse = Client::new()
        .post(format!("{base}/relay/connect"))
        .json(&RelayConnectRequest { relay_token: token })
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(resp.status, "ok");
    assert!(resp.relay_id.is_some());
    let task = tokio::time::timeout(Duration::from_secs(1), rx.recv())
        .await
        .expect("task within 1s")
        .expect("channel open");
    assert_eq!(task.room_id, "room-abc");
}

/// t5 (synthetic_green regression guard): with `signing_public_key = Some` (EdDSA
/// active) a genuine HS256-signed relay token — the normal rollout case where a
/// sender has not yet cut over to EdDSA — MUST be accepted via the HS256 fallback
/// and return 200, not 400. Before the fix the EdDSA verifier mapped the alg
/// mismatch to Malformed, the fallback (which only retried InvalidSignature) never
/// fired, and the request 400'd — the interop the handler comment promises.
#[tokio::test]
async fn relay_connect_hs256_token_accepted_via_fallback_when_signing_key_set() {
    let secret: Arc<[u8]> = Arc::from(b"rollout-shared-secret".as_slice());
    let pubkey = Arc::new(generate_ed25519_pubkey_pem());
    let (base, mut rx) = start_test_api_with_pubkey(Arc::clone(&secret), pubkey).await;
    // A normal HS256-signed token (sender has not cut over to EdDSA yet).
    let token = make_token(&secret, "room-hs256-fallback");
    let http = Client::new()
        .post(format!("{base}/relay/connect"))
        .json(&RelayConnectRequest { relay_token: token })
        .send()
        .await
        .unwrap();
    assert_eq!(
        http.status(),
        reqwest::StatusCode::OK,
        "HS256 token must be accepted via fallback when signing_public_key is Some (was 400 before the fix)"
    );
    let resp: RelayConnectResponse = http.json().await.unwrap();
    assert_eq!(resp.status, "ok");
    assert!(resp.relay_id.is_some());
    let task = tokio::time::timeout(Duration::from_secs(1), rx.recv())
        .await
        .expect("task within 1s")
        .expect("channel open");
    assert_eq!(task.room_id, "room-hs256-fallback");
}

#[tokio::test]
async fn relay_connect_rejects_invalid_jwt() {
    let secret: Arc<[u8]> = Arc::from(b"correct".as_slice());
    let (base, _rx) = start_test_api(Arc::clone(&secret)).await;
    let status = Client::new()
        .post(format!("{base}/relay/connect"))
        .json(&RelayConnectRequest {
            relay_token: "completely.invalid".to_string(),
        })
        .send()
        .await
        .unwrap()
        .status();
    assert!(status.is_client_error(), "expected 4xx, got {status}");
}
