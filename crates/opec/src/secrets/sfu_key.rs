//! Phase 4.3d — fetch SFU signing public key from /api/partner/keys.
//!
//! GET `{backend_api}/api/partner/keys`, parse `sfu_signing_public_key`,
//! replace embedded newlines with literal `\n`, write single-quoted env-file.
//! Missing or empty key → warn and return Ok (mirrors bash L1497 semantics).

use super::error::SecretsError;
use serde::Deserialize;
use std::path::PathBuf;

pub struct Args {
    pub backend_api: String,
    pub out_file: PathBuf,
    pub timeout_secs: u64,
    pub retries: u32,
}

#[derive(Deserialize)]
struct KeysResponse {
    #[serde(default)]
    sfu_signing_public_key: Option<String>,
}

pub fn fetch(args: Args) -> Result<(), SecretsError> {
    let endpoint = format!(
        "{}/api/partner/keys",
        args.backend_api.trim_end_matches('/')
    );

    let agent = ureq::AgentBuilder::new()
        .timeout(std::time::Duration::from_secs(args.timeout_secs))
        .build();

    let raw_key = get_with_retry(&agent, &endpoint, args.retries)?;

    // Missing or empty key → warn and return Ok (not a fatal error).
    // Matches bash L1497: `warn "sfu_signing_public_key not available ..."`.
    let key = match raw_key {
        None => {
            eprintln!(
                "opec secrets sfu-signing-key: sfu_signing_public_key not available \
                 from /api/partner/keys (signaling may need updating; SFU relay JWT \
                 auth will fall back to RELAY_JWT_SECRET)"
            );
            return Ok(());
        }
        Some(s) if s.trim().is_empty() => {
            eprintln!(
                "opec secrets sfu-signing-key: sfu_signing_public_key not available \
                 from /api/partner/keys (signaling may need updating; SFU relay JWT \
                 auth will fall back to RELAY_JWT_SECRET)"
            );
            return Ok(());
        }
        Some(s) => s,
    };

    // Replace embedded newlines with literal `\n` (bash L1487 equivalent).
    let encoded = key.replace('\n', "\\n").replace('\r', "\\r");

    // Defensive: after encoding, the value must not contain bare newlines
    // or carriage returns that would break the env-file line invariant.
    if encoded.contains('\n') || encoded.contains('\r') {
        return Err(SecretsError::InvalidResponseValue {
            name: "SFU_SIGNING_PUBLIC_KEY".to_string(),
            reason: "value contains newline after \\n-encoding — refusing to write env-file".into(),
        });
    }

    write_env_file(&args.out_file, &encoded)?;

    eprintln!(
        "opec secrets sfu-signing-key: fetched (length={})",
        encoded.len()
    );
    Ok(())
}

/// GET with retry: 5xx retries up to `retries` times; 4xx no-retry.
fn get_with_retry(
    agent: &ureq::Agent,
    endpoint: &str,
    retries: u32,
) -> Result<Option<String>, SecretsError> {
    let mut last_err: Option<SecretsError> = None;
    for attempt in 0..=retries {
        match agent.get(endpoint).call() {
            Ok(resp) => {
                let body_str = match resp.into_string() {
                    Ok(s) => s,
                    Err(e) => {
                        return Err(SecretsError::ResponseParse {
                            reason: format!("could not read response body: {e}"),
                        });
                    }
                };
                let parsed: KeysResponse = match serde_json::from_str(&body_str) {
                    Ok(v) => v,
                    Err(e) => {
                        return Err(SecretsError::ResponseParse {
                            reason: format!(
                                "response not JSON: {} bytes, error kind: {}",
                                body_str.len(),
                                classify_json_err(&e)
                            ),
                        });
                    }
                };
                return Ok(parsed.sfu_signing_public_key);
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

fn write_env_file(path: &std::path::Path, encoded_key: &str) -> Result<(), SecretsError> {
    use std::io::Write;

    // SECURITY: single-quote the value — prevents $-expansion and command
    // substitution when the env-file is sourced. Embedded single quotes are
    // escaped via the canonical `'\''` trick.
    let escaped = encoded_key.replace('\'', "'\\''");
    let content = format!("SFU_SIGNING_PUBLIC_KEY='{escaped}'\n");

    let dir = path.parent().unwrap_or_else(|| std::path::Path::new("."));
    let mut tmp = tempfile::Builder::new()
        .prefix(".sfu-keys-envfile.")
        .tempfile_in(dir)
        .map_err(|e| SecretsError::Io {
            path: path.to_path_buf(),
            source: e,
        })?;

    tmp.write_all(content.as_bytes()).map_err(|e| SecretsError::Io {
        path: path.to_path_buf(),
        source: e,
    })?;

    // fsync before persist to survive crash between rename and sync.
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

fn classify_json_err(e: &serde_json::Error) -> &'static str {
    match e.classify() {
        serde_json::error::Category::Io => "io",
        serde_json::error::Category::Syntax => "syntax",
        serde_json::error::Category::Data => "data",
        serde_json::error::Category::Eof => "eof",
    }
}
