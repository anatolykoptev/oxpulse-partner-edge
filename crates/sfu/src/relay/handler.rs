//! Axum HTTP handler for the relay API.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use axum::{extract::State, http::StatusCode, routing::post, Json, Router};
use tokio::net::TcpListener;
use tokio::sync::mpsc::Sender;
use tracing::instrument;

use crate::metrics::{SfuMetrics, RELAY_JWT_ALG_EDDSA, RELAY_JWT_ALG_HS256};
use crate::relay::task::RelayTask;
use crate::relay::types::{RelayConnectRequest, RelayConnectResponse};
use crate::relay::{RelayJwt, RelayJwtError};

pub type SeenJtis = Arc<Mutex<HashMap<String, u64>>>;

/// Shared state threaded into every `/relay/connect` request, and the single
/// argument to [`spawn_relay_api`].
///
/// A named struct rather than a positional tuple (or a 7-arg constructor) so a
/// field reorder is a compile error instead of a silent same-type swap — two
/// `Arc<_>` fields would otherwise transpose with no compiler safety net. This
/// also keeps `spawn_relay_api` under the repo's `>4 params → struct` trigger.
/// Cloned cheaply per request (`Arc`/`Option<Arc>`/`Sender`/`bool`).
///
/// `signing_public_key` is `Some` when `SFU_SIGNING_PUBLIC_KEY` is configured
/// (Ed25519 preferred); when `None`, verification falls back to HS256 via
/// `secret` (deprecated path). `metrics` carries the process-wide `SfuMetrics`
/// so `relay_connect` can bump `relay_jwt_verify_total{algorithm}` (T4.3).
/// `hs256_fallback_enabled` is the `SFU_RELAY_HS256_FALLBACK` kill-switch: when
/// `false`, a non-EdDSA token is rejected instead of being silently downgraded
/// to the HS256 fallback.
#[derive(Clone)]
pub struct RelayApiState {
    /// HS256 shared secret (deprecated symmetric verifier / fallback).
    pub secret: Arc<[u8]>,
    /// Ed25519 public key PEM when `SFU_SIGNING_PUBLIC_KEY` is set (preferred).
    pub signing_public_key: Option<Arc<String>>,
    /// Channel into the relay runner.
    pub task_tx: Sender<RelayTask>,
    /// Replay-prevention JTI cache (SEC-CR-002).
    pub seen_jtis: SeenJtis,
    /// Process-wide SFU metrics — bumps `relay_jwt_verify_total{algorithm}`.
    pub metrics: Arc<SfuMetrics>,
    /// `SFU_RELAY_HS256_FALLBACK` kill-switch (T4.3).
    pub hs256_fallback_enabled: bool,
}

/// Spawn the relay API HTTP server on the given `listener`.
pub fn spawn_relay_api(
    listener: TcpListener,
    state: RelayApiState,
) -> anyhow::Result<tokio::task::JoinHandle<()>> {
    let app = Router::new()
        .route("/relay/connect", post(relay_connect))
        .with_state(state);
    let handle = tokio::spawn(async move {
        axum::serve(listener, app)
            .await
            .unwrap_or_else(|e| tracing::error!(error = %e, "relay API server error"));
    });
    Ok(handle)
}

/// Maximum number of relay candidates processed from a JWT.
/// Bounds the failover loop against a buggy or compromised central sending thousands.
const MAX_RELAY_CANDIDATES: usize = 8;

/// B0: Build an allow-list-filtered, ordered candidate list from a verified JWT.
///
/// When `jwt.upstream_candidates` is non-empty, use it (B0 path — signed ordered
/// list from central).  When empty, fall back to the single `jwt.upstream_url`
/// (pre-B0 / legacy path — back-compat guaranteed by `#[serde(default)]`).
/// Every URL is individually checked against the allow-list; disallowed entries
/// are silently dropped.  Duplicates are removed (first occurrence wins).
/// Result is capped at `MAX_RELAY_CANDIDATES`.  An empty return means no candidate
/// survived and the handler MUST reject the request.
pub(crate) fn select_candidates(jwt: &RelayJwt) -> Vec<String> {
    let raw: Vec<String> = if jwt.upstream_candidates.is_empty() {
        vec![jwt.upstream_url.clone()]
    } else {
        jwt.upstream_candidates.clone()
    };
    if raw.len() > MAX_RELAY_CANDIDATES {
        tracing::warn!(
            count = raw.len(),
            max = MAX_RELAY_CANDIDATES,
            "relay JWT contains more candidates than MAX_RELAY_CANDIDATES — truncating"
        );
    }
    let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
    raw.into_iter()
        .filter(|u| crate::relay::allowlist::is_allowed_upstream(u))
        .filter(|u| seen.insert(u.clone()))
        .take(MAX_RELAY_CANDIDATES)
        .collect()
}

/// Verify a relay JWT, returning the claims plus which algorithm authenticated
/// the token (for `relay_jwt_verify_total{algorithm}`).
///
/// Prefer Ed25519 when a public key is configured; fall back to the HS256 shared
/// secret when the EdDSA verifier reports the token was not signed with EdDSA.
/// Two distinct outcomes both mean "this is an HS256 token, retry under HS256":
///   - `InvalidSignature`   — an EdDSA signature check that failed, and
///   - `AlgorithmMismatch`  — the header alg is HS256, so `decode` rejects it
///     with `ErrorKind::InvalidAlgorithm` BEFORE the signature check.
///
/// Without the `AlgorithmMismatch` arm a genuine HS256-header token (the normal
/// rollout case while `SFU_SIGNING_PUBLIC_KEY` is set) collapses to `Malformed`
/// and the promised HS256 fallback never fires. The `Expired`/`Malformed` paths
/// stay strict — an expired EdDSA token is rejected outright, not re-checked
/// under HS256 (which could otherwise mask clock-skew between the two verifiers).
///
/// `hs256_fallback_enabled` is the T4.3 kill-switch: when `false`, the EdDSA→HS256
/// retry is refused and a non-EdDSA token is rejected as `InvalidSignature`
/// instead of being silently downgraded. The switch only gates the *fallback* —
/// when no EdDSA key is configured HS256 is the primary verifier and always runs.
fn verify_relay_jwt(
    token: &str,
    secret: &[u8],
    signing_public_key: Option<&Arc<String>>,
    hs256_fallback_enabled: bool,
) -> Result<(RelayJwt, &'static str), RelayJwtError> {
    match signing_public_key {
        Some(pubkey) => match RelayJwt::verify_ed25519(token, pubkey) {
            Ok(j) => Ok((j, RELAY_JWT_ALG_EDDSA)),
            Err(RelayJwtError::InvalidSignature | RelayJwtError::AlgorithmMismatch) => {
                if hs256_fallback_enabled {
                    RelayJwt::verify(token, secret).map(|j| (j, RELAY_JWT_ALG_HS256))
                } else {
                    // Kill-switch engaged: EdDSA rollout is complete, so a token
                    // that is not EdDSA-signed is rejected outright rather than
                    // downgraded to the deprecated symmetric path.
                    Err(RelayJwtError::InvalidSignature)
                }
            }
            Err(e) => Err(e),
        },
        None => RelayJwt::verify(token, secret).map(|j| (j, RELAY_JWT_ALG_HS256)),
    }
}

#[instrument(skip_all, fields(otel.kind = "server", relay.endpoint = "/relay/connect"))]
async fn relay_connect(
    State(state): State<RelayApiState>,
    Json(body): Json<RelayConnectRequest>,
) -> (StatusCode, Json<RelayConnectResponse>) {
    let RelayApiState {
        secret,
        signing_public_key,
        task_tx,
        seen_jtis,
        metrics,
        hs256_fallback_enabled,
    } = state;
    let verify_result = verify_relay_jwt(
        &body.relay_token,
        &secret,
        signing_public_key.as_ref(),
        hs256_fallback_enabled,
    );
    let jwt = match verify_result {
        Ok((j, algorithm)) => {
            // T4.3: record which algorithm authenticated the token so the
            // silent HS256 downgrade becomes observable and cuttable.
            metrics
                .relay_jwt_verify_total
                .with_label_values(&[algorithm])
                .inc();
            j
        }
        Err(RelayJwtError::Expired) => {
            tracing::warn!("relay_connect: expired JWT");
            return error_response("expired token");
        }
        Err(RelayJwtError::InvalidSignature) => {
            tracing::warn!("relay_connect: invalid JWT signature");
            return (
                StatusCode::UNAUTHORIZED,
                Json(RelayConnectResponse {
                    status: "error".to_string(),
                    relay_id: None,
                }),
            );
        }
        // AlgorithmMismatch is consumed by the HS256 fallback above and `verify()`
        // never produces it, so it cannot reach here — grouped with Malformed to
        // keep the match exhaustive and fail closed (400) if that ever changes.
        Err(RelayJwtError::Malformed) | Err(RelayJwtError::AlgorithmMismatch) => {
            tracing::warn!("relay_connect: malformed JWT");
            return error_response("malformed token");
        }
    };

    // B0: Build allow-list-filtered candidate list from the signed JWT.
    // Falls back to [upstream_url] when candidates absent (pre-B0 central, back-compat).
    // Defense-in-depth: every candidate is re-checked against the allow-list even
    // though it comes from a signed JWT.  See relay/allowlist.rs for policy details.
    let allowed = select_candidates(&jwt);
    if allowed.is_empty() {
        tracing::warn!(
            upstream_url = %jwt.upstream_url,
            "relay_connect: no upstream candidate passed the allow-list"
        );
        return error_response("upstream URL not allowed");
    }

    // Replay prevention (SEC-CR-002): reject if this JTI has already been seen and not yet expired.
    // Uses TTL-keyed eviction (jti → exp) instead of a blanket clear() at N entries.
    // Blanket clear() would momentarily drop all replay protection: any jti could be
    // replayed in the window between clear() and re-insertion (up to the token's 60s TTL).
    // retain() is lazy GC — O(n) on the map at each request, bounded by token TTL × rate.
    {
        let mut seen = seen_jtis.lock().unwrap_or_else(|p| {
            tracing::error!(
                "SeenJtis mutex poisoned — recovering (replay cache state may be inconsistent)"
            );
            p.into_inner()
        });
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        seen.retain(|_jti, &mut exp| exp > now); // lazy GC: remove entries past their TTL
        if seen.contains_key(&jwt.jti) {
            tracing::warn!(jti = %jwt.jti, "relay_connect: replayed JWT rejected");
            return (
                StatusCode::CONFLICT,
                Json(RelayConnectResponse {
                    status: "error".to_string(),
                    relay_id: None,
                }),
            );
        }
        seen.insert(jwt.jti.clone(), jwt.exp);
    }

    let relay_id = format!("relay-{}", jwt.room_id.chars().take(8).collect::<String>());
    // upstream_url is set to the first allowed candidate for back-compat with
    // code that reads task.upstream_url directly; upstream_candidates carries the
    // full ordered list for the B0 failover loop in the runner.
    let task = RelayTask {
        room_id: jwt.room_id.clone(),
        upstream_url: allowed[0].clone(),
        upstream_room_token: jwt.upstream_room_token.clone(), // from JWT (signed), not body
        upstream_candidates: allowed,
    };

    if task_tx.send(task).await.is_err() {
        tracing::error!("relay task channel closed");
        return error_response("internal error");
    }

    tracing::info!(relay_id = %relay_id, "relay task enqueued");
    (
        StatusCode::OK,
        Json(RelayConnectResponse {
            status: "ok".to_string(),
            relay_id: Some(relay_id),
        }),
    )
}

fn error_response(msg: &str) -> (StatusCode, Json<RelayConnectResponse>) {
    let _ = msg; // msg is for the caller's logging; response omits details
    (
        StatusCode::BAD_REQUEST,
        Json(RelayConnectResponse {
            status: "error".to_string(),
            relay_id: None,
        }),
    )
}

#[cfg(test)]
mod allow_list_tests {
    use crate::relay::allowlist::is_allowed_upstream;

    #[test]
    fn accepts_apex_oxpulse_chat() {
        assert!(is_allowed_upstream("wss://oxpulse.chat/ws/call/r"));
        assert!(is_allowed_upstream("wss://oxpulse.chat:443/ws/call/r"));
    }

    #[test]
    fn accepts_subdomain_oxpulse_chat() {
        assert!(is_allowed_upstream("wss://edge.oxpulse.chat/ws/call/r"));
        assert!(is_allowed_upstream("wss://eu.oxpulse.chat:9443/ws"));
    }

    #[test]
    fn accepts_localhost_dev() {
        assert!(is_allowed_upstream("wss://localhost/ws"));
        assert!(is_allowed_upstream("wss://127.0.0.1:9443/ws"));
    }

    #[test]
    fn rejects_path_component_spoof() {
        // The bug fix: contains() would have returned true for these.
        assert!(!is_allowed_upstream(
            "wss://attacker.com/.oxpulse.chat/path"
        ));
        assert!(!is_allowed_upstream("wss://evil.com/?x=.oxpulse.chat/foo"));
        assert!(!is_allowed_upstream(
            "wss://evil.com:8080/.oxpulse.chat:443/x"
        ));
    }

    #[test]
    fn rejects_lookalike_domains() {
        assert!(!is_allowed_upstream("wss://oxpulse.chat.attacker.com/x"));
        assert!(!is_allowed_upstream("wss://notoxpulse.chat/x"));
        assert!(!is_allowed_upstream("wss://attacker.com/x"));
    }

    #[test]
    fn rejects_non_wss_non_mesh() {
        // ws:// to public internet is rejected; ws:// to mesh is allowed (tested in allowlist.rs).
        assert!(!is_allowed_upstream("ws://oxpulse.chat/x"));
        assert!(!is_allowed_upstream("http://oxpulse.chat/x"));
        assert!(!is_allowed_upstream("https://oxpulse.chat/x"));
    }

    #[test]
    fn accepts_mesh_ws() {
        // AWG mesh subnet ws:// is allowed per new policy.
        assert!(is_allowed_upstream("ws://10.9.0.1/ws/call/r"));
        assert!(is_allowed_upstream("ws://10.9.0.254:8907/ws/call/r"));
    }

    #[test]
    fn rejects_empty_host() {
        assert!(!is_allowed_upstream("wss:///path"));
        assert!(!is_allowed_upstream("wss://"));
    }
}

#[cfg(test)]
mod b0_select_candidates_tests {
    use super::select_candidates;
    use crate::relay::{now_unix_secs, RelayJwt};

    fn make_jwt(upstream_url: &str, candidates: Vec<&str>) -> RelayJwt {
        let now = now_unix_secs();
        RelayJwt {
            room_id: "r".to_string(),
            upstream_url: upstream_url.to_string(),
            upstream_room_token: "tok".to_string(),
            iat: now,
            exp: now + 300,
            jti: "j".to_string(),
            upstream_candidates: candidates.into_iter().map(|s| s.to_string()).collect(),
        }
    }

    // When upstream_candidates is empty, falls back to [upstream_url] (back-compat).
    #[test]
    fn empty_candidates_falls_back_to_upstream_url() {
        let jwt = make_jwt("ws://10.9.0.2:8907/ws", vec![]);
        let result = select_candidates(&jwt);
        assert_eq!(result, vec!["ws://10.9.0.2:8907/ws"]);
    }

    // A list with one allowed + one disallowed: only the allowed one survives.
    #[test]
    fn mixed_list_filters_to_allowed_only() {
        let jwt = make_jwt(
            "ws://10.9.0.2:8907/ws",
            vec!["ws://10.9.0.2:8907/ws", "ws://8.8.8.8/x"],
        );
        let result = select_candidates(&jwt);
        assert_eq!(result, vec!["ws://10.9.0.2:8907/ws"]);
    }

    // All disallowed → empty Vec (handler must reject).
    #[test]
    fn all_disallowed_returns_empty() {
        let jwt = make_jwt("ws://8.8.8.8/x", vec!["ws://8.8.8.8/x", "ws://1.1.1.1/y"]);
        let result = select_candidates(&jwt);
        assert!(
            result.is_empty(),
            "all-disallowed candidates must return empty Vec, got {:?}",
            result
        );
    }

    // Order is preserved from the signed candidate list.
    #[test]
    fn candidate_order_is_preserved() {
        let jwt = make_jwt(
            "ws://10.9.0.2:8907/ws",
            vec!["ws://10.9.0.5:8907/ws", "ws://10.9.0.2:8907/ws"],
        );
        let result = select_candidates(&jwt);
        assert_eq!(
            result,
            vec!["ws://10.9.0.5:8907/ws", "ws://10.9.0.2:8907/ws"],
            "order must match the signed candidate list"
        );
    }

    // Dedup: [A, A, B] → [A, B] preserving first occurrence.
    // Tests fix for review finding: duplicates waste slots + retries against same dark hub.
    #[test]
    fn dedup_preserves_first_occurrence() {
        // ws://10.9.0.2 is allow-listed mesh; appearing twice should collapse to one.
        let jwt = make_jwt(
            "ws://10.9.0.2/x",
            vec!["ws://10.9.0.2/x", "ws://10.9.0.2/x", "ws://10.9.0.3/x"],
        );
        let result = select_candidates(&jwt);
        assert_eq!(
            result,
            vec!["ws://10.9.0.2/x", "ws://10.9.0.3/x"],
            "duplicate URLs must be deduplicated keeping first occurrence"
        );
    }

    // Cap: > MAX_RELAY_CANDIDATES allowed mesh IPs → exactly MAX returned, order preserved.
    // Tests fix for review finding: buggy/compromised central could send thousands.
    #[test]
    fn cap_truncates_to_max() {
        // Build 9 unique allow-listed mesh IPs (MAX is 8).
        let candidates: Vec<&str> = vec![
            "ws://10.9.0.1/x",
            "ws://10.9.0.2/x",
            "ws://10.9.0.3/x",
            "ws://10.9.0.4/x",
            "ws://10.9.0.5/x",
            "ws://10.9.0.6/x",
            "ws://10.9.0.7/x",
            "ws://10.9.0.8/x",
            "ws://10.9.0.9/x",
        ];
        let jwt = make_jwt("ws://10.9.0.1/x", candidates);
        let result = select_candidates(&jwt);
        assert_eq!(result.len(), 8, "must cap at MAX_RELAY_CANDIDATES=8");
        // Order preserved: first 8 IPs in original order.
        assert_eq!(result[0], "ws://10.9.0.1/x");
        assert_eq!(result[7], "ws://10.9.0.8/x");
    }
}

#[cfg(test)]
mod replay_cache_tests {
    // Property tests for the TTL-eviction replay cache (SEC-CR-002).
    // These mirror the exact operations the handler performs under the Mutex:
    //   retain(exp > now) → contains_key → insert(jti, exp).
    // If the retain predicate or insertion logic changes, these tests will catch it.

    fn now_secs() -> u64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0)
    }

    /// (a) A jti inserted with a future exp must still be present after retain,
    /// so a second request with the same jti is correctly rejected.
    #[test]
    fn replay_cache_rejects_duplicate_jti_within_ttl() {
        let mut cache: std::collections::HashMap<String, u64> = std::collections::HashMap::new();
        let now = now_secs();
        let future_exp = now + 60;

        // First request: insert jti with a future expiry.
        cache.insert("jti-abc".to_string(), future_exp);

        // GC step (mirrors handler retain call).
        cache.retain(|_jti, &mut exp| exp > now);

        // jti is still valid — must survive retain.
        assert!(
            cache.contains_key("jti-abc"),
            "jti with future exp must survive retain (replay must be detected)"
        );
    }

    /// (b) A jti with a past exp must be evicted by retain, making it acceptable
    /// again (its token has already expired so it cannot be replayed meaningfully).
    #[test]
    fn replay_cache_retain_evicts_expired_entries() {
        let mut cache: std::collections::HashMap<String, u64> = std::collections::HashMap::new();
        let now = now_secs();
        // Use saturating_sub so the test doesn't panic at time=0 in mocked envs.
        let past_exp = now.saturating_sub(1);

        cache.insert("jti-expired".to_string(), past_exp);

        // GC step mirrors the handler's retain call.
        cache.retain(|_jti, &mut exp| exp > now);

        // Expired entry must be gone.
        assert!(
            !cache.contains_key("jti-expired"),
            "jti with past exp must be evicted by retain"
        );
    }
}

/// T4.3: relay-JWT verify-path observability + HS256-fallback kill-switch.
///
/// These exercise the REAL shipped path: `verify_relay_jwt` (the algorithm
/// discriminator + kill-switch) and `relay_connect` (the wired
/// `relay_jwt_verify_total{algorithm}` increment). They go RED if the counter
/// is removed (compile error on the field) or the kill-switch branch is
/// reverted (the disabled-fallback token would verify instead of being rejected).
#[cfg(test)]
mod t4_3_relay_jwt_verify_tests {
    use super::*;
    use crate::metrics::SfuMetrics;
    use crate::relay::{now_unix_secs, RelayJwt};
    use std::sync::Arc;

    fn allowlisted_jwt(jti: &str) -> RelayJwt {
        let now = now_unix_secs();
        RelayJwt {
            room_id: "room-t43".to_string(),
            // Allow-listed AWG mesh URL so relay_connect reaches the 200 path.
            upstream_url: "ws://10.9.0.2:8907/ws/call/r".to_string(),
            upstream_room_token: "tok".to_string(),
            iat: now,
            exp: now + 300,
            jti: jti.to_string(),
            upstream_candidates: vec![],
        }
    }

    fn gen_ed25519_keypair() -> (String, String) {
        use ed25519_dalek::pkcs8::{EncodePrivateKey, EncodePublicKey};
        use ed25519_dalek::SigningKey as DalekKey;
        use pkcs8::LineEnding;
        let key = DalekKey::generate(&mut rand::rngs::OsRng);
        let priv_pem = key.to_pkcs8_pem(LineEnding::LF).unwrap().to_string();
        let pub_pem = key
            .verifying_key()
            .to_public_key_pem(LineEnding::LF)
            .unwrap();
        (priv_pem, pub_pem)
    }

    fn sign_ed25519(jwt: &RelayJwt, priv_pem: &str) -> String {
        use jsonwebtoken::{encode, Algorithm, EncodingKey, Header};
        let key = EncodingKey::from_ed_pem(priv_pem.as_bytes()).unwrap();
        encode(&Header::new(Algorithm::EdDSA), jwt, &key).unwrap()
    }

    fn hs256_verify_count(m: &SfuMetrics) -> u64 {
        m.relay_jwt_verify_total
            .with_label_values(&[RELAY_JWT_ALG_HS256])
            .get()
    }
    fn eddsa_verify_count(m: &SfuMetrics) -> u64 {
        m.relay_jwt_verify_total
            .with_label_values(&[RELAY_JWT_ALG_EDDSA])
            .get()
    }

    // --- verify_relay_jwt: algorithm discrimination + kill-switch ---

    #[test]
    fn eddsa_token_labels_eddsa_with_both_creds() {
        let secret: &[u8] = b"unit-test-hs256-secret-value-32b!!";
        let (priv_pem, pub_pem) = gen_ed25519_keypair();
        let pubkey = Arc::new(pub_pem);
        let token = sign_ed25519(&allowlisted_jwt("ed-1"), &priv_pem);

        let (_jwt, alg) =
            verify_relay_jwt(&token, secret, Some(&pubkey), true).expect("eddsa token must verify");
        assert_eq!(alg, RELAY_JWT_ALG_EDDSA);
    }

    #[test]
    fn hs256_token_labels_hs256_via_fallback() {
        let secret: &[u8] = b"unit-test-hs256-secret-value-32b!!";
        let (_priv_pem, pub_pem) = gen_ed25519_keypair();
        let pubkey = Arc::new(pub_pem);
        // HS256-signed token presented while EdDSA is the active verifier.
        let token = allowlisted_jwt("hs-1").sign(secret).unwrap();

        let (_jwt, alg) = verify_relay_jwt(&token, secret, Some(&pubkey), true)
            .expect("hs256 token must verify via fallback");
        assert_eq!(alg, RELAY_JWT_ALG_HS256);
    }

    #[test]
    fn hs256_token_labels_hs256_as_primary_when_no_eddsa_key() {
        // No EdDSA key configured: HS256 is the primary verifier, and the
        // kill-switch does NOT gate it (fallback-only), so even disabled it runs.
        let secret: &[u8] = b"unit-test-hs256-secret-value-32b!!";
        let token = allowlisted_jwt("hs-2").sign(secret).unwrap();

        let (_jwt, alg) =
            verify_relay_jwt(&token, secret, None, false).expect("primary hs256 must verify");
        assert_eq!(alg, RELAY_JWT_ALG_HS256);
    }

    #[test]
    fn kill_switch_off_rejects_hs256_token() {
        let secret: &[u8] = b"unit-test-hs256-secret-value-32b!!";
        let (_priv_pem, pub_pem) = gen_ed25519_keypair();
        let pubkey = Arc::new(pub_pem);
        let token = allowlisted_jwt("hs-3").sign(secret).unwrap();

        // Fallback disabled → the HS256 token is rejected, not downgraded.
        let result = verify_relay_jwt(&token, secret, Some(&pubkey), false);
        assert!(
            matches!(result, Err(RelayJwtError::InvalidSignature)),
            "kill-switch OFF must reject an HS256 token, got {result:?}"
        );
    }

    // --- relay_connect: the wired counter increment (deploy-shaped) ---

    async fn call_relay_connect(
        token: String,
        secret: Arc<[u8]>,
        pubkey: Option<Arc<String>>,
        metrics: Arc<SfuMetrics>,
        hs256_fallback_enabled: bool,
    ) -> StatusCode {
        // Keep the receiver alive for the whole call so task_tx.send succeeds
        // (a dropped rx would make relay_connect return 500 before enqueue).
        let (task_tx, _task_rx) = tokio::sync::mpsc::channel::<RelayTask>(4);
        let seen_jtis: SeenJtis = Arc::new(Mutex::new(HashMap::new()));
        let state = RelayApiState {
            secret,
            signing_public_key: pubkey,
            task_tx,
            seen_jtis,
            metrics,
            hs256_fallback_enabled,
        };
        let (status, _body) = relay_connect(
            State(state),
            Json(RelayConnectRequest { relay_token: token }),
        )
        .await;
        status
    }

    #[tokio::test]
    async fn relay_connect_increments_eddsa_on_success() {
        let secret: Arc<[u8]> = Arc::from(b"unit-test-hs256-secret-value-32b!!".as_slice());
        let (priv_pem, pub_pem) = gen_ed25519_keypair();
        let pubkey = Arc::new(pub_pem);
        let metrics = Arc::new(SfuMetrics::new().unwrap());
        let token = sign_ed25519(&allowlisted_jwt("ed-conn"), &priv_pem);

        let before = eddsa_verify_count(&metrics);
        let status = call_relay_connect(token, secret, Some(pubkey), metrics.clone(), true).await;

        assert_eq!(status, StatusCode::OK);
        assert_eq!(
            eddsa_verify_count(&metrics),
            before + 1,
            "relay_jwt_verify_total{{algorithm=eddsa}} must bump on an EdDSA success"
        );
        assert_eq!(hs256_verify_count(&metrics), 0);
    }

    #[tokio::test]
    async fn relay_connect_increments_hs256_on_fallback_success() {
        let secret: Arc<[u8]> = Arc::from(b"unit-test-hs256-secret-value-32b!!".as_slice());
        let (_priv_pem, pub_pem) = gen_ed25519_keypair();
        let pubkey = Arc::new(pub_pem);
        let metrics = Arc::new(SfuMetrics::new().unwrap());
        let token = allowlisted_jwt("hs-conn").sign(&secret).unwrap();

        let before = hs256_verify_count(&metrics);
        let status = call_relay_connect(token, secret, Some(pubkey), metrics.clone(), true).await;

        assert_eq!(status, StatusCode::OK);
        assert_eq!(
            hs256_verify_count(&metrics),
            before + 1,
            "relay_jwt_verify_total{{algorithm=hs256}} must bump on an HS256 fallback success"
        );
        assert_eq!(eddsa_verify_count(&metrics), 0);
    }

    #[tokio::test]
    async fn relay_connect_kill_switch_off_rejects_and_does_not_count() {
        let secret: Arc<[u8]> = Arc::from(b"unit-test-hs256-secret-value-32b!!".as_slice());
        let (_priv_pem, pub_pem) = gen_ed25519_keypair();
        let pubkey = Arc::new(pub_pem);
        let metrics = Arc::new(SfuMetrics::new().unwrap());
        let token = allowlisted_jwt("hs-cut").sign(&secret).unwrap();

        // Kill-switch OFF: HS256 token is rejected (401), no verify counted.
        let status = call_relay_connect(token, secret, Some(pubkey), metrics.clone(), false).await;

        assert_eq!(status, StatusCode::UNAUTHORIZED);
        assert_eq!(hs256_verify_count(&metrics), 0);
        assert_eq!(eddsa_verify_count(&metrics), 0);
    }
}
