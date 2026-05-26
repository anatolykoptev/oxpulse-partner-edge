//! Single source of truth for the relay upstream allow-list (SSRF guard).
//!
//! Two transports are trusted:
//!   * `wss://` to a public oxpulse host (`.oxpulse.chat` / localhost) — TLS on the public internet.
//!   * `ws://`  to the AWG mesh subnet `10.9.0.0/24` — plaintext is safe because the
//!     AmneziaWG tunnel already provides confidentiality + cryptographic peer auth.
//!     This is the besieged-fortress path: no public DNS, ТСПУ-immune.
//!
//! The `upstream_url` is carried in a central-signed relay JWT; this allow-list is
//! defense-in-depth against a forged/leaked token or a buggy central.

use std::net::Ipv4Addr;

/// AWG mesh subnet. Hosts here are cryptographically-authenticated tunnel peers.
const MESH_V4: (Ipv4Addr, u8) = (Ipv4Addr::new(10, 9, 0, 0), 24);
const PUBLIC_WSS_ALLOWED: &[&str] = &[".oxpulse.chat", "localhost", "127.0.0.1", "::1"];

/// Extract the hostname strictly (before first `/` or `:`), defeating
/// path-spoofs like `wss://attacker.com/.oxpulse.chat/x`.
fn host_of(rest: &str) -> &str {
    rest.split(['/', ':']).next().unwrap_or("")
}

fn in_mesh(host: &str) -> bool {
    match host.parse::<Ipv4Addr>() {
        Ok(ip) => {
            let bits = MESH_V4.1;
            let mask = if bits == 0 { 0 } else { !0u32 << (32 - bits) };
            (u32::from(ip) & mask) == (u32::from(MESH_V4.0) & mask)
        }
        Err(_) => false,
    }
}

/// True if `url` is an allowed relay upstream.
pub fn is_allowed_upstream(url: &str) -> bool {
    if let Some(rest) = url.strip_prefix("wss://") {
        let host = host_of(rest);
        if host.is_empty() {
            return false;
        }
        return PUBLIC_WSS_ALLOWED.iter().any(|&p| {
            if let Some(sfx) = p.strip_prefix('.') {
                host == sfx || host.ends_with(p)
            } else {
                host == p
            }
        });
    }
    if let Some(rest) = url.strip_prefix("ws://") {
        // Plaintext ws:// is trusted ONLY inside the AWG mesh.
        return in_mesh(host_of(rest));
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mesh_ws_allowed() {
        assert!(is_allowed_upstream("ws://10.9.0.2:8907/ws/call/room-1"));
        assert!(is_allowed_upstream("ws://10.9.0.7/ws/call/r"));
    }

    #[test]
    fn public_wss_still_allowed() {
        assert!(is_allowed_upstream("wss://oxpulse.chat/ws/call/r"));
        assert!(is_allowed_upstream(
            "wss://edge.oxpulse.chat:9443/ws/call/r"
        ));
        assert!(is_allowed_upstream("wss://localhost/ws/call/r"));
    }

    #[test]
    fn ws_to_public_rejected() {
        assert!(!is_allowed_upstream("ws://oxpulse.chat/ws/call/r"));
    }

    #[test]
    fn ws_to_non_mesh_ip_rejected() {
        assert!(!is_allowed_upstream("ws://8.8.8.8/ws/call/r"));
        assert!(!is_allowed_upstream("ws://10.10.0.2/ws/call/r"));
        assert!(!is_allowed_upstream("ws://192.9.243.148/ws/call/r"));
    }

    #[test]
    fn host_spoof_rejected() {
        assert!(!is_allowed_upstream("wss://attacker.com/.oxpulse.chat/x"));
        assert!(!is_allowed_upstream("ws://10.9.0.2.evil.com/x"));
        assert!(!is_allowed_upstream("https://oxpulse.chat/x"));
        assert!(!is_allowed_upstream(""));
    }
}
