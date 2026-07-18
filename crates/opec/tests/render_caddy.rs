//! Phase 3 Task 2 — opec render caddy byte-identical parity vs bash render_template.

use serial_test::serial;
use std::{env, fs, path::PathBuf};

fn fixture_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
        .join("tests")
        .join("fixtures")
        .join("install-render")
}

fn set_frozen_env() {
    // SAME as render_compose.rs frozen env. Keep in sync — both reuse Phase 1 fixtures.
    env::set_var("PARTNER_ID", "edge-b");
    env::set_var("PARTNER_DOMAIN", "edge-b.example");
    env::set_var("BACKEND_ENDPOINT", "203.0.113.10:5349");
    env::set_var("BACKEND_HOST", "203.0.113.10");
    env::set_var("BACKEND_PORT", "5349");
    env::set_var("TURN_SECRET", "test-turn-secret-deadbeef");
    env::set_var("REALITY_UUID", "d529dee6-3cdd-4079-95d1-f8801722147c");
    env::set_var(
        "REALITY_PUBLIC_KEY",
        "U6ea044JJjgiCjQAnYEBqBBlkeSqrQaLq3lcjnN2EFk",
    );
    env::set_var("REALITY_SHORT_ID", "abcd1234");
    env::set_var("REALITY_SERVER_NAME", "www.samsung.com");
    env::set_var(
        "REALITY_ENCRYPTION",
        "mlkem768x25519plus.native.0rtt.fXgOoxcW",
    );
    env::set_var("TURNS_SUBDOMAIN", "api-test01");
    env::set_var("PUBLIC_IP", "157.22.204.190");
    env::set_var("PRIVATE_IP", "");
    env::set_var("EXTERNAL_IP_LINE", "157.22.204.190");
    env::set_var("IMAGE_VERSION", "stable");
    env::set_var("SFU_UDP_PORT", "7878");
    env::set_var("SFU_METRICS_PORT", "9317");
    env::set_var("SFU_EDGE_ID", "edge-b1");
    env::set_var("OTEL_EXPORTER_OTLP_ENDPOINT", "");
    env::set_var(
        "SFU_SIGNING_PUBLIC_KEY",
        "-----BEGIN PUBLIC KEY-----\\nMCowBQYDK2VwAyEAZiwaWp+FJ1sGprGGS69mq+sB6nhwOMi24xGSGfgdXNo=\\n-----END PUBLIC KEY-----\\n",
    );
    env::set_var("RELAY_JWT_SECRET", "test-relay-jwt-secret");
    env::set_var("SIGNALING_SFU_SECRET", "test-signaling-sfu-secret");
    env::set_var("HYSTERIA2_SOCKS_PORT", "18891");
    env::set_var("NAIVE_SOCKS_PORT", "18892");
    env::set_var("HY2_SERVER", "");
    env::set_var("HY2_AUTH_PASS", "");
    env::set_var("HY2_OBFS_PASS", "");
    env::set_var("HY2_LOCAL_LISTEN", "");
    env::set_var("HY2_REMOTE_BACKEND", "");
    // Caddy tunnel_upstream snippet — refactored to take AWG/SFU-relay backend
    // plus a hysteria2 fallback. Fixture encodes these literals.
    env::set_var("AWG_MOTHERLY_IP", "10.9.0.2");
    env::set_var("HY2_FALLBACK_HOST", "host.docker.internal");
    env::set_var("HY2_FALLBACK_PORT", "18443");
}

#[test]
#[serial]
fn opec_render_caddy_byte_identical() {
    set_frozen_env();
    let dir = fixture_dir();
    let tpl = dir.join("caddy.tpl");
    let out = tempfile::NamedTempFile::new().unwrap();
    opec::render::caddy::render(&tpl, out.path()).expect("render ok");
    let actual = fs::read_to_string(out.path()).unwrap();
    let expected = fs::read_to_string(dir.join("expected").join("caddy.txt")).unwrap();
    assert_eq!(actual, expected);
}

#[test]
#[serial]
fn opec_render_caddy_validates_balanced_braces() {
    set_frozen_env();
    let dir = fixture_dir();
    let tpl = dir.join("caddy.tpl");
    let out = tempfile::NamedTempFile::new().unwrap();
    opec::render::caddy::render(&tpl, out.path()).expect("render ok");
    let body = fs::read_to_string(out.path()).unwrap();
    let opens = body.bytes().filter(|&b| b == b'{').count();
    let closes = body.bytes().filter(|&b| b == b'}').count();
    assert_eq!(
        opens, closes,
        "rendered Caddyfile must have balanced braces"
    );
}

#[test]
#[serial]
fn opec_render_caddy_rejects_unbalanced_braces() {
    // Inject a stray `{` via TURNS_SUBDOMAIN, which appears 4 times in
    // caddy.tpl; an extra `{` produces unbalanced output.
    set_frozen_env();
    env::set_var("TURNS_SUBDOMAIN", "api-test01{extra-open");
    let dir = fixture_dir();
    let tpl = dir.join("caddy.tpl");
    let out = tempfile::NamedTempFile::new().unwrap();
    let err = opec::render::caddy::render(&tpl, out.path()).unwrap_err();
    assert!(
        err.to_string().contains("caddy"),
        "expected validation error to mention kind, got: {err}"
    );
}
