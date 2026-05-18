//! Phase 5.2 — integration tests for awg::keygen using the native wg_keypair path.
//!
//! These tests exercise the native (default) code path without a real `wg` binary.
//! The legacy env-gate path is tested in secrets_awg_unit.rs.

use base64::{engine::general_purpose::STANDARD, Engine as _};
use opec::secrets::{awg, wg_keypair, SecretsError};
use std::{fs, path::PathBuf};
use tempfile::TempDir;

/// On the native path (default, no OPEC_AWG_KEYGEN_LEGACY=1), a fresh keygen
/// must create both files with correct permissions and valid 44-char standard
/// base64 content — even when the wg binary path is a nonexistent path.
#[serial_test::serial]
#[test]
fn awg_keygen_native_path_produces_valid_files() {
    // Ensure legacy gate is OFF for this test.
    // (SAFETY: tests run in separate processes via nextest — no env leak.)
    unsafe { std::env::remove_var("OPEC_AWG_KEYGEN_LEGACY") };

    let out = TempDir::new().unwrap();
    let fake_wg = PathBuf::from("/nonexistent/wg");

    // rotate=true: forces fresh generation.
    awg::keygen(out.path(), true, &fake_wg).expect("native keygen must succeed");

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

/// On the native path, idempotent re-run (rotate=false) with an existing valid
/// priv must derive the pub without touching the priv — even with a fake wg path.
#[serial_test::serial]
#[test]
fn awg_keygen_native_idempotent_reuse() {
    unsafe { std::env::remove_var("OPEC_AWG_KEYGEN_LEGACY") };

    let out = TempDir::new().unwrap();
    let fake_wg = PathBuf::from("/nonexistent/wg");

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
    awg::keygen(out.path(), false, &fake_wg).expect("idempotent native keygen must succeed");

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

/// When OPEC_AWG_KEYGEN_LEGACY=1, keygen falls back to the wg binary.
/// With a nonexistent wg path, it must return a WgMissing / PartnerCliMissing error.
///
/// This test verifies the env gate is wired — not the wg binary itself.
#[serial_test::serial]
#[test]
fn awg_keygen_legacy_env_gate_invokes_wg() {
    // SAFETY: nextest runs each test in an isolated process.
    unsafe { std::env::set_var("OPEC_AWG_KEYGEN_LEGACY", "1") };

    let out = TempDir::new().unwrap();
    let fake_wg = PathBuf::from("/nonexistent/wg-xyz-99");

    let result = awg::keygen(out.path(), true, &fake_wg);

    // Restore env before any assertion to avoid leaking into other tests if
    // they run in the same process (shouldn't happen with nextest, but defensive).
    unsafe { std::env::remove_var("OPEC_AWG_KEYGEN_LEGACY") };

    let err = result.expect_err("legacy path with nonexistent wg must fail");
    assert!(
        matches!(err, SecretsError::PartnerCliMissing(_)),
        "expected PartnerCliMissing (wg not found), got: {err:?}"
    );
}
