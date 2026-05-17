//! Phase 4.3a — Reality x25519 identity management.
//! Task 1 ships the CLI surface only; the real impl arrives in Task 2.

use super::error::SecretsError;
use std::path::Path;

/// Stub — Task 2 replaces this with the real keygen.
///
/// Panics loud (rather than returning a sentinel error) so that any caller
/// reaching this path before Task 2 lands is impossible to ignore. CLI
/// integration tests in Task 1 only exercise clap argument parsing, which
/// short-circuits before `dispatch()` is reached.
pub fn keygen(_out_dir: &Path, _rotate: bool, _partner_cli: &Path) -> Result<(), SecretsError> {
    unimplemented!("opec::secrets::reality::keygen — Task 2 implements this")
}
