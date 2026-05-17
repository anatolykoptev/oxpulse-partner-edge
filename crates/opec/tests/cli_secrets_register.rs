//! Phase 4.3c — opec secrets register CLI surface.
use assert_cmd::Command;
use serial_test::serial;

#[test]
#[serial]
fn opec_secrets_help_lists_register() {
    Command::cargo_bin("opec")
        .unwrap()
        .args(["secrets", "--help"])
        .assert()
        .success()
        .stdout(predicates::str::contains("register"));
}

#[test]
#[serial]
fn opec_secrets_register_requires_registry_url() {
    Command::cargo_bin("opec")
        .unwrap()
        .args(["secrets", "register"])
        .assert()
        .failure()
        .stderr(predicates::str::contains("--registry-url"));
}
