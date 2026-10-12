//! Relay-only node: per-node TURN secret file validation + `render coturn --secret-file`.

use assert_cmd::Command;
use serial_test::serial;
use std::{
    fs,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
};

const S1: &str = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
const S2: &str = "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB";
const S3: &str = "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC";

fn tpl() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../relay/coturn-relay.conf.tpl")
}

fn write_secret(dir: &Path, content: &str, mode: u32) -> PathBuf {
    let p = dir.join("node-secret");
    let _ = fs::remove_file(&p);
    fs::write(&p, content).unwrap();
    fs::set_permissions(&p, fs::Permissions::from_mode(mode)).unwrap();
    p
}

fn check(p: &Path) -> assert_cmd::assert::Assert {
    Command::cargo_bin("opec")
        .unwrap()
        .args(["check-node-secret", "--file"])
        .arg(p)
        .assert()
}

#[test]
fn fixtures_are_43_chars() {
    assert_eq!((S1.len(), S2.len(), S3.len()), (43, 43, 43));
}

#[test]
fn good_one_and_two_line_files_pass() {
    let d = tempfile::tempdir().unwrap();
    check(&write_secret(d.path(), &format!("{S1}\n"), 0o600))
        .success()
        .stdout("node secret ok: 1 line(s)\n");
    check(&write_secret(d.path(), &format!("{S1}\n{S2}\n"), 0o600))
        .success()
        .stdout("node secret ok: 2 line(s)\n");
    check(&write_secret(d.path(), S1, 0o600)).success(); // no trailing newline
}

#[test]
fn wrong_mode_fails() {
    let d = tempfile::tempdir().unwrap();
    for mode in [0o640, 0o644, 0o400, 0o700] {
        check(&write_secret(d.path(), &format!("{S1}\n"), mode))
            .failure()
            .stderr(predicates::str::contains("mode"));
    }
}

#[test]
fn bad_charset_fails() {
    let d = tempfile::tempdir().unwrap();
    // 43 chars, one '+' (standard base64, not base64url)
    let bad = format!("{}+", &S1[..42]);
    assert_eq!(bad.len(), 43);
    check(&write_secret(d.path(), &format!("{bad}\n"), 0o600))
        .failure()
        .stderr(predicates::str::contains("line 1"))
        .stderr(predicates::str::contains(bad.as_str()).not());
}

#[test]
fn wrong_length_blank_crlf_and_empty_fail() {
    let d = tempfile::tempdir().unwrap();
    for content in [
        "AAAA\n".to_string(),
        format!("{S1}A\n"),
        format!("{S1}\n\n"),
        format!("{S1}\r\n"),
        String::new(),
        "\n".to_string(),
    ] {
        check(&write_secret(d.path(), &content, 0o600)).failure();
    }
}

#[test]
fn three_lines_and_duplicates_fail() {
    let d = tempfile::tempdir().unwrap();
    check(&write_secret(
        d.path(),
        &format!("{S1}\n{S2}\n{S3}\n"),
        0o600,
    ))
    .failure()
    .stderr(predicates::str::contains("at most 2"));
    check(&write_secret(d.path(), &format!("{S1}\n{S1}\n"), 0o600))
        .failure()
        .stderr(predicates::str::contains("duplicates"));
}

#[test]
fn symlink_is_refused() {
    let d = tempfile::tempdir().unwrap();
    let real = write_secret(d.path(), &format!("{S1}\n"), 0o600);
    let link = d.path().join("link");
    std::os::unix::fs::symlink(&real, &link).unwrap();
    check(&link)
        .failure()
        .stderr(predicates::str::contains("symlink"));
}

use predicates::prelude::PredicateBooleanExt;

fn render(secret: &Path, out: &Path) -> assert_cmd::assert::Assert {
    Command::cargo_bin("opec")
        .unwrap()
        .env("RELAY_HOSTNAME", "relay.example.org")
        .env("EXTERNAL_IP", "203.0.113.10")
        .args(["render", "coturn", "--tpl"])
        .arg(tpl())
        .arg("--out")
        .arg(out)
        .arg("--secret-file")
        .arg(secret)
        .assert()
}

#[test]
fn render_two_lines_gives_two_secret_lines_and_prints_no_secret() {
    let d = tempfile::tempdir().unwrap();
    let sec = write_secret(d.path(), &format!("{S1}\n{S2}\n"), 0o600);
    let out = d.path().join("coturn.conf");
    let assert = render(&sec, &out).success();
    let o = assert.get_output();
    let streams = format!(
        "{}{}",
        String::from_utf8_lossy(&o.stdout),
        String::from_utf8_lossy(&o.stderr)
    );
    assert!(
        !streams.contains(S1) && !streams.contains(S2),
        "secret leaked to stdout/stderr"
    );
    let conf = fs::read_to_string(&out).unwrap();
    let lines: Vec<&str> = conf
        .lines()
        .filter(|l| l.starts_with("static-auth-secret="))
        .collect();
    assert_eq!(
        lines,
        [
            format!("static-auth-secret={S1}"),
            format!("static-auth-secret={S2}")
        ]
    );
    assert!(conf.contains("realm=relay.example.org") && conf.contains("external-ip=203.0.113.10"));
    assert!(!conf.contains("{{"), "unrendered placeholder");
}

#[test]
fn render_relay_profile_directives() {
    let d = tempfile::tempdir().unwrap();
    let sec = write_secret(d.path(), &format!("{S1}\n"), 0o600);
    let out = d.path().join("coturn.conf");
    render(&sec, &out).success();
    let conf = fs::read_to_string(&out).unwrap();
    for want in [
        "listening-port=3478",
        "tls-listening-port=443",
        "no-cli",
        "no-tcp-relay",
        "no-multicast-peers",
        "min-port=49152",
        "max-port=65535",
        "use-auth-secret",
        "fingerprint",
        "denied-peer-ip=10.0.0.0-10.255.255.255",
        "denied-peer-ip=100.64.0.0-100.127.255.255",
        "denied-peer-ip=fc00::-fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff",
        "syslog",
    ] {
        assert!(conf.lines().any(|l| l == want), "missing {want}");
    }
    assert!(!conf.lines().any(|l| l == "verbose"
        || l.starts_with("allowed-peer-ip")
        || l.starts_with("prometheus")));
}

#[test]
fn render_refuses_invalid_secret_file_and_writes_nothing() {
    let d = tempfile::tempdir().unwrap();
    let sec = write_secret(d.path(), &format!("{S1}\n"), 0o644);
    let out = d.path().join("coturn.conf");
    render(&sec, &out).failure();
    assert!(!out.exists());
}

#[test]
#[serial]
fn render_without_secret_file_refuses_a_secret_template() {
    let d = tempfile::tempdir().unwrap();
    let out = d.path().join("coturn.conf");
    Command::cargo_bin("opec")
        .unwrap()
        .env("RELAY_HOSTNAME", "relay.example.org")
        .env("EXTERNAL_IP", "203.0.113.10")
        .args(["render", "coturn", "--tpl"])
        .arg(tpl())
        .arg("--out")
        .arg(&out)
        .assert()
        .failure()
        .stderr(predicates::str::contains("--secret-file"));
    assert!(!out.exists());
}

#[test]
fn secret_file_flag_is_coturn_only() {
    let d = tempfile::tempdir().unwrap();
    let sec = write_secret(d.path(), &format!("{S1}\n"), 0o600);
    Command::cargo_bin("opec")
        .unwrap()
        .args(["render", "xray", "--tpl"])
        .arg(tpl())
        .arg("--out")
        .arg(d.path().join("x"))
        .arg("--secret-file")
        .arg(&sec)
        .assert()
        .failure();
}

#[test]
fn render_denies_only_explicit_peer_ip_ranges() {
    // coturn 4.6.1 (add_ip_list_range, userdb.c): a peer-ip value with no '-'
    // becomes the range [addr, addr] — EXCEPT the all-zero 'any' address:
    // addr_any() then holds for both endpoints and ioa_addr_in_range()
    // matches EVERY peer, IPv4 included ('8.8.8.8 denied in the range: ::',
    // observed live on msk1). The only bare single-address form proven safe
    // is the IPv6 loopback '::1'.
    const SINGLE_ADDR_ALLOWLIST: &[&str] = &["::1"];
    let d = tempfile::tempdir().unwrap();
    let sec = write_secret(d.path(), &format!("{S1}\n"), 0o600);
    let out = d.path().join("coturn.conf");
    render(&sec, &out).success();
    let conf = fs::read_to_string(&out).unwrap();
    for line in conf.lines() {
        let Some(v) = line
            .strip_prefix("denied-peer-ip=")
            .or_else(|| line.strip_prefix("allowed-peer-ip="))
        else {
            continue;
        };
        assert!(
            v.contains('-') || SINGLE_ADDR_ALLOWLIST.contains(&v),
            "peer-ip directive without an explicit - range end: {line}"
        );
    }
}

#[test]
fn relay_template_denies_every_range_the_full_edge_template_denies() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    let denied = |p: PathBuf| -> Vec<String> {
        fs::read_to_string(p)
            .unwrap()
            .lines()
            .filter(|l| l.starts_with("denied-peer-ip="))
            .map(String::from)
            .collect()
    };
    let relay = denied(root.join("relay/coturn-relay.conf.tpl"));
    for d in denied(root.join("coturn.conf.tpl")) {
        assert!(relay.contains(&d), "relay template lost {d}");
    }
}

#[test]
fn hard_linked_secret_file_is_refused() {
    let d = tempfile::tempdir().unwrap();
    let real = write_secret(d.path(), &format!("{S1}\n"), 0o600);
    fs::hard_link(&real, d.path().join("alias")).unwrap();
    check(&real)
        .failure()
        .stderr(predicates::str::contains("hard links"));
}

#[test]
fn render_with_template_lacking_the_placeholder_fails_and_writes_nothing() {
    // Without the placeholder the secret lines would silently not land in the
    // config; coturn would then run with no auth secret.
    let d = tempfile::tempdir().unwrap();
    let sec = write_secret(d.path(), &format!("{S1}\n{S2}\n"), 0o600);
    let no_ph = d.path().join("no-placeholder.tpl");
    let body = fs::read_to_string(tpl())
        .unwrap()
        .replace("{{STATIC_AUTH_SECRET_LINES}}", "");
    fs::write(&no_ph, body).unwrap();
    let out = d.path().join("coturn.conf");
    Command::cargo_bin("opec")
        .unwrap()
        .env("RELAY_HOSTNAME", "relay.example.org")
        .env("EXTERNAL_IP", "203.0.113.10")
        .args(["render", "coturn", "--tpl"])
        .arg(&no_ph)
        .arg("--out")
        .arg(&out)
        .arg("--secret-file")
        .arg(&sec)
        .assert()
        .failure()
        .stderr(predicates::str::contains("static-auth-secret line"));
    assert!(
        !out.exists(),
        "a config without auth secrets must not be written"
    );
}
