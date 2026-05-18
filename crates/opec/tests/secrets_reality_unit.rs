//! Phase 5.3 — retained native reality keygen tests.
//!
//! All legacy shell-out tests (OPEC_REALITY_KEYGEN_LEGACY=1) were removed in Phase 5.3.
//! Coverage for fresh/idempotent/permissions is in secrets_reality_native.rs.
//! This file retains rotate, partial-identity, and corrupted-uuid tests.

use opec::secrets::{reality, SecretsError};
use serial_test::serial;
use std::fs;
use tempfile::TempDir;

/// --rotate must regenerate even when existing files are valid.
/// Uses native path; keys are random so they must differ.
#[test]
#[serial]
fn keygen_rotate_regenerates_even_when_valid() {
    let out_dir = TempDir::new().unwrap();

    reality::keygen(out_dir.path(), false).expect("first keygen");
    let pub_first = fs::read_to_string(out_dir.path().join("reality.pub")).unwrap();

    reality::keygen(out_dir.path(), true).expect("rotate keygen");
    let pub_second = fs::read_to_string(out_dir.path().join("reality.pub")).unwrap();
    // With true randomness the probability of collision is 2^-256 — effectively impossible.
    assert_ne!(pub_first, pub_second, "--rotate must regenerate");
}

/// Partial identity (only some files present) must error before reaching keygen.
#[test]
#[serial]
fn keygen_partial_identity_errors() {
    let out_dir = TempDir::new().unwrap();
    fs::write(out_dir.path().join("reality.pub"), "stale").unwrap();
    // Only reality.pub present — partial identity must error.
    let err = reality::keygen(out_dir.path(), false).expect_err("partial must error");
    assert!(
        matches!(err, SecretsError::PartialIdentity { .. }),
        "expected PartialIdentity, got: {err:?}"
    );
}

#[test]
#[serial]
fn keygen_idempotent_rejects_corrupted_uuid_file() {
    let out_dir = TempDir::new().unwrap();
    // Plant all three files: keys valid (43-char), uuid garbage.
    fs::write(
        out_dir.path().join("reality.priv"),
        "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG\n",
    )
    .unwrap();
    fs::write(
        out_dir.path().join("reality.pub"),
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefg\n",
    )
    .unwrap();
    fs::write(out_dir.path().join("reality.uuid"), "not-a-uuid\n").unwrap();
    let err = reality::keygen(out_dir.path(), false)
        .expect_err("corrupted uuid in idempotent state must error");
    assert!(
        matches!(err, SecretsError::InvalidKeyFormat { ref path, .. } if path.ends_with("reality.uuid")),
        "expected InvalidKeyFormat on reality.uuid, got: {err:?}"
    );
}
