//! SFU runtime configuration. Env-driven to match the conventions in
//! `crates/server/src/config.rs` — `from_env()` with sensible defaults
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
}

impl Default for SfuConfig {
    fn default() -> Self {
        Self {
            udp_port: 3478,
            metrics_port: 9317,
            bind_address: "0.0.0.0".to_string(),
            log_level: "info".to_string(),
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
    }
}
