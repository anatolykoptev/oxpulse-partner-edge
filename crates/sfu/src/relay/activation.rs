//! Cascade-relay activation gate (T8).
//!
//! The relay `/relay/connect` API spawns when EITHER credential is configured:
//!
//! * `RELAY_JWT_SECRET`        — the legacy HS256 shared secret, or
//! * `SFU_SIGNING_PUBLIC_KEY`  — the Ed25519 signing key (the canonical
//!   federation path: central issues Ed25519-signed relay grants and, per the
//!   opec `register.rs` contract, `relay_jwt_secret` is legacy HS256 and may
//!   never be emitted).
//!
//! Before T8 the gate in `main.rs` read `RELAY_JWT_SECRET` alone, so a
//! pure-Ed25519 deployment (only `SFU_SIGNING_PUBLIC_KEY` set) never spawned the
//! relay — the federation activation path was unreachable via config. `install.sh`
//! masked this by always minting a fallback HS256 secret, so the Ed25519-only path
//! was never exercised. This module makes the gate consult both credentials and is
//! unit- + integration-testable in isolation from `main()`.

use std::sync::Arc;

pub use crate::metrics::{RELAY_AUTH_BOTH, RELAY_AUTH_EDDSA, RELAY_AUTH_HS256};

/// The resolved relay-API activation decision, computed once at boot.
///
/// Threaded into [`crate::relay::handler::RelayApiState`] by `main.rs`: `secret`
/// and `hs256_fallback_effective` feed the state directly, `auth_mode` sets the
/// `relay_api_enabled{auth}` startup gauge, and `enabled` gates the whole spawn.
pub struct RelayActivation {
    /// Whether the relay API should spawn at all.
    pub enabled: bool,
    /// HS256 shared secret for `RelayApiState.secret`.
    ///
    /// Empty (`&[]`) on a pure-Ed25519 deployment where no `RELAY_JWT_SECRET` is
    /// configured. It is never *consulted* in that mode because
    /// [`Self::hs256_fallback_effective`] is `false` and the EdDSA verifier is
    /// primary — but it must be a real `Arc<[u8]>` so `RelayApiState` builds
    /// without an `unwrap()`/`expect()` on a `None` secret (the panic the T8
    /// interaction guard forbids).
    pub secret: Arc<[u8]>,
    /// Effective HS256-fallback flag for `RelayApiState.hs256_fallback_enabled`.
    ///
    /// `config default AND an HS256 secret exists`. Forced `false` on a
    /// pure-Ed25519 deployment regardless of `SFU_RELAY_HS256_FALLBACK`
    /// (default-on): with no secret the fallback verifier would run against the
    /// EMPTY secret, and an HS256 token forged with an empty key (`b""`) is
    /// computable by anyone — so the fallback must be off, not merely inert.
    pub hs256_fallback_effective: bool,
    /// `auth` label for the `relay_api_enabled` gauge, or `None` when disabled.
    pub auth_mode: Option<&'static str>,
}

/// Compute the relay-API activation decision from the two credential sources.
///
/// Activation rule: `RELAY_JWT_SECRET present-and-valid` **OR**
/// `SFU_SIGNING_PUBLIC_KEY present`.
///
/// A PRESENT-but-invalid `RELAY_JWT_SECRET` (the documented placeholder, or
/// shorter than 32 bytes) is a hard error even when Ed25519 would independently
/// activate the relay: an operator who set `RELAY_JWT_SECRET` intends the HS256
/// path, and a broken secret is a misconfiguration to surface — not something to
/// silently paper over by falling through to Ed25519-only.
pub fn compute_relay_activation(
    relay_jwt_secret: Option<&str>,
    signing_public_key: Option<&str>,
    hs256_fallback_config: bool,
) -> anyhow::Result<RelayActivation> {
    let has_hs256_secret = match relay_jwt_secret {
        None => false,
        Some(s) if s == "change-me-in-production" => {
            anyhow::bail!(
                "RELAY_JWT_SECRET is the documented placeholder value — set a random secret of at least 32 bytes. \
                 Generate one with: openssl rand -hex 32"
            );
        }
        Some(s) if s.len() < 32 => {
            anyhow::bail!(
                "RELAY_JWT_SECRET is too short ({} bytes) — minimum 32 bytes required",
                s.len()
            );
        }
        Some(_) => true,
    };
    let has_eddsa_key = signing_public_key.is_some();

    // T8: the fix — activate on EITHER credential, not RELAY_JWT_SECRET alone.
    let enabled = has_hs256_secret || has_eddsa_key;

    // Build a real Arc<[u8]> without unwrapping a None secret. Only carry the
    // bytes when the secret is valid; otherwise an empty slice (never consulted,
    // see `hs256_fallback_effective`).
    let secret: Arc<[u8]> = match relay_jwt_secret {
        Some(s) if has_hs256_secret => Arc::from(s.as_bytes().to_vec()),
        _ => Arc::from(Vec::new()),
    };

    // Fallback only makes sense with a real secret; force off otherwise so an
    // empty-secret HS256 verify (attacker-forgeable) can never fire.
    let hs256_fallback_effective = has_hs256_secret && hs256_fallback_config;

    let auth_mode = match (has_eddsa_key, has_hs256_secret) {
        (true, true) => Some(RELAY_AUTH_BOTH),
        (true, false) => Some(RELAY_AUTH_EDDSA),
        (false, true) => Some(RELAY_AUTH_HS256),
        (false, false) => None,
    };

    Ok(RelayActivation {
        enabled,
        secret,
        hs256_fallback_effective,
        auth_mode,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    // A syntactically-plausible Ed25519 public-key PEM. The gate only checks
    // presence (`Option::is_some`), so the bytes need not be a real key here.
    const PUBKEY_PEM: &str = "-----BEGIN PUBLIC KEY-----\nMCowBQYDK2VwAyEA\n-----END PUBLIC KEY-----\n";
    const VALID_HS256: &str = "0123456789abcdef0123456789abcdef"; // 32 bytes

    /// The T8 fix: `SFU_SIGNING_PUBLIC_KEY` alone activates the relay API.
    /// This is the assertion that is RED on the pre-T8 gate (secret-only).
    #[test]
    fn eddsa_only_activates_relay() {
        let a = compute_relay_activation(None, Some(PUBKEY_PEM), true).unwrap();
        assert!(a.enabled, "Ed25519-only deployment MUST activate the relay API");
        assert_eq!(a.auth_mode, Some(RELAY_AUTH_EDDSA));
    }

    /// Interaction guard: Ed25519-only carries an EMPTY secret and the HS256
    /// fallback is forced OFF even though the config default is on — so the
    /// empty-secret verify path can never be reached.
    #[test]
    fn eddsa_only_has_empty_secret_and_fallback_forced_off() {
        let a = compute_relay_activation(None, Some(PUBKEY_PEM), true).unwrap();
        assert!(a.secret.is_empty(), "no RELAY_JWT_SECRET → empty secret, no panic");
        assert!(
            !a.hs256_fallback_effective,
            "no HS256 secret → fallback MUST be forced off (empty-secret forgery guard)"
        );
    }

    /// HS256-only keeps the legacy behaviour: activates, carries the real
    /// secret, honours the config fallback flag.
    #[test]
    fn hs256_only_activates_with_real_secret() {
        let a = compute_relay_activation(Some(VALID_HS256), None, true).unwrap();
        assert!(a.enabled);
        assert_eq!(a.auth_mode, Some(RELAY_AUTH_HS256));
        assert_eq!(a.secret.as_ref(), VALID_HS256.as_bytes());
        assert!(a.hs256_fallback_effective);
    }

    /// The config kill-switch still disables the fallback when a secret exists.
    #[test]
    fn hs256_only_respects_disabled_fallback_config() {
        let a = compute_relay_activation(Some(VALID_HS256), None, false).unwrap();
        assert!(!a.hs256_fallback_effective, "config off must disable fallback");
    }

    /// Both credentials → `auth=both`, real secret, config-driven fallback.
    #[test]
    fn both_credentials_report_both() {
        let a = compute_relay_activation(Some(VALID_HS256), Some(PUBKEY_PEM), true).unwrap();
        assert!(a.enabled);
        assert_eq!(a.auth_mode, Some(RELAY_AUTH_BOTH));
        assert!(a.hs256_fallback_effective);
    }

    /// Neither credential → disabled, no auth mode, empty secret.
    #[test]
    fn neither_credential_disables_relay() {
        let a = compute_relay_activation(None, None, true).unwrap();
        assert!(!a.enabled);
        assert_eq!(a.auth_mode, None);
        assert!(a.secret.is_empty());
    }

    /// A present-but-invalid HS256 secret is a hard error even with Ed25519 set.
    #[test]
    fn invalid_hs256_secret_errors_even_with_eddsa() {
        assert!(compute_relay_activation(Some("too-short"), Some(PUBKEY_PEM), true).is_err());
        assert!(
            compute_relay_activation(Some("change-me-in-production"), Some(PUBKEY_PEM), true)
                .is_err()
        );
    }
}
