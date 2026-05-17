//! Generic mustache-style template substitution shared by per-kind render
//! modules. Mirrors `channel-render-lib.sh::render_template` semantics:
//!
//! - placeholders match `{{NAME}}` where NAME = `[A-Z][A-Z0-9_]*`
//! - replacement value: `std::env::var(NAME).unwrap_or_default()`
//! - multi-line values preserved verbatim (no escaping)
//! - all other characters pass through unchanged
//!
//! Per-kind modules (xray, coturn, naive) add post-substitution validation
//! (JSON shape, line-count sanity) and the public `render(tpl, out)` entry
//! they expose to `crates/opec/src/main.rs`.

use anyhow::{Context, Result};
use once_cell::sync::Lazy;
use regex::Regex;
use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
};
use thiserror::Error;

pub mod coturn;
pub mod naive;
pub mod xray;

#[derive(Error, Debug)]
pub enum RenderError {
    #[error("source template not found: {0}")]
    SrcMissing(PathBuf),
    #[error("destination directory missing: {0}")]
    DstDirMissing(PathBuf),
    #[error("validation failed for {kind}: {reason}")]
    Validation { kind: &'static str, reason: String },
}

/// Substitute every `{{NAME}}` (NAME = `[A-Z][A-Z0-9_]*`) in `tpl` with the
/// value of env var `NAME`, empty string when unset.
///
/// Pure function — no I/O.
pub fn substitute_from_env(tpl: &str) -> String {
    static PATTERN: Lazy<Regex> =
        Lazy::new(|| Regex::new(r"\{\{([A-Z][A-Z0-9_]*)\}\}").unwrap());

    PATTERN
        .replace_all(tpl, |caps: &regex::Captures| {
            std::env::var(&caps[1]).unwrap_or_default()
        })
        .into_owned()
}

/// Read `src`, substitute env vars, write to a temp file in `dst`'s parent,
/// rename atomically into `dst`. Returns the rendered output as a string for
/// caller-side validation.
///
/// Atomic-write contract matches `channel-render-lib.sh::render_template`:
/// tmp file lives in same directory as dst (so rename is intra-fs) and uses
/// a hidden `.basename.XXXXXX.tmp` template.
pub fn render_to_file(src: &Path, dst: &Path) -> Result<String> {
    if !src.is_file() {
        return Err(RenderError::SrcMissing(src.to_path_buf()).into());
    }
    let dst_dir = dst.parent().unwrap_or_else(|| Path::new("."));
    if !dst_dir.is_dir() {
        return Err(RenderError::DstDirMissing(dst_dir.to_path_buf()).into());
    }

    let tpl = fs::read_to_string(src)
        .with_context(|| format!("reading template {}", src.display()))?;
    let rendered = substitute_from_env(&tpl);

    let mut tmp = tempfile::Builder::new()
        .prefix(&format!(
            ".{}.",
            dst.file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("opec-render")
        ))
        .suffix(".tmp")
        .tempfile_in(dst_dir)
        .with_context(|| format!("creating tmp in {}", dst_dir.display()))?;
    tmp.as_file_mut().write_all(rendered.as_bytes())?;
    tmp.flush()?;
    tmp.persist(dst)
        .with_context(|| format!("rename tmp to {}", dst.display()))?;

    Ok(rendered)
}
