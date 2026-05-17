//! Phase 2 Task 2 — opec render xray byte-identical parity vs bash render_template.

use std::{env, fs, path::PathBuf};

fn fixture_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join("render")
}

fn set_frozen_env() {
    env::set_var("PARTNER_ID", "zvonilka");
    env::set_var("PARTNER_DOMAIN", "zvonilka.net");
    env::set_var("BACKEND_ENDPOINT", "192.9.243.148:5349");
    env::set_var("BACKEND_HOST", "192.9.243.148");
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
    env::set_var("HYSTERIA2_SOCKS_PORT", "18891");
    env::set_var("NAIVE_SOCKS_PORT", "18892");
}

#[test]
fn opec_render_xray_byte_identical_to_bash_render_template() {
    set_frozen_env();
    let dir = fixture_dir();
    let tpl = dir.join("xray.tpl");
    let out = tempfile::NamedTempFile::new().unwrap();
    opec::render::xray::render(&tpl, out.path()).expect("render ok");
    let actual = fs::read_to_string(out.path()).unwrap();
    let expected = fs::read_to_string(dir.join("expected").join("xray.txt")).unwrap();
    assert_eq!(actual, expected, "OPEC render output diverged from bash baseline");
}

#[test]
fn opec_render_xray_validates_json_after_substitution() {
    set_frozen_env();
    let dir = fixture_dir();
    let tpl = dir.join("xray.tpl");
    let out = tempfile::NamedTempFile::new().unwrap();
    opec::render::xray::render(&tpl, out.path()).expect("render ok");
    let body = fs::read_to_string(out.path()).unwrap();
    serde_json::from_str::<serde_json::Value>(&body)
        .expect("rendered xray-client.json must parse as JSON");
}

#[test]
fn opec_render_xray_rejects_unparseable_substituted_output() {
    // Inject a non-numeric string into BACKEND_PORT which is used in a bare
    // number context ("port": {{BACKEND_PORT}}). After substitution the
    // rendered file is invalid JSON and render() must return a Validation error.
    set_frozen_env();
    env::set_var("BACKEND_PORT", "not-a-number");
    let dir = fixture_dir();
    let tpl = dir.join("xray.tpl");
    let out = tempfile::NamedTempFile::new().unwrap();
    let err = opec::render::xray::render(&tpl, out.path()).unwrap_err();
    assert!(
        err.to_string().contains("xray"),
        "expected validation error to mention kind, got: {err}"
    );
}
