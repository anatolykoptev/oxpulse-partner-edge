//! Phase 4.3 — partner-edge secrets bootstrap.
//!
//! Subcommands:
//! - `reality-keygen` (Phase 4.3a) — x25519 keypair + UUID identity files.
//! - `register` (Phase 4.3b) — POST to central registry, parse response.
//! - `runtime` (Phase 4.3c) — fetch SFU signing key, synthesize JWT secret.

use clap::Subcommand;
use std::path::PathBuf;

pub mod awg;
pub mod error;
pub mod reality;

pub use error::SecretsError;

#[derive(Subcommand)]
pub enum SecretsCommands {
    /// Generate or reuse Reality x25519 identity (reality.priv, reality.pub, reality.uuid).
    RealityKeygen {
        /// Directory to write identity files to.
        #[arg(long)]
        out_dir: PathBuf,
        /// Force regeneration even when valid identity exists.
        #[arg(long)]
        rotate: bool,
        /// Override partner-cli binary path (test hook).
        #[arg(long, default_value = "partner-cli")]
        partner_cli: PathBuf,
    },
    /// Generate or reuse AmneziaWG keypair (awg-private.key, awg-public.key).
    AwgKeygen {
        /// Directory to write keypair files to.
        #[arg(long)]
        out_dir: PathBuf,
        /// Force regeneration even when valid keypair exists.
        #[arg(long)]
        rotate: bool,
        /// Override wg binary path (test hook).
        #[arg(long, default_value = "wg")]
        wg: PathBuf,
    },
}

pub fn dispatch(cmd: SecretsCommands) -> anyhow::Result<()> {
    match cmd {
        SecretsCommands::RealityKeygen {
            out_dir,
            rotate,
            partner_cli,
        } => reality::keygen(&out_dir, rotate, &partner_cli).map_err(Into::into),
        SecretsCommands::AwgKeygen { out_dir, rotate, wg } => {
            awg::keygen(&out_dir, rotate, &wg).map_err(Into::into)
        }
    }
}
