//! Phase 4.3a — Reality x25519 identity management.
//! Real impl lands in Task 2. This stub satisfies the dispatch signature
//! so the skeleton test can pass.

use super::error::SecretsError;
use std::path::Path;

pub fn keygen(out_dir: &Path, _rotate: bool, _partner_cli: &Path) -> Result<(), SecretsError> {
    // T2 will implement this. T1 only validates the CLI surface.
    let _ = out_dir;
    Err(SecretsError::PartnerCliFailed {
        stderr: "stub — Task 2 will implement keygen".into(),
    })
}
