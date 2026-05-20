//! Phase 4.3 — partner-edge secrets bootstrap.
//!
//! Subcommands:
//! - `reality-keygen` (Phase 4.3a) — x25519 keypair + UUID identity files.
//! - `register` (Phase 4.3b) — POST to central registry, parse response.
//! - `sfu-signing-key` (Phase 4.3d) — GET signing key, write env-file.

use clap::Subcommand;
use std::path::PathBuf;

pub mod awg;
pub mod error;
pub mod reality;
pub mod register;
pub mod sfu_key;
pub mod wg_keypair;
pub mod x25519;

pub use error::SecretsError;

// Register variant holds 13 clap fields; boxing clap-derive fields is not
// idiomatic — suppress the lint instead.
#[allow(clippy::large_enum_variant)]
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
    },
    /// Generate or reuse AmneziaWG keypair (awg-private.key, awg-public.key).
    AwgKeygen {
        /// Directory to write keypair files to.
        #[arg(long)]
        out_dir: PathBuf,
        /// Force regeneration even when valid keypair exists.
        #[arg(long)]
        rotate: bool,
    },
    /// GET SFU signing public key from /api/partner/keys, write env-file.
    SfuSigningKey {
        /// Backend API base URL (e.g. https://api.example.com).
        #[arg(long)]
        backend_api: String,
        /// Path to write SFU signing key env-file (single-quoted, 0600).
        #[arg(long)]
        out_file: PathBuf,
        /// HTTP request timeout in seconds.
        #[arg(long, default_value = "10")]
        timeout_secs: u64,
        /// Number of retries for 5xx responses.
        #[arg(long, default_value = "3")]
        retries: u32,
    },
    /// POST to backend /api/partner/register, write shell-sourceable env-file.
    Register {
        #[arg(long)]
        registry_url: String,
        #[arg(long)]
        partner_id: String,
        #[arg(long)]
        domain: String,
        #[arg(long)]
        token: String,
        #[arg(long)]
        public_ip: String,
        #[arg(long)]
        reality_pub_file: PathBuf,
        #[arg(long)]
        reality_uuid_file: PathBuf,
        #[arg(long)]
        awg_pub_file: PathBuf,
        #[arg(long)]
        out_env: PathBuf,
        /// Optional path to dump the raw HTTP response body (atomic, 0600)
        /// for install.sh to extract fields beyond the 10 canonical env keys.
        #[arg(long)]
        out_json: Option<PathBuf>,
        #[arg(long)]
        region: Option<String>,
        #[arg(long)]
        branding_config: Option<PathBuf>,
        #[arg(long, default_value = "30")]
        timeout_secs: u64,
        #[arg(long, default_value = "3")]
        retries: u32,
    },
}

pub fn dispatch(cmd: SecretsCommands) -> anyhow::Result<()> {
    match cmd {
        SecretsCommands::SfuSigningKey {
            backend_api,
            out_file,
            timeout_secs,
            retries,
        } => sfu_key::fetch(sfu_key::Args {
            backend_api,
            out_file,
            timeout_secs,
            retries,
        })
        .map_err(Into::into),
        SecretsCommands::RealityKeygen { out_dir, rotate } => {
            reality::keygen(&out_dir, rotate).map_err(Into::into)
        }
        SecretsCommands::AwgKeygen { out_dir, rotate } => {
            awg::keygen(&out_dir, rotate).map_err(Into::into)
        }
        SecretsCommands::Register {
            registry_url,
            partner_id,
            domain,
            token,
            public_ip,
            reality_pub_file,
            reality_uuid_file,
            awg_pub_file,
            out_env,
            out_json,
            region,
            branding_config,
            timeout_secs,
            retries,
        } => register::run(register::Args {
            registry_url,
            partner_id,
            domain,
            token,
            public_ip,
            reality_pub_file,
            reality_uuid_file,
            awg_pub_file,
            out_env,
            out_json,
            region,
            branding_config,
            timeout_secs,
            retries,
        })
        .map_err(Into::into),
    }
}
