//! T8: cascade-relay activation on the Ed25519 signing key.
//!
//! Before T8 the activation gate in `main.rs` read `RELAY_JWT_SECRET` alone, so a
//! pure-Ed25519 deployment (only `SFU_SIGNING_PUBLIC_KEY` set — the canonical
//! federation path) never spawned the relay API. These tests exercise the
//! extracted gate (`relay::activation::compute_relay_activation`) and the
//! deploy-shaped relay-connect path it feeds, proving:
//!   1. Ed25519 alone activates the relay (the assertion that is RED on the
//!      pre-T8 secret-only gate), and
//!   2. the Ed25519-only relay-connect path does NOT panic on the missing HS256
//!      secret and never accepts an empty-secret HS256 forgery.

use std::sync::Arc;
use std::time::Duration;

use oxpulse_sfu::metrics::{SfuMetrics, RELAY_AUTH_EDDSA};
use oxpulse_sfu::relay::activation::compute_relay_activation;
use oxpulse_sfu::relay::handler::{spawn_relay_api, RelayApiState, SeenJtis};
use oxpulse_sfu::relay::task::RelayTask;
use oxpulse_sfu::relay::types::{RelayConnectRequest, RelayConnectResponse};
use oxpulse_sfu::relay::{now_unix_secs, RelayJwt};
use reqwest::Client;
use tokio::net::TcpListener;
use tokio::sync::mpsc;

// ── activation gate: the T8 fix, RED on the pre-T8 secret-only gate ──────────

/// A syntactically-plausible Ed25519 public-key PEM. The gate checks presence
/// only, but the round-trip test below needs the REAL matching key, so this
/// constant is used only by the gate-level assertions.
const PUBKEY_PEM_PLACEHOLDER: &str =
    "-----BEGIN PUBLIC KEY-----\nMCowBQYDK2VwAyEA\n-----END PUBLIC KEY-----\n";

#[test]
fn ed25519_only_activates_relay_api() {
    // ONLY the signing public key is configured — no RELAY_JWT_SECRET. This is
    // the canonical federation deployment. Pre-T8 this returned enabled=false.
    let a = compute_relay_activation(None, Some(PUBKEY_PEM_PLACEHOLDER), true)
        .expect("valid Ed25519-only config must not error");
    assert!(
        a.enabled,
        "Ed25519-only deployment MUST activate the relay API (T8): the gate must \
         consult SFU_SIGNING_PUBLIC_KEY, not RELAY_JWT_SECRET alone"
    );
    assert_eq!(
        a.auth_mode,
        Some(RELAY_AUTH_EDDSA),
        "auth mode must report eddsa for a pure-Ed25519 activation"
    );
}

#[test]
fn ed25519_only_forces_hs256_fallback_off_with_empty_secret() {
    // Interaction guard with T7: no HS256 secret means the fallback verifier
    // would run against the EMPTY secret (attacker-forgeable), so it must be
    // forced off regardless of the default-on SFU_RELAY_HS256_FALLBACK.
    let a = compute_relay_activation(None, Some(PUBKEY_PEM_PLACEHOLDER), true).unwrap();
    assert!(
        a.secret.is_empty(),
        "no RELAY_JWT_SECRET → empty secret Arc (no unwrap/panic)"
    );
    assert!(
        !a.hs256_fallback_effective,
        "no HS256 secret → fallback forced off even though config default is on"
    );
}

// ── deploy-shaped no-panic path: Ed25519-only relay-connect over real HTTP ───

fn gen_ed25519_keypair() -> (String, String) {
    use ed25519_dalek::pkcs8::{EncodePrivateKey, EncodePublicKey};
    use ed25519_dalek::SigningKey;
    use pkcs8::LineEnding;
    let key = SigningKey::generate(&mut rand::rngs::OsRng);
    let priv_pem = key.to_pkcs8_pem(LineEnding::LF).unwrap().to_string();
    let pub_pem = key.verifying_key().to_public_key_pem(LineEnding::LF).unwrap();
    (priv_pem, pub_pem)
}

fn sign_ed25519(jwt: &RelayJwt, priv_pem: &str) -> String {
    use jsonwebtoken::{encode, Algorithm, EncodingKey, Header};
    let key = EncodingKey::from_ed_pem(priv_pem.as_bytes()).unwrap();
    encode(&Header::new(Algorithm::EdDSA), jwt, &key).unwrap()
}

fn allowlisted_jwt(jti: &str) -> RelayJwt {
    let now = now_unix_secs();
    RelayJwt {
        room_id: "room-t8".to_string(),
        // Allow-listed AWG mesh URL so a verified token reaches the 200 path.
        upstream_url: "ws://10.9.0.2:8907/ws/call/r".to_string(),
        upstream_room_token: "tok".to_string(),
        iat: now,
        exp: now + 300,
        jti: jti.to_string(),
        upstream_candidates: vec![],
    }
}

/// Spawn the relay API exactly as `main.rs` would for a pure-Ed25519 deployment:
/// the empty secret + forced-off fallback come straight from `compute_relay_activation`.
async fn start_ed25519_only_api(pubkey_pem: &str) -> (String, mpsc::Receiver<RelayTask>) {
    let activation = compute_relay_activation(None, Some(pubkey_pem), true).unwrap();
    assert!(activation.enabled, "precondition: Ed25519-only must be enabled");

    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let (tx, rx) = mpsc::channel::<RelayTask>(8);
    let seen_jtis: SeenJtis = Arc::new(std::sync::Mutex::new(std::collections::HashMap::new()));
    let metrics = Arc::new(SfuMetrics::default());
    spawn_relay_api(
        listener,
        RelayApiState {
            secret: activation.secret.clone(), // empty — must not be consulted
            signing_public_key: Some(Arc::new(pubkey_pem.to_string())),
            task_tx: tx,
            seen_jtis,
            metrics,
            hs256_fallback_enabled: activation.hs256_fallback_effective, // forced false
        },
    )
    .unwrap();
    (format!("http://{addr}"), rx)
}

/// A valid EdDSA-signed token verifies and enqueues a relay task — the
/// Ed25519-only path works end-to-end with an empty HS256 secret (no panic).
#[tokio::test]
async fn ed25519_only_relay_connect_accepts_eddsa_token() {
    let (priv_pem, pub_pem) = gen_ed25519_keypair();
    let (base, mut rx) = start_ed25519_only_api(&pub_pem).await;

    let token = sign_ed25519(&allowlisted_jwt("t8-ed-ok"), &priv_pem);
    let http = Client::new()
        .post(format!("{base}/relay/connect"))
        .json(&RelayConnectRequest { relay_token: token })
        .send()
        .await
        .unwrap();
    assert_eq!(
        http.status(),
        reqwest::StatusCode::OK,
        "a valid EdDSA token must be accepted on a pure-Ed25519 relay (no panic on empty secret)"
    );
    let resp: RelayConnectResponse = http.json().await.unwrap();
    assert_eq!(resp.status, "ok");
    let task = tokio::time::timeout(Duration::from_secs(1), rx.recv())
        .await
        .expect("task within 1s")
        .expect("channel open");
    assert_eq!(task.room_id, "room-t8");
}

/// An HS256 token (any secret, including the exploitable empty key) is REJECTED
/// on a pure-Ed25519 relay — the fallback is off, the empty secret is never
/// consulted, and the handler returns 401 instead of panicking or accepting a forgery.
#[tokio::test]
async fn ed25519_only_relay_connect_rejects_hs256_token_without_panic() {
    let (_priv_pem, pub_pem) = gen_ed25519_keypair();
    let (base, _rx) = start_ed25519_only_api(&pub_pem).await;

    // Forge an HS256 token with an EMPTY key — the exact value an attacker would
    // try against a secret-less deployment if the fallback ran on the empty secret.
    let forged = allowlisted_jwt("t8-hs-forge").sign(b"").unwrap();
    let status = Client::new()
        .post(format!("{base}/relay/connect"))
        .json(&RelayConnectRequest { relay_token: forged })
        .send()
        .await
        .unwrap()
        .status();
    assert_eq!(
        status,
        reqwest::StatusCode::UNAUTHORIZED,
        "an HS256 (empty-key forged) token must be rejected 401 on a pure-Ed25519 relay, \
         proving the fallback is off and the empty secret is never consulted"
    );
}
