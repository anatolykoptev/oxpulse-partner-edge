//! Phase 4.3a — unit tests for reality::keygen against synthetic partner-cli output.
//!
//! Tests that exercise the shell-out path set OPEC_REALITY_KEYGEN_LEGACY=1 and are
//! marked #[serial] so that concurrent tests don't observe each other's env changes.

use opec::secrets::{reality, SecretsError};
use serial_test::serial;
use std::{fs, path::PathBuf};
use tempfile::TempDir;

// Helper: place a fake partner-cli on the temp PATH that emits canned keygen output.
fn fake_partner_cli(dir: &std::path::Path, priv_key: &str, pub_key: &str) -> PathBuf {
    let path = dir.join("partner-cli");
    let script = format!(
        "#!/usr/bin/env bash\n\
         if [[ \"$1\" == \"keygen\" ]]; then\n\
           echo 'private_key: {priv_key}'\n\
           echo 'public_key: {pub_key}'\n\
           exit 0\n\
         fi\n\
         echo 'fake partner-cli: only keygen supported' >&2\n\
         exit 1\n"
    );
    fs::write(&path, script).unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perm = fs::metadata(&path).unwrap().permissions();
        perm.set_mode(0o755);
        fs::set_permissions(&path, perm).unwrap();
    }
    path
}

/// Fresh keygen via legacy shell-out path produces the three identity files.
/// Uses OPEC_REALITY_KEYGEN_LEGACY=1 to exercise the partner-cli branch.
#[test]
#[serial]
fn keygen_fresh_writes_three_files() {
    std::env::set_var("OPEC_REALITY_KEYGEN_LEGACY", "1");
    let bin_dir = TempDir::new().unwrap();
    let out_dir = TempDir::new().unwrap();
    let pc = fake_partner_cli(
        bin_dir.path(),
        "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG", // 43 chars
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefg", // 43 chars
    );
    let result = reality::keygen(out_dir.path(), false, &pc);
    std::env::remove_var("OPEC_REALITY_KEYGEN_LEGACY");
    result.expect("keygen succeeds");
    assert!(out_dir.path().join("reality.priv").is_file());
    assert!(out_dir.path().join("reality.pub").is_file());
    assert!(out_dir.path().join("reality.uuid").is_file());
    let priv_mode = fs::metadata(out_dir.path().join("reality.priv"))
        .unwrap()
        .permissions();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(priv_mode.mode() & 0o777, 0o600, "reality.priv must be 0600");
    }
}

/// Idempotent re-run reuses existing valid files without calling partner-cli.
/// First call uses legacy gate to seed the files; second call uses native path
/// (no legacy gate) to prove the idempotent path is path-independent.
#[test]
#[serial]
fn keygen_idempotent_when_all_three_present_and_valid() {
    std::env::set_var("OPEC_REALITY_KEYGEN_LEGACY", "1");
    let bin_dir = TempDir::new().unwrap();
    let out_dir = TempDir::new().unwrap();
    let pc = fake_partner_cli(
        bin_dir.path(),
        "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG",
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefg",
    );
    let result = reality::keygen(out_dir.path(), false, &pc);
    std::env::remove_var("OPEC_REALITY_KEYGEN_LEGACY");
    result.expect("first call");
    let pub_before = fs::read_to_string(out_dir.path().join("reality.pub")).unwrap();
    // Second invocation uses native path; idempotent check must NOT regenerate.
    let fake_nonexistent = PathBuf::from("/nonexistent/partner-cli-must-not-be-called");
    let pub_after = fs::read_to_string(out_dir.path().join("reality.pub")).unwrap();
    assert_eq!(
        pub_before, pub_after,
        "idempotent re-run must not mutate reality.pub"
    );
    let res = reality::keygen(out_dir.path(), false, &fake_nonexistent);
    assert!(res.is_ok(), "idempotent re-run should succeed: {:?}", res);
}

/// --rotate must regenerate even when existing files are valid.
/// Uses native path (no legacy gate) for both calls; keys are random so they must differ.
#[test]
#[serial]
fn keygen_rotate_regenerates_even_when_valid() {
    std::env::remove_var("OPEC_REALITY_KEYGEN_LEGACY");
    let out_dir = TempDir::new().unwrap();
    let fake_cli = PathBuf::from("/nonexistent/partner-cli-must-not-be-called");

    reality::keygen(out_dir.path(), false, &fake_cli).expect("first keygen");
    let pub_first = fs::read_to_string(out_dir.path().join("reality.pub")).unwrap();

    reality::keygen(out_dir.path(), true, &fake_cli).expect("rotate keygen");
    let pub_second = fs::read_to_string(out_dir.path().join("reality.pub")).unwrap();
    // With true randomness the probability of collision is 2^-256 — effectively impossible.
    assert_ne!(pub_first, pub_second, "--rotate must regenerate");
}

/// Partial identity (only some files present) must error before reaching keygen.
#[test]
#[serial]
fn keygen_partial_identity_errors() {
    std::env::remove_var("OPEC_REALITY_KEYGEN_LEGACY");
    let out_dir = TempDir::new().unwrap();
    fs::write(out_dir.path().join("reality.pub"), "stale").unwrap();
    // Only reality.pub present — partial identity, partner-cli must NOT be reached.
    let pc = PathBuf::from("/nonexistent/partner-cli-must-not-be-called");
    let err = reality::keygen(out_dir.path(), false, &pc).expect_err("partial must error");
    assert!(
        matches!(err, SecretsError::PartialIdentity { .. }),
        "expected PartialIdentity, got: {err:?}"
    );
}

/// Legacy path: missing partner-cli binary must error with PartnerCliMissing.
/// Requires OPEC_REALITY_KEYGEN_LEGACY=1 to exercise the shell-out branch.
#[test]
#[serial]
fn keygen_missing_partner_cli_errors() {
    std::env::set_var("OPEC_REALITY_KEYGEN_LEGACY", "1");
    let out_dir = TempDir::new().unwrap();
    let nonexistent = PathBuf::from("/nonexistent/partner-cli-xyz-123");
    let result = reality::keygen(out_dir.path(), false, &nonexistent);
    std::env::remove_var("OPEC_REALITY_KEYGEN_LEGACY");
    let err = result.expect_err("must error");
    assert!(
        matches!(err, SecretsError::PartnerCliMissing(_)),
        "expected PartnerCliMissing, got: {err:?}"
    );
}

/// Legacy path: partner-cli emitting short keys must error with InvalidKeyFormat.
/// Requires OPEC_REALITY_KEYGEN_LEGACY=1 to exercise the shell-out branch.
#[test]
#[serial]
fn keygen_invalid_key_length_errors() {
    std::env::set_var("OPEC_REALITY_KEYGEN_LEGACY", "1");
    let bin_dir = TempDir::new().unwrap();
    let out_dir = TempDir::new().unwrap();
    let pc = fake_partner_cli(bin_dir.path(), "tooshort", "alsoshort");
    let result = reality::keygen(out_dir.path(), false, &pc);
    std::env::remove_var("OPEC_REALITY_KEYGEN_LEGACY");
    let err = result.expect_err("len must error");
    assert!(
        matches!(err, SecretsError::InvalidKeyFormat { .. }),
        "expected InvalidKeyFormat, got: {err:?}"
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
    // partner-cli intentionally bogus — must NOT be reached (validate fails first).
    let pc = PathBuf::from("/nonexistent/partner-cli-must-not-be-called");
    let err = reality::keygen(out_dir.path(), false, &pc)
        .expect_err("corrupted uuid in idempotent state must error");
    assert!(
        matches!(err, SecretsError::InvalidKeyFormat { ref path, .. } if path.ends_with("reality.uuid")),
        "expected InvalidKeyFormat on reality.uuid, got: {err:?}"
    );
}
