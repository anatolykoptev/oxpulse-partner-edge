//! Phase 4.3a — Reality x25519 identity management.
//!
//! Mirrors install.sh Step 4 sub-step 2 (L753-916):
//! - 3 identity files: reality.priv (0600), reality.pub (0644), reality.uuid (0644)
//! - Idempotent: all-three-valid → reuse; none → fresh keygen; partial → error
//! - --rotate forces regeneration
//! - base64url 43-char validation on private + public keys

use super::error::SecretsError;
use std::{fs, io::Write, path::Path, process::Command};
use uuid::Uuid;

const FILES: &[&str] = &["reality.priv", "reality.pub", "reality.uuid"];
const REALITY_KEY_LEN: usize = 43;

pub fn keygen(out_dir: &Path, rotate: bool, partner_cli: &Path) -> Result<(), SecretsError> {
    // Detect existing identity state.
    let present: Vec<&'static str> = FILES
        .iter()
        .copied()
        .filter(|n| out_dir.join(n).is_file())
        .collect();

    if !rotate {
        match present.len() {
            3 => {
                // Validate existing files; if good, idempotent return.
                validate_existing(out_dir)?;
                eprintln!("opec secrets reality-keygen: reusing existing identity");
                return Ok(());
            }
            0 => { /* fall through to fresh keygen */ }
            _ => {
                let missing: Vec<&'static str> = FILES
                    .iter()
                    .copied()
                    .filter(|n| !present.contains(n))
                    .collect();
                return Err(SecretsError::PartialIdentity {
                    dir: out_dir.to_path_buf(),
                    found: present,
                    missing,
                });
            }
        }
    }

    // Locate partner-cli binary.
    let pc_resolved = resolve_partner_cli(partner_cli)?;

    // Invoke `partner-cli keygen`.
    let output = Command::new(&pc_resolved)
        .arg("keygen")
        .output()
        .map_err(|e| SecretsError::Io {
            path: pc_resolved.clone(),
            source: e,
        })?;
    if !output.status.success() {
        return Err(SecretsError::PartnerCliFailed {
            stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
        });
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    let priv_key =
        grep_field(&stdout, "private_key").ok_or_else(|| SecretsError::PartnerCliFailed {
            stderr: format!("missing 'private_key:' line in keygen output: {stdout}"),
        })?;
    let pub_key =
        grep_field(&stdout, "public_key").ok_or_else(|| SecretsError::PartnerCliFailed {
            stderr: format!("missing 'public_key:' line in keygen output: {stdout}"),
        })?;
    if priv_key.len() != REALITY_KEY_LEN {
        return Err(SecretsError::InvalidKeyFormat {
            path: out_dir.join("reality.priv"),
            actual_len: priv_key.len(),
        });
    }
    if pub_key.len() != REALITY_KEY_LEN {
        return Err(SecretsError::InvalidKeyFormat {
            path: out_dir.join("reality.pub"),
            actual_len: pub_key.len(),
        });
    }

    let uuid = Uuid::new_v4().to_string();

    write_atomic(&out_dir.join("reality.priv"), priv_key.as_bytes(), 0o600)?;
    write_atomic(&out_dir.join("reality.pub"), pub_key.as_bytes(), 0o644)?;
    write_atomic(&out_dir.join("reality.uuid"), uuid.as_bytes(), 0o644)?;

    eprintln!("opec secrets reality-keygen: generated new identity (uuid={uuid})");
    Ok(())
}

fn resolve_partner_cli(p: &Path) -> Result<std::path::PathBuf, SecretsError> {
    if p.is_absolute() {
        if p.is_file() {
            Ok(p.to_path_buf())
        } else {
            Err(SecretsError::PartnerCliMissing(p.to_path_buf()))
        }
    } else {
        which::which(p).map_err(|_| SecretsError::PartnerCliMissing(p.to_path_buf()))
    }
}

fn grep_field<'a>(text: &'a str, name: &str) -> Option<&'a str> {
    for line in text.lines() {
        if let Some(rest) = line.strip_prefix(&format!("{name}:")) {
            return Some(rest.trim());
        }
    }
    None
}

fn validate_existing(out_dir: &Path) -> Result<(), SecretsError> {
    for (file, must_len) in [
        ("reality.priv", REALITY_KEY_LEN),
        ("reality.pub", REALITY_KEY_LEN),
    ] {
        let path = out_dir.join(file);
        let content = fs::read_to_string(&path).map_err(|e| SecretsError::Io {
            path: path.clone(),
            source: e,
        })?;
        let trimmed = content.trim();
        if trimmed.len() != must_len {
            return Err(SecretsError::InvalidKeyFormat {
                path,
                actual_len: trimmed.len(),
            });
        }
    }
    Ok(())
}

fn write_atomic(path: &Path, bytes: &[u8], mode: u32) -> Result<(), SecretsError> {
    let dir = path.parent().unwrap_or_else(|| Path::new("."));
    let mut tmp = tempfile::Builder::new()
        .prefix(&format!(
            ".{}.",
            path.file_name().unwrap_or_default().to_string_lossy()
        ))
        .tempfile_in(dir)
        .map_err(|e| SecretsError::Io {
            path: path.to_path_buf(),
            source: e,
        })?;
    tmp.write_all(bytes).map_err(|e| SecretsError::Io {
        path: path.to_path_buf(),
        source: e,
    })?;
    tmp.as_file_mut()
        .write_all(b"\n")
        .map_err(|e| SecretsError::Io {
            path: path.to_path_buf(),
            source: e,
        })?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(tmp.path(), fs::Permissions::from_mode(mode)).map_err(|e| {
            SecretsError::Io {
                path: tmp.path().to_path_buf(),
                source: e,
            }
        })?;
    }
    tmp.persist(path).map_err(|e| SecretsError::Io {
        path: path.to_path_buf(),
        source: e.error,
    })?;
    Ok(())
}
