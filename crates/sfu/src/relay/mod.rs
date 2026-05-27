//! Relay subsystem — JWT auth, HTTP handler, outbound WebRTC client.

pub mod allowlist;
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
    /// Claim: WebSocket URL of the upstream SFU room endpoint (primary / legacy single-hub).
    pub upstream_url: String,
    /// Claim: Room token for the upstream SFU join.
    pub upstream_room_token: String,
    /// Standard claim: issued-at (Unix seconds).
    pub iat: u64,
    /// Standard claim: expiry (Unix seconds).
    pub exp: u64,
    /// Claim: JWT ID for replay prevention.
    pub jti: String,
    /// B0: Ordered list of upstream hub WebSocket URLs to try in sequence.
    ///
    /// When present and non-empty, the edge attempts each candidate in order
    /// until one connects, providing failover if a hub is dark.  When absent
    /// (tokens from central before B0), `#[serde(default)]` yields an empty Vec
    /// and the edge falls back to the single `upstream_url` — fully back-compat.
    #[serde(default)]
    pub upstream_candidates: Vec<String>,
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
        validation.leeway = 0; // SEC-CR-201: match the replay-cache GC (evicts at exp) and verify_ed25519 -- no replay window past exp
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

    /// Verify with Ed25519 public key PEM -- the asymmetric replacement for HS256.
    ///
    /// The public key is fetched from oxpulse-chat's /api/partner/keys endpoint.
    /// This method replaces the shared-secret `verify()` and cannot be used to mint tokens.
    pub fn verify_ed25519(token: &str, public_key_pem: &str) -> Result<Self, RelayJwtError> {
        use jsonwebtoken::{decode, Algorithm, DecodingKey, Validation};
        let key = DecodingKey::from_ed_pem(public_key_pem.as_bytes())
            .map_err(|_| RelayJwtError::Malformed)?;
        let mut validation = Validation::new(Algorithm::EdDSA);
        validation.validate_exp = true;
        validation.leeway = 0;
        validation.required_spec_claims = std::collections::HashSet::new();

        let claims = decode::<RelayJwt>(token, &key, &validation)
            .map(|d| d.claims)
            .map_err(|e| match e.kind() {
                jsonwebtoken::errors::ErrorKind::ExpiredSignature => RelayJwtError::Expired,
                jsonwebtoken::errors::ErrorKind::InvalidSignature => {
                    RelayJwtError::InvalidSignature
                }
                _ => RelayJwtError::Malformed,
            })?;

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
            upstream_candidates: vec![],
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
            upstream_candidates: vec![],
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
            upstream_candidates: vec![],
        };
        let token = jwt.sign(b"s").unwrap();
        assert!(matches!(
            RelayJwt::verify(&token, b"s"),
            Err(RelayJwtError::Malformed)
        ));
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

    /// SEC-CR-201: HS256 verify() must reject tokens expired by even 5 seconds.
    /// Before the fix (leeway=0), jsonwebtoken v10.4.0 default 60s leeway accepted
    /// tokens in [exp, exp+60s] — exactly the window after the replay-cache GC evicts
    /// the jti. This test proves the fix closes that window.
    #[test]
    fn verify_hs256_rejects_just_expired_token_no_leeway() {
        let secret = b"test-secret-at-least-32-bytes-long-x";
        let now = now_unix_secs();
        let jwt = RelayJwt {
            jti: "leeway-test".to_string(),
            room_id: "r".to_string(),
            upstream_url: "ws://10.9.0.2:8907/ws/call/r".to_string(),
            upstream_room_token: "t".to_string(),
            upstream_candidates: vec![],
            iat: now.saturating_sub(120),
            exp: now.saturating_sub(5), // expired 5s ago — within OLD 60s leeway, must now be REJECTED
        };
        let token = jwt.sign(secret).expect("sign");
        let res = RelayJwt::verify(&token, secret);
        assert!(
            res.is_err(),
            "expired HS256 token must be rejected with leeway=0 (was accepted within default 60s leeway)"
        );
    }
    // --- Ed25519 (EdDSA) test helpers ---

    #[cfg(test)]
    fn generate_test_keypair_relay() -> (String, String) {
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

    #[cfg(test)]
    fn sign_ed25519_for_test(jwt: &RelayJwt, priv_pem: &str) -> String {
        use jsonwebtoken::{encode, Algorithm, EncodingKey, Header};
        let key = EncodingKey::from_ed_pem(priv_pem.as_bytes()).unwrap();
        encode(&Header::new(Algorithm::EdDSA), jwt, &key).unwrap()
    }

    fn sample(iat: u64, exp: u64) -> RelayJwt {
        RelayJwt {
            room_id: "room-ed25519".to_string(),
            upstream_url: "wss://eu.example/ws/sfu/ed".to_string(),
            upstream_room_token: "tok-ed".to_string(),
            iat,
            exp,
            jti: "ed-test-jti".to_string(),
            upstream_candidates: vec![],
        }
    }

    #[test]
    fn verify_ed25519_accepts_valid_token() {
        let (priv_pem, pub_pem) = generate_test_keypair_relay();
        let jwt = sample(now_unix_secs(), now_unix_secs() + 300);
        let token = sign_ed25519_for_test(&jwt, &priv_pem);
        let verified = RelayJwt::verify_ed25519(&token, &pub_pem).unwrap();
        assert_eq!(verified.room_id, jwt.room_id);
    }

    #[test]
    fn verify_ed25519_rejects_wrong_public_key() {
        let (priv_pem1, _pub1) = generate_test_keypair_relay();
        let (_priv2, pub_pem2) = generate_test_keypair_relay();
        let jwt = sample(now_unix_secs(), now_unix_secs() + 300);
        let token = sign_ed25519_for_test(&jwt, &priv_pem1);
        assert!(matches!(
            RelayJwt::verify_ed25519(&token, &pub_pem2),
            Err(RelayJwtError::InvalidSignature)
        ));
    }

    #[test]
    fn verify_ed25519_rejects_expired() {
        let (priv_pem, pub_pem) = generate_test_keypair_relay();
        let jwt = sample(now_unix_secs() - 600, now_unix_secs() - 10);
        let token = sign_ed25519_for_test(&jwt, &priv_pem);
        assert!(matches!(
            RelayJwt::verify_ed25519(&token, &pub_pem),
            Err(RelayJwtError::Expired)
        ));
    }

    #[test]
    fn verify_ed25519_rejects_forward_dated_iat() {
        let (priv_pem, pub_pem) = generate_test_keypair_relay();
        let jwt = RelayJwt {
            room_id: "r".to_string(),
            upstream_url: "wss://x".to_string(),
            upstream_room_token: "t".to_string(),
            jti: "j".to_string(),
            iat: now_unix_secs() + 600,
            exp: now_unix_secs() + 660,
            upstream_candidates: vec![],
        };
        let token = sign_ed25519_for_test(&jwt, &priv_pem);
        assert!(matches!(
            RelayJwt::verify_ed25519(&token, &pub_pem),
            Err(RelayJwtError::Malformed)
        ));
    }
}

#[cfg(test)]
mod b0_candidates_tests {
    use super::*;

    // Build a minimal RelayJwt JSON string WITHOUT the upstream_candidates field.
    // After the field is added with #[serde(default)], this must deserialise to an
    // empty Vec (back-compat guarantee — central tokens from before B0 remain valid).
    #[test]
    fn upstream_candidates_defaults_to_empty_vec_when_absent() {
        let now = now_unix_secs();
        let json = format!(
            r#"{{"room_id":"r","upstream_url":"ws://10.9.0.2:8907/ws","upstream_room_token":"tok","iat":{now},"exp":{},"jti":"j"}}"#,
            now + 300
        );
        let jwt: RelayJwt = serde_json::from_str(&json).expect("must deserialise");
        assert!(
            jwt.upstream_candidates.is_empty(),
            "absent upstream_candidates must deserialise to empty Vec, got {:?}",
            jwt.upstream_candidates
        );
    }

    // A token WITH the field must populate the Vec correctly.
    #[test]
    fn upstream_candidates_populated_when_present() {
        let now = now_unix_secs();
        let json = format!(
            r#"{{"room_id":"r","upstream_url":"ws://10.9.0.2:8907/ws","upstream_room_token":"tok","iat":{now},"exp":{},"jti":"j","upstream_candidates":["ws://10.9.0.2:8907/ws","ws://10.9.0.3:8907/ws"]}}"#,
            now + 300
        );
        let jwt: RelayJwt = serde_json::from_str(&json).expect("must deserialise");
        assert_eq!(
            jwt.upstream_candidates,
            vec!["ws://10.9.0.2:8907/ws", "ws://10.9.0.3:8907/ws"]
        );
    }
}
