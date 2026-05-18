//! Phase 4.3b — AmneziaWG (wg-tools) keypair management.
//!
//! Mirrors install.sh Step 4 AWG block (L988-1009):
//!
//! - 2 files: awg-private.key (0600), awg-public.key (0644)
//! - Idempotent: existing priv → derive pub via native wg_keypair::pub_from_priv_b64;
//!   missing priv → fresh keygen via native wg_keypair::keygen_wg
//! - `--rotate` forces regeneration of priv
//! - Empty/missing priv on idempotent path = treat as missing (regenerate)
//!
//! Phase 5.3: legacy wg-tools shell-out removed. Keygen is unconditionally
//! native (x25519-dalek in-process).

use super::error::SecretsError;
use super::wg_keypair;
use std::{fs, io::Write, path::Path};
use zeroize::Zeroizing;

const PRIV_FILE: &str = "awg-private.key";
const PUB_FILE: &str = "awg-public.key";

pub fn keygen(out_dir: &Path, rotate: bool) -> Result<(), SecretsError> {
    let priv_path = out_dir.join(PRIV_FILE);
    let pub_path = out_dir.join(PUB_FILE);

    // Decide whether we need a fresh keygen. Read the file and trim — a
    // whitespace-only priv (e.g. "\n") would pass a bare m.len() > 0 check
    // and then fail later with a cryptic error. Treat trimmed-empty as missing.
    let priv_existing = fs::read_to_string(&priv_path).ok();
    let priv_is_valid = priv_existing
        .as_deref()
        .map(str::trim)
        .is_some_and(|s| !s.is_empty());

    let regenerated = rotate || !priv_is_valid;

    // Native path (unconditional since Phase 5.3): in-process x25519-dalek keygen.
    keygen_native(out_dir, &priv_path, &pub_path, regenerated)?;

    Ok(())
}

/// Native keygen path — uses wg_keypair for both fresh generation and pub derivation.
fn keygen_native(
    _out_dir: &Path,
    priv_path: &Path,
    pub_path: &Path,
    regenerated: bool,
) -> Result<(), SecretsError> {
    // priv_key is Zeroizing<String> end-to-end so the heap copy is wiped on drop.
    let priv_key: Zeroizing<String>;

    if regenerated {
        let (new_priv, _) = wg_keypair::keygen_wg();
        priv_key = new_priv;
        write_atomic(priv_path, priv_key.as_bytes(), 0o600)?;
    } else {
        // Idempotent: read existing priv from disk.
        let existing = fs::read_to_string(priv_path).map_err(|e| SecretsError::Io {
            path: priv_path.to_path_buf(),
            source: e,
        })?;
        priv_key = Zeroizing::new(existing.trim().to_owned());
    }

    // Derive pub from priv (native, no subprocess).
    let pub_key = wg_keypair::pub_from_priv_b64(&priv_key)?;
    write_atomic(pub_path, pub_key.as_bytes(), 0o644)?;

    // Only log on regeneration — idempotent re-runs stay quiet.
    if regenerated {
        eprintln!("opec secrets awg-keygen: generated new keypair (pub={pub_key})");
    }
    Ok(())
}

/// Write `bytes` to `path` atomically (temp-file-in-same-dir → rename) with
/// the given Unix permission mode. Appends a trailing newline.
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
