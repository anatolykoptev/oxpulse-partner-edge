//! Phase 4.3d — opec secrets sfu-signing-key CLI surface.
use assert_cmd::Command;
use serial_test::serial;

#[test]
#[serial]
fn opec_secrets_help_lists_sfu_signing_key() {
    Command::cargo_bin("opec")
        .unwrap()
        .args(["secrets", "--help"])
        .assert()
        .success()
        .stdout(predicates::str::contains("sfu-signing-key"));
}

#[test]
#[serial]
fn opec_secrets_sfu_signing_key_requires_out_file() {
    Command::cargo_bin("opec")
        .unwrap()
        .args(["secrets", "sfu-signing-key"])
        .assert()
        .failure()
        .stderr(predicates::str::contains("--out-file"));
}
