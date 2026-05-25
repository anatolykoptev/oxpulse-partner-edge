//! oxpulse-awg-params-agent — T1.3.d: pull side of AWG params federation.
//!
//! Polls `GET /api/partner/awg-params/latest?component=awg`, applies new
//! AmneziaWG obfuscation params to the kernel, and reports back (best-effort)
//! via `POST /api/partner/awg-params/applied`.
//!
//! Configuration is entirely via environment variables:
//!   OXPULSE_CENTRAL_URL         (required)
//!   OXPULSE_NODE_ID             (required)
//!   OXPULSE_SERVICE_TOKEN_PATH  (default /etc/oxpulse-partner-edge/token)
//!   OXPULSE_AWG_CONF_PATH       (default /etc/amnezia/amneziawg/awg0.conf)
//!   OXPULSE_AWG_IFACE           (default awg0)
//!   OXPULSE_STATE_PATH          (default /var/lib/oxpulse-partner-edge/awg-params-state.json)
//!   OXPULSE_POLL_INTERVAL       (default 30s, humantime format: "30s", "1m")

mod agent;
mod client;
mod conf_merge;
mod error;
mod params;
mod state;

use agent::{AgentConfig, AgentLoop};
use error::Result;
use std::{path::PathBuf, time::Duration};
use tracing::info;

fn main() -> anyhow::Result<()> {
    // Init tracing. RUST_LOG controls verbosity; default to info.
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .init();

    let cfg = load_config()?;

    let rt = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?;

    rt.block_on(async move {
        let agent = AgentLoop::new(cfg)?;
        agent.run().await
    })
}

fn load_config() -> Result<AgentConfig> {
    let central_url = require_env("OXPULSE_CENTRAL_URL")?;
    let node_id = require_env("OXPULSE_NODE_ID")?;

    let token_path = env_or(
        "OXPULSE_SERVICE_TOKEN_PATH",
        "/etc/oxpulse-partner-edge/token",
    );
    let service_token = std::fs::read_to_string(&token_path)
        .map(|s| s.trim().to_owned())
        .map_err(|e| {
            anyhow::anyhow!(
                "read service token from {:?}: {} \
                 (set OXPULSE_SERVICE_TOKEN_PATH to override)",
                token_path,
                e
            )
        })?;

    if service_token.is_empty() {
        return Err(anyhow::anyhow!(
            "service token file {:?} is empty",
            token_path
        ));
    }

    let awg_conf_path: PathBuf =
        env_or("OXPULSE_AWG_CONF_PATH", "/etc/amnezia/amneziawg/awg0.conf").into();

    let awg_iface = env_or("OXPULSE_AWG_IFACE", "awg0");

    let state_path: PathBuf = env_or(
        "OXPULSE_STATE_PATH",
        "/var/lib/oxpulse-partner-edge/awg-params-state.json",
    )
    .into();

    let poll_interval = parse_duration(&env_or("OXPULSE_POLL_INTERVAL", "30s"))?;

    info!(
        central_url = %central_url,
        node_id = %node_id,
        token_path = %token_path,
        awg_conf = ?awg_conf_path,
        awg_iface = %awg_iface,
        state_path = ?state_path,
        poll_interval = ?poll_interval,
        "config loaded"
    );

    Ok(AgentConfig {
        central_url,
        service_token_path: std::path::PathBuf::from(&token_path),
        awg_conf_path,
        awg_iface,
        state_path,
        poll_interval,
        node_id,
    })
}

fn require_env(key: &str) -> Result<String> {
    std::env::var(key).map_err(|_| anyhow::anyhow!("required env var {} is not set", key))
}

fn env_or(key: &str, default: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| default.to_owned())
}

/// Parse a humantime duration string like "30s", "1m", "2m30s".
fn parse_duration(s: &str) -> Result<Duration> {
    humantime::parse_duration(s)
        .map_err(|e| anyhow::anyhow!("invalid OXPULSE_POLL_INTERVAL {:?}: {}", s, e))
}
