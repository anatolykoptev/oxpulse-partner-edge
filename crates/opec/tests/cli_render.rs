//! Phase 2 Task 5 — `opec render <kind>` CLI integration test.

use assert_cmd::Command;
use serial_test::serial;
use std::{fs, path::PathBuf};

fn fixture_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join("render")
}

fn fixture_dir_install_render() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
        .join("tests")
        .join("fixtures")
        .join("install-render")
}

fn frozen_env() -> Vec<(&'static str, &'static str)> {
    vec![
        ("PARTNER_ID", "zvonilka"),
        ("PARTNER_DOMAIN", "zvonilka.net"),
        ("BACKEND_ENDPOINT", "192.9.243.148:5349"),
        ("BACKEND_HOST", "192.9.243.148"),
        ("BACKEND_PORT", "5349"),
        ("TURN_SECRET", "test-turn-secret-deadbeef"),
        ("REALITY_UUID", "d529dee6-3cdd-4079-95d1-f8801722147c"),
        ("REALITY_PUBLIC_KEY", "U6ea044JJjgiCjQAnYEBqBBlkeSqrQaLq3lcjnN2EFk"),
        ("REALITY_SHORT_ID", "abcd1234"),
        ("REALITY_SERVER_NAME", "www.samsung.com"),
        ("REALITY_ENCRYPTION", "mlkem768x25519plus.native.0rtt.fXgOoxcW"),
        ("TURNS_SUBDOMAIN", "api-test01"),
        ("PUBLIC_IP", "157.22.204.190"),
        ("PRIVATE_IP", ""),
        ("EXTERNAL_IP_LINE", "157.22.204.190"),
        ("IMAGE_VERSION", "stable"),
        ("SFU_UDP_PORT", "7878"),
        ("SFU_METRICS_PORT", "9317"),
        ("SFU_EDGE_ID", "zvonilka1"),
        ("OTEL_EXPORTER_OTLP_ENDPOINT", ""),
        (
            "SFU_SIGNING_PUBLIC_KEY",
            "-----BEGIN PUBLIC KEY-----\\nMCowBQYDK2VwAyEAZiwaWp+FJ1sGprGGS69mq+sB6nhwOMi24xGSGfgdXNo=\\n-----END PUBLIC KEY-----\\n",
        ),
        ("RELAY_JWT_SECRET", "test-relay-jwt-secret"),
        ("SIGNALING_SFU_SECRET", "test-signaling-sfu-secret"),
        ("HYSTERIA2_SOCKS_PORT", "18891"),
        ("NAIVE_SERVER", ""),
        ("NAIVE_PORT", "44433"),
        ("NAIVE_USER", ""),
        ("NAIVE_PASS", ""),
        ("NAIVE_SOCKS_PORT", "18892"),
        ("HY2_SERVER", ""),
        ("HY2_AUTH_PASS", ""),
        ("HY2_OBFS_PASS", ""),
        ("HY2_LOCAL_LISTEN", ""),
        ("HY2_REMOTE_BACKEND", ""),
    ]
}

#[test]
#[serial]
fn cli_render_xray_byte_identical_to_fixture() {
    let dir = fixture_dir();
    let tpl = dir.join("xray.tpl");
    let out_dir = tempfile::tempdir().unwrap();
    let out = out_dir.path().join("xray-client.json");

    let mut cmd = Command::cargo_bin("opec").unwrap();
    for (k, v) in frozen_env() {
        cmd.env(k, v);
    }
    cmd.args(["render", "xray", "--tpl"])
        .arg(&tpl)
        .args(["--out"])
        .arg(&out)
        .assert()
        .success();

    let actual = fs::read_to_string(&out).unwrap();
    let expected = fs::read_to_string(dir.join("expected").join("xray.txt")).unwrap();
    assert_eq!(actual, expected);
}

#[test]
#[serial]
fn cli_render_compose_byte_identical_to_fixture() {
    let dir = fixture_dir_install_render();
    let tpl = dir.join("compose.tpl");
    let out_dir = tempfile::tempdir().unwrap();
    let out = out_dir.path().join("docker-compose.yml");

    let mut cmd = Command::cargo_bin("opec").unwrap();
    for (k, v) in frozen_env() {
        cmd.env(k, v);
    }
    cmd.args(["render", "compose", "--tpl"])
        .arg(&tpl)
        .args(["--out"])
        .arg(&out)
        .assert()
        .success();

    let actual = fs::read_to_string(&out).unwrap();
    let expected = fs::read_to_string(dir.join("expected").join("compose.txt")).unwrap();
    assert_eq!(actual, expected);
}

#[test]
#[serial]
fn cli_render_caddy_byte_identical_to_fixture() {
    let dir = fixture_dir_install_render();
    let tpl = dir.join("caddy.tpl");
    let out_dir = tempfile::tempdir().unwrap();
    let out = out_dir.path().join("Caddyfile");

    let mut cmd = Command::cargo_bin("opec").unwrap();
    for (k, v) in frozen_env() {
        cmd.env(k, v);
    }
    cmd.args(["render", "caddy", "--tpl"])
        .arg(&tpl)
        .args(["--out"])
        .arg(&out)
        .assert()
        .success();

    let actual = fs::read_to_string(&out).unwrap();
    let expected = fs::read_to_string(dir.join("expected").join("caddy.txt")).unwrap();
    assert_eq!(actual, expected);
}

#[test]
#[serial]
fn cli_render_unknown_kind_errors() {
    let mut cmd = Command::cargo_bin("opec").unwrap();
    cmd.args(["render", "bogus", "--tpl", "/tmp/x", "--out", "/tmp/y"])
        .assert()
        .failure();
}
