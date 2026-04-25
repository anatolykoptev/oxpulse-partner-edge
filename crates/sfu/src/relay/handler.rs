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

/// Allow-list: upstream must be a wss:// URL on a trusted host.
/// Prevents SSRF even if JWT is somehow forged or RELAY_JWT_SECRET leaks.
///
/// Extracts the hostname strictly (before first `/` or `:`) and matches
/// against an allow-list. Rejects path-component spoofs like
/// `wss://attacker.com/.oxpulse.chat/foo` that a naive `contains()`
/// check would let through.
fn is_allowed_upstream(url: &str) -> bool {
    let Some(rest) = url.strip_prefix("wss://") else {
        return false;
    };
    let host = rest.split(['/', ':']).next().unwrap_or("");
    if host.is_empty() {
        return false;
    }
    const ALLOWED: &[&str] = &[".oxpulse.chat", "localhost", "127.0.0.1", "::1"];
    ALLOWED.iter().any(|&pattern| {
        if let Some(suffix) = pattern.strip_prefix('.') {
            // suffix-match `.oxpulse.chat` matches `oxpulse.chat` and `*.oxpulse.chat`
            host == suffix || host.ends_with(pattern)
        } else {
            host == pattern
        }
    })
}

#[cfg(test)]
mod allow_list_tests {
    use super::is_allowed_upstream;

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
        assert!(!is_allowed_upstream("wss://attacker.com/.oxpulse.chat/path"));
        assert!(!is_allowed_upstream("wss://evil.com/?x=.oxpulse.chat/foo"));
        assert!(!is_allowed_upstream("wss://evil.com:8080/.oxpulse.chat:443/x"));
    }

    #[test]
    fn rejects_lookalike_domains() {
        assert!(!is_allowed_upstream("wss://oxpulse.chat.attacker.com/x"));
        assert!(!is_allowed_upstream("wss://notoxpulse.chat/x"));
        assert!(!is_allowed_upstream("wss://attacker.com/x"));
    }

    #[test]
    fn rejects_non_wss() {
        assert!(!is_allowed_upstream("ws://oxpulse.chat/x"));
        assert!(!is_allowed_upstream("http://oxpulse.chat/x"));
        assert!(!is_allowed_upstream("https://oxpulse.chat/x"));
    }

    #[test]
    fn rejects_empty_host() {
        assert!(!is_allowed_upstream("wss:///path"));
        assert!(!is_allowed_upstream("wss://"));
    }
}

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

#[instrument(skip_all)]
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
            Err(RelayJwtError::InvalidSignature) => {
                RelayJwt::verify(&body.relay_token, &secret)
            }
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

    // Defense-in-depth: validate upstream URL against allow-list even though
    // it comes from a signed JWT.
    if !is_allowed_upstream(&jwt.upstream_url) {
        tracing::warn!(upstream_url = %jwt.upstream_url, "relay_connect: upstream URL not in allow-list");
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
    let task = RelayTask {
        room_id: jwt.room_id.clone(),
        upstream_url: jwt.upstream_url.clone(), // from JWT (signed), not body
        upstream_room_token: jwt.upstream_room_token.clone(), // from JWT (signed), not body
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
