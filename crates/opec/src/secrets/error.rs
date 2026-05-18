//! Typed errors for `opec secrets` subcommands.

use std::path::PathBuf;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum SecretsError {
    #[error(
        "PARTIAL identity at {dir}: found {found:?}, missing {missing:?}. \
         Remove all reality.* files for a fresh identity, or restore the missing ones from backup."
    )]
    PartialIdentity {
        dir: PathBuf,
        found: Vec<&'static str>,
        missing: Vec<&'static str>,
    },

    #[error("invalid key format at {path}: expected 43-char base64url, got {actual_len} bytes")]
    InvalidKeyFormat { path: PathBuf, actual_len: usize },

    #[error("io error at {path}: {source}")]
    Io {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },

    #[error("HTTP {status}: {body}")]
    Http { status: u16, body: String },

    #[error("transport error: {source}")]
    Transport {
        #[source]
        source: Box<ureq::Error>,
    },

    #[error("missing required response field: {name}")]
    MissingResponseField { name: &'static str },

    #[error("stale registry response: reality_encryption is empty but reality_public_key is set — refusing to write known-broken xray-client config")]
    StaleRegistry,

    /// JSON parse / serialization failure during local body construction or
    /// response decoding. NEVER carries raw body content — only metadata
    /// (length, error category) — to avoid leaking secrets via Display.
    #[error("response/body parse error: {reason}")]
    ResponseParse { reason: String },

    /// `--branding-config` file is not valid JSON. `reason` carries only
    /// length + error category; never raw file content.
    #[error("invalid --branding-config at {path}: {reason}")]
    InvalidBranding { path: PathBuf, reason: String },

    /// Backend returned a value that would break the env-file invariant
    /// (e.g. newline → shell-source injection vector). Refuse to write.
    #[error("invalid response value for {name}: {reason}")]
    InvalidResponseValue { name: String, reason: String },
}
