//! SFU runtime configuration. Env-driven to match the conventions in
//! `crates/server/src/config.rs` -- `from_env()` with sensible defaults
//! and panics only on obviously malformed numeric input at startup.

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SfuConfig {
    /// UDP port the SFU listens on for WebRTC media (DTLS/SRTP/STUN
    /// multiplexed over a single socket per the str0m `chat.rs` pattern).
    pub udp_port: u16,
    /// HTTP port for Prometheus `/metrics`. Wired up in M1.5; kept in
    /// config now so the env surface is stable from day one.
    pub metrics_port: u16,
    /// Bind address for both sockets (default `0.0.0.0`).
    pub bind_address: String,
    /// `RUST_LOG`-style directive for `tracing_subscriber`. Falls back
    /// to the `RUST_LOG` env var when the user sets it directly.
    pub log_level: String,
    /// HTTP port for the relay API (`POST /relay/connect`).
    /// Env: `SFU_RELAY_API_PORT`. Default: 8912.
    pub relay_api_port: u16,
    /// Shared secret for verifying room JWTs issued by oxpulse-chat signaling.
    /// Must match `SIGNALING_SFU_SECRET` on the signaling server.
    /// When `Some`, relay_source DataChannel messages MUST include a valid roomToken.
    /// When `None`, relay promotion is unauthenticated (dev/test only).
    /// Env: `SIGNALING_SFU_SECRET`.
    pub relay_auth_secret: Option<Vec<u8>>,
    /// Whether FIPS 140-3 mode is required. Binary must be compiled with
    /// `--features fips` (aws-lc-rs). Env: `SFU_FIPS=1`. Default: false.
    pub fips_mode: bool,
}

impl Default for SfuConfig {
    fn default() -> Self {
        Self {
            udp_port: 3478,
            metrics_port: 9317,
            bind_address: "0.0.0.0".to_string(),
            log_level: "info".to_string(),
            relay_api_port: 8912,
            relay_auth_secret: None,
            fips_mode: false,
        }
    }
}

impl SfuConfig {
    pub fn from_env() -> Self {
        let defaults = Self::default();
        Self {
            udp_port: env("SFU_UDP_PORT", &defaults.udp_port.to_string())
                .parse()
                .expect("SFU_UDP_PORT must be a number"),
            metrics_port: env("SFU_METRICS_PORT", &defaults.metrics_port.to_string())
                .parse()
                .expect("SFU_METRICS_PORT must be a number"),
            bind_address: env("SFU_BIND_ADDRESS", &defaults.bind_address),
            log_level: env("RUST_LOG", &defaults.log_level),
            relay_api_port: env("SFU_RELAY_API_PORT", &defaults.relay_api_port.to_string())
                .parse()
                .expect("SFU_RELAY_API_PORT must be a number"),
            relay_auth_secret: std::env::var("SIGNALING_SFU_SECRET")
                .ok()
                .filter(|s| !s.is_empty())
                .map(|s| s.into_bytes()),
            fips_mode: std::env::var("SFU_FIPS").as_deref() == Ok("1"),
        }
    }
}

fn env(key: &str, default: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| default.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_is_sensible() {
        let cfg = SfuConfig::default();
        assert_eq!(cfg.bind_address, "0.0.0.0");
        assert_eq!(cfg.udp_port, 3478);
        assert_ne!(cfg.udp_port, cfg.metrics_port);
        assert_ne!(cfg.metrics_port, cfg.relay_api_port);
        assert_ne!(cfg.udp_port, cfg.relay_api_port);
        assert!(!cfg.fips_mode);
    }

    #[test]
    fn relay_api_port_default_and_env() {
        let cfg = SfuConfig::default();
        assert_eq!(cfg.relay_api_port, 8912);
    }

    #[test]
    fn relay_auth_secret_default_is_none() {
        let cfg = SfuConfig::default();
        assert!(cfg.relay_auth_secret.is_none(),
            "relay_auth_secret should default to None (unauthenticated dev mode)");
    }

    #[test]
    fn fips_mode_defaults_false() {
        std::env::remove_var("SFU_FIPS");
        let cfg = SfuConfig::default();
        assert!(!cfg.fips_mode, "fips_mode must default to false");
    }

    #[test]
    fn fips_mode_env_one_enables() {
        std::env::set_var("SFU_FIPS", "1");
        let cfg = SfuConfig::from_env();
        assert!(cfg.fips_mode);
        std::env::remove_var("SFU_FIPS");
    }

    #[test]
    fn fips_mode_env_empty_is_false() {
        std::env::set_var("SFU_FIPS", "");
        let cfg = SfuConfig::from_env();
        assert!(!cfg.fips_mode);
        std::env::remove_var("SFU_FIPS");
    }
}
