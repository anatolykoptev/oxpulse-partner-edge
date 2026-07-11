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
    /// Additional host-candidate addresses advertised in the SDP answer
    /// alongside `local_udp_addr` (OCI-hairpin fix, 2026-07-11). Typically
    /// the node's private IP (`SFU_LOCAL_IP`) at the same UDP port, so a
    /// co-located coturn can relay client media to the SFU on private
    /// addressing where the public candidate would hairpin. Empty on nodes
    /// where the public candidate is directly reachable. See
    /// [`crate::config::SfuConfig::local_ip`].
    pub additional_host_candidates: Vec<SocketAddr>,
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
    /// T4.3 kill-switch (`SFU_RELAY_HS256_FALLBACK`) for the EdDSA→HS256 room-token
    /// fallback. When `false`, a token that fails EdDSA with `InvalidSignature`
    /// is rejected instead of being silently retried under the deprecated HS256
    /// secret. Only gates the *fallback* — when no EdDSA key is configured HS256
    /// is the primary verifier and always runs. Mirrors `relay/handler.rs`.
    pub hs256_fallback_enabled: bool,
}

/// Caller-supplied configuration for [`spawn_client_ws_api`].
///
/// A named struct rather than a 7-arg constructor so a field reorder is a
/// compile error instead of a silent same-type swap (e.g. transposing two
/// `Arc<_>` args), and so `spawn_client_ws_api` stays under the repo's
/// `>4 params → struct` trigger. This holds only the externally-provided
/// fields; `hint_rate_registry` is constructed internally by the spawn fn and
/// is therefore not part of the config. Every field maps 1:1 onto the
/// like-named [`ClientWsState`] field it populates.
pub struct ClientWsApiConfig {
    /// HS256 shared secret (`SIGNALING_SFU_SECRET`).
    pub secret: Arc<[u8]>,
    /// Optional EdDSA public key PEM (`SFU_SIGNING_PUBLIC_KEY`).
    pub signing_pubkey: Option<Arc<String>>,
    /// Channel back to the main UDP loop for accepted sessions.
    pub client_inject_tx: Sender<PendingClient>,
    /// Address advertised in the SFU host candidate in the SDP answer.
    pub local_udp_addr: SocketAddr,
    /// Additional host-candidate addresses (e.g. the private `SFU_LOCAL_IP`)
    /// advertised alongside `local_udp_addr`. OCI-hairpin fix — see the
    /// like-named [`ClientWsState`] field.
    pub additional_host_candidates: Vec<SocketAddr>,
    /// Process-wide SFU metrics.
    pub metrics: Arc<SfuMetrics>,
    /// str0m built-in stats interval (seconds; 0 = disabled).
    pub stats_interval_secs: u64,
    /// `SFU_RELAY_HS256_FALLBACK` kill-switch (T4.3).
    pub hs256_fallback_enabled: bool,
}

/// Spawn the client WS API on the given listener. Returns the join handle
/// of the background server task.
pub fn spawn_client_ws_api(
    listener: TcpListener,
    config: ClientWsApiConfig,
) -> anyhow::Result<tokio::task::JoinHandle<()>> {
    let ClientWsApiConfig {
        secret,
        signing_pubkey,
        client_inject_tx,
        local_udp_addr,
        additional_host_candidates,
        metrics,
        stats_interval_secs,
        hs256_fallback_enabled,
    } = config;
    let state = ClientWsState {
        secret,
        signing_pubkey,
        client_inject_tx,
        local_udp_addr,
        additional_host_candidates,
        metrics,
        stats_interval_secs,
        hint_rate_registry: Arc::new(std::sync::Mutex::new(HashMap::new())),
        hs256_fallback_enabled,
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
///
/// T4.3: on a fully-verified token (signature + room match) bumps
/// `relay_jwt_verify_total{algorithm}` so the silent HS256 downgrade is
/// observable, and honors the `hs256_fallback_enabled` kill-switch — when it
/// is `false` a non-EdDSA token is rejected as `InvalidSignature` instead of
/// being downgraded. The switch gates only the fallback: with no EdDSA key
/// configured HS256 is the primary verifier and always runs.
fn verify_token(
    token: &str,
    room_id: &str,
    state: &ClientWsState,
) -> Result<RoomClaims, RoomAuthError> {
    if let Some(pubkey) = &state.signing_pubkey {
        match verify_room_token_ed25519(token, room_id, pubkey) {
            Ok(c) => {
                state
                    .metrics
                    .relay_jwt_verify_total
                    .with_label_values(&[crate::metrics::RELAY_JWT_ALG_EDDSA])
                    .inc();
                return Ok(c);
            }
            // The token was probably HS256-signed by a legacy signaling
            // server; try HS256 only when the fallback is still enabled.
            Err(RoomAuthError::InvalidSignature) => {
                if !state.hs256_fallback_enabled {
                    // Kill-switch engaged: reject instead of silently
                    // downgrading to the deprecated symmetric path.
                    return Err(RoomAuthError::InvalidSignature);
                }
            }
            // Mismatch / expired / malformed are definitive verdicts.
            Err(e) => return Err(e),
        }
    }
    let claims = verify_room_token(token, room_id, &state.secret)?;
    state
        .metrics
        .relay_jwt_verify_total
        .with_label_values(&[crate::metrics::RELAY_JWT_ALG_HS256])
        .inc();
    Ok(claims)
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
    let additional_host_candidates = state.additional_host_candidates.clone();
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
                additional_host_candidates,
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

/// T4.3: room-token verify-path observability + HS256-fallback kill-switch.
///
/// Exercises the REAL shipped `verify_token` (the wired
/// `relay_jwt_verify_total{algorithm}` increment + the kill-switch branch).
/// Goes RED if the counter is removed (compile error on the field) or the
/// kill-switch branch is reverted (the disabled-fallback token would verify
/// instead of being rejected).
#[cfg(test)]
mod t4_3_client_ws_verify_tests {
    use super::*;
    use crate::metrics::{SfuMetrics, RELAY_JWT_ALG_EDDSA, RELAY_JWT_ALG_HS256};
    use crate::room_auth::RoomClaims;
    use jsonwebtoken::{encode, Algorithm, EncodingKey, Header};
    use std::time::Duration;

    const ROOM: &str = "room-t43-ws";
    const SECRET: &[u8] = b"unit-test-hs256-secret-value-32b!!";

    fn claims() -> RoomClaims {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs();
        RoomClaims {
            sub: 42,
            room: ROOM.to_string(),
            iat: now,
            exp: now + 300,
        }
    }

    fn sign_hs256() -> String {
        encode(
            &Header::new(Algorithm::HS256),
            &claims(),
            &EncodingKey::from_secret(SECRET),
        )
        .unwrap()
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

    fn sign_ed25519(priv_pem: &str) -> String {
        let key = EncodingKey::from_ed_pem(priv_pem.as_bytes()).unwrap();
        encode(&Header::new(Algorithm::EdDSA), &claims(), &key).unwrap()
    }

    fn make_state(
        signing_pubkey: Option<Arc<String>>,
        metrics: Arc<SfuMetrics>,
        hs256_fallback_enabled: bool,
    ) -> ClientWsState {
        // client_inject_tx is never touched by verify_token; a dropped rx is fine.
        let (client_inject_tx, _rx) = tokio::sync::mpsc::channel(1);
        ClientWsState {
            secret: Arc::from(SECRET),
            signing_pubkey,
            client_inject_tx,
            local_udp_addr: "127.0.0.1:0".parse().unwrap(),
            additional_host_candidates: Vec::new(),
            metrics,
            stats_interval_secs: 0,
            hint_rate_registry: Arc::new(std::sync::Mutex::new(HashMap::new())),
            hs256_fallback_enabled,
        }
    }

    fn count(m: &SfuMetrics, alg: &str) -> u64 {
        m.relay_jwt_verify_total.with_label_values(&[alg]).get()
    }

    #[test]
    fn eddsa_token_increments_eddsa_with_both_creds() {
        let metrics = Arc::new(SfuMetrics::new().unwrap());
        let (priv_pem, pub_pem) = gen_ed25519_keypair();
        let state = make_state(Some(Arc::new(pub_pem)), metrics.clone(), true);
        let token = sign_ed25519(&priv_pem);

        let claims = verify_token(&token, ROOM, &state).expect("eddsa token must verify");
        assert_eq!(claims.room, ROOM);
        assert_eq!(count(&metrics, RELAY_JWT_ALG_EDDSA), 1);
        assert_eq!(count(&metrics, RELAY_JWT_ALG_HS256), 0);
    }

    #[test]
    fn hs256_token_increments_hs256_via_fallback() {
        let metrics = Arc::new(SfuMetrics::new().unwrap());
        let (_priv_pem, pub_pem) = gen_ed25519_keypair();
        let state = make_state(Some(Arc::new(pub_pem)), metrics.clone(), true);
        let token = sign_hs256();

        let claims =
            verify_token(&token, ROOM, &state).expect("hs256 token must verify via fallback");
        assert_eq!(claims.room, ROOM);
        assert_eq!(count(&metrics, RELAY_JWT_ALG_HS256), 1);
        assert_eq!(count(&metrics, RELAY_JWT_ALG_EDDSA), 0);
    }

    #[test]
    fn hs256_token_primary_when_no_eddsa_key_ignores_kill_switch() {
        // No EdDSA key → HS256 is the primary verifier; the kill-switch is
        // fallback-only, so even disabled the primary path verifies + counts.
        let metrics = Arc::new(SfuMetrics::new().unwrap());
        let state = make_state(None, metrics.clone(), false);
        let token = sign_hs256();

        let claims = verify_token(&token, ROOM, &state).expect("primary hs256 must verify");
        assert_eq!(claims.room, ROOM);
        assert_eq!(count(&metrics, RELAY_JWT_ALG_HS256), 1);
    }

    #[test]
    fn kill_switch_off_rejects_hs256_token_and_does_not_count() {
        let metrics = Arc::new(SfuMetrics::new().unwrap());
        let (_priv_pem, pub_pem) = gen_ed25519_keypair();
        let state = make_state(Some(Arc::new(pub_pem)), metrics.clone(), false);
        let token = sign_hs256();

        let result = verify_token(&token, ROOM, &state);
        assert!(
            matches!(result, Err(RoomAuthError::InvalidSignature)),
            "kill-switch OFF must reject an HS256 token, got {result:?}"
        );
        assert_eq!(count(&metrics, RELAY_JWT_ALG_HS256), 0);
        assert_eq!(count(&metrics, RELAY_JWT_ALG_EDDSA), 0);
    }

    #[test]
    fn expired_eddsa_token_is_not_downgraded_and_not_counted() {
        // Sanity: Expired from the EdDSA path is a definitive verdict — it must
        // NOT fall through to HS256, and nothing is counted.
        let metrics = Arc::new(SfuMetrics::new().unwrap());
        let (priv_pem, pub_pem) = gen_ed25519_keypair();
        let state = make_state(Some(Arc::new(pub_pem)), metrics.clone(), true);

        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            - Duration::from_secs(600);
        let expired = RoomClaims {
            sub: 42,
            room: ROOM.to_string(),
            iat: now.as_secs(),
            exp: now.as_secs() + 60, // still in the past
        };
        let key = EncodingKey::from_ed_pem(priv_pem.as_bytes()).unwrap();
        let token = encode(&Header::new(Algorithm::EdDSA), &expired, &key).unwrap();

        let result = verify_token(&token, ROOM, &state);
        assert!(
            matches!(result, Err(RoomAuthError::Expired)),
            "got {result:?}"
        );
        assert_eq!(count(&metrics, RELAY_JWT_ALG_HS256), 0);
        assert_eq!(count(&metrics, RELAY_JWT_ALG_EDDSA), 0);
    }
}
