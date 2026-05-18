//! Phase 5.2 — native WireGuard/AmneziaWG keypair generation.
//!
//! WireGuard keys are standard x25519 keypairs (RFC 7748) with a different
//! base64 variant than Reality: **standard base64 WITH `=` padding** (44 chars
//! for 32 bytes), matching the output of `wg genkey` / `wg pubkey`.
//!
//! Output contract:
//! - Both keys are 44-char standard base64 (RFC 4648 §4) strings with `=` padding.
//! - Private key is wrapped in `Zeroizing<String>` so the heap copy is wiped on drop.
//! - Encoding uses `+` and `/` characters (not `-` and `_`), with trailing `=` padding.

use crate::secrets::error::SecretsError;
use base64::{engine::general_purpose::STANDARD, Engine as _};
use x25519_dalek::{PublicKey, StaticSecret};
use zeroize::Zeroizing;

/// Generate a fresh WireGuard/AmneziaWG keypair.
///
/// Returns `(priv_b64, pub_b64)` — both 44-char standard base64 strings
/// with `=` padding, matching `wg genkey` / `wg pubkey` output format.
///
/// The private base64 string is wrapped in [`Zeroizing`] so the heap copy
/// is wiped on drop. [`StaticSecret`] itself has `ZeroizeOnDrop`, but that
/// only covers the raw key bytes — without this wrapper the base64 string
/// encoding persists on the heap until the allocator reuses the memory.
pub fn keygen_wg() -> (Zeroizing<String>, String) {
    let secret = StaticSecret::random_from_rng(rand::thread_rng());
    let public = PublicKey::from(&secret);
    let priv_b64 = Zeroizing::new(STANDARD.encode(secret.as_bytes()));
    let pub_b64 = STANDARD.encode(public.as_bytes());
    (priv_b64, pub_b64)
}

/// Derive the WireGuard public key from a base64-encoded private key string.
///
/// Decodes the priv (must be exactly 32 bytes), derives the public key, and
/// returns the standard base64 encoding.
///
/// Used on the idempotent path in `awg.rs` where an existing private key on
/// disk needs a public key derived without re-generating the private.
///
/// # Errors
///
/// Returns [`SecretsError::InvalidKeyFormat`] if:
/// - `priv_b64` is not valid standard base64.
/// - The decoded bytes are not exactly 32 bytes.
pub fn pub_from_priv_b64(priv_b64: &str) -> Result<String, SecretsError> {
    // Decoded bytes wrapped in Zeroizing so the heap allocation is wiped on
    // drop, and the [u8; 32] copy is also Zeroizing-wrapped because [u8; 32]
    // is Copy and StaticSecret::from would otherwise leave the raw priv
    // lingering on the stack. Matches the Phase 5.1 lesson — same class of
    // leak previously caught in reality.rs's keygen path.
    let priv_bytes: zeroize::Zeroizing<Vec<u8>> =
        zeroize::Zeroizing::new(STANDARD.decode(priv_b64.trim()).map_err(|_| {
            SecretsError::InvalidKeyFormat {
                path: std::path::PathBuf::from("<wg-private-key>"),
                actual_len: priv_b64.trim().len(),
            }
        })?);
    if priv_bytes.len() != 32 {
        return Err(SecretsError::InvalidKeyFormat {
            path: std::path::PathBuf::from("<wg-private-key>"),
            actual_len: priv_bytes.len(),
        });
    }
    let mut priv_array: zeroize::Zeroizing<[u8; 32]> = zeroize::Zeroizing::new([0u8; 32]);
    priv_array.copy_from_slice(&priv_bytes);
    let secret = StaticSecret::from(*priv_array);
    let public = PublicKey::from(&secret);
    Ok(STANDARD.encode(public.as_bytes()))
}

#[cfg(test)]
mod tests {
    use super::*;

    // Standard base64 alphabet: A-Z, a-z, 0-9, +, /, =
    fn is_standard_base64_char(c: char) -> bool {
        c.is_ascii_alphanumeric() || c == '+' || c == '/' || c == '='
    }

    /// Both keys must be exactly 44 chars, only standard base64 alphabet
    /// (including `+`, `/`, and `=` padding), decoding to exactly 32 bytes.
    ///
    /// 32 bytes × 4/3 = 42.67 → padded to 44 with `=`.
    #[test]
    fn keygen_produces_44_char_standard_base64_per_key() {
        let (priv_b64, pub_b64) = keygen_wg();
        for (label, key) in [("private", priv_b64.as_str()), ("public", pub_b64.as_str())] {
            assert_eq!(
                key.len(),
                44,
                "{label} key must be exactly 44 chars, got {}",
                key.len()
            );
            assert!(
                key.chars().all(is_standard_base64_char),
                "{label} key contains non-standard-base64 chars: {key}"
            );
            let decoded = STANDARD.decode(key).expect("must decode");
            assert_eq!(
                decoded.len(),
                32,
                "{label} key must decode to 32 bytes, got {}",
                decoded.len()
            );
        }
    }

    /// Two successive calls must produce different keypairs (randomness sanity).
    /// Also validates that re-deriving the public key from the private key bytes
    /// reproduces the same public key that keygen_wg returned.
    #[test]
    fn keygen_pub_derivable_from_priv() {
        let (priv1, pub1) = keygen_wg();
        let (priv2, _pub2) = keygen_wg();

        // Sanity: different keys on successive calls.
        assert_ne!(
            priv1.as_str(),
            priv2.as_str(),
            "successive calls must produce distinct private keys"
        );

        // Re-derive public key from private bytes; must match the returned pub.
        let priv_bytes: [u8; 32] = STANDARD
            .decode(priv1.as_str())
            .expect("priv decodes")
            .try_into()
            .expect("32 bytes");
        let secret = StaticSecret::from(priv_bytes);
        let derived_pub = PublicKey::from(&secret);
        let derived_pub_b64 = STANDARD.encode(derived_pub.as_bytes());
        assert_eq!(
            derived_pub_b64, pub1,
            "public key must be derivable from private key bytes"
        );
    }

    /// Feed a known priv, derive pub, then call pub_from_priv_b64 again with
    /// the same priv — must yield the same pub.
    #[test]
    fn pub_from_priv_b64_round_trips() {
        let (priv_b64, pub_b64) = keygen_wg();
        let derived = pub_from_priv_b64(&priv_b64).expect("round-trip succeeds");
        assert_eq!(
            derived, pub_b64,
            "pub_from_priv_b64 must reproduce the same public key"
        );
    }

    /// base64 of 31 bytes → InvalidKeyFormat error (wrong decoded length).
    #[test]
    fn pub_from_priv_b64_rejects_wrong_length() {
        let short = STANDARD.encode(&[0u8; 31]); // 31 bytes → base64 decodes fine but wrong len
        let err = pub_from_priv_b64(&short).expect_err("31-byte priv must be rejected");
        assert!(
            matches!(err, SecretsError::InvalidKeyFormat { .. }),
            "expected InvalidKeyFormat, got: {err:?}"
        );
    }

    /// Input with non-base64 chars must return an error.
    #[test]
    fn pub_from_priv_b64_rejects_non_base64() {
        let bad = "!@#$%^&*()!@#$%^&*()!@#$%^&*()!@#$%^&*()!@";
        let err = pub_from_priv_b64(bad).expect_err("non-base64 must be rejected");
        assert!(
            matches!(err, SecretsError::InvalidKeyFormat { .. }),
            "expected InvalidKeyFormat, got: {err:?}"
        );
    }
}
