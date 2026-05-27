//! Axum HTTP handler for the relay API.

use std::collections::HashSet;
use std::sync::{Arc, Mutex};

use axum::{extract::State, http::StatusCode, routing::post, Json, Router};
use tokio::net::TcpListener;
use tokio::sync::mpsc::Sender;
use tracing::instrument;

use crate::relay::task::RelayTask;
use crate::relay::types::{RelayConnectRequest, RelayConnectResponse};
use crate::relay::{RelayJwt, RelayJwtError};

pub type SeenJtis = Arc<Mutex<HashSet<String>>>;

/// `(hs256_secret, signing_public_key, task_tx, seen_jtis)`
/// `signing_public_key` is `Some` when SFU_SIGNING_PUBLIC_KEY is configured (Ed25519 preferred).
/// When `None`, falls back to HS256 via `hs256_secret` (deprecated path).
type AppState = (Arc<[u8]>, Option<Arc<String>>, Sender<RelayTask>, SeenJtis);

/// Spawn the relay API HTTP server on the given `listener`.
pub fn spawn_relay_api(
    listener: TcpListener,
    secret: Arc<[u8]>,
    signing_public_key: Option<Arc<String>>,
    task_tx: Sender<RelayTask>,
    seen_jtis: SeenJtis,
) -> anyhow::Result<tokio::task::JoinHandle<()>> {
    let app = Router::new()
        .route("/relay/connect", post(relay_connect))
        .with_state((secret, signing_public_key, task_tx, seen_jtis));
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

#[instrument(skip_all, fields(otel.kind = "server", relay.endpoint = "/relay/connect"))]
async fn relay_connect(
    State((secret, signing_public_key, task_tx, seen_jtis)): State<AppState>,
    Json(body): Json<RelayConnectRequest>,
) -> (StatusCode, Json<RelayConnectResponse>) {
    // Prefer Ed25519 if public key is configured; fall back to HS256 shared secret
    // ONLY when the EdDSA path returns InvalidSignature (i.e. the sender did not
    // sign with EdDSA). This keeps both EdDSA-capable and HS256-only senders
    // interoperable during rollout while preserving the strictness of the
    // Expired/Malformed paths — an expired EdDSA token is rejected outright,
    // not re-checked under HS256 (which could otherwise mask clock skew
    // discrepancies between the two verifiers).
    let verify_result = if let Some(pubkey) = &signing_public_key {
        match RelayJwt::verify_ed25519(&body.relay_token, pubkey) {
            Ok(j) => Ok(j),
            Err(RelayJwtError::InvalidSignature) => RelayJwt::verify(&body.relay_token, &secret),
            Err(e) => Err(e),
        }
    } else {
        RelayJwt::verify(&body.relay_token, &secret)
    };
    let jwt = match verify_result {
        Ok(j) => j,
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
        Err(RelayJwtError::Malformed) => {
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

    // Replay prevention: reject if this JTI has already been seen.
    {
        let mut seen = seen_jtis.lock().unwrap_or_else(|p| {
            tracing::error!(
                "SeenJtis mutex poisoned — recovering (replay cache state may be inconsistent)"
            );
            p.into_inner()
        });
        if seen.contains(&jwt.jti) {
            tracing::warn!(jti = %jwt.jti, "relay_connect: replayed JWT rejected");
            return (
                StatusCode::CONFLICT,
                Json(RelayConnectResponse {
                    status: "error".to_string(),
                    relay_id: None,
                }),
            );
        }
        seen.insert(jwt.jti.clone());
        // Simple bounded eviction: TTL is 60s, set won't grow unbounded in practice.
        if seen.len() > 1000 {
            seen.clear();
        }
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
