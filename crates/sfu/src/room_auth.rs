//! Room token verification -- validates JWTs issued by oxpulse-chat signaling.
//!
//! The signaling server (oxpulse-chat) mints tokens with:
//!   claims: { sub: u64 (peer_id), room: String, iat: u64, exp: u64 }
//!   alg:    HS256 (legacy) or EdDSA (Phase 2 preferred)
//!   secret: SIGNALING_SFU_SECRET env var (HS256) or SFU_SIGNING_PUBLIC_KEY (EdDSA)
//!
//! The SFU verifies these tokens before promoting any DataChannel peer to
//! ClientOrigin::RelayFromSfu status, and (Phase 7 M4.A1+) before upgrading any
//! browser WebSocket at `/sfu/ws/{room_id}`. The same secret must be set on both
//! the signaling server (as SIGNALING_SFU_SECRET) and the SFU (same var).
//!
//! Architectural note: the SFU binary has no WebSocket signaling server --
//! it is pure UDP (WebRTC media) + relay HTTP API + (M4.A1) client_ws upgrade
//! endpoint. Room-token verification at join time as described in CRITICAL-3
//! is therefore not applicable here; the gap exists at the signaling layer
//! (oxpulse-chat). What IS actionable in this crate is gating the DataChannel
//! relay_source privilege escalation behind a verified token, and gating
//! browser WS upgrades the same way.

use jsonwebtoken::{decode, Algorithm, DecodingKey, Validation};
use serde::{Deserialize, Serialize};

/// Claims contained in a room token issued by oxpulse-chat.
///
/// Field names MUST match signaling wire contract exactly:
///   - sub  -> peer_id (u64); signaling encodes peer_id under "sub"
///   - room -> room ID string
///   - iat  -> issued-at (Unix seconds)
///   - exp  -> expiry (Unix seconds); validated automatically by jsonwebtoken
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RoomClaims {
    /// Peer ID assigned by signaling. Encoded as "sub" per signaling wire contract.
    pub sub: u64,
    /// Room ID this token grants access to.
    pub room: String,
    /// Issued-at (Unix seconds).
    pub iat: u64,
    /// Expiry (Unix seconds). Validated automatically by jsonwebtoken.
    pub exp: u64,
}

/// Error returned when token verification fails.
///
/// Phase 7 M4.A2 split the prior coarse `Invalid` variant into three granular
/// kinds so callers can implement strict EdDSA-with-HS256-fallback rules
/// (mirroring `relay::RelayJwtError`): only `InvalidSignature` should ever
/// trigger an HS256 fallback after an EdDSA failure; `Expired` and `Malformed`
/// must propagate immediately to avoid masking clock-skew or forgery attempts.
#[derive(Debug, thiserror::Error)]
pub enum RoomAuthError {
    /// JWT decode reached the signature step and the signature did not verify
    /// against the supplied key. Includes wrong-secret and wrong-algorithm
    /// cases (an HS256-signed token presented to an EdDSA verifier maps here).
    #[error("invalid room token signature")]
    InvalidSignature,
    /// JWT was syntactically well-formed and signed correctly, but its `exp`
    /// claim is in the past.
    #[error("expired room token")]
    Expired,
    /// JWT could not be parsed (missing parts, invalid base64, claims missing
    /// required fields, key PEM malformed). Caller should NOT fall through to
    /// alternative algorithms — a malformed token is a malformed token.
    #[error("malformed room token")]
    Malformed,
    /// Signature and expiry both passed, but the `room` claim does not match
    /// the path/request room. This is a definitive verdict — do not retry
    /// under another algorithm.
    #[error("token is for room {token_room}, not {request_room}")]
    RoomMismatch {
        token_room: String,
        request_room: String,
    },
}

/// Map a `jsonwebtoken::errors::Error` to the appropriate granular
/// `RoomAuthError` kind. Mirrors the mapping in `relay::RelayJwt::verify`.
fn map_jwt_error(e: jsonwebtoken::errors::Error) -> RoomAuthError {
    match e.kind() {
        jsonwebtoken::errors::ErrorKind::ExpiredSignature => RoomAuthError::Expired,
        jsonwebtoken::errors::ErrorKind::InvalidSignature
        | jsonwebtoken::errors::ErrorKind::InvalidAlgorithmName
        | jsonwebtoken::errors::ErrorKind::InvalidAlgorithm => RoomAuthError::InvalidSignature,
        _ => RoomAuthError::Malformed,
    }
}

/// Verify token for access to room_id using HMAC-SHA256.
///
/// Returns the verified claims on success, or `RoomAuthError` on failure.
/// `secret` must match `SIGNALING_SFU_SECRET` on the signaling server.
pub fn verify_room_token(
    token: &str,
    room_id: &str,
    secret: &[u8],
) -> Result<RoomClaims, RoomAuthError> {
    let key = DecodingKey::from_secret(secret);
    let mut validation = Validation::new(Algorithm::HS256);
    validation.validate_exp = true;
    validation.leeway = 0; // reject expired tokens without any clock-skew grace period
                           // signaling does not set all standard claims -- only validate exp
    validation.required_spec_claims = std::collections::HashSet::new();

    let claims = decode::<RoomClaims>(token, &key, &validation)
        .map(|t| t.claims)
        .map_err(map_jwt_error)?;

    if claims.room != room_id {
        return Err(RoomAuthError::RoomMismatch {
            token_room: claims.room,
            request_room: room_id.to_string(),
        });
    }

    Ok(claims)
}

/// Verify a room token signed with Ed25519 (Phase 2 replacement for HS256).
///
/// `public_key_pem` is the Ed25519 public key obtained from `/api/partner/keys`.
/// Partner-edge nodes fetch this key on startup and cache it. A failure to parse
/// the PEM is a configuration bug, not a signature problem; it maps to
/// `Malformed` so callers don't accidentally fall back to HS256 on a deploy
/// misconfiguration.
pub fn verify_room_token_ed25519(
    token: &str,
    room_id: &str,
    public_key_pem: &str,
) -> Result<RoomClaims, RoomAuthError> {
    let key = DecodingKey::from_ed_pem(public_key_pem.as_bytes())
        .map_err(|_| RoomAuthError::Malformed)?;
    let mut validation = Validation::new(Algorithm::EdDSA);
    validation.validate_exp = true;
    validation.leeway = 0;
    // signaling does not set all standard claims — only validate exp
    validation.required_spec_claims = std::collections::HashSet::new();

    let claims = decode::<RoomClaims>(token, &key, &validation)
        .map(|t| t.claims)
        .map_err(map_jwt_error)?;

    if claims.room != room_id {
        return Err(RoomAuthError::RoomMismatch {
            token_room: claims.room,
            request_room: room_id.to_string(),
        });
    }
    Ok(claims)
}

#[cfg(test)]
mod tests {
    use super::*;
    use jsonwebtoken::{encode, EncodingKey, Header};

    fn make_token(room: &str, sub: u64, secret: &[u8], exp_delta_secs: i64) -> String {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs();
        let exp = (now as i64 + exp_delta_secs).max(0) as u64;
        let claims = RoomClaims {
            sub,
            room: room.to_string(),
            iat: now,
            exp,
        };
        encode(
            &Header::default(),
            &claims,
            &EncodingKey::from_secret(secret),
        )
        .unwrap()
    }

    #[test]
    fn valid_token_accepted() {
        let secret = b"test-secret-32-bytes-long-enough!";
        let token = make_token("room-abc", 42, secret, 3600);
        let claims = verify_room_token(&token, "room-abc", secret).unwrap();
        assert_eq!(claims.sub, 42);
        assert_eq!(claims.room, "room-abc");
    }

    #[test]
    fn wrong_room_rejected() {
        let secret = b"test-secret-32-bytes-long-enough!";
        let token = make_token("room-abc", 1, secret, 3600);
        let err = verify_room_token(&token, "room-xyz", secret).unwrap_err();
        assert!(matches!(err, RoomAuthError::RoomMismatch { .. }));
    }

    #[test]
    fn expired_token_rejected() {
        let secret = b"test-secret-32-bytes-long-enough!";
        let token = make_token("room-abc", 1, secret, -10);
        assert!(matches!(
            verify_room_token(&token, "room-abc", secret),
            Err(RoomAuthError::Expired)
        ));
    }

    #[test]
    fn wrong_secret_rejected() {
        let token = make_token("room-abc", 1, b"correct-secret-32-bytes-long!!!!!", 3600);
        assert!(matches!(
            verify_room_token(&token, "room-abc", b"wrong-secret-32-bytes-long-ok!!!"),
            Err(RoomAuthError::InvalidSignature)
        ));
    }

    #[test]
    fn malformed_token_rejected() {
        assert!(matches!(
            verify_room_token("not.a.valid.jwt", "room-abc", b"any-secret"),
            Err(RoomAuthError::Malformed)
        ));
    }

    #[test]
    fn empty_token_rejected() {
        assert!(matches!(
            verify_room_token("", "room-abc", b"secret"),
            Err(RoomAuthError::Malformed)
        ));
    }

    // --- Ed25519 room token tests ---

    /// Generate a fresh Ed25519 keypair for tests.
    /// Returns `(private_key_pem, public_key_pem)`.
    fn generate_test_keypair_room() -> (String, String) {
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

    fn make_ed25519_room_token(room: &str, sub: u64, priv_pem: &str, exp_delta: i64) -> String {
        use jsonwebtoken::{encode, Algorithm, EncodingKey, Header};
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs();
        let exp = (now as i64 + exp_delta).max(0) as u64;
        let claims = RoomClaims {
            sub,
            room: room.to_string(),
            iat: now,
            exp,
        };
        let key = EncodingKey::from_ed_pem(priv_pem.as_bytes()).unwrap();
        encode(&Header::new(Algorithm::EdDSA), &claims, &key).unwrap()
    }

    #[test]
    fn verify_room_token_ed25519_accepts_valid() {
        let (priv_pem, pub_pem) = generate_test_keypair_room();
        let token = make_ed25519_room_token("room-abc", 42, &priv_pem, 3600);
        let claims = verify_room_token_ed25519(&token, "room-abc", &pub_pem).unwrap();
        assert_eq!(claims.sub, 42);
        assert_eq!(claims.room, "room-abc");
    }

    #[test]
    fn verify_room_token_ed25519_wrong_room_rejected() {
        let (priv_pem, pub_pem) = generate_test_keypair_room();
        let token = make_ed25519_room_token("room-abc", 1, &priv_pem, 3600);
        let err = verify_room_token_ed25519(&token, "room-xyz", &pub_pem).unwrap_err();
        assert!(matches!(err, RoomAuthError::RoomMismatch { .. }));
    }

    #[test]
    fn verify_room_token_ed25519_expired_rejected() {
        let (priv_pem, pub_pem) = generate_test_keypair_room();
        let token = make_ed25519_room_token("room-abc", 1, &priv_pem, -10);
        assert!(matches!(
            verify_room_token_ed25519(&token, "room-abc", &pub_pem),
            Err(RoomAuthError::Expired)
        ));
    }

    #[test]
    fn verify_room_token_ed25519_wrong_pubkey_rejected() {
        let (priv_pem, _pub1) = generate_test_keypair_room();
        let (_priv2, pub_pem2) = generate_test_keypair_room();
        let token = make_ed25519_room_token("room-abc", 1, &priv_pem, 3600);
        assert!(matches!(
            verify_room_token_ed25519(&token, "room-abc", &pub_pem2),
            Err(RoomAuthError::InvalidSignature)
        ));
    }

    #[test]
    fn verify_room_token_ed25519_hs256_token_rejected() {
        // An HS256-signed token must not be accepted by the EdDSA verifier.
        // Algorithm-mismatch failures are mapped to `InvalidSignature` so the
        // caller's EdDSA→HS256 fallback rule kicks in (see
        // `client_ws::handler::verify_token`).
        let secret = b"test-secret-32-bytes-long-enough!";
        let hs256_token = make_token("room-abc", 1, secret, 3600);
        let (_priv, pub_pem) = generate_test_keypair_room();
        assert!(matches!(
            verify_room_token_ed25519(&hs256_token, "room-abc", &pub_pem),
            Err(RoomAuthError::InvalidSignature)
        ));
    }

    #[test]
    fn verify_room_token_ed25519_malformed_pubkey_pem_returns_malformed() {
        // Configuration error (operator pasted a corrupt PEM): must NOT trigger
        // the HS256 fallback path. `Malformed` makes the caller's distinction
        // explicit.
        let token = "any.thing.here";
        let bad_pem = "-----BEGIN PUBLIC KEY-----\nnot-base64\n-----END PUBLIC KEY-----\n";
        assert!(matches!(
            verify_room_token_ed25519(token, "room-abc", bad_pem),
            Err(RoomAuthError::Malformed)
        ));
    }
}
