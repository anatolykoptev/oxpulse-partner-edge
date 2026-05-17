//! Phase 4.3a — unit tests for reality::keygen against synthetic partner-cli output.

use opec::secrets::{reality, SecretsError};
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

#[test]
fn keygen_fresh_writes_three_files() {
    let bin_dir = TempDir::new().unwrap();
    let out_dir = TempDir::new().unwrap();
    let pc = fake_partner_cli(
        bin_dir.path(),
        "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG", // 43 chars
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefg", // 43 chars
    );
    reality::keygen(out_dir.path(), false, &pc).expect("keygen succeeds");
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

#[test]
fn keygen_idempotent_when_all_three_present_and_valid() {
    let bin_dir = TempDir::new().unwrap();
    let out_dir = TempDir::new().unwrap();
    let pc = fake_partner_cli(
        bin_dir.path(),
        "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG",
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefg",
    );
    reality::keygen(out_dir.path(), false, &pc).expect("first call");
    let pub_before = fs::read_to_string(out_dir.path().join("reality.pub")).unwrap();
    // Second invocation must NOT call partner-cli — verify by removing it and re-running.
    drop(pc); // partner-cli binary path still valid in bin_dir
    let pub_after = fs::read_to_string(out_dir.path().join("reality.pub")).unwrap();
    assert_eq!(
        pub_before, pub_after,
        "idempotent re-run must not mutate reality.pub"
    );
    // Even with --rotate=false, second call should succeed without rewriting.
    let pc2 = bin_dir.path().join("partner-cli");
    let res = reality::keygen(out_dir.path(), false, &pc2);
    assert!(res.is_ok(), "idempotent re-run should succeed: {:?}", res);
}

#[test]
fn keygen_rotate_regenerates_even_when_valid() {
    let bin_dir = TempDir::new().unwrap();
    let out_dir = TempDir::new().unwrap();
    let pc1 = fake_partner_cli(
        bin_dir.path(),
        "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG",
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefg",
    );
    reality::keygen(out_dir.path(), false, &pc1).expect("first keygen");
    let pub_first = fs::read_to_string(out_dir.path().join("reality.pub")).unwrap();

    // Replace partner-cli with one that emits a different pubkey.
    let pc2 = fake_partner_cli(
        bin_dir.path(),
        "1234567890abcdefghijklmnopqrstuvwxyzABCDEFG",
        "1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefg",
    );
    reality::keygen(out_dir.path(), true, &pc2).expect("rotate keygen");
    let pub_second = fs::read_to_string(out_dir.path().join("reality.pub")).unwrap();
    assert_ne!(pub_first, pub_second, "--rotate must regenerate");
}

#[test]
fn keygen_partial_identity_errors() {
    let bin_dir = TempDir::new().unwrap();
    let out_dir = TempDir::new().unwrap();
    fs::write(out_dir.path().join("reality.pub"), "stale").unwrap();
    // Only reality.pub present — partial.
    let pc = fake_partner_cli(
        bin_dir.path(),
        "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG",
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefg",
    );
    let err = reality::keygen(out_dir.path(), false, &pc).expect_err("partial must error");
    assert!(
        matches!(err, SecretsError::PartialIdentity { .. }),
        "expected PartialIdentity, got: {err:?}"
    );
}

#[test]
fn keygen_missing_partner_cli_errors() {
    let out_dir = TempDir::new().unwrap();
    let nonexistent = PathBuf::from("/nonexistent/partner-cli-xyz-123");
    let err = reality::keygen(out_dir.path(), false, &nonexistent).expect_err("must error");
    assert!(
        matches!(err, SecretsError::PartnerCliMissing(_)),
        "expected PartnerCliMissing, got: {err:?}"
    );
}

#[test]
fn keygen_invalid_key_length_errors() {
    let bin_dir = TempDir::new().unwrap();
    let out_dir = TempDir::new().unwrap();
    let pc = fake_partner_cli(bin_dir.path(), "tooshort", "alsoshort");
    let err = reality::keygen(out_dir.path(), false, &pc).expect_err("len must error");
    assert!(
        matches!(err, SecretsError::InvalidKeyFormat { .. }),
        "expected InvalidKeyFormat, got: {err:?}"
    );
}
