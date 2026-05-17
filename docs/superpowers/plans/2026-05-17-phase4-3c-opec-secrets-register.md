# Phase 4.3c — `opec secrets register`

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development.

**Goal:** Absorb the largest single block of install.sh Step 4 — backend register POST + response parse (L1010-1201, ~190 LoC bash + 35 LoC inline python) — into `opec secrets register`. install.sh keeps bash fallback under `OPEC_SECRETS_REGISTER=${...:-1}`.

**Architecture:**
- New module `crates/opec/src/secrets/register.rs` — `RegisterRequest` serde struct (body), POST via `ureq`, response parse → atomic env-file write.
- HTTP client: `ureq` 2.x with `rustls` (per architect — no tokio, sync, ~400 KB).
- Output format: shell-sourceable `KEY=VALUE` env-file at `--out-env`. Mode 0600 (secret values).
- **Scope chunked**: This phase ships `--branding-config <PATH>` passthrough (read file → embed in body). Native `--brand-*` flags + BrandingConfig serde struct → Phase 4.3d.

**Existing invariants to preserve:**
- `DRY_RUN=1` → OPEC path emits warn + synthesizes DRYRUN placeholders in env-file (mirrors install.sh L957-976 dry-run synthesis)
- `MANUAL_CONFIG` → bypass POST entirely, copy the manual file → caller (install.sh) handles this BEFORE OPEC dispatch
- Stale-registry detection: empty `reality_encryption` + non-empty `reality_public_key` → die

**Tech Stack:** Rust 2021, `ureq = { version = "2", default-features = false, features = ["tls", "json"] }`, `serde`, `serde_json`. NO tokio.

**Out of scope:**
- Native `--brand-*` flag synthesis (Phase 4.3d)
- SFU signing-key fetch + JWT synthesis (Phase 4.3e per re-numbered roadmap)
- partner-cli absorption (Phase 5)

**Roadmap ref:** `docs/superpowers/specs/2026-05-17-phase4-install-decomposition-roadmap.md` (Phase 4.3c row to be updated post-merge: HTTP + register only; native branding chunked to 4.3d)

## File structure

```
crates/opec/
├── Cargo.toml                                       # MODIFY — +ureq
└── src/secrets/
    ├── mod.rs                                       # MODIFY — Register variant + dispatch
    └── register.rs                                  # NEW
crates/opec/tests/
├── cli_secrets_register.rs                          # NEW — CLI integration (no network)
├── secrets_register_body_unit.rs                    # NEW — body builder
└── secrets_register_flow_unit.rs                    # NEW — POST + parse via mock HTTP
install.sh                                           # MODIFY (T4)
tests/test_install_opec_parity.sh                    # MODIFY (T4)
```

## CLI surface

```
opec secrets register \
  --registry-url <URL> \
  --partner-id <ID> \
  --domain <DOMAIN> \
  --token <TOKEN> \
  --public-ip <IP> \
  --reality-pub-file <PATH> \
  --reality-uuid-file <PATH> \
  --awg-pub-file <PATH> \
  --out-env <PATH> \
  [--region <REGION>] \
  [--branding-config <PATH>] \
  [--timeout-secs 30] \
  [--retries 3]
```

`--out-env`: shell-sourceable file with 0600 mode, contains:
```
NODE_ID="..."
BACKEND_ENDPOINT="..."
TURN_SECRET="..."
REALITY_UUID="..."
REALITY_PUBLIC_KEY="..."
REALITY_SHORT_ID="..."
REALITY_SERVER_NAME="..."
REALITY_ENCRYPTION="..."
RELAY_JWT_SECRET="..."
TURNS_SUBDOMAIN="..."
```

Stderr: `opec secrets register: POST <url>/api/partner/register → 200 (node_id=...)`. Redact TURN_SECRET / RELAY_JWT_SECRET from logs.

Error variants (extending `SecretsError`):
- `Http { status: u16, body: String }` — non-2xx
- `Transport { source: ureq::Error }` — network/dns
- `MissingResponseField { name: &'static str }`
- `StaleRegistry` — empty encryption + non-empty pubkey
- (reuse) `Io`, `InvalidKeyFormat`

---

## Task 1 — Skeleton + ureq dep

**Files:**
- Modify: `crates/opec/Cargo.toml`
- Modify: `crates/opec/src/secrets/mod.rs` + `error.rs`
- Create: `crates/opec/src/secrets/register.rs` (stub)
- Create: `crates/opec/tests/cli_secrets_register.rs`

- [ ] **Step 1.1 (RED) — CLI tests**

```rust
//! Phase 4.3c — opec secrets register CLI surface.
use assert_cmd::Command;
use serial_test::serial;

#[test]
#[serial]
fn opec_secrets_help_lists_register() {
    Command::cargo_bin("opec")
        .unwrap()
        .args(["secrets", "--help"])
        .assert()
        .success()
        .stdout(predicates::str::contains("register"));
}

#[test]
#[serial]
fn opec_secrets_register_requires_registry_url() {
    Command::cargo_bin("opec")
        .unwrap()
        .args(["secrets", "register"])
        .assert()
        .failure()
        .stderr(predicates::str::contains("--registry-url"));
}
```

- [ ] **Step 1.2 (GREEN) — variant + stub**

`crates/opec/src/secrets/mod.rs`:
```rust
pub mod register;
```

Add to `SecretsCommands`:
```rust
    /// POST to backend /api/partner/register, write shell-sourceable env-file.
    Register {
        #[arg(long)]
        registry_url: String,
        #[arg(long)]
        partner_id: String,
        #[arg(long)]
        domain: String,
        #[arg(long)]
        token: String,
        #[arg(long)]
        public_ip: String,
        #[arg(long)]
        reality_pub_file: PathBuf,
        #[arg(long)]
        reality_uuid_file: PathBuf,
        #[arg(long)]
        awg_pub_file: PathBuf,
        #[arg(long)]
        out_env: PathBuf,
        #[arg(long)]
        region: Option<String>,
        #[arg(long)]
        branding_config: Option<PathBuf>,
        #[arg(long, default_value = "30")]
        timeout_secs: u64,
        #[arg(long, default_value = "3")]
        retries: u32,
    },
```

Dispatch:
```rust
        SecretsCommands::Register { registry_url, partner_id, domain, token, public_ip,
            reality_pub_file, reality_uuid_file, awg_pub_file, out_env, region,
            branding_config, timeout_secs, retries } => {
            register::run(register::Args {
                registry_url, partner_id, domain, token, public_ip,
                reality_pub_file, reality_uuid_file, awg_pub_file, out_env,
                region, branding_config, timeout_secs, retries,
            }).map_err(Into::into)
        }
```

`register.rs` stub:
```rust
//! Phase 4.3c — backend register POST + response parse.
use super::error::SecretsError;
use std::path::PathBuf;

pub struct Args {
    pub registry_url: String,
    pub partner_id: String,
    pub domain: String,
    pub token: String,
    pub public_ip: String,
    pub reality_pub_file: PathBuf,
    pub reality_uuid_file: PathBuf,
    pub awg_pub_file: PathBuf,
    pub out_env: PathBuf,
    pub region: Option<String>,
    pub branding_config: Option<PathBuf>,
    pub timeout_secs: u64,
    pub retries: u32,
}

pub fn run(_args: Args) -> Result<(), SecretsError> {
    unimplemented!("opec::secrets::register::run — Tasks 2-3 implement this")
}
```

Extend `error.rs`:
```rust
    #[error("HTTP {status}: {body}")]
    Http { status: u16, body: String },

    #[error("transport error: {source}")]
    Transport {
        #[source]
        source: Box<ureq::Error>,
    },

    #[error("missing required response field: {name}")]
    MissingResponseField { name: &'static str },

    #[error("stale registry response: reality_encryption is empty but reality_public_key is set — refusing to write known-broken xray-client config")]
    StaleRegistry,
```

`Cargo.toml` add:
```toml
ureq = { version = "2", default-features = false, features = ["tls", "json"] }
```

- [ ] **Step 1.3 — verify**

```bash
cargo build -p opec
cargo nextest run -p opec --test cli_secrets_register
cargo clippy -p opec --all-targets -- -D warnings
```

Expected: 2/2 PASS; clippy clean.

- [ ] **Step 1.4 — commit**

```
feat(opec): scaffold secrets register subcommand

Phase 4.3c Task 1 — SecretsCommands::Register variant + ureq HTTP
client dep. register::run is an unimplemented!() stub; Tasks 2-3
land the real impl. SecretsError extended with Http/Transport/
MissingResponseField/StaleRegistry variants.
```

---

## Task 2 — Body builder (`RegisterRequest` serde struct)

**Files:**
- Modify: `crates/opec/src/secrets/register.rs`
- Create: `crates/opec/tests/secrets_register_body_unit.rs`

Mirror install.sh L1010-1166 python body construction. This task: minimal body builder (no native --brand-* flags; branding loaded from --branding-config file).

- [ ] **Step 2.1 (RED) — body tests**

```rust
//! Phase 4.3c — body builder unit tests.
use opec::secrets::register;
use std::fs;
use tempfile::TempDir;

#[test]
fn body_required_fields_only() {
    let tmp = TempDir::new().unwrap();
    fs::write(tmp.path().join("reality.pub"), "REALITY_PUB_44_CHARS=\n").unwrap();
    fs::write(tmp.path().join("reality.uuid"), "11111111-2222-3333-4444-555555555555\n").unwrap();
    fs::write(tmp.path().join("awg.pub"), "AWG_PUB_KEY_BASE64\n").unwrap();

    let body = register::build_body(&register::BodyInputs {
        partner_id: "zvonilka",
        domain: "zvonilka.net",
        token: "test-token",
        public_ip: "1.2.3.4",
        region: None,
        reality_pub_file: tmp.path().join("reality.pub"),
        reality_uuid_file: tmp.path().join("reality.uuid"),
        awg_pub_file: tmp.path().join("awg.pub"),
        branding_config: None,
    }).expect("body builds");

    let v: serde_json::Value = serde_json::from_str(&body).unwrap();
    assert_eq!(v["partner_id"], "zvonilka");
    assert_eq!(v["domain"], "zvonilka.net");
    assert_eq!(v["token"], "test-token");
    assert_eq!(v["public_ip"], "1.2.3.4");
    assert_eq!(v["reality_public_key"], "REALITY_PUB_44_CHARS=");
    assert_eq!(v["reality_uuid"], "11111111-2222-3333-4444-555555555555");
    assert_eq!(v["awg_pubkey"], "AWG_PUB_KEY_BASE64");
    assert!(v.get("region").is_none(), "region absent when not provided");
    assert!(v.get("branding").is_none(), "branding absent when not provided");
}

#[test]
fn body_with_region() {
    let tmp = TempDir::new().unwrap();
    fs::write(tmp.path().join("a.pub"), "X\n").unwrap();
    fs::write(tmp.path().join("a.uuid"), "11111111-2222-3333-4444-555555555555\n").unwrap();
    fs::write(tmp.path().join("b.pub"), "Y\n").unwrap();

    let body = register::build_body(&register::BodyInputs {
        partner_id: "p", domain: "d.net", token: "t", public_ip: "1.1.1.1",
        region: Some("ru-msk".to_string()),
        reality_pub_file: tmp.path().join("a.pub"),
        reality_uuid_file: tmp.path().join("a.uuid"),
        awg_pub_file: tmp.path().join("b.pub"),
        branding_config: None,
    }).unwrap();
    let v: serde_json::Value = serde_json::from_str(&body).unwrap();
    assert_eq!(v["region"], "ru-msk");
}

#[test]
fn body_with_branding_config_file() {
    let tmp = TempDir::new().unwrap();
    fs::write(tmp.path().join("a.pub"), "X\n").unwrap();
    fs::write(tmp.path().join("a.uuid"), "11111111-2222-3333-4444-555555555555\n").unwrap();
    fs::write(tmp.path().join("b.pub"), "Y\n").unwrap();
    let branding = r#"{"display_name":"Test","logo":{"light":"/l.svg","dark":"/d.svg"}}"#;
    fs::write(tmp.path().join("brand.json"), branding).unwrap();

    let body = register::build_body(&register::BodyInputs {
        partner_id: "p", domain: "d.net", token: "t", public_ip: "1.1.1.1",
        region: None,
        reality_pub_file: tmp.path().join("a.pub"),
        reality_uuid_file: tmp.path().join("a.uuid"),
        awg_pub_file: tmp.path().join("b.pub"),
        branding_config: Some(tmp.path().join("brand.json")),
    }).unwrap();
    let v: serde_json::Value = serde_json::from_str(&body).unwrap();
    assert_eq!(v["branding"]["display_name"], "Test");
    assert_eq!(v["branding"]["logo"]["light"], "/l.svg");
}

#[test]
fn body_invalid_branding_json_errors() {
    let tmp = TempDir::new().unwrap();
    fs::write(tmp.path().join("a.pub"), "X\n").unwrap();
    fs::write(tmp.path().join("a.uuid"), "11111111-2222-3333-4444-555555555555\n").unwrap();
    fs::write(tmp.path().join("b.pub"), "Y\n").unwrap();
    fs::write(tmp.path().join("brand.json"), "not-json").unwrap();

    let result = register::build_body(&register::BodyInputs {
        partner_id: "p", domain: "d.net", token: "t", public_ip: "1.1.1.1",
        region: None,
        reality_pub_file: tmp.path().join("a.pub"),
        reality_uuid_file: tmp.path().join("a.uuid"),
        awg_pub_file: tmp.path().join("b.pub"),
        branding_config: Some(tmp.path().join("brand.json")),
    });
    assert!(result.is_err());
}
```

- [ ] **Step 2.2 (GREEN) — body builder impl**

Add to `register.rs`:

```rust
use serde::Serialize;
use std::{fs, path::PathBuf};

pub struct BodyInputs<'a> {
    pub partner_id: &'a str,
    pub domain: &'a str,
    pub token: &'a str,
    pub public_ip: &'a str,
    pub region: Option<String>,
    pub reality_pub_file: PathBuf,
    pub reality_uuid_file: PathBuf,
    pub awg_pub_file: PathBuf,
    pub branding_config: Option<PathBuf>,
}

#[derive(Serialize)]
struct RegisterBody {
    partner_id: String,
    domain: String,
    token: String,
    public_ip: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    region: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    awg_pubkey: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    reality_public_key: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    reality_uuid: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    branding: Option<serde_json::Value>,
}

pub fn build_body(inputs: &BodyInputs) -> Result<String, SecretsError> {
    let read_trim = |p: &std::path::Path| -> Result<Option<String>, SecretsError> {
        match fs::read_to_string(p) {
            Ok(s) => {
                let t = s.trim().to_string();
                Ok(if t.is_empty() { None } else { Some(t) })
            }
            Err(_) => Ok(None),
        }
    };

    let branding = match &inputs.branding_config {
        Some(p) => {
            let content = fs::read_to_string(p).map_err(|e| SecretsError::Io {
                path: p.clone(),
                source: e,
            })?;
            let parsed: serde_json::Value = serde_json::from_str(&content).map_err(|e| {
                SecretsError::Http {
                    status: 0,
                    body: format!("branding-config file is not valid JSON: {e}"),
                }
            })?;
            Some(parsed)
        }
        None => None,
    };

    let body = RegisterBody {
        partner_id: inputs.partner_id.to_string(),
        domain: inputs.domain.to_string(),
        token: inputs.token.to_string(),
        public_ip: inputs.public_ip.to_string(),
        region: inputs.region.clone(),
        awg_pubkey: read_trim(&inputs.awg_pub_file)?,
        reality_public_key: read_trim(&inputs.reality_pub_file)?,
        reality_uuid: read_trim(&inputs.reality_uuid_file)?,
        branding,
    };

    serde_json::to_string(&body).map_err(|e| SecretsError::Http {
        status: 0,
        body: format!("body serialization failed: {e}"),
    })
}
```

Note: `Http { status: 0, body: ... }` is a small overload for "non-network errors during body prep" — could be a separate variant. Acceptable for now; quality review may suggest refining.

Verify per Step 2.1, commit per body builder commit msg.

---

## Task 3 — POST + response parse + env-file write

**Files:**
- Modify: `crates/opec/src/secrets/register.rs`
- Create: `crates/opec/tests/secrets_register_flow_unit.rs` (mock HTTP via `mockito` or in-process httptest)

- [ ] **Step 3.1 — Decide mock crate**

Two options:
- `mockito = "1"` — popular, easy, but blocks dev-deps
- in-process `std::net::TcpListener` + thread — no dep but more code

Pick `mockito` for testability ROI. Add to `[dev-dependencies]`:
```toml
mockito = "1"
```

- [ ] **Step 3.2 (RED) — flow tests**

```rust
use mockito;
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
    let mock = server.mock("POST", "/api/partner/register")
        .with_status(200)
        .with_body(r#"{
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
        }"#)
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
        let mode = fs::metadata(tmp.path().join("out.env")).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "out-env must be 0600");
    }
}

#[test]
fn register_http_500_errors() {
    let mut server = mockito::Server::new();
    let _mock = server.mock("POST", "/api/partner/register")
        .with_status(500).with_body("backend down").create();
    let tmp = TempDir::new().unwrap();
    make_files(tmp.path());
    let err = register::run(args_for(tmp.path(), server.url())).expect_err("must fail");
    matches!(err, SecretsError::Http { status: 500, .. });
}

#[test]
fn register_stale_registry_dies() {
    let mut server = mockito::Server::new();
    let _mock = server.mock("POST", "/api/partner/register")
        .with_status(200)
        .with_body(r#"{
            "node_id": "n", "backend_endpoint": "x", "turn_secret": "t",
            "reality_uuid": "u", "reality_public_key": "STALE_KEY",
            "reality_short_id": "s", "reality_server_name": "n",
            "reality_encryption": "",
            "relay_jwt_secret": "j", "turns_subdomain": "d"
        }"#)
        .create();
    let tmp = TempDir::new().unwrap();
    make_files(tmp.path());
    let err = register::run(args_for(tmp.path(), server.url())).expect_err("stale must die");
    matches!(err, SecretsError::StaleRegistry);
}

#[test]
fn register_missing_required_field_errors() {
    let mut server = mockito::Server::new();
    let _mock = server.mock("POST", "/api/partner/register")
        .with_status(200)
        .with_body(r#"{"node_id": "n"}"#)  // missing everything else
        .create();
    let tmp = TempDir::new().unwrap();
    make_files(tmp.path());
    let err = register::run(args_for(tmp.path(), server.url())).expect_err("must error");
    matches!(err, SecretsError::MissingResponseField { .. });
}
```

- [ ] **Step 3.3 (GREEN) — impl**

```rust
use serde::Deserialize;

#[derive(Deserialize)]
struct RegisterResponse {
    node_id: String,
    backend_endpoint: String,
    turn_secret: String,
    reality_uuid: String,
    reality_public_key: String,
    reality_short_id: String,
    reality_server_name: String,
    reality_encryption: String,
    relay_jwt_secret: String,
    #[serde(default)]
    turns_subdomain: String,
}

pub fn run(args: Args) -> Result<(), SecretsError> {
    let body = build_body(&BodyInputs {
        partner_id: &args.partner_id,
        domain: &args.domain,
        token: &args.token,
        public_ip: &args.public_ip,
        region: args.region.clone(),
        reality_pub_file: args.reality_pub_file.clone(),
        reality_uuid_file: args.reality_uuid_file.clone(),
        awg_pub_file: args.awg_pub_file.clone(),
        branding_config: args.branding_config.clone(),
    })?;

    let endpoint = format!("{}/api/partner/register", args.registry_url.trim_end_matches('/'));

    let agent = ureq::AgentBuilder::new()
        .timeout(std::time::Duration::from_secs(args.timeout_secs))
        .build();

    let response = (|| -> Result<RegisterResponse, SecretsError> {
        let mut last_err: Option<SecretsError> = None;
        for attempt in 0..=args.retries {
            match agent.post(&endpoint)
                .set("Content-Type", "application/json")
                .send_string(&body)
            {
                Ok(resp) => {
                    let parsed: RegisterResponse = resp.into_json().map_err(|e| {
                        SecretsError::Http {
                            status: 0,
                            body: format!("response not JSON: {e}"),
                        }
                    })?;
                    return Ok(parsed);
                }
                Err(ureq::Error::Status(code, resp)) => {
                    let body_excerpt = resp
                        .into_string()
                        .unwrap_or_default()
                        .chars()
                        .take(500)
                        .collect();
                    last_err = Some(SecretsError::Http { status: code, body: body_excerpt });
                    // 4xx not retried; 5xx retried.
                    if code < 500 || attempt == args.retries {
                        break;
                    }
                }
                Err(e) => {
                    last_err = Some(SecretsError::Transport { source: Box::new(e) });
                    if attempt == args.retries {
                        break;
                    }
                }
            }
            std::thread::sleep(std::time::Duration::from_millis(500 * (attempt as u64 + 1)));
        }
        Err(last_err.unwrap_or(SecretsError::Http {
            status: 0,
            body: "no attempts made".into(),
        }))
    })()?;

    // Stale-registry detection: install.sh L1181-1184 contract.
    if response.reality_encryption.trim().is_empty() && !response.reality_public_key.trim().is_empty() {
        return Err(SecretsError::StaleRegistry);
    }

    write_env_file(&args.out_env, &response)?;

    eprintln!("opec secrets register: 200 OK (node_id={})", response.node_id);
    Ok(())
}

fn write_env_file(path: &std::path::Path, r: &RegisterResponse) -> Result<(), SecretsError> {
    use std::io::Write;
    let mut content = String::new();
    for (k, v) in [
        ("NODE_ID", &r.node_id),
        ("BACKEND_ENDPOINT", &r.backend_endpoint),
        ("TURN_SECRET", &r.turn_secret),
        ("REALITY_UUID", &r.reality_uuid),
        ("REALITY_PUBLIC_KEY", &r.reality_public_key),
        ("REALITY_SHORT_ID", &r.reality_short_id),
        ("REALITY_SERVER_NAME", &r.reality_server_name),
        ("REALITY_ENCRYPTION", &r.reality_encryption),
        ("RELAY_JWT_SECRET", &r.relay_jwt_secret),
        ("TURNS_SUBDOMAIN", &r.turns_subdomain),
    ] {
        // Escape backslash + double-quote in values (defensive — these
        // are mostly opaque tokens, no surprise content expected).
        let escaped = v.replace('\\', "\\\\").replace('"', "\\\"");
        content.push_str(&format!("{k}=\"{escaped}\"\n"));
    }

    let dir = path.parent().unwrap_or_else(|| std::path::Path::new("."));
    let mut tmp = tempfile::Builder::new()
        .prefix(".register-envfile.")
        .tempfile_in(dir)
        .map_err(|e| SecretsError::Io { path: path.to_path_buf(), source: e })?;
    tmp.write_all(content.as_bytes()).map_err(|e| SecretsError::Io {
        path: path.to_path_buf(),
        source: e,
    })?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(tmp.path(), std::fs::Permissions::from_mode(0o600))
            .map_err(|e| SecretsError::Io { path: tmp.path().to_path_buf(), source: e })?;
    }
    tmp.persist(path).map_err(|e| SecretsError::Io { path: path.to_path_buf(), source: e.error })?;
    Ok(())
}
```

Verify per Step 3.2, commit per impl.

---

## Task 4 — install.sh delegate register

Wrap install.sh register section (currently between `# ---------- Reality x25519...` end and `# jq-free JSON extraction` start, roughly L953-1174) under `OPEC_SECRETS_REGISTER=${...:-1}`.

**Key invariants:**
- Skip OPEC entirely when `MANUAL_CONFIG` is set (existing flow — manual-config bypasses register)
- DRY_RUN — emit warn + synthesize the same DRYRUN-* env in tmp_cfg shell-source path
- Retain `tmp_cfg` semantics — downstream parse expects file at that path
- Wrap the AWG keygen + body-construction + POST + parse into one OPEC call:
  ```bash
  opec secrets register \
    --registry-url "$BACKEND_API" \
    --partner-id "$PARTNER_ID" --domain "$DOMAIN" --token "$TOKEN" \
    --public-ip "$PUBLIC_IP" \
    [--region "$REGION"] \
    --reality-pub-file "$REALITY_PUB_PATH" \
    --reality-uuid-file "$REALITY_UUID_PATH" \
    --awg-pub-file "$AWG_PUB_PATH" \
    [--branding-config "$BRANDING_CONFIG"] \
    --out-env "$tmp_cfg.env"
  set -a; . "$tmp_cfg.env"; set +a
  ```

- **Note**: install.sh CURRENTLY does AWG keygen INSIDE the register `else` (Phase 4.3b wrapped that). AWG keygen must still happen BEFORE `opec secrets register` — keep the AWG block at its current position, then OPEC register reads `$AWG_PUB_PATH`.

Add 3 parity bats:
```bash
@test "install.sh delegates register to opec when OPEC_SECRETS_REGISTER!=0" {
    grep -qE 'OPEC_SECRETS_REGISTER' install.sh
    grep -qE 'opec[[:space:]]+secrets[[:space:]]+register' install.sh
}

@test "install.sh preserves bash fallback for register" {
    grep -qE '/api/partner/register' install.sh
}

@test "install.sh OPEC register path honors MANUAL_CONFIG bypass" {
    # MANUAL_CONFIG branch precedes OPEC dispatch — same as it precedes
    # the legacy curl block.
    awk '/MANUAL_CONFIG/,/elif|else/' install.sh | grep -qE 'cp.*tmp_cfg'
}
```

Commit:
```
feat(install): delegate register POST to opec secrets (env-gated)

Phase 4.3c Task 4 — install.sh's register call (POST
$BACKEND_API/api/partner/register + python body construction +
json_get parse, ~190 LoC bash + 35 LoC inline python) now delegates
to 'opec secrets register' when OPEC_SECRETS_REGISTER != 0.

OPEC writes shell-sourceable env-file at $tmp_cfg.env; install.sh
'set -a; . $tmp_cfg.env; set +a' to consume. tmp_cfg JSON path
stays around for the bash fallback.

MANUAL_CONFIG bypass kept ahead of the dispatcher — manual config
skips register entirely on both paths.

Native --brand-* flag synthesis deferred to Phase 4.3d; this PR
ships --branding-config <PATH> passthrough only (file read → embed
in body).
```

---

## Acceptance gate

- [ ] `cargo nextest run -p opec` — 100/100 (target: 93 prior + 7 new across 3 register test files)
- [ ] `cargo clippy -p opec --all-targets -- -D warnings` — clean
- [ ] `cargo machete -p opec` — no unused
- [ ] bats full suite green
- [ ] shellcheck install.sh — no NEW warnings vs main
- [ ] Post-merge canary on cheburator (3-day soak before Phase 4.3d)

## Risk register (HIGH for this phase — central API contract)

| Risk | Detection | Mitigation |
|------|-----------|------------|
| Backend response schema drift | mockito flow test asserts exact field set | RegisterResponse has explicit fields, missing = MissingResponseField error |
| Body encoding inconsistency vs python | byte-identical body integration test (if added later) | serde produces canonical JSON; install.sh inline python uses same shape |
| 4xx silently retried | unit test register_http_500_errors + Http variant fires on first 4xx | retry only on 5xx and Transport |
| Secrets leak in logs | redact TURN_SECRET, RELAY_JWT_SECRET in stderr | only `node_id` logged on success |
| Stale registry response broken xray-client | StaleRegistry variant | Detect empty encryption + non-empty pubkey, die |

## Commit summary (4 commits, single PR)

```
feat(opec): scaffold secrets register subcommand
feat(opec): register body builder + serde
feat(opec): register POST + response parse + env-file write
feat(install): delegate register POST to opec secrets (env-gated)
```
