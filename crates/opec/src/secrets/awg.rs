//! Phase 4.3b — AmneziaWG (wg-tools) keypair management.
//!
//! Mirrors install.sh Step 4 AWG block (L988-1009):
//! - 2 files: awg-private.key (0600), awg-public.key (0644)
//! - Idempotent: existing priv → derive pub via `wg pubkey`; missing priv → fresh keygen
//! - --rotate forces regeneration of priv
//! - Empty/missing priv on idempotent path = treat as missing (regenerate)

use super::error::SecretsError;
use std::{fs, io::Write, path::Path, process::Command};

const PRIV_FILE: &str = "awg-private.key";
const PUB_FILE: &str = "awg-public.key";

pub fn keygen(out_dir: &Path, rotate: bool, wg: &Path) -> Result<(), SecretsError> {
    let priv_path = out_dir.join(PRIV_FILE);
    let pub_path = out_dir.join(PUB_FILE);

    let wg_resolved = resolve_wg(wg)?;

    // Decide whether we need a fresh keygen. Read the file and trim — a
    // whitespace-only priv (e.g. "\n") would pass a bare m.len() > 0 check
    // and then fail later with a cryptic `wg pubkey` stderr. Treat
    // trimmed-empty as missing.
    let priv_existing = fs::read_to_string(&priv_path).ok();
    let priv_is_valid = priv_existing
        .as_deref()
        .map(str::trim)
        .is_some_and(|s| !s.is_empty());

    let regenerated = rotate || !priv_is_valid;
    if regenerated {
        let priv_key = run_wg(&wg_resolved, &["genkey"], None)?;
        let priv_trimmed = priv_key.trim();
        if priv_trimmed.is_empty() {
            return Err(SecretsError::PartnerCliFailed {
                stderr: "wg genkey emitted empty output".into(),
            });
        }
        write_atomic(&priv_path, priv_trimmed.as_bytes(), 0o600)?;
    }

    // Always re-derive pub from priv so a stale awg-public.key gets refreshed
    // even on idempotent re-runs.
    let priv_content = fs::read_to_string(&priv_path).map_err(|e| SecretsError::Io {
        path: priv_path.clone(),
        source: e,
    })?;
    let pub_key = run_wg(&wg_resolved, &["pubkey"], Some(&priv_content))?;
    let pub_trimmed = pub_key.trim();
    if pub_trimmed.is_empty() {
        return Err(SecretsError::PartnerCliFailed {
            stderr: "wg pubkey emitted empty output".into(),
        });
    }
    write_atomic(&pub_path, pub_trimmed.as_bytes(), 0o644)?;

    // Only log on regeneration — idempotent re-runs stay quiet, matching
    // the bash path's behaviour (it logs `awg pubkey:` only after a real
    // wg-genkey, not on every install.sh invocation).
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
