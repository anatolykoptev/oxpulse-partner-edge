//! Axum HTTP handler for the relay API.

use std::sync::Arc;

use axum::{extract::State, http::StatusCode, routing::post, Json, Router};
use tokio::net::TcpListener;
use tokio::sync::mpsc::Sender;
use tracing::instrument;

use crate::relay::task::RelayTask;
use crate::relay::types::{RelayConnectRequest, RelayConnectResponse};
use crate::relay::{now_unix_secs, RelayJwt, RelayJwtError};

type AppState = (Arc<[u8]>, Sender<RelayTask>);

/// Spawn the relay API HTTP server on the given `listener`.
pub fn spawn_relay_api(
    listener: TcpListener,
    secret: Arc<[u8]>,
    task_tx: Sender<RelayTask>,
) -> anyhow::Result<tokio::task::JoinHandle<()>> {
    let app = Router::new()
        .route("/relay/connect", post(relay_connect))
        .with_state((secret, task_tx));
    let handle = tokio::spawn(async move {
        axum::serve(listener, app)
            .await
            .unwrap_or_else(|e| tracing::error!(error = %e, "relay API server error"));
    });
    Ok(handle)
}

#[instrument(skip_all)]
async fn relay_connect(
    State((secret, task_tx)): State<AppState>,
    Json(body): Json<RelayConnectRequest>,
) -> (StatusCode, Json<RelayConnectResponse>) {
    let now = now_unix_secs();
    let jwt = match RelayJwt::verify(&body.relay_token, &secret, now) {
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

    let relay_id = format!("relay-{}", &jwt.room_id[..8.min(jwt.room_id.len())]);
    let task = RelayTask {
        room_id: jwt.room_id,
        upstream_url: body.upstream_url,
        upstream_room_token: body.upstream_room_token,
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
