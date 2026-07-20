//! SFU runtime configuration. Env-driven to match the conventions in
//! `crates/server/src/config.rs` -- `from_env()` with sensible defaults
//! and panics only on obviously malformed numeric input at startup.

use std::net::IpAddr;
use std::time::{Duration, Instant};

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
    /// Note: 8911 was the original choice but is squatted on hub
    /// (San Jose) by an unrelated go-imagine process. 8920 was picked
    /// to avoid a fleet-wide eviction; the value is partner-edge-wide
    /// (edge-c / relay-x / hub all bind 8920) so the same Caddy
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
    /// Private/local IP advertised as a SECOND WebRTC host candidate,
    /// alongside `public_ip`. Env: `SFU_LOCAL_IP`.
    ///
    /// OCI-hairpin fix (2026-07-11): on providers whose instances cannot
    /// route to their own public/floating IP (Oracle Cloud has no NAT
    /// hairpin), a co-located coturn relaying client media to the SFU's
    /// public host candidate sends the packet out the gateway and it never
    /// returns → relay-forced group calls fail with ICE `no_pair`. Emitting
    /// the node's PRIVATE IP as an additional host candidate lets the
    /// co-located coturn relay to the SFU entirely on private addressing
    /// (the client installs a TURN CreatePermission for this IP, and coturn
    /// must allow it via `allowed-peer-ip`). Set to the same private IP that
    /// coturn binds its relay sockets to (the PRIV half of coturn's
    /// `external-ip=PUB/PRIV`). Unset in dev/test and on nodes where the
    /// public candidate is directly reachable from the co-located coturn.
    pub local_ip: Option<IpAddr>,
    /// Interval in seconds for str0m built-in peer/media stats events
    /// (`Event::PeerStats`, `Event::MediaEgressStats`, `Event::MediaIngressStats`).
    /// Set to 0 to disable. Env: `STR0M_STATS_INTERVAL_SECS`. Default: 2.
    pub stats_interval_secs: u64,
    /// How long (in seconds) a room with exactly one participant is allowed to
    /// persist before the SFU disconnects the lone peer. Set to 0 to disable
    /// the feature. Env: `SFU_SOLO_KICK_AFTER_SECS`. Default: 120.
    pub solo_kick_after_secs: u64,
    /// Optional per-socket bind override for the Prometheus `/metrics` HTTP
    /// server. When `None`, defaults to loopback (`127.0.0.1`) so the metrics
    /// socket is never exposed on the public NIC by default (#404). Set to the
    /// AWG mesh IP (e.g. `10.9.0.6`) on partner-edge deployments to expose it
    /// on a reachable-but-private interface for remote scrape. Env:
    /// `SFU_METRICS_BIND`.
    pub metrics_bind: Option<String>,
    /// Optional per-socket bind override for the relay-API HTTP server
    /// (`POST /relay/connect`). When `None`, falls back to `bind_address`.
    /// Mesh-only on partner-edge (set to AWG IP). Env: `SFU_RELAY_API_BIND`.
    pub relay_api_bind: Option<String>,
    /// Optional per-socket bind override for the client-facing WebSocket
    /// endpoint (`/sfu/ws/{room_id}`). When `None`, falls back to
    /// `bind_address`. Caddy reverse-proxies via `host.docker.internal:8920`
    /// (docker bridge gw), so safe to bind to the bridge IP when known;
    /// otherwise leave unset and rely on host firewall. Env: `SFU_CLIENT_WS_BIND`.
    pub client_ws_bind: Option<String>,
    /// T4.3 kill-switch for the EdDSA→HS256 relay-JWT fallback. When `true`
    /// (default), a token that fails EdDSA verification with `InvalidSignature`
    /// / `AlgorithmMismatch` is retried under the deprecated HS256 shared
    /// secret — the rollout-interop path. When `false`, that retry is refused
    /// and a non-EdDSA token is rejected outright, turning a fleet-wide
    /// `relay_jwt_verify_total{algorithm=hs256}` == 0 observation into an
    /// enforced cutover. Only gates the *fallback*: when no EdDSA key is
    /// configured, HS256 is the primary verifier and this flag does not apply.
    /// Env: `SFU_RELAY_HS256_FALLBACK` (default-on; `0`/`false` disables).
    pub relay_hs256_fallback_enabled: bool,
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
            local_ip: None,
            stats_interval_secs: 2,
            solo_kick_after_secs: 120,
            metrics_bind: None,
            relay_api_bind: None,
            client_ws_bind: None,
            relay_hs256_fallback_enabled: true,
        }
    }
}

impl SfuConfig {
    /// Additional host-candidate addresses to advertise alongside the primary
    /// (public) candidate — at most the private `local_ip` at the primary's
    /// port (the SFU listens on a single `0.0.0.0:port` socket reachable via
    /// both IPs). Deduped: `local_ip` unset OR equal to the primary's IP yields
    /// an empty vec (advertise the primary only). Pure fn — unit-tested; this
    /// dedup is the backstop that makes the unguarded compose
    /// `SFU_LOCAL_IP: "{{PRIVATE_IP}}"` render safe when PRIVATE_IP == PUBLIC_IP.
    pub fn additional_host_candidates(
        &self,
        primary: std::net::SocketAddr,
    ) -> Vec<std::net::SocketAddr> {
        self.local_ip
            .filter(|ip| *ip != primary.ip())
            .map(|ip| std::net::SocketAddr::new(ip, primary.port()))
            .into_iter()
            .collect()
    }

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
            local_ip: parse_local_ip_env(),
            stats_interval_secs: std::env::var("STR0M_STATS_INTERVAL_SECS")
                .ok()
                .and_then(|s| s.parse().ok())
                .unwrap_or(2),
            solo_kick_after_secs: std::env::var("SFU_SOLO_KICK_AFTER_SECS")
                .ok()
                .and_then(|s| s.parse().ok())
                .unwrap_or(120),
            metrics_bind: std::env::var("SFU_METRICS_BIND")
                .ok()
                .filter(|s| !s.is_empty()),
            relay_api_bind: std::env::var("SFU_RELAY_API_BIND")
                .ok()
                .filter(|s| !s.is_empty()),
            client_ws_bind: std::env::var("SFU_CLIENT_WS_BIND")
                .ok()
                .filter(|s| !s.is_empty()),
            relay_hs256_fallback_enabled: parse_hs256_fallback_env(),
        }
    }
}

impl SfuConfig {
    /// Resolved bind address for the Prometheus /metrics socket.
    ///
    /// Returns `metrics_bind` if set, otherwise defaults to loopback
    /// (`127.0.0.1`): `/metrics` is an internal observability surface and must
    /// not be reachable on the public NIC by default (#404). Set
    /// `SFU_METRICS_BIND` (e.g. the AWG mesh IP `10.9.0.6`) to expose it on a
    /// reachable-but-private interface for remote scrape.
    pub fn metrics_bind_addr(&self) -> &str {
        self.metrics_bind.as_deref().unwrap_or("127.0.0.1")
    }

    /// Resolved bind address for the relay-API socket. See `metrics_bind_addr`.
    pub fn relay_api_bind_addr(&self) -> &str {
        self.relay_api_bind.as_deref().unwrap_or(&self.bind_address)
    }

    /// Resolved bind address for the client-WebSocket socket. See `metrics_bind_addr`.
    pub fn client_ws_bind_addr(&self) -> &str {
        self.client_ws_bind.as_deref().unwrap_or(&self.bind_address)
    }

    /// Build a fresh subscriber-facing `str0m::Rtc` with the stats interval
    /// from config and native BWE armed (see [`subscriber_rtc_config`]).
    ///
    /// Use this instead of bare `Rtc::new(Instant::now())` in all production
    /// paths so `Event::PeerStats` / `Event::MediaEgressStats` /
    /// `Event::MediaIngressStats` flow through the dispatch loop.
    /// A `stats_interval_secs` of 0 disables stats (same as `Rtc::new`).
    pub fn build_rtc(&self) -> str0m::Rtc {
        let interval = if self.stats_interval_secs == 0 {
            None
        } else {
            Some(Duration::from_secs(self.stats_interval_secs))
        };
        subscriber_rtc_config(interval).build(Instant::now())
    }
}

/// Initial GoogCC estimate (bits/s) applied when native str0m BWE is armed on a
/// subscriber-facing (browser) leg. Conservative per the kit's guidance —
/// GoogCC ramps up from here on TWCC feedback rather than starting high and
/// backing off. See [`subscriber_rtc_config`] (T1: native BWE arming).
pub const SUBSCRIBER_BWE_INITIAL_BPS: u64 = 600_000;

/// Cap on a subscriber leg's *desired* send bitrate. str0m gates upward probing
/// on `desired_bitrate`, which defaults to `Bitrate::ZERO` (no probing → the
/// estimate is pinned to the current send rate and never discovers headroom).
/// A fixed cap arms probing so `EgressBitrateEstimate` reflects real available
/// bandwidth, while bounding the padding cost (LiveKit StreamAllocator pattern;
/// uncapped probing = padding-bandwidth waste, an anti-censorship cost). Sized
/// to ~one high simulcast video layer plus headroom.
///
/// ARC 2 replaces this static cap with a per-tick target
/// (`current allocated bps + one-layer headroom`) recomputed in the registry
/// allocation loop once the native estimate is actually consumed by the
/// allocator. Until then the frozen-300k base dominates `min()`, so this value
/// changes no forwarding behavior — it only lets the estimate become truthful.
pub const SUBSCRIBER_BWE_DESIRED_CAP_BPS: u64 = 2_500_000;

/// Build the [`str0m::RtcConfig`] for a subscriber-facing (browser) leg with
/// native str0m BWE armed (TWCC + GoogCC). Returned as the *config* (not a
/// built `Rtc`) so callers can add ICE candidates / `accept_offer` on the
/// result and tests can assert `bwe_initial_bitrate()` — str0m exposes no
/// BWE-enabled accessor on a built `Rtc`.
///
/// Arming is the whole point of T1: partner-edge previously built the answerer
/// `Rtc` via a bare `Rtc::builder()` and never called `.enable_bwe()`, so str0m
/// emitted no `EgressBitrateEstimate` and `native_estimate` stayed `None`. RELAY
/// (SFU↔SFU) legs deliberately do NOT use this helper — see `relay/client.rs`.
pub fn subscriber_rtc_config(stats_interval: Option<Duration>) -> str0m::RtcConfig {
    // G3 P0: register the AV1 Dependency Descriptor (DD) RTP header-extension
    // serializer on every browser-facing leg. str0m rebinds this to whatever
    // extmap id the browser negotiates, matched BY URI (ext.rs `remap` /
    // `session.rs remote_extmap`), so the local id is arbitrary — it just
    // must not collide with `ExtensionMap::standard()` (1,2,3,4,10,11,13).
    // We pick 9. P0 is observability-only: the serializer marks DD presence
    // on ingress `MediaData.ext_vals.user_values`; no bit-parse, no drop.
    // See `svc::dd_ext` and `client::fanout::handle_media_data_out`.
    let dd_ext =
        str0m::rtp::Extension::with_serializer(crate::svc::DD_URI, crate::svc::DdSerializer);
    str0m::Rtc::builder()
        .set_stats_interval(stats_interval)
        .enable_bwe(Some(str0m::bwe::Bitrate::bps(SUBSCRIBER_BWE_INITIAL_BPS)))
        .set_extension(DD_LOCAL_EXTMAP_ID, dd_ext)
}

/// Local extmap id under which the Dependency Descriptor serializer is
/// registered on the subscriber-facing [`str0m::RtcConfig`].
///
/// The exact value is irrelevant to behaviour: str0m's URI-reconcile rebinds
/// the serializer to whatever extmap id the browser negotiates (matched by
/// URI, see `str0m::rtp::ext.rs` `remap`). It only needs to avoid the ids
/// already used by [`str0m::rtp::ExtensionMap::standard`] (1, 2, 3, 4, 10,
/// 11, 13) and stay within `1..=MAX_ID` (16). 9 is free.
pub const DD_LOCAL_EXTMAP_ID: u8 = 9;

fn env(key: &str, default: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| default.to_string())
}

/// Parse `SFU_RELAY_HS256_FALLBACK` into the fallback kill-switch. Default-on:
/// unset (or empty) means the EdDSA→HS256 fallback stays enabled so existing
/// deployments are not silently hardened mid-rollout. The explicit off-values
/// `0` and `false` disable it; the explicit on-values `1` and `true` enable it
/// (all case-insensitive).
///
/// An *unrecognized* value (e.g. the typo `flase`) also defaults to on so it
/// fails safe for interop rather than cutting the fallback out from under
/// HS256-only senders — but, unlike a bare typo silently winning, it emits a
/// `warn` log so the drift is visible in Loki. Mirrors `parse_public_ip_env`'s
/// warn-on-garbage convention: this kill-switch is the sole advertised lever for
/// hardening after EdDSA rollout, so an operator who runs
/// `SFU_RELAY_HS256_FALLBACK=flase` believing they enforced the cutover must get
/// a signal that the fallback is still live.
fn parse_hs256_fallback_env() -> bool {
    let raw = match std::env::var("SFU_RELAY_HS256_FALLBACK") {
        Ok(v) => v,
        Err(_) => return true,
    };
    let v = raw.trim();
    // Empty behaves like unset: leave the default (enabled) in place with no
    // warning, so `SFU_RELAY_HS256_FALLBACK=` in an env file is a no-op.
    if v.is_empty() {
        return true;
    }
    if v.eq_ignore_ascii_case("false") || v == "0" {
        return false;
    }
    if v.eq_ignore_ascii_case("true") || v == "1" {
        return true;
    }
    tracing::warn!(
        value = %v,
        "SFU_RELAY_HS256_FALLBACK: unrecognized value, defaulting to enabled \
         (EdDSA→HS256 fallback stays on) — expected one of true/false/1/0"
    );
    true
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

/// True when `ip` is inside the RFC1918 / IPv6 unique-local space that the
/// co-located coturn's `denied-peer-ip` block otherwise forbids. The
/// `allowed-peer-ip` override this env drives is only ever meant to re-permit
/// ONE private address; a public IP here would turn coturn into an open relay
/// to that host (public IPs hit no `denied-peer-ip` range), so we refuse it.
fn is_private_relay_target(ip: &IpAddr) -> bool {
    match ip {
        // 10/8, 172.16/12, 192.168/16.
        IpAddr::V4(v4) => v4.is_private(),
        // fc00::/7 unique-local.
        IpAddr::V6(v6) => (v6.segments()[0] & 0xfe00) == 0xfc00,
    }
}

/// Parse `SFU_LOCAL_IP` into an `IpAddr` for the additional private host
/// candidate (OCI-hairpin fix). Same lenient contract as
/// [`parse_public_ip_env`]: empty/unset → `None`, garbage → `warn` + `None`
/// so startup continues (the node just loses the private-candidate path and
/// behaves as before). Additionally REFUSES a non-private address (SEC-CR-902):
/// the value feeds coturn's `allowed-peer-ip`, and a public IP there would make
/// coturn an open relay to that host. See [`SfuConfig::local_ip`].
fn parse_local_ip_env() -> Option<IpAddr> {
    let raw = std::env::var("SFU_LOCAL_IP").ok()?;
    if raw.is_empty() {
        return None;
    }
    match raw.parse::<IpAddr>() {
        Ok(ip) if is_private_relay_target(&ip) => Some(ip),
        Ok(ip) => {
            tracing::warn!(
                value = %ip,
                "SFU_LOCAL_IP is not an RFC1918 / unique-local address — refusing it as a host \
                 candidate (a public value would widen the co-located coturn allowed-peer-ip into \
                 an open relay). The SFU will advertise only its public candidate."
            );
            None
        }
        Err(e) => {
            tracing::warn!(
                value = %raw, error = %e,
                "SFU_LOCAL_IP failed to parse as an IP address — the SFU will advertise only its \
                 public host candidate (co-located relay on no-hairpin providers may fail)"
            );
            None
        }
    }
}

/// Default cap for [`max_participants`] when `SFU_MAX_PARTICIPANTS` is
/// unset or unparseable.
///
/// T9 (2026-07-01 bug-hunt, resource_exhaustion/high): sized to the
/// *current* single-task `udp_loop::serve` forwarding budget, not to a
/// target scale. That loop demuxes every inbound UDP datagram against the
/// registry with an O(N) linear scan on one CPU core (the O(1) redesign
/// is tracked separately as Escalation #2 — out of scope here). At the
/// existing per-room cap of 6 peers (`client_ws/session.rs`), 50
/// participants is ~8 concurrent rooms on one node — enough headroom for a
/// small self-hosted partner-edge node before the demux's quadratic term
/// dominates loop latency. Raise only after Escalation #2 lands, or after
/// load-testing the target node; this is a safety valve, not an SLA.
pub const DEFAULT_MAX_PARTICIPANTS: u32 = 50;

/// Global cap on concurrent browser (`client_ws`) sessions this SFU node
/// will admit, independent of any per-room limit. Env: `SFU_MAX_PARTICIPANTS`.
/// Default: [`DEFAULT_MAX_PARTICIPANTS`].
///
/// Read fresh on every call (no caching) rather than through `SfuConfig` —
/// the admission check lives in `client_ws::handler`, which is constructed
/// once at startup from individual params, not a held `SfuConfig`; a plain
/// env re-read avoids threading a new field through `spawn_client_ws_api`
/// and its `main.rs` call site for a value that only needs to change
/// between test runs, not per-request. Mirrors this module's `env()`
/// helper's error handling: malformed input degrades to the default with a
/// warn, it never panics — this is a per-request path, not startup.
pub fn max_participants() -> u32 {
    match std::env::var("SFU_MAX_PARTICIPANTS") {
        Ok(raw) if !raw.is_empty() => raw.parse().unwrap_or_else(|e| {
            tracing::warn!(
                value = %raw, error = %e,
                "SFU_MAX_PARTICIPANTS failed to parse as u32 — falling back to default \
                 ({DEFAULT_MAX_PARTICIPANTS})"
            );
            DEFAULT_MAX_PARTICIPANTS
        }),
        _ => DEFAULT_MAX_PARTICIPANTS,
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

    /// T1 regression guard (REAL-CODE): the subscriber-facing builder that
    /// `build_rtc` and `client_ws::session` both use MUST arm native BWE.
    /// Removing `.enable_bwe(..)` from `subscriber_rtc_config` reverts
    /// `bwe_initial_bitrate()` to `None`, which is exactly the pre-T1 bug —
    /// str0m emits no `EgressBitrateEstimate` and `native_estimate` stays
    /// `None`. This assertion goes RED on that revert.
    #[test]
    fn subscriber_rtc_config_arms_native_bwe() {
        let cfg = subscriber_rtc_config(Some(Duration::from_secs(2)));
        assert_eq!(
            cfg.bwe_initial_bitrate(),
            Some(str0m::bwe::Bitrate::bps(SUBSCRIBER_BWE_INITIAL_BPS)),
            "subscriber Rtc must have native BWE armed with the configured initial estimate"
        );
    }

    /// The desired-bitrate cap that arms upward probing must stay above the
    /// frozen-300k base (else probing never lifts the estimate past it) and
    /// remain finite/capped (uncapped probing = padding waste — an
    /// anti-censorship cost).
    #[test]
    fn subscriber_bwe_desired_cap_is_bounded_and_above_base() {
        // Inline `const {}` blocks evaluate these at compile time (strictly
        // stronger than a runtime assert, and clippy-clean: a plain
        // `assert!` on consts trips `clippy::assertions_on_constants`).
        const { assert!(SUBSCRIBER_BWE_DESIRED_CAP_BPS > 300_000) };
        const { assert!(SUBSCRIBER_BWE_DESIRED_CAP_BPS >= SUBSCRIBER_BWE_INITIAL_BPS) };
        const { assert!(SUBSCRIBER_BWE_DESIRED_CAP_BPS <= 10_000_000) };
    }

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
    fn metrics_bind_addr_defaults_to_loopback() {
        // #404: /metrics is an internal observability surface — with no
        // SFU_METRICS_BIND override it must resolve to loopback, NOT the
        // 0.0.0.0 `bind_address` that carries the media/signaling sockets.
        let cfg = SfuConfig::default();
        assert_eq!(cfg.metrics_bind, None);
        assert_eq!(cfg.metrics_bind_addr(), "127.0.0.1");
        assert_ne!(
            cfg.metrics_bind_addr(),
            cfg.bind_address,
            "regression #404: /metrics fell back to the public bind_address"
        );
    }

    #[test]
    fn metrics_bind_addr_honors_explicit_override() {
        // An operator scoping /metrics to the private AWG mesh IP still works.
        let cfg = SfuConfig {
            metrics_bind: Some("10.9.0.6".to_string()),
            ..SfuConfig::default()
        };
        assert_eq!(cfg.metrics_bind_addr(), "10.9.0.6");
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
    fn relay_hs256_fallback_defaults_on() {
        // Default-on: no env var set → the fallback stays enabled so an
        // existing rollout is not silently hardened.
        let _env = ENV_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        std::env::remove_var("SFU_RELAY_HS256_FALLBACK");
        assert!(SfuConfig::default().relay_hs256_fallback_enabled);
        assert!(SfuConfig::from_env().relay_hs256_fallback_enabled);
    }

    #[test]
    fn relay_hs256_fallback_env_zero_and_false_disable() {
        let _env = ENV_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        for off in ["0", "false", "FALSE", "False"] {
            std::env::set_var("SFU_RELAY_HS256_FALLBACK", off);
            assert!(
                !SfuConfig::from_env().relay_hs256_fallback_enabled,
                "SFU_RELAY_HS256_FALLBACK={off:?} must disable the fallback"
            );
        }
        std::env::remove_var("SFU_RELAY_HS256_FALLBACK");
    }

    #[test]
    fn relay_hs256_fallback_env_on_values_keep_enabled() {
        let _env = ENV_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        // Empty (compose passes "" for an unset var) and any non-off value
        // keep the fallback enabled — a typo fails safe toward interop.
        for on in ["", "1", "true", "yes", "on", "garbage"] {
            std::env::set_var("SFU_RELAY_HS256_FALLBACK", on);
            assert!(
                SfuConfig::from_env().relay_hs256_fallback_enabled,
                "SFU_RELAY_HS256_FALLBACK={on:?} must keep the fallback enabled"
            );
        }
        std::env::remove_var("SFU_RELAY_HS256_FALLBACK");
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
    fn local_ip_default_is_none() {
        let cfg = SfuConfig::default();
        assert!(
            cfg.local_ip.is_none(),
            "local_ip must default to None (nodes without SFU_LOCAL_IP advertise only the primary candidate)"
        );
    }

    #[test]
    fn local_ip_env_parses_ipv4() {
        let _env = ENV_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        // Must be RFC1918 — parse_local_ip_env refuses public IPs (SEC-CR-902).
        std::env::set_var("SFU_LOCAL_IP", "192.168.50.7");
        let cfg = SfuConfig::from_env();
        assert_eq!(
            cfg.local_ip,
            Some("192.168.50.7".parse().unwrap()),
            "valid RFC1918 IPv4 must round-trip through SFU_LOCAL_IP (OCI-hairpin private candidate)"
        );
        std::env::remove_var("SFU_LOCAL_IP");
    }

    #[test]
    fn local_ip_env_empty_is_none() {
        let _env = ENV_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        std::env::set_var("SFU_LOCAL_IP", "");
        let cfg = SfuConfig::from_env();
        assert!(
            cfg.local_ip.is_none(),
            "empty SFU_LOCAL_IP must be treated as unset (compose passes empty string when var unset)"
        );
        std::env::remove_var("SFU_LOCAL_IP");
    }

    #[test]
    fn local_ip_env_garbage_falls_back_to_none() {
        let _env = ENV_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        std::env::set_var("SFU_LOCAL_IP", "not-an-ip");
        let cfg = SfuConfig::from_env();
        assert!(
            cfg.local_ip.is_none(),
            "garbage SFU_LOCAL_IP must yield None (warn + degrade), not panic"
        );
        std::env::remove_var("SFU_LOCAL_IP");
    }

    #[test]
    fn local_ip_env_public_ip_refused() {
        // SEC-CR-902: a public IP in SFU_LOCAL_IP would widen coturn's
        // allowed-peer-ip into an open relay — it must be refused (warn + None).
        let _env = ENV_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        for public in ["8.8.8.8", "1.1.1.1", "203.0.113.42"] {
            std::env::set_var("SFU_LOCAL_IP", public);
            assert!(
                SfuConfig::from_env().local_ip.is_none(),
                "public SFU_LOCAL_IP={public} must be refused (not advertised, not relayed to)"
            );
        }
        // Sanity: a private value is still accepted.
        std::env::set_var("SFU_LOCAL_IP", "10.0.1.44");
        assert_eq!(
            SfuConfig::from_env().local_ip,
            Some("10.0.1.44".parse().unwrap()),
            "RFC1918 SFU_LOCAL_IP must still be accepted"
        );
        std::env::remove_var("SFU_LOCAL_IP");
    }

    #[test]
    fn additional_host_candidates_dedup_and_derivation() {
        let primary: std::net::SocketAddr = "203.0.113.42:7878".parse().unwrap();

        // local_ip unset → no additional candidate.
        let mut cfg = SfuConfig::default();
        assert!(
            cfg.additional_host_candidates(primary).is_empty(),
            "unset local_ip must yield no additional candidate"
        );

        // local_ip equal to the primary's IP → deduped away.
        cfg.local_ip = Some(primary.ip());
        assert!(
            cfg.additional_host_candidates(primary).is_empty(),
            "local_ip == primary IP must be deduped (advertise primary only)"
        );

        // Distinct private local_ip → exactly one candidate, at the primary port.
        cfg.local_ip = Some("10.0.1.44".parse().unwrap());
        assert_eq!(
            cfg.additional_host_candidates(primary),
            vec!["10.0.1.44:7878".parse().unwrap()],
            "distinct local_ip must be advertised at the primary's UDP port"
        );
    }

    #[test]
    fn split_bind_defaults_to_bind_address() {
        // Backward compat — if the operator hasn't set the override env vars,
        // the FUNCTIONAL relay/WS sockets still default to `bind_address` (what
        // existing partner-edge deployments rely on). The observability
        // `/metrics` socket instead defaults to loopback (#404) — asserted in
        // `metrics_bind_addr_defaults_to_loopback`, not here, so there is a
        // single authoritative expectation for that default.
        let cfg = SfuConfig::default();
        assert_eq!(cfg.relay_api_bind_addr(), cfg.bind_address);
        assert_eq!(cfg.client_ws_bind_addr(), cfg.bind_address);
        assert!(cfg.metrics_bind.is_none());
        assert!(cfg.relay_api_bind.is_none());
        assert!(cfg.client_ws_bind.is_none());
    }

    #[test]
    fn split_bind_metrics_env_overrides_bind_address() {
        let _env = ENV_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        std::env::set_var("SFU_BIND_ADDRESS", "0.0.0.0");
        std::env::set_var("SFU_METRICS_BIND", "10.9.0.6");
        let cfg = SfuConfig::from_env();
        assert_eq!(cfg.metrics_bind_addr(), "10.9.0.6");
        assert_eq!(cfg.relay_api_bind_addr(), "0.0.0.0");
        assert_eq!(cfg.client_ws_bind_addr(), "0.0.0.0");
        std::env::remove_var("SFU_METRICS_BIND");
        std::env::remove_var("SFU_BIND_ADDRESS");
    }

    #[test]
    fn split_bind_empty_env_treated_as_unset() {
        let _env = ENV_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        // Compose passes literal "" when an env block names a variable that
        // is unset — same edge case as SFU_PUBLIC_IP. Must not lock the
        // socket to an empty string (which would fail to bind).
        std::env::set_var("SFU_BIND_ADDRESS", "0.0.0.0");
        std::env::set_var("SFU_METRICS_BIND", "");
        std::env::set_var("SFU_RELAY_API_BIND", "");
        std::env::set_var("SFU_CLIENT_WS_BIND", "");
        let cfg = SfuConfig::from_env();
        assert!(cfg.metrics_bind.is_none());
        assert!(cfg.relay_api_bind.is_none());
        assert!(cfg.client_ws_bind.is_none());
        // Empty env is treated as unset → `/metrics` still resolves to its
        // secure loopback default (#404), not the public `bind_address`.
        assert_eq!(cfg.metrics_bind_addr(), "127.0.0.1");
        std::env::remove_var("SFU_METRICS_BIND");
        std::env::remove_var("SFU_RELAY_API_BIND");
        std::env::remove_var("SFU_CLIENT_WS_BIND");
        std::env::remove_var("SFU_BIND_ADDRESS");
    }

    #[test]
    fn split_bind_all_three_independent() {
        // Verify each override is scoped to its own socket — flipping one
        // doesn't leak across to the others.
        let _env = ENV_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        std::env::set_var("SFU_BIND_ADDRESS", "0.0.0.0");
        std::env::set_var("SFU_METRICS_BIND", "10.9.0.7");
        std::env::set_var("SFU_RELAY_API_BIND", "10.9.0.8");
        std::env::set_var("SFU_CLIENT_WS_BIND", "127.0.0.1");
        let cfg = SfuConfig::from_env();
        assert_eq!(cfg.metrics_bind_addr(), "10.9.0.7");
        assert_eq!(cfg.relay_api_bind_addr(), "10.9.0.8");
        assert_eq!(cfg.client_ws_bind_addr(), "127.0.0.1");
        std::env::remove_var("SFU_METRICS_BIND");
        std::env::remove_var("SFU_RELAY_API_BIND");
        std::env::remove_var("SFU_CLIENT_WS_BIND");
        std::env::remove_var("SFU_BIND_ADDRESS");
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

    #[test]
    fn max_participants_default_when_unset() {
        let _env = ENV_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        std::env::remove_var("SFU_MAX_PARTICIPANTS");
        assert_eq!(max_participants(), DEFAULT_MAX_PARTICIPANTS);
    }

    #[test]
    fn max_participants_env_overrides_default() {
        let _env = ENV_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        std::env::set_var("SFU_MAX_PARTICIPANTS", "7");
        assert_eq!(max_participants(), 7);
        std::env::remove_var("SFU_MAX_PARTICIPANTS");
    }

    #[test]
    fn max_participants_garbage_falls_back_to_default() {
        let _env = ENV_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        // Non-fatal: this is read on the per-request admission-check path,
        // not at startup — a malformed override must degrade, not panic
        // and never take the whole handler down mid-traffic.
        std::env::set_var("SFU_MAX_PARTICIPANTS", "not-a-number");
        assert_eq!(max_participants(), DEFAULT_MAX_PARTICIPANTS);
        std::env::remove_var("SFU_MAX_PARTICIPANTS");
    }

    #[test]
    fn max_participants_empty_env_treated_as_unset() {
        let _env = ENV_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        // Compose passes literal "" when an env block names a variable
        // that is unset — same edge case as SFU_PUBLIC_IP / split-bind.
        std::env::set_var("SFU_MAX_PARTICIPANTS", "");
        assert_eq!(max_participants(), DEFAULT_MAX_PARTICIPANTS);
        std::env::remove_var("SFU_MAX_PARTICIPANTS");
    }
}
