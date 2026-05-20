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
    // The nested if-let structure is intentional: downcast and pattern-match are
    // separate concerns (downcast can fail; pattern-match guards the variant).
    #[allow(clippy::collapsible_match)]
    if let Err(e) = result {
        if let Ok(render_err) = e.downcast::<RenderError>() {
            if let RenderError::Validation { reason, .. } = render_err {
                assert!(
                    !reason.contains("test fixture"),
                    "empty server should not trigger fixture guard, got: {reason}"
                );
            }
        }
    }
}

// ── MAJOR #2 + MINOR #1/#2 — extended RFC fixture patterns ───────────────────
// RFC2606: *.invalid
#[test]
#[serial]
fn naive_render_rejects_dot_invalid_host() {
    // RFC2606 §2 — .invalid TLD reserved for invalid/error indicators.
    set_fixture_env("proxy.invalid");
    let tpl = fixture_dir().join("naive.tpl");
    let out = tempfile::NamedTempFile::new().unwrap();
    let result = naive::render(&tpl, out.path());
    assert_validation_err(result, "proxy.invalid");
}

#[test]
#[serial]
fn naive_render_rejects_bare_invalid() {
    set_fixture_env("invalid");
    let tpl = fixture_dir().join("naive.tpl");
    let out = tempfile::NamedTempFile::new().unwrap();
    let result = naive::render(&tpl, out.path());
    assert_validation_err(result, "invalid");
}

#[test]
#[serial]
fn naive_render_rejects_example_invalid() {
    // example.invalid — combined RFC2606 hostname
    set_fixture_env("example.invalid");
    let tpl = fixture_dir().join("naive.tpl");
    let out = tempfile::NamedTempFile::new().unwrap();
    let result = naive::render(&tpl, out.path());
    assert_validation_err(result, "example.invalid");
}

// RFC5737 documentation IP ranges
#[test]
#[serial]
fn naive_render_rejects_rfc5737_192_0_2() {
    // 192.0.2.0/24 — TEST-NET-1 (RFC5737)
    set_fixture_env("192.0.2.1");
    let tpl = fixture_dir().join("naive.tpl");
    let out = tempfile::NamedTempFile::new().unwrap();
    let result = naive::render(&tpl, out.path());
    assert_validation_err(result, "192.0.2.1");
}

#[test]
#[serial]
fn naive_render_rejects_rfc5737_198_51_100() {
    // 198.51.100.0/24 — TEST-NET-2 (RFC5737)
    set_fixture_env("198.51.100.42");
    let tpl = fixture_dir().join("naive.tpl");
    let out = tempfile::NamedTempFile::new().unwrap();
    let result = naive::render(&tpl, out.path());
    assert_validation_err(result, "198.51.100.42");
}

#[test]
#[serial]
fn naive_render_rejects_rfc5737_203_0_113() {
    // 203.0.113.0/24 — TEST-NET-3 (RFC5737)
    set_fixture_env("203.0.113.99");
    let tpl = fixture_dir().join("naive.tpl");
    let out = tempfile::NamedTempFile::new().unwrap();
    let result = naive::render(&tpl, out.path());
    assert_validation_err(result, "203.0.113.99");
}

// Link-local
#[test]
#[serial]
fn naive_render_rejects_link_local_169_254() {
    // 169.254.x.x — IPv4 link-local (RFC3927)
    set_fixture_env("169.254.1.1");
    let tpl = fixture_dir().join("naive.tpl");
    let out = tempfile::NamedTempFile::new().unwrap();
    let result = naive::render(&tpl, out.path());
    assert_validation_err(result, "169.254.1.1");
}

// Loopback IPv4
#[test]
#[serial]
fn naive_render_rejects_loopback_127_x() {
    // 127.x.x.x — loopback block (RFC1122)
    set_fixture_env("127.0.0.1");
    let tpl = fixture_dir().join("naive.tpl");
    let out = tempfile::NamedTempFile::new().unwrap();
    let result = naive::render(&tpl, out.path());
    assert_validation_err(result, "127.0.0.1");
}

#[test]
#[serial]
fn naive_render_rejects_loopback_127_non_zero() {
    set_fixture_env("127.1.2.3");
    let tpl = fixture_dir().join("naive.tpl");
    let out = tempfile::NamedTempFile::new().unwrap();
    let result = naive::render(&tpl, out.path());
    assert_validation_err(result, "127.1.2.3");
}

// 0.0.0.0
#[test]
#[serial]
fn naive_render_rejects_zero_address() {
    set_fixture_env("0.0.0.0");
    let tpl = fixture_dir().join("naive.tpl");
    let out = tempfile::NamedTempFile::new().unwrap();
    let result = naive::render(&tpl, out.path());
    assert_validation_err(result, "0.0.0.0");
}

// IPv6 loopback
#[test]
#[serial]
fn naive_render_rejects_ipv6_loopback() {
    // ::1 — IPv6 loopback
    set_fixture_env("::1");
    let tpl = fixture_dir().join("naive.tpl");
    let out = tempfile::NamedTempFile::new().unwrap();
    let result = naive::render(&tpl, out.path());
    assert_validation_err(result, "::1");
}

#[test]
#[serial]
fn naive_render_rejects_ipv6_unspecified() {
    // :: — IPv6 unspecified address
    set_fixture_env("::");
    let tpl = fixture_dir().join("naive.tpl");
    let out = tempfile::NamedTempFile::new().unwrap();
    let result = naive::render(&tpl, out.path());
    assert_validation_err(result, "::");
}

// MINOR #2 — case sensitivity: Rust regex already uses (?i), verify uppercase hosts
#[test]
#[serial]
fn naive_render_rejects_uppercase_example_com() {
    // Example.COM — case-insensitive match via (?i)
    set_fixture_env("Example.COM");
    let tpl = fixture_dir().join("naive.tpl");
    let out = tempfile::NamedTempFile::new().unwrap();
    let result = naive::render(&tpl, out.path());
    assert_validation_err(result, "Example.COM");
}

#[test]
#[serial]
fn naive_render_rejects_uppercase_localhost() {
    set_fixture_env("LOCALHOST");
    let tpl = fixture_dir().join("naive.tpl");
    let out = tempfile::NamedTempFile::new().unwrap();
    let result = naive::render(&tpl, out.path());
    assert_validation_err(result, "LOCALHOST");
}
