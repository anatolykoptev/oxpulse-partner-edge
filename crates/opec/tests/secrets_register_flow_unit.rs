//! Phase 4.3c — register POST + parse + env-file write flow tests.
//! Mock HTTP via mockito; no real network required.
use opec::secrets::{register, SecretsError};
use std::fs;
use tempfile::TempDir;

fn make_files(tmp: &std::path::Path) {
    fs::write(tmp.join("reality.pub"), "REALITY_PUB_VALUE\n").unwrap();
    fs::write(tmp.join("reality.uuid"), "11111111-2222-3333-4444-555555555555\n").unwrap();
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
    assert!(env.contains("NODE_ID=\"node-123\""));
    assert!(env.contains("BACKEND_ENDPOINT=\"1.2.3.4:5349\""));
    assert!(env.contains("TURN_SECRET=\"ts-deadbeef\""));
    assert!(env.contains("REALITY_ENCRYPTION=\"mlkem768x25519plus\""));
    assert!(env.contains("RELAY_JWT_SECRET=\"rjs-cafebabe\""));
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
        matches!(err, SecretsError::MissingResponseField { .. } | SecretsError::Http { .. }),
        "expected MissingResponseField or Http parse error, got {err:?}"
    );
}
