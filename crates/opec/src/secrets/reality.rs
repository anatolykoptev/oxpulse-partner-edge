//! Phase 4.3a — Reality x25519 identity management.
//!
//! Mirrors install.sh Step 4 sub-step 2 (L753-916):
//! - 3 identity files: reality.priv (0600), reality.pub (0644), reality.uuid (0644)
//! - Idempotent: all-three-valid → reuse; none → fresh keygen; partial → error
//! - --rotate forces regeneration
//! - base64url 43-char validation on private + public keys
//!
//! Phase 5.3: legacy partner-cli shell-out removed. Keygen is unconditionally
//! native (x25519-dalek in-process).

use super::error::SecretsError;
use super::x25519;
use std::{fs, io::Write, path::Path};
use uuid::Uuid;

const FILES: &[&str] = &["reality.priv", "reality.pub", "reality.uuid"];
const REALITY_KEY_LEN: usize = 43;

pub fn keygen(out_dir: &Path, rotate: bool) -> Result<(), SecretsError> {
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

    // priv_key_owned wrapped in Zeroizing so the heap copy is wiped on drop —
    // x25519::keygen_x25519 returns Zeroizing<String> but to_owned()/format!
    // would otherwise leak a plain String onto the heap.
    // Native path (unconditional since Phase 5.3): in-process x25519-dalek keygen.
    let (priv_key_owned, pub_key_owned) = x25519::keygen_x25519();

    let priv_key: &str = &priv_key_owned;
    let pub_key: &str = &pub_key_owned;

    // Invariant: both keys must be 43-char base64url (post-keygen gate).
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

fn validate_existing(out_dir: &Path) -> Result<(), SecretsError> {
    // Keys: 43-char base64url length check.
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
    // UUID: parse-check — mirrors install.sh L902-906 hex-regex validation.
    // Without this, a corrupted reality.uuid silently passes the idempotent
    // path despite the keys being intact.
    let uuid_path = out_dir.join("reality.uuid");
    let uuid_content = fs::read_to_string(&uuid_path).map_err(|e| SecretsError::Io {
        path: uuid_path.clone(),
        source: e,
    })?;
    let uuid_trimmed = uuid_content.trim();
    if uuid::Uuid::parse_str(uuid_trimmed).is_err() {
        return Err(SecretsError::InvalidKeyFormat {
            path: uuid_path,
            actual_len: uuid_trimmed.len(),
        });
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
