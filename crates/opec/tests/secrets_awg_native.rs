//! Phase 5.3 — integration tests for awg::keygen using the native wg_keypair path.
//!
//! All tests exercise the unconditional native (x25519-dalek) code path.
//! The legacy wg-tools shell-out path was removed in Phase 5.3.

use base64::{engine::general_purpose::STANDARD, Engine as _};
use opec::secrets::{awg, wg_keypair};
use std::fs;
use tempfile::TempDir;

/// Fresh keygen must create both files with correct permissions and valid
/// 44-char standard base64 content.
#[serial_test::serial]
#[test]
fn awg_keygen_native_path_produces_valid_files() {
    let out = TempDir::new().unwrap();

    // rotate=true: forces fresh generation.
    awg::keygen(out.path(), true).expect("native keygen must succeed");

    let priv_path = out.path().join("awg-private.key");
    let pub_path = out.path().join("awg-public.key");

    assert!(priv_path.is_file(), "awg-private.key must exist");
    assert!(pub_path.is_file(), "awg-public.key must exist");

    // Validate permissions.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let priv_mode = fs::metadata(&priv_path).unwrap().permissions().mode() & 0o777;
        let pub_mode = fs::metadata(&pub_path).unwrap().permissions().mode() & 0o777;
        assert_eq!(priv_mode, 0o600, "awg-private.key must be 0600");
        assert_eq!(pub_mode, 0o644, "awg-public.key must be 0644");
    }

    // Validate content: 44-char standard base64, decodes to 32 bytes.
    let priv_content = fs::read_to_string(&priv_path).unwrap();
    let pub_content = fs::read_to_string(&pub_path).unwrap();
    let priv_trimmed = priv_content.trim();
    let pub_trimmed = pub_content.trim();

    assert_eq!(
        priv_trimmed.len(),
        44,
        "private key must be 44 chars, got {}",
        priv_trimmed.len()
    );
    assert_eq!(
        pub_trimmed.len(),
        44,
        "public key must be 44 chars, got {}",
        pub_trimmed.len()
    );

    let priv_bytes = STANDARD
        .decode(priv_trimmed)
        .expect("priv must be valid base64");
    let pub_bytes = STANDARD
        .decode(pub_trimmed)
        .expect("pub must be valid base64");
    assert_eq!(priv_bytes.len(), 32, "private key must decode to 32 bytes");
    assert_eq!(pub_bytes.len(), 32, "public key must decode to 32 bytes");

    // Pub must match re-derived pub from priv.
    let rederived_pub = wg_keypair::pub_from_priv_b64(priv_trimmed).expect("rederive succeeds");
    assert_eq!(
        rederived_pub, pub_trimmed,
        "public key in file must match pub_from_priv_b64(priv)"
    );
}

/// Idempotent re-run (rotate=false) with an existing valid priv must derive
/// the pub without touching the priv.
#[serial_test::serial]
#[test]
fn awg_keygen_native_idempotent_reuse() {
    let out = TempDir::new().unwrap();

    // Plant a known-good 32-byte private key.
    let known_priv_bytes: [u8; 32] = [
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
        0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e,
        0x1f, 0x20,
    ];
    let known_priv_b64 = STANDARD.encode(known_priv_bytes);
    assert_eq!(known_priv_b64.len(), 44);

    let priv_path = out.path().join("awg-private.key");
    fs::write(&priv_path, format!("{known_priv_b64}\n")).unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&priv_path, fs::Permissions::from_mode(0o600)).unwrap();
    }

    // rotate=false: must reuse the planted priv.
    awg::keygen(out.path(), false).expect("idempotent native keygen must succeed");

    let priv_after = fs::read_to_string(&priv_path).unwrap();
    assert_eq!(
        priv_after.trim(),
        known_priv_b64,
        "private key must be unchanged on idempotent path"
    );

    let pub_path = out.path().join("awg-public.key");
    assert!(pub_path.is_file(), "awg-public.key must be written");
    let pub_content = fs::read_to_string(&pub_path).unwrap();
    let pub_trimmed = pub_content.trim();

    // The pub must match what pub_from_priv_b64 derives from the known priv.
    let expected_pub = wg_keypair::pub_from_priv_b64(&known_priv_b64).expect("known priv is valid");
    assert_eq!(
        pub_trimmed, expected_pub,
        "idempotent path must derive correct pub from existing priv"
    );
}

/// Empty-priv file (zero bytes) must trigger regeneration just like a missing
/// priv file. Coverage parity for legacy test awg_keygen_corrupted_priv_on_idempotent_path_regenerates.
#[serial_test::serial]
#[test]
fn awg_keygen_empty_priv_triggers_regen() {
    let out = TempDir::new().unwrap();
    let priv_path = out.path().join("awg-private.key");

    // Plant empty private key file.
    fs::write(&priv_path, "").unwrap();

    awg::keygen(out.path(), false).expect("regenerates on empty priv");

    let priv_content = fs::read_to_string(&priv_path).unwrap();
    let priv_trimmed = priv_content.trim();

    // Must have regenerated — non-empty, valid 44-char base64.
    assert!(
        !priv_trimmed.is_empty(),
        "priv must be non-empty after regen from empty"
    );
    assert_eq!(
        priv_trimmed.len(),
        44,
        "regenerated priv must be 44 chars, got {}",
        priv_trimmed.len()
    );

    // Pub file must also be written.
    let pub_path = out.path().join("awg-public.key");
    assert!(
        pub_path.is_file(),
        "awg-public.key must exist after regen from empty priv"
    );
}

/// Whitespace-only priv (e.g. "\n\t  \n") must be treated as missing and trigger
/// regeneration. Coverage parity for legacy test awg_keygen_whitespace_only_priv_treated_as_missing.
#[serial_test::serial]
#[test]
fn awg_keygen_whitespace_only_priv_triggers_regen() {
    let out = TempDir::new().unwrap();
    let priv_path = out.path().join("awg-private.key");

    // Plant whitespace-only private key file — non-zero length but empty after trim.
    fs::write(&priv_path, "   \n\t  \n").unwrap();

    awg::keygen(out.path(), false).expect("regenerates on whitespace-only priv");

    let priv_content = fs::read_to_string(&priv_path).unwrap();
    let priv_trimmed = priv_content.trim();

    // Must have regenerated with a real key.
    assert!(
        priv_trimmed.len() == 44,
        "regenerated priv must be 44 chars after whitespace-only priv, got: {}",
        priv_trimmed.len()
    );

    // Verify the written value is valid base64 (decodes to 32 bytes).
    let bytes = STANDARD
        .decode(priv_trimmed)
        .expect("regenerated priv must be valid base64");
    assert_eq!(bytes.len(), 32, "regenerated priv must decode to 32 bytes");
}
