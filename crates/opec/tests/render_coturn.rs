//! Phase 2 Task 3 — opec render coturn byte-identical parity vs bash render_template.

use serial_test::serial;
use std::{env, fs, path::PathBuf};

fn fixture_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join("render")
}

fn set_frozen_env() {
    env::set_var("PARTNER_ID", "edge-b");
    env::set_var("PARTNER_DOMAIN", "edge-b.example");
    env::set_var("TURN_SECRET", "test-turn-secret-deadbeef");
    env::set_var("PUBLIC_IP", "157.22.204.190");
    env::set_var("PRIVATE_IP", "");
    env::set_var("EXTERNAL_IP_LINE", "157.22.204.190");
    env::set_var("TURNS_SUBDOMAIN", "api-test01");
}

#[test]
#[serial]
fn opec_render_coturn_byte_identical() {
    set_frozen_env();
    let dir = fixture_dir();
    let tpl = dir.join("coturn.tpl");
    let out = tempfile::NamedTempFile::new().unwrap();
    opec::render::coturn::render(&tpl, out.path()).expect("render ok");
    let actual = fs::read_to_string(out.path()).unwrap();
    let expected = fs::read_to_string(dir.join("expected").join("coturn.txt")).unwrap();
    assert_eq!(actual, expected);
}

#[test]
#[serial]
fn opec_render_coturn_validation_requires_realm_directive() {
    // Sanity: rendered file must contain a `realm=<domain>` line.
    // Verify by unsetting PARTNER_DOMAIN — rendered realm becomes `realm=`
    // which the validator must reject.
    set_frozen_env();
    env::set_var("PARTNER_DOMAIN", "");
    let dir = fixture_dir();
    let tpl = dir.join("coturn.tpl");
    let out = tempfile::NamedTempFile::new().unwrap();
    let err = opec::render::coturn::render(&tpl, out.path()).unwrap_err();
    assert!(
        err.to_string().contains("realm") || err.to_string().contains("coturn"),
        "expected realm/coturn validation error, got: {err}"
    );
}
