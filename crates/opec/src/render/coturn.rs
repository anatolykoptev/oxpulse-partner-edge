//! coturn.conf render — substitute env vars + sanity-check the realm directive.
//!
//! Note: if validation fails the rendered file remains on disk (atomic-rename
//! happens before validation). Callers do cleanup. Matches bash
//! render_template semantics.

use anyhow::Result;
use std::path::Path;

use super::{render_to_file, RenderError};

/// Render coturn.conf from `src` template into `dst`. After substitution,
/// asserts that a non-empty `realm=<value>` line is present. coturn silently
/// rejects an empty realm (HMAC-credential validation fails for all clients),
/// so catching it at render time saves a downstream debugging cycle.
pub fn render(src: &Path, dst: &Path) -> Result<()> {
    let rendered = render_to_file(src, dst)?;
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
