//! Phase 5.1 — native x25519 keypair generation for Reality identity.
//!
//! Copied verbatim from `crates/partner-cli/src/commands.rs` keygen_x25519 +
//! base64_url_encode to eliminate the shell-out to partner-cli.
//!
//! Output contract:
//! - Both keys are 43-char base64url-no-pad strings encoding 32-byte x25519 keys.
//! - Private key is wrapped in `Zeroizing<String>` so the heap copy is wiped on drop.
//! - Encoding is RFC 4648 §5 url-safe, no padding.

use x25519_dalek::{PublicKey, StaticSecret};
use zeroize::Zeroizing;

/// URL-safe base64 without padding, matching RFC 4648 §5.
///
/// Copied verbatim from `crates/partner-cli/src/commands.rs:base64_url_encode`.
pub(crate) fn base64_url_encode(bytes: &[u8]) -> String {
    const CHARS: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut out = String::with_capacity((bytes.len() * 4).div_ceil(3));
    for chunk in bytes.chunks(3) {
        let b0 = chunk[0] as usize;
        let b1 = if chunk.len() > 1 {
            chunk[1] as usize
        } else {
            0
        };
        let b2 = if chunk.len() > 2 {
            chunk[2] as usize
        } else {
            0
        };
        out.push(CHARS[b0 >> 2] as char);
        out.push(CHARS[((b0 & 3) << 4) | (b1 >> 4)] as char);
        if chunk.len() > 1 {
            out.push(CHARS[((b1 & 0xf) << 2) | (b2 >> 6)] as char);
        }
        if chunk.len() > 2 {
            out.push(CHARS[b2 & 0x3f] as char);
        }
    }
    out
}

/// Generate a fresh x25519 keypair.
///
/// Returns `(private_key_b64url, public_key_b64url)`. Both are 43-char
/// base64url-no-pad strings encoding the 32-byte x25519 keys.
///
/// The private key is wrapped in [`Zeroizing`] so the heap copy of the
/// base64 representation is wiped on drop. [`StaticSecret`] itself has
/// `ZeroizeOnDrop`, but that only covers the raw key bytes — without this
/// wrapper the base64 string encoding persists on the heap until the
/// allocator reuses the memory.
///
/// Copied verbatim from `crates/partner-cli/src/commands.rs:keygen_x25519`.
pub fn keygen_x25519() -> (Zeroizing<String>, String) {
    let secret = StaticSecret::random_from_rng(rand::thread_rng());
    let public = PublicKey::from(&secret);
    let private_b64 = Zeroizing::new(base64_url_encode(secret.as_bytes()));
    let public_b64 = base64_url_encode(public.as_bytes());
    (private_b64, public_b64)
}

#[cfg(test)]
mod tests {
    use super::*;
    use x25519_dalek::{PublicKey, StaticSecret};

    /// Verify base64url encoding against RFC 4648 §5 test vectors.
    /// Copied from `crates/partner-cli/src/commands.rs:base64_url_encode_rfc4648_vectors`
    /// to lock encoding identity across both crates.
    #[test]
    fn base64_url_encode_rfc4648_vectors() {
        let cases: &[(&[u8], &str)] = &[
            (b"", ""),
            (b"f", "Zg"),
            (b"fo", "Zm8"),
            (b"foo", "Zm9v"),
            (b"foob", "Zm9vYg"),
            (b"fooba", "Zm9vYmE"),
            (b"foobar", "Zm9vYmFy"),
        ];
        for (input, expected) in cases {
            assert_eq!(base64_url_encode(input), *expected, "base64url({input:?})");
        }
    }

    /// Each key must be exactly 43 chars, only base64url alphabet, decoding to 32 bytes.
    #[test]
    fn keygen_produces_43_char_base64url_per_key() {
        let (priv_b64, pub_b64) = keygen_x25519();
        for (label, key) in [("private", priv_b64.as_str()), ("public", pub_b64.as_str())] {
            assert_eq!(
                key.len(),
                43,
                "{label} key must be exactly 43 chars, got {}",
                key.len()
            );
            assert!(
                key.chars()
                    .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_'),
                "{label} key contains non-base64url chars: {key}"
            );
            // Decode and assert 32 bytes.
            let decoded = base64_url_decode_test(key);
            assert_eq!(
                decoded.len(),
                32,
                "{label} key must decode to 32 bytes, got {}",
                decoded.len()
            );
        }
    }

    /// Two successive calls must produce different keypairs (sanity randomness check).
    /// Also validates that re-deriving the public key from the private key bytes
    /// reproduces the same public key that keygen returned.
    #[test]
    fn keygen_pub_derivable_from_priv() {
        let (priv1, pub1) = keygen_x25519();
        let (priv2, _pub2) = keygen_x25519();

        // Sanity: different keys on successive calls.
        assert_ne!(
            priv1.as_str(),
            priv2.as_str(),
            "successive calls must produce distinct private keys"
        );

        // Re-derive public key from private bytes; must match the returned pub.
        let priv_bytes: [u8; 32] = base64_url_decode_test(&priv1)
            .try_into()
            .expect("private key decoded to 32 bytes");
        let secret = StaticSecret::from(priv_bytes);
        let derived_pub = PublicKey::from(&secret);
        let derived_pub_b64 = base64_url_encode(derived_pub.as_bytes());
        assert_eq!(
            derived_pub_b64, pub1,
            "public key must be derivable from private key bytes"
        );
    }

    // Minimal base64url decoder used only in tests for round-trip verification.
    fn base64_url_decode_test(s: &str) -> Vec<u8> {
        const CHARS: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
        let mut bits: u32 = 0;
        let mut bit_count: u32 = 0;
        let mut out = Vec::with_capacity(s.len() * 3 / 4 + 1);
        for c in s.bytes() {
            let val = CHARS
                .iter()
                .position(|&b| b == c)
                .unwrap_or_else(|| panic!("invalid base64url char: {c}"));
            bits = (bits << 6) | val as u32;
            bit_count += 6;
            if bit_count >= 8 {
                bit_count -= 8;
                out.push((bits >> bit_count) as u8);
            }
        }
        out
    }
}
