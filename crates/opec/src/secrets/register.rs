//! Phase 4.3c — backend register POST + response parse.
use super::error::SecretsError;
use serde::Serialize;
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
            let parsed: serde_json::Value =
                serde_json::from_str(&content).map_err(|e| SecretsError::Http {
                    status: 0,
                    body: format!("branding-config file is not valid JSON: {e}"),
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

    let endpoint = format!(
        "{}/api/partner/register",
        args.registry_url.trim_end_matches('/')
    );

    let agent = ureq::AgentBuilder::new()
        .timeout(std::time::Duration::from_secs(args.timeout_secs))
        .build();

    let response = {
        let mut last_err: Option<SecretsError> = None;
        let mut result: Option<RegisterResponse> = None;
        for attempt in 0..=args.retries {
            match agent
                .post(&endpoint)
                .set("Content-Type", "application/json")
                .send_string(&body)
            {
                Ok(resp) => {
                    let parsed: RegisterResponse = resp.into_json().map_err(|e| SecretsError::Http {
                        status: 0,
                        body: format!("response not JSON: {e}"),
                    })?;
                    result = Some(parsed);
                    break;
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
                    // 4xx not retried; 5xx retried up to args.retries.
                    if code < 500 || attempt == args.retries {
                        break;
                    }
                }
                Err(e) => {
                    last_err = Some(SecretsError::Transport {
                        source: Box::new(e),
                    });
                    if attempt == args.retries {
                        break;
                    }
                }
            }
            std::thread::sleep(std::time::Duration::from_millis(500 * (attempt as u64 + 1)));
        }
        result.ok_or_else(|| {
            last_err.unwrap_or(SecretsError::Http {
                status: 0,
                body: "no attempts made".into(),
            })
        })?
    };

    // Stale-registry detection: mirrors install.sh L1181-1184 contract.
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
        // Escape backslash + double-quote (defensive; values are opaque tokens).
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
    tmp.persist(path)
        .map_err(|e| SecretsError::Io {
            path: path.to_path_buf(),
            source: e.error,
        })?;
    Ok(())
}
