//! SFU runtime configuration. Env-driven to match the conventions in
//! `crates/server/src/config.rs` -- `from_env()` with sensible defaults
//! and panics only on obviously malformed numeric input at startup.

use std::net::IpAddr;

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
    /// HTTP port for the client-facing WebSocket endpoint
    /// (`/sfu/ws/{room_id}`). Browsers connect here directly via the
    /// Caddy `/sfu/ws/*` reverse_proxy. Env: `SFU_CLIENT_WS_PORT`.
    /// Default: 8920.
    ///
    /// Note: 8911 was the original choice but is squatted on krolik
    /// (San Jose) by an unrelated go-imagine process. 8920 was picked
    /// to avoid a fleet-wide eviction; the value is partner-edge-wide
    /// (rvpn / piter / krolik all bind 8920) so the same Caddy
    /// template ships everywhere.
    pub client_ws_port: u16,
    /// Shared secret for verifying room JWTs issued by oxpulse-chat signaling.
    /// Must match `SIGNALING_SFU_SECRET` on the signaling server.
    /// When `Some`, relay_source DataChannel messages MUST include a valid roomToken.
    /// When `None`, relay promotion is unauthenticated (dev/test only).
    /// Env: `SIGNALING_SFU_SECRET`.
    pub relay_auth_secret: Option<Vec<u8>>,
    /// Whether FIPS 140-3 mode is required. Binary must be compiled with
    /// `--features fips` (aws-lc-rs). Env: `SFU_FIPS=1`. Default: false.
    pub fips_mode: bool,
    /// Ed25519 public key PEM for verifying relay JWT tokens issued by oxpulse-chat.
    /// Fetched from /api/partner/keys and stored in node-config.
    /// Env: SFU_SIGNING_PUBLIC_KEY.
    /// If None, falls back to HS256 RELAY_JWT_SECRET (deprecated -- use Ed25519).
    pub sfu_signing_public_key: Option<String>,
    /// Public IP advertised in WebRTC host candidates. When `Some`, the
    /// SFU emits `Candidate::host(SocketAddr::new(public_ip, udp_port))`
    /// instead of the bind address (which is typically `0.0.0.0:N` and
    /// unroutable from off-box browsers). Env: `SFU_PUBLIC_IP`.
    ///
    /// Phase 7 M4.A6 — without this, browsers from off-box networks
    /// cannot complete ICE because the SFU's only host candidate is
    /// `0.0.0.0:N`. Falls back to the bind address when unset, which
    /// preserves the dev/test loopback behavior. Set this to the node's
    /// public IPv4 in production (rendered by install.sh / docker-compose
    /// from the `$PUBLIC_IP` autodetect).
    pub public_ip: Option<IpAddr>,
}

impl Default for SfuConfig {
    fn default() -> Self {
        Self {
            udp_port: 3478,
            metrics_port: 9317,
            bind_address: "0.0.0.0".to_string(),
            log_level: "info".to_string(),
            relay_api_port: 8912,
            client_ws_port: 8920,
            relay_auth_secret: None,
            fips_mode: false,
            sfu_signing_public_key: None,
            public_ip: None,
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
            client_ws_port: env("SFU_CLIENT_WS_PORT", &defaults.client_ws_port.to_string())
                .parse()
                .expect("SFU_CLIENT_WS_PORT must be a number"),
            relay_auth_secret: std::env::var("SIGNALING_SFU_SECRET")
                .ok()
                .filter(|s| !s.is_empty())
                .map(|s| s.into_bytes()),
            fips_mode: std::env::var("SFU_FIPS").as_deref() == Ok("1"),
            sfu_signing_public_key: std::env::var("SFU_SIGNING_PUBLIC_KEY").ok(),
            public_ip: parse_public_ip_env(),
        }
    }
}

fn env(key: &str, default: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| default.to_string())
}

/// Parse `SFU_PUBLIC_IP` into an `IpAddr`. Garbage input produces a
/// `warn` log and `None` — startup must continue (degraded to the bind
/// address fallback) rather than crash, because the env var is a
/// production-quality knob and dev/test still works without it.
fn parse_public_ip_env() -> Option<IpAddr> {
    let raw = std::env::var("SFU_PUBLIC_IP").ok()?;
    if raw.is_empty() {
        return None;
    }
    match raw.parse::<IpAddr>() {
        Ok(ip) => Some(ip),
        Err(e) => {
            tracing::warn!(
                value = %raw, error = %e,
                "SFU_PUBLIC_IP failed to parse as an IP address — falling back to bind address \
                 for host candidates (off-box ICE will likely fail)"
            );
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    /// Serializes env-mutating tests in this module — `cargo test` runs
    /// tests in parallel within a single process, but `std::env` is
    /// process-global. Without serialization a test that sets
    /// `SFU_PUBLIC_IP=203.0.113.42` can race a sibling that sets
    /// `SFU_PUBLIC_IP=""` and observe `None`, producing the flaky
    /// CI failure tracked as task #63.
    ///
    /// Holds the lock for the env set/read/remove cycle. Recovers from
    /// a poisoned mutex (a sibling test panicked while holding it) —
    /// we want "sequential access to env", not "trust prior state".
    static ENV_LOCK: Mutex<()> = Mutex::new(());

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
    fn client_ws_port_default_and_distinct() {
        let cfg = SfuConfig::default();
        assert_eq!(cfg.client_ws_port, 8920);
        // Each port must be distinct so we can bind all four side-by-side.
        assert_ne!(cfg.client_ws_port, cfg.relay_api_port);
        assert_ne!(cfg.client_ws_port, cfg.metrics_port);
        assert_ne!(cfg.client_ws_port, cfg.udp_port);
    }

    #[test]
    fn relay_auth_secret_default_is_none() {
        let cfg = SfuConfig::default();
        assert!(
            cfg.relay_auth_secret.is_none(),
            "relay_auth_secret should default to None (unauthenticated dev mode)"
        );
    }

    #[test]
    fn fips_mode_defaults_false() {
        let _env = ENV_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        std::env::remove_var("SFU_FIPS");
        let cfg = SfuConfig::default();
        assert!(!cfg.fips_mode, "fips_mode must default to false");
    }

    #[test]
    fn fips_mode_env_one_enables() {
        let _env = ENV_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        std::env::set_var("SFU_FIPS", "1");
        let cfg = SfuConfig::from_env();
        assert!(cfg.fips_mode);
        std::env::remove_var("SFU_FIPS");
    }

    #[test]
    fn fips_mode_env_empty_is_false() {
        let _env = ENV_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        std::env::set_var("SFU_FIPS", "");
        let cfg = SfuConfig::from_env();
        assert!(!cfg.fips_mode);
        std::env::remove_var("SFU_FIPS");
    }

    #[test]
    fn public_ip_default_is_none() {
        let cfg = SfuConfig::default();
        assert!(
            cfg.public_ip.is_none(),
            "public_ip must default to None (preserves dev/test bind-address behavior)"
        );
    }

    #[test]
    fn public_ip_env_parses_ipv4() {
        let _env = ENV_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        // RFC 5737 TEST-NET-3 — reserved for documentation / examples.
        std::env::set_var("SFU_PUBLIC_IP", "203.0.113.42");
        let cfg = SfuConfig::from_env();
        assert_eq!(
            cfg.public_ip,
            Some("203.0.113.42".parse().unwrap()),
            "valid IPv4 must round-trip through SFU_PUBLIC_IP"
        );
        std::env::remove_var("SFU_PUBLIC_IP");
    }

    #[test]
    fn public_ip_env_empty_is_none() {
        let _env = ENV_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        std::env::set_var("SFU_PUBLIC_IP", "");
        let cfg = SfuConfig::from_env();
        assert!(
            cfg.public_ip.is_none(),
            "empty SFU_PUBLIC_IP must be treated as unset (compose passes empty string when var unset)"
        );
        std::env::remove_var("SFU_PUBLIC_IP");
    }

    #[test]
    fn public_ip_env_garbage_warns_and_falls_back() {
        let _env = ENV_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        // Non-fatal: log a warning and fall back to the bind address.
        // Crashing on a malformed env var would block startup for a
        // typo in the operator's compose env block — the SFU degrades
        // to the (already known) loopback-only candidate instead.
        std::env::set_var("SFU_PUBLIC_IP", "not-an-ip-address");
        let cfg = SfuConfig::from_env();
        assert!(
            cfg.public_ip.is_none(),
            "garbage SFU_PUBLIC_IP must yield None, not panic"
        );
        std::env::remove_var("SFU_PUBLIC_IP");
    }
}
