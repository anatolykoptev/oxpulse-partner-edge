//! Phase 4.3d — sfu-signing-key GET + parse + env-file write flow tests.
//! Mock HTTP via mockito; no real network required.
use opec::secrets::{sfu_key, SecretsError};
use std::fs;
use tempfile::TempDir;

fn args_for(tmp: &std::path::Path, backend_api: String) -> sfu_key::Args {
    sfu_key::Args {
        backend_api,
        out_file: tmp.join("sfu-keys.env"),
        timeout_secs: 5,
        retries: 1,
    }
}

/// 1. Success: multi-line PEM → embedded newlines replaced with literal \n,
///    single-quoted, 0600 permissions.
#[test]
fn sfu_key_fetch_success_writes_file() {
    let mut server = mockito::Server::new();
    let pem = "-----BEGIN PUBLIC KEY-----\nMCowBQYDK2VwAyEAZiwaWp+FJ1sGprGGS69mq+sB6nhwOMi24xGSGfgdXNo=\n-----END PUBLIC KEY-----\n";
    let _mock = server
        .mock("GET", "/api/partner/keys")
        .with_status(200)
        .with_body(format!(r#"{{"sfu_signing_public_key": {}}}"#, serde_json::to_string(pem).unwrap()))
        .create();

    let tmp = TempDir::new().unwrap();
    sfu_key::fetch(args_for(tmp.path(), server.url())).expect("fetch succeeds");

    let content = fs::read_to_string(tmp.path().join("sfu-keys.env")).unwrap();

    // Newlines replaced with literal \n
    assert!(
        !content.contains('\n'.to_string().as_str().repeat(2).as_str()),
        "PEM real newlines must be replaced with literal \\n"
    );
    // Single-quoted
    assert!(
        content.contains("SFU_SIGNING_PUBLIC_KEY='"),
        "value must be single-quoted; got:\n{content}"
    );
    // Length check: PEM was multi-line, now has literal \n
    assert!(
        content.contains("\\n"),
        "embedded PEM newlines must become literal \\n; got:\n{content}"
    );

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = fs::metadata(tmp.path().join("sfu-keys.env"))
            .unwrap()
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(mode, 0o600, "sfu-keys.env must be 0600");
    }
}

/// 2. Empty string value → file NOT created, Ok returned (warn semantics).
#[test]
fn sfu_key_fetch_empty_key_warns_does_not_fail() {
    let mut server = mockito::Server::new();
    let _mock = server
        .mock("GET", "/api/partner/keys")
        .with_status(200)
        .with_body(r#"{"sfu_signing_public_key": ""}"#)
        .create();

    let tmp = TempDir::new().unwrap();
    let result = sfu_key::fetch(args_for(tmp.path(), server.url()));
    assert!(result.is_ok(), "empty key must be Ok (warn semantics), got: {result:?}");
    assert!(
        !tmp.path().join("sfu-keys.env").exists(),
        "file must NOT be created when key is empty"
    );
}

/// 3. Missing field in response → file NOT created, Ok returned (warn semantics).
#[test]
fn sfu_key_fetch_missing_field_warns_does_not_fail() {
    let mut server = mockito::Server::new();
    let _mock = server
        .mock("GET", "/api/partner/keys")
        .with_status(200)
        .with_body(r#"{}"#)
        .create();

    let tmp = TempDir::new().unwrap();
    let result = sfu_key::fetch(args_for(tmp.path(), server.url()));
    assert!(result.is_ok(), "missing field must be Ok (warn semantics), got: {result:?}");
    assert!(
        !tmp.path().join("sfu-keys.env").exists(),
        "file must NOT be created when field is missing"
    );
}

/// 4. 5xx always → Http error after retries exhausted.
#[test]
fn sfu_key_fetch_5xx_retries_then_errors() {
    let mut server = mockito::Server::new();
    let _mock = server
        .mock("GET", "/api/partner/keys")
        .with_status(500)
        .with_body("internal error")
        .expect(2) // retries=1 → 2 attempts total
        .create();

    let tmp = TempDir::new().unwrap();
    let mut args = args_for(tmp.path(), server.url());
    args.retries = 1;
    let err = sfu_key::fetch(args).expect_err("5xx must fail");
    assert!(
        matches!(err, SecretsError::Http { status: 500, .. }),
        "expected Http{{500}}, got: {err:?}"
    );
}

/// 5. 4xx → Http error, no retry (single shot).
#[test]
fn sfu_key_fetch_4xx_no_retry() {
    let mut server = mockito::Server::new();
    let _mock = server
        .mock("GET", "/api/partner/keys")
        .with_status(404)
        .with_body("not found")
        .expect(1) // must not retry
        .create();

    let tmp = TempDir::new().unwrap();
    let err = sfu_key::fetch(args_for(tmp.path(), server.url())).expect_err("404 must fail");
    assert!(
        matches!(err, SecretsError::Http { status: 404, .. }),
        "expected Http{{404}}, got: {err:?}"
    );
}

/// 6. Closed port → Transport error.
#[test]
fn sfu_key_fetch_transport_error_returns_transport() {
    let tmp = TempDir::new().unwrap();
    let mut args = args_for(tmp.path(), "http://127.0.0.1:1".to_string());
    args.retries = 0;
    args.timeout_secs = 2;
    let err = sfu_key::fetch(args).expect_err("connect refused must error");
    assert!(
        matches!(err, SecretsError::Transport { .. }),
        "expected Transport, got: {err:?}"
    );
}

/// 7. Security regression guard — file content must begin with single quote,
///    NOT double quote.
#[test]
fn sfu_key_fetch_value_single_quoted() {
    let mut server = mockito::Server::new();
    let _mock = server
        .mock("GET", "/api/partner/keys")
        .with_status(200)
        .with_body(r#"{"sfu_signing_public_key": "some-key-value"}"#)
        .create();

    let tmp = TempDir::new().unwrap();
    sfu_key::fetch(args_for(tmp.path(), server.url())).expect("fetch succeeds");

    let content = fs::read_to_string(tmp.path().join("sfu-keys.env")).unwrap();
    assert!(
        content.contains("SFU_SIGNING_PUBLIC_KEY='"),
        "value must be single-quoted (security regression guard); got:\n{content}"
    );
    assert!(
        !content.contains("SFU_SIGNING_PUBLIC_KEY=\""),
        "value must NOT be double-quoted; got:\n{content}"
    );
}
