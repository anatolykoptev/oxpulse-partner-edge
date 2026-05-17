//! Phase 4.3a — opec secrets reality-keygen CLI integration tests.
use assert_cmd::Command;
use serial_test::serial;

#[test]
#[serial]
fn opec_secrets_help_lists_reality_keygen() {
    Command::cargo_bin("opec")
        .unwrap()
        .args(["secrets", "--help"])
        .assert()
        .success()
        .stdout(predicates::str::contains("reality-keygen"));
}

#[test]
#[serial]
fn opec_secrets_reality_keygen_requires_out_dir() {
    Command::cargo_bin("opec")
        .unwrap()
        .args(["secrets", "reality-keygen"])
        .assert()
        .failure()
        .stderr(predicates::str::contains("--out-dir"));
}

#[test]
#[serial]
fn opec_secrets_reality_keygen_partial_identity_fails() {
    use std::fs;
    let out_dir = tempfile::TempDir::new().unwrap();
    fs::write(out_dir.path().join("reality.pub"), "stale").unwrap();
    Command::cargo_bin("opec")
        .unwrap()
        .args(["secrets", "reality-keygen", "--out-dir"])
        .arg(out_dir.path())
        .assert()
        .failure()
        .stderr(predicates::str::contains("PARTIAL identity"));
}
