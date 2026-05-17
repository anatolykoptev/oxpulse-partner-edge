//! Caddyfile render — substitute env vars + balanced-brace + site-block sanity.
//!
//! Caddyfile syntax doesn't have a lightweight Rust parser; full validation
//! would require shelling out to `caddy validate` which adds a runtime
//! dependency. Two cheap post-substitution checks instead:
//!
//! 1. Brace balance — Caddyfile site blocks use `{...}`; extra/missing
//!    braces produce cryptic Caddy startup errors. Catching at render time
//!    gives the installer a clear diagnostic.
//! 2. Site-block presence — at least one non-whitespace, non-comment line
//!    must contain `{`. Catches the broken-template case where substitution
//!    leaves no actionable config.
//!
//! Note: if validation fails the rendered file remains on disk (atomic-rename
//! happens before validation). Callers do cleanup. Matches render::xray
//! semantics.

use anyhow::Result;
use std::path::Path;

use super::{render_to_file, RenderError};

pub fn render(src: &Path, dst: &Path) -> Result<()> {
    let rendered = render_to_file(src, dst)?;

    let opens = rendered.bytes().filter(|&b| b == b'{').count();
    let closes = rendered.bytes().filter(|&b| b == b'}').count();
    if opens != closes {
        return Err(RenderError::Validation {
            kind: "caddy",
            reason: format!(
                "rendered Caddyfile has unbalanced braces: {opens} opens vs {closes} closes"
            ),
        }
        .into());
    }

    let has_site_block = rendered.lines().any(|line| {
        let t = line.trim_start();
        !t.is_empty() && !t.starts_with('#') && t.contains('{')
    });
    if !has_site_block {
        return Err(RenderError::Validation {
            kind: "caddy",
            reason: "rendered Caddyfile contains no site-block opener (`<domain> {`)".to_string(),
        }
        .into());
    }

    Ok(())
}
