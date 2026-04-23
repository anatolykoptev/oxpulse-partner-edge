//! HTTP request/response types for the relay API.

use serde::{Deserialize, Serialize};

/// Body of `POST /relay/connect`.
#[derive(Debug, Serialize, Deserialize)]
pub struct RelayConnectRequest {
    /// Signed [`super::RelayJwt`] token.
    pub relay_token: String,
    /// WebSocket URL of the upstream SFU room endpoint.
    pub upstream_url: String,
    /// Room token for the upstream SFU join.
    pub upstream_room_token: String,
}

/// Response from `POST /relay/connect`.
#[derive(Debug, Serialize, Deserialize)]
pub struct RelayConnectResponse {
    /// `"ok"` on success, `"error"` on failure.
    pub status: String,
    /// Opaque relay identifier for logging. Present on success.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub relay_id: Option<String>,
}
