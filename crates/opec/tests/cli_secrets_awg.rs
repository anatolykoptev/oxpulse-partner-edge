//! Phase 4.3b — opec secrets awg-keygen CLI integration tests.
use assert_cmd::Command;
use serial_test::serial;

#[test]
#[serial]
fn opec_secrets_help_lists_awg_keygen() {
    Command::cargo_bin("opec")
        .unwrap()
        .args(["secrets", "--help"])
        .assert()
        .success()
        .stdout(predicates::str::contains("awg-keygen"));
}

#[test]
#[serial]
fn opec_secrets_awg_keygen_requires_out_dir() {
    Command::cargo_bin("opec")
        .unwrap()
        .args(["secrets", "awg-keygen"])
        .assert()
        .failure()
        .stderr(predicates::str::contains("--out-dir"));
}
