//! Fix #2 — fixture-host guard for naive::render.
//!
//! Regression test: if NAIVE_SERVER is a test fixture host (*.example.com,
//! localhost, *.test), naive::render must return RenderError::Validation
//! before starting the container, not silently produce a config that will
//! crashloop.
//!
//! Evidence: ruoxp shipped naive_server=naive-test.example.com on 2026-05-17
//! and the container crashed because real DNS doesn't resolve.
//!
//! See: reports/partner-edge/investigations/2026-05-17-ruoxp-naive-fixture-crashloop.md

use opec::render::{naive, RenderError};
use serial_test::serial;
use std::{env, path::PathBuf};

fn fixture_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join("render")
}

fn set_fixture_env(naive_server: &str) {
    env::set_var("NAIVE_SERVER", naive_server);
    env::set_var("NAIVE_PORT", "44433");
    env::set_var("NAIVE_USER", "testuser");
    env::set_var("NAIVE_PASS", "testpass");
    env::set_var("NAIVE_SOCKS_PORT", "1080");
    env::set_var("PARTNER_ID", "zvonilka");
    env::set_var("PARTNER_DOMAIN", "zvonilka.net");
}

// Helper: assert err is RenderError::Validation for "naive"
fn assert_validation_err(result: anyhow::Result<()>, host: &str) {
    let err = result.expect_err(&format!(
        "naive::render should reject fixture host '{}' with Validation error",
        host
    ));
    // Downcast to RenderError
    let render_err = err
        .downcast::<RenderError>()
        .unwrap_or_else(|e| panic!("expected RenderError, got: {e:?}"));
    match &render_err {
        RenderError::Validation { kind, reason } => {
            assert_eq!(*kind, "naive", "kind must be 'naive'");
            assert!(
                reason.contains("test fixture"),
                "reason should mention 'test fixture', got: {reason}"
            );
        }
        other => panic!("expected RenderError::Validation, got: {other:?}"),
    }
}

/// naive-test.example.com is the exact host from the ruoxp crashloop incident.
#[test]
#[serial]
fn naive_render_rejects_example_com_fixture() {
    set_fixture_env("naive-test.example.com");
    let tpl = fixture_dir().join("naive.tpl");
    let out = tempfile::NamedTempFile::new().unwrap();
    let result = naive::render(&tpl, out.path());
    assert_validation_err(result, "naive-test.example.com");
}

#[test]
#[serial]
fn naive_render_rejects_bare_example_com() {
    set_fixture_env("example.com");
    let tpl = fixture_dir().join("naive.tpl");
    let out = tempfile::NamedTempFile::new().unwrap();
    let result = naive::render(&tpl, out.path());
    assert_validation_err(result, "example.com");
}

#[test]
#[serial]
fn naive_render_rejects_localhost() {
    set_fixture_env("localhost");
    let tpl = fixture_dir().join("naive.tpl");
    let out = tempfile::NamedTempFile::new().unwrap();
    let result = naive::render(&tpl, out.path());
    assert_validation_err(result, "localhost");
}

#[test]
#[serial]
fn naive_render_rejects_dot_test_host() {
    set_fixture_env("naive.test");
    let tpl = fixture_dir().join("naive.tpl");
    let out = tempfile::NamedTempFile::new().unwrap();
    let result = naive::render(&tpl, out.path());
    assert_validation_err(result, "naive.test");
}

#[test]
#[serial]
fn naive_render_rejects_example_net() {
    set_fixture_env("proxy.example.net");
    let tpl = fixture_dir().join("naive.tpl");
    let out = tempfile::NamedTempFile::new().unwrap();
    let result = naive::render(&tpl, out.path());
    assert_validation_err(result, "proxy.example.net");
}

/// A real production host must NOT be rejected.
#[test]
#[serial]
fn naive_render_allows_real_host() {
    set_fixture_env("naive.zvonilka.net");
    let tpl = fixture_dir().join("naive.tpl");
    let out = tempfile::NamedTempFile::new().unwrap();
    naive::render(&tpl, out.path()).expect("real host should render without error");
}

/// Empty NAIVE_SERVER (default state before any channel config) must not trip
/// the guard — the proxy URL will be malformed and caught by JSON validation,
/// not fixture guard.
#[test]
#[serial]
fn naive_render_empty_server_not_fixture_error() {
    set_fixture_env("");
    let tpl = fixture_dir().join("naive.tpl");
    let out = tempfile::NamedTempFile::new().unwrap();
    let result = naive::render(&tpl, out.path());
    // May succeed or fail with JSON-invalid error, but NOT with fixture-host reason
    if let Err(e) = result {
        if let Ok(render_err) = e.downcast::<RenderError>() {
            if let RenderError::Validation { reason, .. } = &render_err {
                assert!(
                    !reason.contains("test fixture"),
                    "empty server should not trigger fixture guard, got: {reason}"
                );
            }
        }
    }
}
