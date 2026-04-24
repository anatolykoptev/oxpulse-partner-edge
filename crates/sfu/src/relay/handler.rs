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

/// Allow-list: upstream must be a wss:// URL on a trusted domain.
/// Prevents SSRF even if JWT is somehow forged.
fn is_allowed_upstream(url: &str) -> bool {
    url.starts_with("wss://")
        && (url.contains(".oxpulse.chat/")
            || url.contains(".oxpulse.chat:")
            // Allow local/dev for testing — remove in production hardening
            || url.starts_with("wss://localhost")
            || url.starts_with("wss://127."))
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
    // Prefer Ed25519 if public key is configured; fall back to HS256 shared secret.
    let verify_result = if let Some(pubkey) = &signing_public_key {
        RelayJwt::verify_ed25519(&body.relay_token, pubkey)
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
