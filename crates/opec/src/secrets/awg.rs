//! Phase 4.3b — AmneziaWG (wg-tools) keypair management.
//! Task 1 ships the CLI surface only; the real impl arrives in Task 2.

use super::error::SecretsError;
use std::path::Path;

/// Stub — Task 2 replaces this.
pub fn keygen(_out_dir: &Path, _rotate: bool, _wg: &Path) -> Result<(), SecretsError> {
    unimplemented!("opec::secrets::awg::keygen — Task 2 implements this")
}
