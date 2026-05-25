//! Phase 3 Task 1 — opec render compose byte-identical parity vs bash render_template.

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
    env::set_var("PARTNER_ID", "zvonilka");
    env::set_var("PARTNER_DOMAIN", "zvonilka.net");
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
    env::set_var("SFU_EDGE_ID", "zvonilka1");
    env::set_var("OTEL_EXPORTER_OTLP_ENDPOINT", "");
    env::set_var(
        "SFU_SIGNING_PUBLIC_KEY",
        "-----BEGIN PUBLIC KEY-----\\nMCowBQYDK2VwAyEAZiwaWp+FJ1sGprGGS69mq+sB6nhwOMi24xGSGfgdXNo=\\n-----END PUBLIC KEY-----\\n",
    );
    env::set_var("RELAY_JWT_SECRET", "test-relay-jwt-secret");
    env::set_var("SIGNALING_SFU_SECRET", "test-signaling-sfu-secret");
    // AWG_ALLOCATED_IP — this partner's own mesh IP. Wired into the SFU
    // SFU_METRICS_BIND / SFU_RELAY_API_BIND env vars by the compose template
    // so the privileged HTTP sockets are mesh-only. Audit 2026-05-21.
    env::set_var("AWG_ALLOCATED_IP", "10.9.0.6");
    env::set_var("HYSTERIA2_SOCKS_PORT", "18891");
    env::set_var("NAIVE_SOCKS_PORT", "18892");
    env::set_var("HY2_SERVER", "");
    env::set_var("HY2_AUTH_PASS", "");
    env::set_var("HY2_OBFS_PASS", "");
    env::set_var("HY2_LOCAL_LISTEN", "");
    env::set_var("HY2_REMOTE_BACKEND", "");
}

#[test]
#[serial]
fn opec_render_compose_byte_identical() {
    set_frozen_env();
    let dir = fixture_dir();
    let tpl = dir.join("compose.tpl");
    let out = tempfile::NamedTempFile::new().unwrap();
    opec::render::compose::render(&tpl, out.path()).expect("render ok");
    let actual = fs::read_to_string(out.path()).unwrap();
    let expected = fs::read_to_string(dir.join("expected").join("compose.txt")).unwrap();
    assert_eq!(actual, expected);
}

#[test]
#[serial]
fn opec_render_compose_validates_yaml() {
    set_frozen_env();
    let dir = fixture_dir();
    let tpl = dir.join("compose.tpl");
    let out = tempfile::NamedTempFile::new().unwrap();
    opec::render::compose::render(&tpl, out.path()).expect("render ok");
    let body = fs::read_to_string(out.path()).unwrap();
    serde_norway::from_str::<serde_norway::Value>(&body)
        .expect("rendered compose.yml must parse as YAML");
}

#[test]
#[serial]
fn opec_render_compose_rejects_unparseable_substituted_output() {
    set_frozen_env();
    // Inject a value that breaks YAML structure when substituted into a key.
    // PARTNER_ID appears in container_name labels — multi-line garbage breaks the doc.
    env::set_var("PARTNER_ID", "name\n!!INVALID\n  YAML: :");
    let dir = fixture_dir();
    let tpl = dir.join("compose.tpl");
    let out = tempfile::NamedTempFile::new().unwrap();
    let err = opec::render::compose::render(&tpl, out.path()).unwrap_err();
    assert!(
        err.to_string().contains("compose"),
        "expected validation error to mention kind, got: {err}"
    );
}
