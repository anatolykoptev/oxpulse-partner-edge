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
//! Phase 5.2: keygen is now native (x25519-dalek in-process) by default.
//! Set `OPEC_AWG_KEYGEN_LEGACY=1` to fall back to the wg-tools shell-out
//! for one release cycle before full removal.

use super::error::SecretsError;
use super::wg_keypair;
use std::{fs, io::Write, path::Path, process::Command};
use zeroize::Zeroizing;

const PRIV_FILE: &str = "awg-private.key";
const PUB_FILE: &str = "awg-public.key";

pub fn keygen(out_dir: &Path, rotate: bool, wg: &Path) -> Result<(), SecretsError> {
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

    // OPEC_AWG_KEYGEN_LEGACY accepts the literal "1" only — any other value
    // (including "true", "yes", "0", or unset) takes the native default path.
    // Deliberately narrow to avoid accidental opt-in from typos.
    let use_legacy = std::env::var("OPEC_AWG_KEYGEN_LEGACY").as_deref() == Ok("1");

    if use_legacy {
        // Legacy fallback: shell out to wg-tools binary.
        // Only used when OPEC_AWG_KEYGEN_LEGACY=1 is set; remove in Phase 5.X cleanup.
        let wg_resolved = resolve_wg(wg)?;
        keygen_legacy(out_dir, &priv_path, &pub_path, &wg_resolved, regenerated)?;
    } else {
        // Native path (default): in-process x25519-dalek keygen, no subprocess.
        keygen_native(out_dir, &priv_path, &pub_path, regenerated)?;
    }

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

/// Legacy keygen path — shells out to `wg genkey` / `wg pubkey`.
/// Only active when OPEC_AWG_KEYGEN_LEGACY=1.
fn keygen_legacy(
    _out_dir: &Path,
    priv_path: &Path,
    pub_path: &Path,
    wg_resolved: &Path,
    regenerated: bool,
) -> Result<(), SecretsError> {
    if regenerated {
        let priv_key = run_wg(wg_resolved, &["genkey"], None)?;
        let priv_trimmed = priv_key.trim();
        if priv_trimmed.is_empty() {
            return Err(SecretsError::PartnerCliFailed {
                stderr: "wg genkey emitted empty output".into(),
            });
        }
        write_atomic(priv_path, priv_trimmed.as_bytes(), 0o600)?;
    }

    // Always re-derive pub from priv so a stale awg-public.key gets refreshed.
    let priv_content = fs::read_to_string(priv_path).map_err(|e| SecretsError::Io {
        path: priv_path.to_path_buf(),
        source: e,
    })?;
    let pub_key = run_wg(wg_resolved, &["pubkey"], Some(&priv_content))?;
    let pub_trimmed = pub_key.trim();
    if pub_trimmed.is_empty() {
        return Err(SecretsError::PartnerCliFailed {
            stderr: "wg pubkey emitted empty output".into(),
        });
    }
    write_atomic(pub_path, pub_trimmed.as_bytes(), 0o644)?;

    if regenerated {
        eprintln!("opec secrets awg-keygen: generated new keypair (pub={pub_trimmed})");
    }
    Ok(())
}

/// Resolve the `wg` binary: absolute paths are checked for existence; relative
/// names are looked up on PATH via `which`.
fn resolve_wg(p: &Path) -> Result<std::path::PathBuf, SecretsError> {
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

/// Run `wg <args>`, optionally piping `stdin` to the process.
///
/// Uses `Command::spawn` + `wait_with_output` for the stdin path to avoid
/// a deadlock that could occur if the child's stdout buffer fills before we
/// finish writing stdin.
fn run_wg(bin: &Path, args: &[&str], stdin: Option<&str>) -> Result<String, SecretsError> {
    let mut cmd = Command::new(bin);
    cmd.args(args);

    let output = if let Some(s) = stdin {
        cmd.stdin(std::process::Stdio::piped());
        cmd.stdout(std::process::Stdio::piped());
        cmd.stderr(std::process::Stdio::piped());
        let mut child = cmd.spawn().map_err(|e| SecretsError::Io {
            path: bin.to_path_buf(),
            source: e,
        })?;
        if let Some(mut sin) = child.stdin.take() {
            sin.write_all(s.as_bytes()).map_err(|e| SecretsError::Io {
                path: bin.to_path_buf(),
                source: e,
            })?;
            // Drop `sin` here so the child sees EOF on its stdin.
        }
        child.wait_with_output().map_err(|e| SecretsError::Io {
            path: bin.to_path_buf(),
            source: e,
        })?
    } else {
        cmd.output().map_err(|e| SecretsError::Io {
            path: bin.to_path_buf(),
            source: e,
        })?
    };

    if !output.status.success() {
        return Err(SecretsError::PartnerCliFailed {
            stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
        });
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
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
