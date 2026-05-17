//! naive-client.json render — substitute env vars then validate as JSON.
//!
//! Note: if validation fails the rendered file remains on disk (atomic-rename
//! happens before validation). Callers do cleanup. Matches bash
//! render_template + render::xray semantics.

use anyhow::Result;
use std::path::Path;

use super::{render_to_file, RenderError};

pub fn render(src: &Path, dst: &Path) -> Result<()> {
    let rendered = render_to_file(src, dst)?;
    serde_json::from_str::<serde_json::Value>(&rendered).map_err(|e| RenderError::Validation {
        kind: "naive",
        reason: format!("rendered file is not valid JSON: {e}"),
    })?;
    Ok(())
}
