//! coturn.conf render — substitute env vars + sanity-check the realm directive.
//!
//! Note: if validation fails the rendered file remains on disk (atomic-rename
//! happens before validation). Callers do cleanup. Matches bash
//! render_template semantics.

use anyhow::Result;
use std::path::Path;

use super::{render_string_pre, render_to_file, secret_file, write_atomic, RenderError};

/// Render coturn.conf from `src` template into `dst`. After substitution,
/// asserts that a non-empty `realm=<value>` line is present. coturn silently
/// rejects an empty realm (HMAC-credential validation fails for all clients),
/// so catching it at render time saves a downstream debugging cycle.
pub fn render(src: &Path, dst: &Path) -> Result<()> {
    let tpl_text = std::fs::read_to_string(src).unwrap_or_default();
    if tpl_text.contains(secret_file::SECRET_LINES_PLACEHOLDER) {
        // Without a secret file the placeholder would silently render empty,
        // leaving coturn with no auth secret. Refuse instead.
        return Err(RenderError::Validation {
            kind: "coturn",
            reason: "template has a secret-lines placeholder but no --secret-file was given"
                .to_string(),
        }
        .into());
    }
    let rendered = render_to_file(src, dst)?;
    check_realm(&rendered)
}

/// Render a relay-only-node template: one `static-auth-secret=` line per line of
/// `secret_file` (see [`secret_file::read_node_secrets`] for the file contract).
/// The secrets never enter the environment and are never printed.
pub fn render_with_secret_file(src: &Path, dst: &Path, secret_path: &Path) -> Result<()> {
    let secrets = secret_file::read_node_secrets(secret_path)?;
    let lines = secret_file::secret_lines(&secrets);
    let rendered = render_string_pre(src, dst, |tpl| {
        tpl.replace(
            secret_file::SECRET_LINES_PLACEHOLDER,
            lines.trim_end_matches('\n'),
        )
    })?;
    let got = rendered
        .lines()
        .filter(|l| l.starts_with("static-auth-secret="))
        .count();
    if got != secrets.len() {
        return Err(RenderError::Validation {
            kind: "coturn",
            reason: format!(
                "rendered {got} static-auth-secret line(s), expected {} (template lacks the secret-lines placeholder?)",
                secrets.len()
            ),
        }
        .into());
    }
    // Validate fully BEFORE writing: a refused render leaves no file behind.
    check_realm(&rendered)?;
    write_atomic(dst, &rendered)
}

fn check_realm(rendered: &str) -> Result<()> {
    let has_realm = rendered.lines().any(|line| {
        let t = line.trim_start();
        if let Some(rest) = t.strip_prefix("realm=") {
            !rest.trim().is_empty()
        } else {
            false
        }
    });
    if !has_realm {
        return Err(RenderError::Validation {
            kind: "coturn",
            reason: "rendered coturn.conf has empty or missing `realm=` directive".to_string(),
        }
        .into());
    }
    Ok(())
}
