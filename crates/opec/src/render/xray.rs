//! xray-client.json render — substitute env vars then validate as JSON.

use anyhow::Result;
use std::path::Path;

use super::{render_to_file, RenderError};

/// Render xray-client.json from `src` template into `dst`. Substitutes
/// `{{NAME}}` placeholders from env, writes atomically, then parses the
/// result as JSON to catch any substitution that produced invalid syntax.
///
/// Note: if the post-substitution JSON validation fails, the rendered
/// file IS still present at `dst` (the atomic-rename happened before
/// validation). Callers should `fs::remove_file(dst)` on error if they
/// want a clean rollback. This mirrors bash `render_template` semantics.
pub fn render(src: &Path, dst: &Path) -> Result<()> {
    let rendered = render_to_file(src, dst)?;
    serde_json::from_str::<serde_json::Value>(&rendered).map_err(|e| RenderError::Validation {
        kind: "xray",
        reason: format!("rendered file is not valid JSON: {e}"),
    })?;
    Ok(())
}
