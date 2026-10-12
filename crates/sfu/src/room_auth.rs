//! Room token verification -- validates JWTs issued by oxpulse-chat signaling.
//!
//! The signaling server (oxpulse-chat) mints tokens with:
//!   claims: { sub: u64 (peer_id), room: String, iat: u64, exp: u64,
//!             iss: String, aud: String }   (iss/aud: SEC-CR-011 binding)
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

use std::collections::HashSet;
use std::sync::OnceLock;

use jsonwebtoken::{decode, Algorithm, DecodingKey, Validation};
use serde::{Deserialize, Serialize};

/// Default `aud` the SFU expects (`SFU_ROOM_TOKEN_AUDIENCE` overrides).
pub const DEFAULT_ROOM_TOKEN_AUDIENCE: &str = "oxpulse-sfu";

/// Issuer / audience binding policy for room tokens (SEC-CR-011).
///
/// Without it any instance holding the signing key mints tokens every SFU
/// accepts. The policy is applied to BOTH the EdDSA and HS256 verifiers.
///
/// `jsonwebtoken` 10.x semantics this relies on (`validation.rs`):
/// - `iss` is checked only when the token carries it AND `Validation::iss` is
///   set; an SFU that never calls `set_issuer` ignores it.
/// - `aud` is checked when the token carries it; with `Validation::aud` unset a
///   token that carries `aud` is rejected (`InvalidAudience`). So tokens with
///   `aud` are accepted only by SFUs running this policy.
/// - A claim is *required* only if listed in `required_spec_claims`.
///
/// In both modes the configured `iss`/`aud` are validated whenever the token
/// carries them (a foreign `iss` is rejected even in transition). `require_binding`
/// additionally makes `iss` + `aud` mandatory (`SFU_REQUIRE_TOKEN_BINDING=1`).
#[derive(Debug, Clone)]
pub struct RoomTokenPolicy {
    issuers: Vec<String>,
    audience: String,
    require_binding: bool,
}

impl RoomTokenPolicy {
    /// Build a policy. `issuers` empty is only valid while `require_binding`
    /// is off; an empty set would otherwise reject every token carrying `iss`.
    pub fn new(
        issuers: Vec<String>,
        audience: impl Into<String>,
        require_binding: bool,
    ) -> Result<Self, String> {
        let audience = audience.into();
        if audience.is_empty() {
            return Err("room token audience must not be empty".into());
        }
        if require_binding && issuers.is_empty() {
            return Err(
                "SFU_REQUIRE_TOKEN_BINDING is on but SFU_ROOM_TOKEN_ISSUERS is empty — \
                 refusing to start (no issuer could ever match)"
                    .into(),
            );
        }
        Ok(Self {
            issuers,
            audience,
            require_binding,
        })
    }

    /// Transition policy: nothing required; an unset issuer list skips the
    /// issuer check, the default audience is still enforced when present.
    pub fn transitional() -> Self {
        Self {
            issuers: Vec::new(),
            audience: DEFAULT_ROOM_TOKEN_AUDIENCE.to_string(),
            require_binding: false,
        }
    }

    /// Read `SFU_ROOM_TOKEN_ISSUERS` (comma list), `SFU_ROOM_TOKEN_AUDIENCE`
    /// and `SFU_REQUIRE_TOKEN_BINDING` (`1`/`true` on, unset/`0`/`false` off).
    /// An unrecognised flag value is a startup error, not a silent "off".
    pub fn from_env() -> Result<Self, String> {
        Self::from_lookup(|k| std::env::var(k).ok())
    }

    /// [`Self::from_env`] over an injectable lookup (unit-testable without
    /// mutating process env).
    pub fn from_lookup(get: impl Fn(&str) -> Option<String>) -> Result<Self, String> {
        let issuers = get("SFU_ROOM_TOKEN_ISSUERS")
            .unwrap_or_default()
            .split(',')
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_string)
            .collect();
        let audience = get("SFU_ROOM_TOKEN_AUDIENCE")
            .filter(|v| !v.is_empty())
            .unwrap_or_else(|| DEFAULT_ROOM_TOKEN_AUDIENCE.to_string());
        let require = match get("SFU_REQUIRE_TOKEN_BINDING")
            .unwrap_or_default()
            .trim()
            .to_ascii_lowercase()
            .as_str()
        {
            "" | "0" | "false" => false,
            "1" | "true" => true,
            other => {
                return Err(format!(
                    "SFU_REQUIRE_TOKEN_BINDING={other:?} unrecognised (expected 1/true/0/false)"
                ))
            }
        };
        Self::new(issuers, audience, require)
    }

    pub fn require_binding(&self) -> bool {
        self.require_binding
    }

    fn validation(&self, alg: Algorithm) -> Validation {
        let mut v = Validation::new(alg);
        v.validate_exp = true;
        v.leeway = 0; // reject expired tokens without any clock-skew grace period
        let mut required: HashSet<String> = HashSet::from(["exp".to_string()]);
        v.set_audience(&[self.audience.as_str()]);
        if !self.issuers.is_empty() {
            v.set_issuer(&self.issuers);
        }
        if self.require_binding {
            required.insert("iss".into());
            required.insert("aud".into());
        }
        v.required_spec_claims = required;
        v
    }
}

static POLICY: OnceLock<RoomTokenPolicy> = OnceLock::new();

/// Install the process-wide policy once at startup (`main`). The verify fns
/// without a `_with` suffix read it; uninitialised == [`RoomTokenPolicy::transitional`].
/// A second call is an error so a mis-ordered init cannot silently win.
pub fn init_policy(policy: RoomTokenPolicy) -> Result<(), String> {
    POLICY
        .set(policy)
        .map_err(|_| "room token policy already initialised".to_string())
}

fn effective_policy() -> RoomTokenPolicy {
    #[cfg(test)]
    if let Some(p) = TEST_POLICY.with(|c| c.borrow().clone()) {
        return p;
    }
    POLICY.get_or_init(RoomTokenPolicy::transitional).clone()
}

// Test-only per-thread policy override so call-site tests (e.g. the sync DC
// `relay_source` handler) can run strict without poisoning the process-wide
// `OnceLock` shared by the rest of the lib test binary.
#[cfg(test)]
thread_local! {
    static TEST_POLICY: std::cell::RefCell<Option<RoomTokenPolicy>> =
        const { std::cell::RefCell::new(None) };
}

#[cfg(test)]
pub(crate) fn with_test_policy<R>(p: RoomTokenPolicy, f: impl FnOnce() -> R) -> R {
    TEST_POLICY.with(|c| *c.borrow_mut() = Some(p));
    let r = f();
    TEST_POLICY.with(|c| *c.borrow_mut() = None);
    r
}

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
/// Applies the process-wide [`RoomTokenPolicy`].
pub fn verify_room_token(
    token: &str,
    room_id: &str,
    secret: &[u8],
) -> Result<RoomClaims, RoomAuthError> {
    verify_room_token_with(&effective_policy(), token, room_id, secret)
}

/// [`verify_room_token`] with an explicit policy.
pub fn verify_room_token_with(
    policy: &RoomTokenPolicy,
    token: &str,
    room_id: &str,
    secret: &[u8],
) -> Result<RoomClaims, RoomAuthError> {
    let key = DecodingKey::from_secret(secret);
    let validation = policy.validation(Algorithm::HS256);
    decode_and_match(token, room_id, &key, &validation)
}

/// Verify a room token signed with Ed25519 (Phase 2 replacement for HS256).
///
/// `public_key_pem` is the Ed25519 public key obtained from `/api/partner/keys`.
/// Partner-edge nodes fetch this key on startup and cache it. A failure to parse
/// the PEM is a configuration bug, not a signature problem; it maps to
/// `Malformed` so callers don't accidentally fall back to HS256 on a deploy
/// misconfiguration. Applies the process-wide [`RoomTokenPolicy`].
pub fn verify_room_token_ed25519(
    token: &str,
    room_id: &str,
    public_key_pem: &str,
) -> Result<RoomClaims, RoomAuthError> {
    verify_room_token_ed25519_with(&effective_policy(), token, room_id, public_key_pem)
}

/// [`verify_room_token_ed25519`] with an explicit policy.
pub fn verify_room_token_ed25519_with(
    policy: &RoomTokenPolicy,
    token: &str,
    room_id: &str,
    public_key_pem: &str,
) -> Result<RoomClaims, RoomAuthError> {
    let key = DecodingKey::from_ed_pem(public_key_pem.as_bytes())
        .map_err(|_| RoomAuthError::Malformed)?;
    let validation = policy.validation(Algorithm::EdDSA);
    decode_and_match(token, room_id, &key, &validation)
}

fn decode_and_match(
    token: &str,
    room_id: &str,
    key: &DecodingKey,
    validation: &Validation,
) -> Result<RoomClaims, RoomAuthError> {
    let claims = decode::<RoomClaims>(token, key, validation)
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

    // --- SEC-CR-011: issuer / audience binding ---

    const ISS: &str = "oxpulse-chat";
    const AUD: &str = "oxpulse-sfu";
    const SECRET: &[u8] = b"test-secret-32-bytes-long-enough!";

    fn strict() -> RoomTokenPolicy {
        RoomTokenPolicy::new(vec![ISS.into()], AUD, true).unwrap()
    }

    fn transitional_with_issuer() -> RoomTokenPolicy {
        RoomTokenPolicy::new(vec![ISS.into()], AUD, false).unwrap()
    }

    /// Mint an HS256 token from raw JSON claims (independent of `RoomClaims`,
    /// which deliberately carries no iss/aud).
    fn mint(iss: Option<&str>, aud: Option<&str>) -> String {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs();
        let mut c = serde_json::json!({"sub": 7, "room": "room-abc", "iat": now, "exp": now + 600});
        if let Some(i) = iss {
            c["iss"] = i.into();
        }
        if let Some(a) = aud {
            c["aud"] = a.into();
        }
        encode(&Header::default(), &c, &EncodingKey::from_secret(SECRET)).unwrap()
    }

    fn mint_ed(iss: Option<&str>, aud: Option<&str>, priv_pem: &str) -> String {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs();
        let mut c = serde_json::json!({"sub": 7, "room": "room-abc", "iat": now, "exp": now + 600});
        if let Some(i) = iss {
            c["iss"] = i.into();
        }
        if let Some(a) = aud {
            c["aud"] = a.into();
        }
        let key = EncodingKey::from_ed_pem(priv_pem.as_bytes()).unwrap();
        encode(&Header::new(Algorithm::EdDSA), &c, &key).unwrap()
    }

    fn hs(p: &RoomTokenPolicy, t: &str) -> Result<RoomClaims, RoomAuthError> {
        verify_room_token_with(p, t, "room-abc", SECRET)
    }

    #[test]
    fn strict_accepts_correctly_bound_token() {
        // Positive control: also the real falsifier for dropping `set_audience`
        // (library then rejects ANY aud).
        assert!(hs(&strict(), &mint(Some(ISS), Some(AUD))).is_ok());
        let (priv_pem, pub_pem) = generate_test_keypair_room();
        let t = mint_ed(Some(ISS), Some(AUD), &priv_pem);
        assert!(verify_room_token_ed25519_with(&strict(), &t, "room-abc", &pub_pem).is_ok());
    }

    #[test]
    fn strict_rejects_foreign_issuer() {
        let t = mint(Some("oxpulse-staging"), Some(AUD));
        assert!(matches!(hs(&strict(), &t), Err(RoomAuthError::Malformed)));
        let (priv_pem, pub_pem) = generate_test_keypair_room();
        let t = mint_ed(Some("oxpulse-staging"), Some(AUD), &priv_pem);
        assert!(matches!(
            verify_room_token_ed25519_with(&strict(), &t, "room-abc", &pub_pem),
            Err(RoomAuthError::Malformed)
        ));
    }

    #[test]
    fn strict_rejects_wrong_audience() {
        let t = mint(Some(ISS), Some("some-other-service"));
        assert!(matches!(hs(&strict(), &t), Err(RoomAuthError::Malformed)));
    }

    #[test]
    fn strict_rejects_missing_audience() {
        let t = mint(Some(ISS), None);
        assert!(matches!(hs(&strict(), &t), Err(RoomAuthError::Malformed)));
    }

    #[test]
    fn strict_rejects_missing_issuer_and_unbound_legacy_token() {
        assert!(matches!(
            hs(&strict(), &mint(None, Some(AUD))),
            Err(RoomAuthError::Malformed)
        ));
        assert!(matches!(
            hs(&strict(), &mint(None, None)),
            Err(RoomAuthError::Malformed)
        ));
    }

    #[test]
    fn transition_accepts_old_and_new_tokens() {
        for p in [RoomTokenPolicy::transitional(), transitional_with_issuer()] {
            assert!(hs(&p, &mint(None, None)).is_ok(), "legacy token w/o claims");
            assert!(hs(&p, &mint(Some(ISS), Some(AUD))).is_ok(), "bound token");
            assert!(
                hs(&p, &mint(Some(ISS), None)).is_ok(),
                "iss-only token (signaling step 2)"
            );
        }
    }

    #[test]
    fn transition_still_rejects_foreign_claims_when_present() {
        let p = transitional_with_issuer();
        assert!(matches!(
            hs(&p, &mint(Some("oxpulse-staging"), None)),
            Err(RoomAuthError::Malformed)
        ));
        assert!(matches!(
            hs(&p, &mint(None, Some("other"))),
            Err(RoomAuthError::Malformed)
        ));
    }

    #[test]
    fn policy_rejects_inconsistent_config() {
        assert!(RoomTokenPolicy::new(vec![], AUD, true).is_err());
        assert!(RoomTokenPolicy::new(vec![ISS.into()], "", false).is_err());
        let env = |pairs: &'static [(&'static str, &'static str)]| {
            move |k: &str| {
                pairs
                    .iter()
                    .find(|(n, _)| *n == k)
                    .map(|(_, v)| v.to_string())
            }
        };
        // flag on, no issuers -> startup error
        assert!(RoomTokenPolicy::from_lookup(env(&[("SFU_REQUIRE_TOKEN_BINDING", "1")])).is_err());
        // typo must not silently mean "off"
        assert!(
            RoomTokenPolicy::from_lookup(env(&[("SFU_REQUIRE_TOKEN_BINDING", "yes")])).is_err()
        );
        let ok = RoomTokenPolicy::from_lookup(env(&[
            ("SFU_REQUIRE_TOKEN_BINDING", "1"),
            ("SFU_ROOM_TOKEN_ISSUERS", "oxpulse-chat, oxpulse-eu"),
        ]))
        .unwrap();
        assert!(ok.require_binding());
        assert!(hs(&ok, &mint(Some("oxpulse-eu"), Some(AUD))).is_ok());
        let off = RoomTokenPolicy::from_lookup(env(&[])).unwrap();
        assert!(!off.require_binding());
    }

    /// Pins the `jsonwebtoken` facts the rollout order depends on: a verifier
    /// that never set an audience (every SFU built before SEC-CR-011) ignores
    /// `iss` but REJECTS any token carrying `aud`. If a jsonwebtoken upgrade
    /// changes this, the documented order (SFU first, then iss, then aud) must
    /// be re-derived.
    #[test]
    fn legacy_verifier_ignores_iss_but_rejects_aud() {
        let mut legacy = Validation::new(Algorithm::HS256);
        legacy.required_spec_claims = std::collections::HashSet::new();
        let key = DecodingKey::from_secret(SECRET);
        let check = |t: &str| decode::<RoomClaims>(t, &key, &legacy).map_err(|e| e.into_kind());
        assert!(
            check(&mint(Some(ISS), None)).is_ok(),
            "old SFU must tolerate iss"
        );
        assert!(matches!(
            check(&mint(Some(ISS), Some(AUD))),
            Err(jsonwebtoken::errors::ErrorKind::InvalidAudience)
        ));
    }
}
