//! Axum handler for `/sfu/ws/{room_id}` — client-facing WebSocket endpoint.
//!
//! See [module docs](super) for the auth contract.
//!
//! M4.A1 added auth + WS upgrade.
//! M4.A2 wires the upgraded socket into [`crate::client_ws::session::run`]
//! so the SDP exchange and Registry registration happen here, then the
//! main UDP loop drives ICE/DTLS just like for relay clients.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Instant;

use crate::metrics::SfuMetrics;
use axum::{
    extract::{
        ws::{CloseCode, CloseFrame, Message, WebSocket, WebSocketUpgrade},
        Path, State,
    },
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::any,
    Router,
};
use tokio::net::TcpListener;
use tokio::sync::mpsc::Sender;
use tracing::{instrument, warn};

use crate::client_ws::session::{run as run_session, PendingClient};
use crate::room_auth::{verify_room_token, verify_room_token_ed25519, RoomAuthError, RoomClaims};

/// WS subprotocol identifier this server speaks. Browsers MUST list it in
/// `Sec-WebSocket-Protocol` and the server echoes it back.
pub const SUBPROTOCOL: &str = "oxpulse-sfu-v1";

/// WS close code returned when `claims.room` does not match the path's
/// `room_id`. Codes in 4000-4999 are reserved for application use
/// (RFC 6455 §7.4.2).
pub const CLOSE_CODE_ROOM_MISMATCH: CloseCode = 4001;

/// Upper bound for draining an application-initiated close handshake.
/// Stops a misbehaving peer from leaving the session task hanging on TCP
/// keepalive after we've sent a `Close` frame.
pub(crate) const CLOSE_DRAIN_TIMEOUT: std::time::Duration = std::time::Duration::from_millis(200);

/// Shared state for the client_ws router: HS256 secret + optional
/// Ed25519 verifier + injection channel into the registry. Cloned cheaply
/// (Arc<[u8]>, Arc<String>, Sender, SocketAddr).
#[derive(Clone)]
pub struct ClientWsState {
    /// HS256 shared secret (`SIGNALING_SFU_SECRET`).
    pub secret: Arc<[u8]>,
    /// Optional EdDSA public key PEM (`SFU_SIGNING_PUBLIC_KEY`).
    /// When present, takes precedence over HS256 with a strict fallback
    /// rule: HS256 is tried only when the EdDSA path returns
    /// `RoomAuthError::InvalidSignature` (i.e. the token was likely
    /// HS256-signed by a legacy signaling server). `Expired` and
    /// `Malformed` propagate immediately — mirrors
    /// `relay/handler.rs:relay_connect`.
    pub signing_pubkey: Option<Arc<String>>,
    /// Channel back to the main UDP loop. Once the session has built an
    /// `Rtc` and exchanged SDP with the browser, it sends a
    /// [`PendingClient`] here; `udp_loop::serve` calls
    /// `Client::new(rtc, metrics)` (origin defaults to
    /// `ClientOrigin::Local`) and `Registry::insert`.
    pub client_inject_tx: Sender<PendingClient>,
    /// Address advertised in the SFU's host candidate (`Candidate::host`)
    /// in the SDP answer. The session installs this on the `Rtc` before
    /// `accept_offer`, so the answer SDP carries it in `a=candidate`.
    ///
    /// Phase 7 M4.A6 - main.rs now computes this as `host_candidate_addr`:
    /// when `SFU_PUBLIC_IP` is set, the IP is overridden to the node's
    /// public IPv4 (port stays the kernel-bound one); otherwise it falls
    /// back to the bind address. The same value is threaded into
    /// `relay::client::connect_relay`, so cascade and browser paths emit
    /// matching candidates.
    pub local_udp_addr: SocketAddr,
    /// Process-wide SFU metrics (M4.B1 client_ws verification). Increments
    /// happen at handshake-accept, handshake-reject (per reason), and
    /// session-end inside [`crate::client_ws::session::run`].
    pub metrics: Arc<SfuMetrics>,
    /// Interval in seconds for str0m built-in stats events.
    /// 0 = disabled. Forwarded to `session::run` so each new `Rtc` is
    /// built with `RtcConfig::set_stats_interval(Some(Duration))`.
    pub stats_interval_secs: u64,
    /// Shared per-peer rate-gate clock for bwe-hint throttling.
    ///
    /// Keyed by numeric peer_id (JWT `sub`). A session writes the accepted
    /// `Instant` here; concurrent sessions for the same peer_id (steal window,
    /// duplicate tab) check this shared clock and are correctly throttled within
    /// the same HINT_MIN_INTERVAL window. BLOCKER fix: prior implementation used
    /// a task-local `last_hint: Option<Instant>`, allowing two concurrent tasks
    /// for the same peer to each accept one hint independently (2× the cap).
    pub hint_rate_registry: Arc<std::sync::Mutex<HashMap<u64, Instant>>>,
}

/// Spawn the client WS API on the given listener. Returns the join handle
/// of the background server task.
pub fn spawn_client_ws_api(
    listener: TcpListener,
    secret: Arc<[u8]>,
    signing_pubkey: Option<Arc<String>>,
    client_inject_tx: Sender<PendingClient>,
    local_udp_addr: SocketAddr,
    metrics: Arc<SfuMetrics>,
    stats_interval_secs: u64,
) -> anyhow::Result<tokio::task::JoinHandle<()>> {
    let state = ClientWsState {
        secret,
        signing_pubkey,
        client_inject_tx,
        local_udp_addr,
        metrics,
        stats_interval_secs,
        hint_rate_registry: Arc::new(std::sync::Mutex::new(HashMap::new())),
    };
    let app = Router::new()
        // axum 0.8 routes WS upgrades through `any` (the upgrade is GET
        // for HTTP/1.1 and CONNECT for HTTP/2+).
        .route("/sfu/ws/{room_id}", any(client_ws_upgrade))
        .with_state(state);
    let handle = tokio::spawn(async move {
        if let Err(e) = axum::serve(listener, app).await {
            tracing::error!(error = %e, "client_ws API server error");
        }
    });
    Ok(handle)
}

/// Extract the bearer token from the comma-separated
/// `Sec-WebSocket-Protocol` header. The browser cannot set
/// `Authorization` on a WS upgrade, so the standard pattern is to put
/// the token *inside* the subprotocol list.
///
/// Two formats accepted (order-insensitive):
/// - `bearer.<token>` — preferred. Each subprotocol value must satisfy
///   the RFC 7230 `token` grammar (no spaces, no separators), so we use
///   `.` as the literal separator. Browsers' WebSocket constructor
///   validates this client-side, and rejects values containing spaces.
/// - `Bearer <token>` — legacy form (with space). Still accepted because
///   server-to-server callers and tests pass headers directly without
///   going through the browser's strict subprotocol validation. Will be
///   removed after the client transition lands in oxpulse-chat.
///
/// Returns `None` if neither prefix is present.
fn extract_bearer_from_subprotocols(headers: &HeaderMap) -> Option<String> {
    let raw = headers.get(axum::http::header::SEC_WEBSOCKET_PROTOCOL)?;
    let raw_str = raw.to_str().ok()?;
    for part in raw_str.split(',') {
        let trimmed = part.trim();
        // Preferred form — `bearer.<token>`. RFC 7230 token-grammar safe,
        // so browsers accept it as a subprotocol value.
        if let Some(token) = trimmed.strip_prefix("bearer.") {
            if !token.is_empty() {
                return Some(token.to_string());
            }
        }
        // Legacy form — kept for back-compat during migration.
        if let Some(token) = trimmed.strip_prefix("Bearer ") {
            if !token.is_empty() {
                return Some(token.to_string());
            }
        }
    }
    None
}

/// Verify a room token against the configured auth backend(s). Mirrors
/// the strict EdDSA→HS256 fallback in `relay/handler.rs:relay_connect`:
/// only `InvalidSignature` from the EdDSA path triggers an HS256 retry;
/// `Expired` and `Malformed` propagate immediately so a forged token
/// cannot bypass exp validation by being re-checked under HS256, and a
/// malformed token cannot mask a real signature failure.
fn verify_token(
    token: &str,
    room_id: &str,
    state: &ClientWsState,
) -> Result<RoomClaims, RoomAuthError> {
    if let Some(pubkey) = &state.signing_pubkey {
        match verify_room_token_ed25519(token, room_id, pubkey) {
            Ok(c) => return Ok(c),
            // The token was probably HS256-signed by a legacy signaling
            // server; try HS256.
            Err(RoomAuthError::InvalidSignature) => {}
            // Mismatch / expired / malformed are definitive verdicts.
            Err(e) => return Err(e),
        }
    }
    verify_room_token(token, room_id, &state.secret)
}

/// HTTP handler for the WS upgrade. Returns `401` (no upgrade) on auth
/// failure, otherwise upgrades and either:
/// - on room mismatch, sends a close frame with code 4001 and drops;
/// - on success, runs the per-connection session loop (M4.A2).
#[instrument(skip(ws, headers, state), fields(room_id = %room_id))]
pub async fn client_ws_upgrade(
    ws: WebSocketUpgrade,
    Path(room_id): Path<String>,
    State(state): State<ClientWsState>,
    headers: HeaderMap,
) -> Response {
    let Some(token) = extract_bearer_from_subprotocols(&headers) else {
        warn!("client_ws: missing Bearer in Sec-WebSocket-Protocol");
        state
            .metrics
            .client_ws_handshake_failures_total
            .with_label_values(&["missing_token"])
            .inc();
        return StatusCode::UNAUTHORIZED.into_response();
    };

    let claims = match verify_token(&token, &room_id, &state) {
        Ok(c) => c,
        Err(RoomAuthError::RoomMismatch { token_room, .. }) => {
            // Signature/expiry passed but the claim's room doesn't match
            // the path. Per the M4.A1 contract, accept the upgrade then
            // close with application code 4001 — this gives the client a
            // clear "wrong room" signal as opposed to a generic 401.
            warn!(%room_id, %token_room, "client_ws: token/path room mismatch");
            state
                .metrics
                .client_ws_handshake_failures_total
                .with_label_values(&["room_mismatch"])
                .inc();
            return ws
                .protocols([SUBPROTOCOL])
                .on_upgrade(|socket| {
                    close_with_code(socket, CLOSE_CODE_ROOM_MISMATCH, "room mismatch")
                })
                .into_response();
        }
        Err(RoomAuthError::Expired) => {
            warn!(%room_id, "client_ws: expired token");
            state
                .metrics
                .client_ws_handshake_failures_total
                .with_label_values(&["expired_token"])
                .inc();
            return StatusCode::UNAUTHORIZED.into_response();
        }
        Err(RoomAuthError::InvalidSignature) | Err(RoomAuthError::Malformed) => {
            warn!(%room_id, "client_ws: invalid or malformed token");
            state
                .metrics
                .client_ws_handshake_failures_total
                .with_label_values(&["invalid_token"])
                .inc();
            return StatusCode::UNAUTHORIZED.into_response();
        }
    };

    // T9 (2026-07-01 bug-hunt, resource_exhaustion/high): admission cap.
    // The relay-dial path (`RELAY_MAX_CONCURRENT` semaphore in main.rs) was
    // already bounded; `client_ws_active_sessions` (incremented by
    // `ActiveSessionGuard` in `session::run`) was a pure gauge with no gate
    // on this browser-facing path. Checked post-auth so an unauthenticated
    // caller can't probe node capacity, and before `on_upgrade` so a
    // rejection is a real HTTP 503 (no upgrade), matching the existing
    // pre-upgrade 401 rejections above rather than an open-then-close.
    let active_sessions = state.metrics.client_ws_active_sessions.get();
    let max_participants = crate::config::max_participants();
    if active_sessions >= i64::from(max_participants) {
        warn!(
            %room_id, active_sessions, max_participants,
            "client_ws: at capacity, rejecting upgrade"
        );
        state
            .metrics
            .sfu_admission_rejected_total
            .with_label_values(&["at_capacity"])
            .inc();
        return StatusCode::SERVICE_UNAVAILABLE.into_response();
    }

    let peer_id = claims.sub;
    let inject_tx = state.client_inject_tx.clone();
    let local_udp_addr = state.local_udp_addr;
    let metrics = state.metrics.clone();
    let stats_interval_secs = state.stats_interval_secs;
    let hint_rate_registry = state.hint_rate_registry.clone();
    tracing::info!(
        target: "sfu::client_ws",
        peer_id, %room_id,
        "client_ws upgrade accepted; running M4.A2 session"
    );
    ws.protocols([SUBPROTOCOL])
        .on_upgrade(move |socket| async move {
            metrics.client_ws_sessions_started_total.inc();
            if let Err(e) = run_session(
                socket,
                room_id.clone(),
                peer_id,
                local_udp_addr,
                inject_tx,
                metrics.clone(),
                stats_interval_secs,
                hint_rate_registry,
            )
            .await
            {
                tracing::warn!(target: "sfu::client_ws", peer_id, %room_id, error = %e, "client_ws session ended with error");
            }
        })
        .into_response()
}

/// Close the upgraded WS with a custom application close code, then drain
/// any further frames the peer may send up to [`CLOSE_DRAIN_TIMEOUT`].
pub(crate) async fn close_with_code(mut socket: WebSocket, code: CloseCode, reason: &'static str) {
    let _ = socket
        .send(Message::Close(Some(CloseFrame {
            code,
            reason: reason.into(),
        })))
        .await;
    // Bound the drain so a misbehaving peer can't pin this task open via
    // TCP keepalive.
    let _ = tokio::time::timeout(CLOSE_DRAIN_TIMEOUT, async {
        while let Some(msg) = socket.recv().await {
            if matches!(msg, Ok(Message::Close(_)) | Err(_)) {
                break;
            }
        }
    })
    .await;
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::http::HeaderValue;

    #[test]
    fn extract_bearer_finds_token_at_end() {
        let mut h = HeaderMap::new();
        h.insert(
            axum::http::header::SEC_WEBSOCKET_PROTOCOL,
            HeaderValue::from_static("oxpulse-sfu-v1, Bearer eyJabc.def.ghi"),
        );
        assert_eq!(
            extract_bearer_from_subprotocols(&h).as_deref(),
            Some("eyJabc.def.ghi")
        );
    }

    #[test]
    fn extract_bearer_finds_token_at_start() {
        let mut h = HeaderMap::new();
        h.insert(
            axum::http::header::SEC_WEBSOCKET_PROTOCOL,
            HeaderValue::from_static("Bearer xyz, oxpulse-sfu-v1"),
        );
        assert_eq!(extract_bearer_from_subprotocols(&h).as_deref(), Some("xyz"));
    }

    #[test]
    fn extract_bearer_none_when_only_subprotocol() {
        let mut h = HeaderMap::new();
        h.insert(
            axum::http::header::SEC_WEBSOCKET_PROTOCOL,
            HeaderValue::from_static("oxpulse-sfu-v1"),
        );
        assert!(extract_bearer_from_subprotocols(&h).is_none());
    }

    #[test]
    fn extract_bearer_none_when_header_missing() {
        let h = HeaderMap::new();
        assert!(extract_bearer_from_subprotocols(&h).is_none());
    }

    #[test]
    fn extract_bearer_rejects_empty_token() {
        let mut h = HeaderMap::new();
        h.insert(
            axum::http::header::SEC_WEBSOCKET_PROTOCOL,
            HeaderValue::from_static("oxpulse-sfu-v1, Bearer "),
        );
        assert!(extract_bearer_from_subprotocols(&h).is_none());
    }
}
