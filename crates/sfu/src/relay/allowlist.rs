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
//!
//! Validation uses the same `http::Uri` parser that `tokio_tungstenite::connect_async`
//! ultimately resolves — eliminating the parser-differential class of SSRF bypass where
//! a hand-rolled host extractor trusts a different host than the one actually dialled.

use std::net::Ipv4Addr;
use tokio_tungstenite::tungstenite::http::Uri;

/// AWG mesh subnet. Hosts here are cryptographically-authenticated tunnel peers.
const MESH_V4: (Ipv4Addr, u8) = (Ipv4Addr::new(10, 9, 0, 0), 24);

/// Public WSS host patterns: exact match or `.oxpulse.chat` suffix.
/// Note: `::1` is omitted — `Uri::host()` returns `[::1]` with brackets for IPv6
/// literals, which would never match the bare string `::1` anyway.
const PUBLIC_WSS_ALLOWED: &[&str] = &[".oxpulse.chat", "localhost", "127.0.0.1"];

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
///
/// Validates using the same `http::Uri` parser that tungstenite's `connect_async`
/// uses, so the host we check is the host that will actually be dialled.
/// Userinfo (`user@host`) is stripped by `Uri::host()`, preventing SSRF bypasses
/// like `ws://10.9.0.2:0@evil.com/x` (old `host_of` split on `:` → `10.9.0.2`;
/// `Uri::host()` correctly returns `evil.com`).
pub fn is_allowed_upstream(url: &str) -> bool {
    let uri = match url.parse::<Uri>() {
        Ok(u) => u,
        Err(_) => return false,
    };

    // Scheme must be exactly "ws" or "wss" — no http/https/ftp/etc.
    let scheme = match uri.scheme_str() {
        Some(s) => s,
        None => return false,
    };

    // Host is what the client will actually dial (userinfo already stripped by Uri::host()).
    let host = match uri.host() {
        Some(h) if !h.is_empty() => h,
        _ => return false,
    };

    match scheme {
        "wss" => PUBLIC_WSS_ALLOWED.iter().any(|&p| {
            if let Some(sfx) = p.strip_prefix('.') {
                host == sfx || (host.len() > p.len() && host.ends_with(p))
            } else {
                host == p
            }
        }),
        "ws" => in_mesh(host),
        _ => false,
    }
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

    #[test]
    fn userinfo_bypass_rejected() {
        // CRITICAL regression: guard host must equal the host the client dials.
        assert!(!is_allowed_upstream("ws://10.9.0.2:0@evil.com/x"));
        assert!(!is_allowed_upstream("wss://edge.oxpulse.chat:0@evil.com/x"));
        assert!(!is_allowed_upstream("ws://10.9.0.2@evil.com/x"));
        assert!(!is_allowed_upstream("wss://oxpulse.chat@evil.com/x"));
    }

    #[test]
    fn parser_agreement_with_client() {
        // Whatever host the guard trusts must be the host tungstenite's Uri parser resolves.
        use tokio_tungstenite::tungstenite::http::Uri;
        for url in [
            "ws://10.9.0.2:8907/ws/call/r",
            "wss://oxpulse.chat/ws/call/r",
        ] {
            let parsed_host = url.parse::<Uri>().unwrap().host().unwrap().to_string();
            // allowed urls must parse to the expected host (no userinfo surprise)
            assert!(is_allowed_upstream(url));
            assert!(parsed_host == "10.9.0.2" || parsed_host == "oxpulse.chat");
        }
        // a userinfo url that the OLD guard accepted must now be rejected AND parse to evil.com
        let evil = "ws://10.9.0.2:0@evil.com/x";
        assert_eq!(evil.parse::<Uri>().unwrap().host().unwrap(), "evil.com");
        assert!(!is_allowed_upstream(evil));
    }

    #[test]
    fn leading_dot_host_rejected() {
        assert!(!is_allowed_upstream("wss://.oxpulse.chat/x"));
        // sanity: legitimate forms still pass
        assert!(is_allowed_upstream("wss://oxpulse.chat/x"));
        assert!(is_allowed_upstream("wss://edge.oxpulse.chat/x"));
    }
}
