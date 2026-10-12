//! Per-node TURN secret file (S_n) for relay-only nodes.
//!
//! A relay-only node holds exactly one credential: its own TURN auth secret,
//! written by the operator to a root-owned 0600 file. One secret per line, one
//! or two lines (two = the overlap window while the secret is rotated).
//! Every error names the rule and the line NUMBER — never the line itself.

use anyhow::{bail, Context, Result};
use std::{
    fs::OpenOptions,
    io::Read,
    os::unix::fs::{MetadataExt, OpenOptionsExt},
    path::Path,
};

/// Placeholder in a template, replaced by one `static-auth-secret=` line per secret.
pub const SECRET_LINES_PLACEHOLDER: &str = "{{STATIC_AUTH_SECRET_LINES}}";
/// Base64url of 32 random bytes, unpadded.
pub const SECRET_LEN: usize = 43;
/// Current secret + (during a bump) the previous one.
pub const MAX_SECRETS: usize = 2;

/// Read and validate `path`; returns the secrets in file order.
///
/// The file is opened ONCE with O_NOFOLLOW and every check runs on that file
/// descriptor, so a swap between check and read cannot change what is read.
/// It must be a regular file, mode exactly 0600, a single hard link, owned by
/// the effective user running opec (root in the installer), and hold 1..=2
/// distinct valid lines.
pub fn read_node_secrets(path: &Path) -> Result<Vec<String>> {
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
        .with_context(|| {
            format!(
                "secret file {}: cannot open (missing, or a symlink, which is refused)",
                path.display()
            )
        })?;
    let meta = file
        .metadata()
        .with_context(|| format!("secret file {}: cannot stat", path.display()))?;
    if !meta.file_type().is_file() {
        bail!("secret file {}: not a regular file", path.display());
    }
    let mode = meta.mode() & 0o7777;
    if mode != 0o600 {
        bail!("secret file {}: mode {:o}, want 600", path.display(), mode);
    }
    if meta.nlink() != 1 {
        bail!(
            "secret file {}: {} hard links, want 1",
            path.display(),
            meta.nlink()
        );
    }
    // SAFETY: geteuid has no preconditions and cannot fail.
    let euid = unsafe { libc::geteuid() };
    if meta.uid() != euid {
        bail!(
            "secret file {}: owner uid {}, want {} (the user running opec)",
            path.display(),
            meta.uid(),
            euid
        );
    }
    let mut text = String::new();
    file.read_to_string(&mut text)
        .with_context(|| format!("secret file {}: unreadable or not UTF-8", path.display()))?;
    parse_secrets(&text).with_context(|| format!("secret file {}", path.display()))
}

/// Validate the file CONTENT (no filesystem checks). Split out for unit tests.
pub fn parse_secrets(text: &str) -> Result<Vec<String>> {
    let body = text.strip_suffix('\n').unwrap_or(text);
    if body.is_empty() {
        bail!("empty");
    }
    let lines: Vec<&str> = body.split('\n').collect();
    if lines.len() > MAX_SECRETS {
        bail!("{} lines, at most {} allowed", lines.len(), MAX_SECRETS);
    }
    let mut out: Vec<String> = Vec::with_capacity(lines.len());
    for (i, line) in lines.iter().enumerate() {
        let n = i + 1;
        if line.len() != SECRET_LEN || !line.bytes().all(is_b64url) {
            bail!("line {n} is not exactly {SECRET_LEN} chars of [A-Za-z0-9_-]");
        }
        if out.iter().any(|s| s == line) {
            bail!("line {n} duplicates an earlier line");
        }
        out.push((*line).to_string());
    }
    Ok(out)
}

fn is_b64url(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'_' || b == b'-'
}

/// `static-auth-secret=<s>\n` per secret, in order.
pub fn secret_lines(secrets: &[String]) -> String {
    secrets
        .iter()
        .map(|s| format!("static-auth-secret={s}\n"))
        .collect()
}
