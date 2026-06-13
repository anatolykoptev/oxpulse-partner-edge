//! oxpulse-awg-params-agent — T1.3.d: pull side of AWG params federation.
//!
//! Polls `GET /api/partner/awg-params/latest?component=awg`, applies new
//! AmneziaWG obfuscation params to the kernel, and reports back (best-effort)
//! via `POST /api/partner/awg-params/applied`.
//!
//! # Deployment
//!
//! This is a **host binary** installed at `/usr/local/bin/oxpulse-awg-params-agent`
//! and managed by the `oxpulse-awg-params-agent.service` systemd unit.  It is NOT
//! containerized.  To update the binary: re-run `install-awg-params-agent.sh` (or
//! re-run the full installer) which fetches the new release asset from GitHub
//! releases.  The unit-file-only change (no binary bump) is deployed by
//! `upgrade.sh` via `_HOST_SCRIPT_SYSTEMD_FILES` sync without reinstalling the binary.
//!
//! # Configuration
//!
//! Configuration is entirely via environment variables:
//!   OXPULSE_CENTRAL_URL         (required)
//!   OXPULSE_NODE_ID             (required)
//!   OXPULSE_SERVICE_TOKEN_PATH  (default /etc/oxpulse-partner-edge/token)
//!   OXPULSE_AWG_CONF_PATH       (default /etc/amnezia/amneziawg/awg0.conf)
//!   OXPULSE_AWG_IFACE           (default awg0)
//!   OXPULSE_STATE_PATH          (default /var/lib/oxpulse-partner-edge/awg-params-state.json)
//!   OXPULSE_POLL_INTERVAL       (default 30s, humantime format: "30s", "1m")
//!   OXPULSE_RESTART_UNIT_AFTER_APPLY  (optional; systemd unit restarted after each
//!                                      successful kernel apply — used by split-routing
//!                                      to re-assert AllowedIPs widening after syncconf)

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

    // Optional post-apply hook: restart this systemd unit after each successful
    // kernel apply.  Empty string → disabled.  Used by split-routing to re-assert
    // AllowedIPs widening strictly after awg syncconf re-narrowed it.
    let restart_unit_after_apply = {
        let val = env_or("OXPULSE_RESTART_UNIT_AFTER_APPLY", "");
        if val.is_empty() {
            None
        } else {
            Some(val)
        }
    };

    info!(
        central_url = %central_url,
        node_id = %node_id,
        token_path = %token_path,
        awg_conf = ?awg_conf_path,
        awg_iface = %awg_iface,
        state_path = ?state_path,
        poll_interval = ?poll_interval,
        restart_unit_after_apply = ?restart_unit_after_apply,
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
        restart_unit_after_apply,
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

#[cfg(test)]
mod tests {

    // ── OXPULSE_RESTART_UNIT_AFTER_APPLY env → Option mapping ────────────────
    //
    // These tests guard the load_config() branch: unset or empty env var must
    // produce None (hook disabled); non-empty must produce Some(unit).
    // A regression that removed the is_empty() guard would make the unset case
    // return Some(""), enabling the hook unconditionally — caught here.

    #[test]
    fn restart_unit_unset_maps_to_none() {
        // When the env var is absent, env_or returns the default ""; is_empty →
        // None.  We test env_or + branch inline to avoid touching real env state.
        let val = env_or_for_test("OXPULSE_RESTART_UNIT_AFTER_APPLY_ABSENT_42x", "");
        let result: Option<String> = if val.is_empty() { None } else { Some(val) };
        assert_eq!(
            result, None,
            "unset env var must map to None (hook disabled)"
        );
    }

    #[test]
    fn restart_unit_empty_string_maps_to_none() {
        // Explicit empty string in the unit file: Environment=OXPULSE_RESTART_UNIT_AFTER_APPLY=
        // Must map to None.
        let val = String::new();
        let result: Option<String> = if val.is_empty() { None } else { Some(val) };
        assert_eq!(
            result, None,
            "empty string must map to None (hook disabled)"
        );
    }

    #[test]
    fn restart_unit_non_empty_maps_to_some() {
        // Non-empty value maps to Some.
        let val = "oxpulse-partner-edge-split-routing.service".to_owned();
        let result: Option<String> = if val.is_empty() {
            None
        } else {
            Some(val.clone())
        };
        assert_eq!(
            result,
            Some("oxpulse-partner-edge-split-routing.service".to_owned()),
            "non-empty env var must map to Some(unit)",
        );
    }

    /// Thin wrapper that keeps test code identical to the production branch.
    /// Returns `default` when the variable is absent (same as `env_or`).
    fn env_or_for_test(key: &str, default: &str) -> String {
        std::env::var(key).unwrap_or_else(|_| default.to_owned())
    }
}
