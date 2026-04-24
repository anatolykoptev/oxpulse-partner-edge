//! Room token verification -- validates HS256 JWTs issued by oxpulse-chat signaling.
//!
//! The signaling server (oxpulse-chat) mints tokens with:
//!   claims: { sub: u64 (peer_id), room: String, iat: u64, exp: u64 }
//!   alg:    HS256
//!   secret: SIGNALING_SFU_SECRET env var
//!
//! The SFU verifies these tokens before promoting any DataChannel peer to
//! ClientOrigin::RelayFromSfu status. The same secret must be set on both
//! the signaling server (as SIGNALING_SFU_SECRET) and the SFU (same var).
//!
//! Architectural note: the SFU binary has no WebSocket signaling server --
//! it is pure UDP (WebRTC media) + relay HTTP API. Room-token verification
//! at join time as described in CRITICAL-3 is therefore not applicable here;
//! the gap exists at the signaling layer (oxpulse-chat). What IS actionable
//! in this crate is gating the DataChannel relay_source privilege escalation
//! behind a verified token.

use jsonwebtoken::{decode, DecodingKey, Validation, Algorithm};
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
#[derive(Debug, thiserror::Error)]
pub enum RoomAuthError {
    #[error("invalid or expired room token")]
    Invalid,
    #[error("token is for room {token_room}, not {request_room}")]
    RoomMismatch {
        token_room: String,
        request_room: String,
    },
}

/// Verify token for access to room_id.
///
/// Returns the verified claims on success, or RoomAuthError on failure.
/// secret must match SIGNALING_SFU_SECRET on the signaling server.
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
        .map_err(|_| RoomAuthError::Invalid)?;

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
        let claims = RoomClaims { sub, room: room.to_string(), iat: now, exp };
        encode(&Header::default(), &claims, &EncodingKey::from_secret(secret)).unwrap()
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
            Err(RoomAuthError::Invalid)
        ));
    }

    #[test]
    fn wrong_secret_rejected() {
        let token = make_token("room-abc", 1, b"correct-secret-32-bytes-long!!!!!", 3600);
        assert!(matches!(
            verify_room_token(&token, "room-abc", b"wrong-secret-32-bytes-long-ok!!!"),
            Err(RoomAuthError::Invalid)
        ));
    }

    #[test]
    fn malformed_token_rejected() {
        assert!(matches!(
            verify_room_token("not.a.valid.jwt", "room-abc", b"any-secret"),
            Err(RoomAuthError::Invalid)
        ));
    }

    #[test]
    fn empty_token_rejected() {
        assert!(matches!(
            verify_room_token("", "room-abc", b"secret"),
            Err(RoomAuthError::Invalid)
        ));
    }
}
