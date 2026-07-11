//! Phase 2 Task 4 — opec render naive byte-identical parity vs bash render_template.

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
    env::set_var("NAIVE_SERVER", "");
    env::set_var("NAIVE_PORT", "44433");
    env::set_var("NAIVE_USER", "");
    env::set_var("NAIVE_PASS", "");
    env::set_var("NAIVE_SOCKS_PORT", "18892");
}

#[test]
#[serial]
fn opec_render_naive_byte_identical() {
    set_frozen_env();
    let dir = fixture_dir();
    let tpl = dir.join("naive.tpl");
    let out = tempfile::NamedTempFile::new().unwrap();
    opec::render::naive::render(&tpl, out.path()).expect("render ok");
    let actual = fs::read_to_string(out.path()).unwrap();
    let expected = fs::read_to_string(dir.join("expected").join("naive.txt")).unwrap();
    assert_eq!(actual, expected);
}

#[test]
#[serial]
fn opec_render_naive_validates_json() {
    set_frozen_env();
    let dir = fixture_dir();
    let tpl = dir.join("naive.tpl");
    let out = tempfile::NamedTempFile::new().unwrap();
    opec::render::naive::render(&tpl, out.path()).expect("render ok");
    let body = fs::read_to_string(out.path()).unwrap();
    serde_json::from_str::<serde_json::Value>(&body)
        .expect("rendered naive-client.json must parse as JSON");
}
