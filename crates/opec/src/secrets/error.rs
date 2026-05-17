//! Typed errors for `opec secrets` subcommands.

use std::path::PathBuf;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum SecretsError {
    #[error("partner-cli not found at {0} — install partner-cli first or pass --partner-cli")]
    PartnerCliMissing(PathBuf),

    #[error("partner-cli keygen failed: {stderr}")]
    PartnerCliFailed { stderr: String },

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
}
