//! Phase 4.3c — backend register POST + response parse.
use super::error::SecretsError;
use serde::{Deserialize, Serialize};
use std::{fs, path::PathBuf};

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
            // Redacted error — never include raw content (may contain secrets later).
            let parsed: serde_json::Value =
                serde_json::from_str(&content).map_err(|e| SecretsError::InvalidBranding {
                    path: p.clone(),
                    reason: format!("not valid JSON: {} bytes, error kind: {}", content.len(), e.classify_kind()),
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

    serde_json::to_string(&body).map_err(|e| SecretsError::ResponseParse {
        reason: format!("body serialization failed: {e}"),
    })
}

/// Backend response — all required fields are `Option<String>` so we can emit
/// a precise `MissingResponseField` per absent name instead of a generic
/// serde "missing field" error (which can leak response content via Display).
#[derive(Deserialize)]
struct RegisterResponseRaw {
    node_id: Option<String>,
    backend_endpoint: Option<String>,
    turn_secret: Option<String>,
    reality_uuid: Option<String>,
    reality_public_key: Option<String>,
    reality_short_id: Option<String>,
    reality_server_name: Option<String>,
    reality_encryption: Option<String>,
    relay_jwt_secret: Option<String>,
    #[serde(default)]
    turns_subdomain: String,
}

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
    turns_subdomain: String,
}

impl RegisterResponseRaw {
    fn into_validated(self) -> Result<RegisterResponse, SecretsError> {
        // Macro-like inline check: empty/missing → MissingResponseField.
        fn require(value: Option<String>, name: &'static str) -> Result<String, SecretsError> {
            match value {
                Some(v) if !v.trim().is_empty() => Ok(v),
                _ => Err(SecretsError::MissingResponseField { name }),
            }
        }
        // reality_encryption can be empty (legacy); validate via StaleRegistry check, not here.
        let reality_encryption = self.reality_encryption.unwrap_or_default();
        Ok(RegisterResponse {
            node_id: require(self.node_id, "node_id")?,
            backend_endpoint: require(self.backend_endpoint, "backend_endpoint")?,
            turn_secret: require(self.turn_secret, "turn_secret")?,
            reality_uuid: require(self.reality_uuid, "reality_uuid")?,
            reality_public_key: require(self.reality_public_key, "reality_public_key")?,
            reality_short_id: require(self.reality_short_id, "reality_short_id")?,
            reality_server_name: require(self.reality_server_name, "reality_server_name")?,
            reality_encryption,
            relay_jwt_secret: require(self.relay_jwt_secret, "relay_jwt_secret")?,
            turns_subdomain: self.turns_subdomain,
        })
    }
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

    let endpoint = format!(
        "{}/api/partner/register",
        args.registry_url.trim_end_matches('/')
    );

    let agent = ureq::AgentBuilder::new()
        .timeout(std::time::Duration::from_secs(args.timeout_secs))
        .build();

    let raw = post_with_retry(&agent, &endpoint, &body, args.retries)?;
    let response = raw.into_validated()?;

    // Stale-registry detection: install.sh L1181-1184 contract.
    if response.reality_encryption.trim().is_empty()
        && !response.reality_public_key.trim().is_empty()
    {
        return Err(SecretsError::StaleRegistry);
    }

    write_env_file(&args.out_env, &response)?;

    // Redact secrets — only log node_id on success.
    eprintln!(
        "opec secrets register: 200 OK (node_id={})",
        response.node_id
    );
    Ok(())
}

fn post_with_retry(
    agent: &ureq::Agent,
    endpoint: &str,
    body: &str,
    retries: u32,
) -> Result<RegisterResponseRaw, SecretsError> {
    let mut last_err: Option<SecretsError> = None;
    for attempt in 0..=retries {
        match agent
            .post(endpoint)
            .set("Content-Type", "application/json")
            .send_string(body)
        {
            Ok(resp) => {
                // Read as string first, then parse — separates transport vs parse errors,
                // and keeps us from emitting secrets via serde_json::Error Display.
                let body_str = match resp.into_string() {
                    Ok(s) => s,
                    Err(e) => {
                        return Err(SecretsError::ResponseParse {
                            reason: format!("could not read response body: {e}"),
                        });
                    }
                };
                let parsed: RegisterResponseRaw = match serde_json::from_str(&body_str) {
                    Ok(v) => v,
                    Err(e) => {
                        // Redacted: log byte length + error category, never raw body.
                        return Err(SecretsError::ResponseParse {
                            reason: format!(
                                "response not JSON: {} bytes, error kind: {}",
                                body_str.len(),
                                e.classify_kind()
                            ),
                        });
                    }
                };
                return Ok(parsed);
            }
            Err(ureq::Error::Status(code, resp)) => {
                let body_excerpt: String = resp
                    .into_string()
                    .unwrap_or_default()
                    .chars()
                    .take(500)
                    .collect();
                last_err = Some(SecretsError::Http {
                    status: code,
                    body: body_excerpt,
                });
                if code < 500 || attempt == retries {
                    break;
                }
            }
            Err(e) => {
                last_err = Some(SecretsError::Transport {
                    source: Box::new(e),
                });
                if attempt == retries {
                    break;
                }
            }
        }
        std::thread::sleep(std::time::Duration::from_millis(500 * (attempt as u64 + 1)));
    }
    Err(last_err.unwrap_or(SecretsError::ResponseParse {
        reason: "no attempts made".into(),
    }))
}

/// Reject values that would let a backend inject shell env vars via `source`.
/// Newlines / carriage returns break the KEY="VALUE" line invariant — bash
/// `source` would interpret the remainder as new assignments.
fn validate_env_value(name: &str, value: &str) -> Result<(), SecretsError> {
    if value.contains('\n') || value.contains('\r') {
        return Err(SecretsError::InvalidResponseValue {
            name: name.to_string(),
            reason: "value contains newline — refusing to write env-file (injection vector)".into(),
        });
    }
    Ok(())
}

fn write_env_file(path: &std::path::Path, r: &RegisterResponse) -> Result<(), SecretsError> {
    use std::io::Write;
    let pairs: [(&str, &str); 10] = [
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
    ];

    let mut content = String::new();
    for (k, v) in pairs {
        validate_env_value(k, v)?;
        // Escape backslash + double-quote so shell-source doesn't end the
        // quoted value early on a stray quote.
        let escaped = v.replace('\\', "\\\\").replace('"', "\\\"");
        content.push_str(&format!("{k}=\"{escaped}\"\n"));
    }

    let dir = path.parent().unwrap_or_else(|| std::path::Path::new("."));
    let mut tmp = tempfile::Builder::new()
        .prefix(".register-envfile.")
        .tempfile_in(dir)
        .map_err(|e| SecretsError::Io {
            path: path.to_path_buf(),
            source: e,
        })?;
    tmp.write_all(content.as_bytes())
        .map_err(|e| SecretsError::Io {
            path: path.to_path_buf(),
            source: e,
        })?;
    // fsync before persist — crash between rename + sync on ext4 data=writeback
    // could otherwise leave a zero-length file.
    tmp.as_file().sync_all().map_err(|e| SecretsError::Io {
        path: tmp.path().to_path_buf(),
        source: e,
    })?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(tmp.path(), std::fs::Permissions::from_mode(0o600)).map_err(
            |e| SecretsError::Io {
                path: tmp.path().to_path_buf(),
                source: e,
            },
        )?;
    }
    tmp.persist(path).map_err(|e| SecretsError::Io {
        path: path.to_path_buf(),
        source: e.error,
    })?;
    Ok(())
}

trait ClassifyKindExt {
    fn classify_kind(&self) -> &'static str;
}
impl ClassifyKindExt for serde_json::Error {
    fn classify_kind(&self) -> &'static str {
        match self.classify() {
            serde_json::error::Category::Io => "io",
            serde_json::error::Category::Syntax => "syntax",
            serde_json::error::Category::Data => "data",
            serde_json::error::Category::Eof => "eof",
        }
    }
}
