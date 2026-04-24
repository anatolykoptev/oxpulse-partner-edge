//! Relay subsystem — JWT auth, HTTP handler, outbound WebRTC client.

pub mod client;
pub mod handler;
pub mod task;
pub mod types;

use jsonwebtoken::{decode, encode, Algorithm, DecodingKey, EncodingKey, Header, Validation};

/// Short-lived relay grant token. Signed with HMAC-SHA256 (RFC 7519 / HS256).
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct RelayJwt {
    /// Claim: room ID being relayed.
    pub room_id: String,
    /// Claim: WebSocket URL of the upstream SFU room endpoint.
    pub upstream_url: String,
    /// Claim: Room token for the upstream SFU join.
    pub upstream_room_token: String,
    /// Standard claim: issued-at (Unix seconds).
    pub iat: u64,
    /// Standard claim: expiry (Unix seconds).
    pub exp: u64,
    /// Claim: JWT ID for replay prevention.
    pub jti: String,
}

#[derive(Debug)]
pub enum RelayJwtError {
    Malformed,
    InvalidSignature,
    Expired,
}

impl RelayJwt {
    /// Sign with HMAC-SHA256 and return a standard RFC 7519 JWT string.
    pub fn sign(&self, secret: &[u8]) -> anyhow::Result<String> {
        let key = EncodingKey::from_secret(secret);
        encode(&Header::new(Algorithm::HS256), self, &key)
            .map_err(|e| anyhow::anyhow!("relay JWT sign failed: {e}"))
    }

    /// Verify a JWT string. Returns `Err` if signature is invalid, expired, or malformed.
    pub fn verify(token: &str, secret: &[u8]) -> Result<Self, RelayJwtError> {
        let key = DecodingKey::from_secret(secret);
        let mut validation = Validation::new(Algorithm::HS256);
        validation.validate_exp = true;
        // We validate jti ourselves in the handler; don't require it as a spec claim.
        validation.required_spec_claims = std::collections::HashSet::new();

        let claims = decode::<RelayJwt>(token, &key, &validation)
            .map(|data| data.claims)
            .map_err(|e| match e.kind() {
                jsonwebtoken::errors::ErrorKind::ExpiredSignature => RelayJwtError::Expired,
                jsonwebtoken::errors::ErrorKind::InvalidSignature
                | jsonwebtoken::errors::ErrorKind::InvalidAlgorithmName
                | jsonwebtoken::errors::ErrorKind::InvalidKeyFormat => {
                    RelayJwtError::InvalidSignature
                }
                _ => RelayJwtError::Malformed,
            })?;
        // Reject forward-dated tokens: iat must not be more than 30s in the future.
        // Prevents a forged token with iat=u64::MAX / exp=u64::MAX from being accepted.
        let now = now_unix_secs();
        if claims.iat > now + 30 {
            return Err(RelayJwtError::Malformed);
        }
        Ok(claims)
    }
}

pub fn now_unix_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_valid() -> RelayJwt {
        let now = now_unix_secs();
        RelayJwt {
            room_id: "abc123".to_string(),
            upstream_url: "wss://eu.example/ws/sfu/abc123".to_string(),
            upstream_room_token: "tok".to_string(),
            iat: now,
            exp: now + 300,
            jti: "test-jti".to_string(),
        }
    }

    fn sample_expired() -> RelayJwt {
        let now = now_unix_secs();
        RelayJwt {
            room_id: "abc123".to_string(),
            upstream_url: "wss://eu.example/ws/sfu/abc123".to_string(),
            upstream_room_token: "tok".to_string(),
            iat: now - 600,
            exp: now - 300,
            jti: "test-jti-exp".to_string(),
        }
    }

    #[test]
    fn sign_and_verify_roundtrip() {
        let jwt = sample_valid();
        let token = jwt.sign(b"secret").unwrap();
        let verified = RelayJwt::verify(&token, b"secret").unwrap();
        assert_eq!(verified.room_id, "abc123");
        assert_eq!(verified.upstream_url, "wss://eu.example/ws/sfu/abc123");
    }

    #[test]
    fn verify_rejects_expired() {
        let token = sample_expired().sign(b"s").unwrap();
        assert!(matches!(
            RelayJwt::verify(&token, b"s"),
            Err(RelayJwtError::Expired)
        ));
    }

    #[test]
    fn verify_rejects_wrong_secret() {
        let token = sample_valid().sign(b"correct").unwrap();
        assert!(matches!(
            RelayJwt::verify(&token, b"wrong"),
            Err(RelayJwtError::InvalidSignature)
        ));
    }

    #[test]
    fn verify_rejects_malformed_token() {
        assert!(matches!(
            RelayJwt::verify("not-a-jwt", b"s"),
            Err(RelayJwtError::Malformed)
        ));
    }

    #[test]
    fn verify_rejects_forward_dated_iat() {
        // iat = now + 600s is a forgery attempt; must be rejected
        let jwt = RelayJwt {
            room_id: "r".to_string(),
            upstream_url: "wss://x".to_string(),
            upstream_room_token: "t".to_string(),
            jti: "j".to_string(),
            iat: now_unix_secs() + 600, // 10 minutes in the future
            exp: now_unix_secs() + 660,
        };
        let token = jwt.sign(b"s").unwrap();
        assert!(matches!(RelayJwt::verify(&token, b"s"), Err(RelayJwtError::Malformed)));
    }

    #[test]
    fn verify_rejects_tampered_payload() {
        let token = sample_valid().sign(b"s").unwrap();
        // JWT has 3 dot-separated parts: header.payload.signature
        let parts: Vec<&str> = token.split('.').collect();
        assert_eq!(parts.len(), 3, "standard JWT must have 3 parts");
        let mut payload = parts[1].to_string();
        // Flip a char in the payload to produce a different base64url string.
        let last = payload.pop().unwrap_or('A');
        payload.push(if last == 'A' { 'B' } else { 'A' });
        let tampered = format!("{}.{}.{}", parts[0], payload, parts[2]);
        assert!(matches!(
            RelayJwt::verify(&tampered, b"s"),
            Err(RelayJwtError::InvalidSignature | RelayJwtError::Malformed)
        ));
    }
}
