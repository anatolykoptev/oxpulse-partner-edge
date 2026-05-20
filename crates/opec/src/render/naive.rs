//! naive-client.json render — substitute env vars then validate as JSON.
//!
//! Note: if validation fails the rendered file remains on disk (atomic-rename
//! happens before validation). Callers do cleanup. Matches bash
//! render_template + render::xray semantics.

use anyhow::Result;
use once_cell::sync::Lazy;
use regex::Regex;
use std::path::Path;

use super::{render_to_file, RenderError};

/// Regex for test-fixture hostnames that must never reach a container.
/// Matches: localhost, *.example.{com,net,org} (and bare example.{com,net,org}),
/// *.test (and bare .test)
/// Evidence: ruoxp crashloop 2026-05-17 -- naive_server=naive-test.example.com
/// was rendered and started; container crashed because real DNS doesn't resolve.
static FIXTURE_HOST_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"(?i)^(localhost|(.*\.)?example\.(com|net|org)|.*\.test)$").unwrap());

pub fn render(src: &Path, dst: &Path) -> Result<()> {
    let rendered = render_to_file(src, dst)?;

    // Fix #2: fixture-host guard -- check NAIVE_SERVER env var directly after
    // substitute_from_env has run (inside render_to_file).  Reading from env
    // here mirrors what the template substituted, without re-parsing rendered JSON.
    // Guard fires BEFORE JSON validation per spec.
    let naive_server = std::env::var("NAIVE_SERVER").unwrap_or_default();
    if !naive_server.is_empty() && FIXTURE_HOST_RE.is_match(&naive_server) {
        return Err(RenderError::Validation {
            kind: "naive",
            reason: format!(
                "rendered naive_server '{}' resolves to a test fixture host \
                 (matches localhost / *.example.{{com,net,org}} / *.test); \
                 set a real production host in naive_server",
                naive_server
            ),
        }
        .into());
    }

    serde_json::from_str::<serde_json::Value>(&rendered).map_err(|e| RenderError::Validation {
        kind: "naive",
        reason: format!("rendered file is not valid JSON: {e}"),
    })?;
    Ok(())
}
