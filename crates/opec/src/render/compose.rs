//! docker-compose.yml render — substitute env vars then validate as YAML.
//!
//! Note: if validation fails the rendered file remains on disk (atomic-rename
//! happens before validation). Callers do cleanup. Matches bash
//! render_template + render::xray semantics.

use anyhow::Result;
use std::path::Path;

use super::{render_to_file, RenderError};

/// Render docker-compose.yml from `src` template into `dst`. Substitutes
/// `{{NAME}}` placeholders from env, writes atomically, then parses the
/// result via serde_yml to catch substitution that produced invalid YAML.
pub fn render(src: &Path, dst: &Path) -> Result<()> {
    let rendered = render_to_file(src, dst)?;
    serde_yml::from_str::<serde_yml::Value>(&rendered).map_err(|e| RenderError::Validation {
        kind: "compose",
        reason: format!("rendered file is not valid YAML: {e}"),
    })?;
    Ok(())
}
