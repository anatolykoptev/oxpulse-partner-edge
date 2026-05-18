//! Phase 5.1 — integration tests for reality::keygen native x25519 path.
//!
//! These tests verify:
//! 1. Native path (default) produces valid files without invoking partner-cli.
//! 2. Legacy env gate (OPEC_REALITY_KEYGEN_LEGACY=1) invokes partner-cli and
//!    errors with PartnerCliMissing when the binary is absent.

use opec::secrets::{reality, SecretsError};
use serial_test::serial;
use std::fs;
use std::path::PathBuf;
use tempfile::TempDir;

/// Native path produces all three valid identity files.
///
/// Pass `/nonexistent/partner-cli` — if the native path accidentally falls
/// through to the shell-out, the test will fail because that binary doesn't
/// exist (it would surface as PartnerCliMissing or Io, not Ok).
#[test]
#[serial]
fn keygen_native_path_produces_three_valid_files() {
    // Ensure legacy env gate is NOT set for this test.
    std::env::remove_var("OPEC_REALITY_KEYGEN_LEGACY");

    let out_dir = TempDir::new().unwrap();
    let fake_cli = std::path::PathBuf::from("/nonexistent/partner-cli-must-not-be-called");

    reality::keygen(out_dir.path(), true, &fake_cli).expect("native keygen must succeed");

    // All three files must exist.
    let priv_path = out_dir.path().join("reality.priv");
    let pub_path = out_dir.path().join("reality.pub");
    let uuid_path = out_dir.path().join("reality.uuid");
    assert!(priv_path.is_file(), "reality.priv missing");
    assert!(pub_path.is_file(), "reality.pub missing");
    assert!(uuid_path.is_file(), "reality.uuid missing");

    // File permissions.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let priv_mode = fs::metadata(&priv_path).unwrap().permissions().mode() & 0o777;
        assert_eq!(
            priv_mode, 0o600,
            "reality.priv must be 0600, got {priv_mode:o}"
        );
        let pub_mode = fs::metadata(&pub_path).unwrap().permissions().mode() & 0o777;
        assert_eq!(
            pub_mode, 0o644,
            "reality.pub must be 0644, got {pub_mode:o}"
        );
        let uuid_mode = fs::metadata(&uuid_path).unwrap().permissions().mode() & 0o777;
        assert_eq!(
            uuid_mode, 0o644,
            "reality.uuid must be 0644, got {uuid_mode:o}"
        );
    }

    // Key format: 43-char base64url.
    let priv_content = fs::read_to_string(&priv_path).unwrap();
    let pub_content = fs::read_to_string(&pub_path).unwrap();
    let priv_trimmed = priv_content.trim();
    let pub_trimmed = pub_content.trim();

    assert_eq!(
        priv_trimmed.len(),
        43,
        "reality.priv must be 43 chars, got {}",
        priv_trimmed.len()
    );
    assert_eq!(
        pub_trimmed.len(),
        43,
        "reality.pub must be 43 chars, got {}",
        pub_trimmed.len()
    );
    assert!(
        priv_trimmed
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_'),
        "reality.priv contains non-base64url chars: {priv_trimmed}"
    );
    assert!(
        pub_trimmed
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_'),
        "reality.pub contains non-base64url chars: {pub_trimmed}"
    );

    // UUID is parseable.
    let uuid_content = fs::read_to_string(&uuid_path).unwrap();
    uuid::Uuid::parse_str(uuid_content.trim()).expect("reality.uuid must be a valid UUID");

    // Idempotent re-run with rotate=false must succeed (reuse path).
    let result = reality::keygen(out_dir.path(), false, &fake_cli);
    assert!(
        result.is_ok(),
        "idempotent re-run (rotate=false) must succeed: {:?}",
        result
    );

    // Content must not have changed.
    let pub_after = fs::read_to_string(&pub_path).unwrap();
    assert_eq!(
        pub_content, pub_after,
        "idempotent re-run must not mutate reality.pub"
    );
}

/// When OPEC_REALITY_KEYGEN_LEGACY=1 is set, reality::keygen must take the
/// legacy branch (Command::new partner-cli) and fail with PartnerCliMissing
/// for a nonexistent binary — proving it did NOT take the native path.
#[test]
#[serial]
fn keygen_legacy_env_gate_invokes_partner_cli() {
    std::env::set_var("OPEC_REALITY_KEYGEN_LEGACY", "1");

    let out_dir = TempDir::new().unwrap();
    let nonexistent = std::path::PathBuf::from("/nonexistent/partner-cli-legacy-test");

    let result = reality::keygen(out_dir.path(), true, &nonexistent);

    // Always clean up the env var before asserting so subsequent tests aren't poisoned.
    std::env::remove_var("OPEC_REALITY_KEYGEN_LEGACY");

    let err = result.expect_err("legacy path with nonexistent binary must error");
    assert!(
        matches!(err, SecretsError::PartnerCliMissing(_)),
        "expected PartnerCliMissing (proves legacy branch was taken), got: {err:?}"
    );
}
