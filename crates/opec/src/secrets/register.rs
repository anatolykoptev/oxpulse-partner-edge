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

pub fn run(_args: Args) -> Result<(), SecretsError> {
    unimplemented!("opec::secrets::register::run — Tasks 3 implements this")
}
