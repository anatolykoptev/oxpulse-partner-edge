//! Data-channel ingestion for the SFU-side subscriber path.
//!
//! Currently handles one channel:
//!   * DC id:2, label `sfu-budget` (negotiated, unordered) — subscriber
//!     control messages. Wire format parsed without serde; malformed
//!     messages are logged at WARN and dropped.
//!
//! Supported message types:
//!   * `{ "type": "budget", "bps": <u64> }` →
//!     `Propagated::ClientBudgetHint(client_id, bps)`
//!   * `{ "type": "max_temporal_layer", "vfm": <u8> }` (feature `vfm`) →
//!     `Propagated::VfmLayerCap(client_id, layer)`
//!   * `{ "type": "relay_source", "upstreamUrl": "<url>", "roomToken": "<jwt>" }` (any channel) →
//!     `Propagated::MarkRelaySource(client_id, upstream_url)` — marks this
//!     connection as a cascade SFU relay node. When SIGNALING_SFU_SECRET is
//!     configured, roomToken MUST be a valid room JWT signed by signaling;
//!     unauthenticated relay promotions are rejected.
//!
//! Returns `Propagated::Noop` for any unrecognised payload.

use crate::propagate::{ClientId, Propagated};
use crate::room_auth;

/// Label of the pre-negotiated budget data channel.
const BUDGET_CHANNEL_LABEL: &str = "sfu-budget";

/// Handle an incoming `Event::ChannelData` from str0m.
///
/// `label` is pre-resolved by the caller (via `rtc.channel(id)`) because
/// `Rtc::channel` requires `&mut self`, which can't be borrowed alongside
/// the event data in a match arm. Label mismatch → `Noop`.
/// `relay_auth_secret`: when `Some`, relay_source messages MUST carry a valid `roomToken`
/// JWT signed with this HS256 secret. Pass `None` to allow unauthenticated relay (dev/test only).
///
/// `relay_signing_pubkey`: when `Some`, EdDSA (Ed25519) room token verification is preferred
/// over HS256. When both are set, EdDSA takes priority. When neither is set, relay is
/// unauthenticated (dev/test only).
pub(super) fn handle_channel_data(
    client_id: ClientId,
    label: &str,
    data: &[u8],
    relay_auth_secret: Option<&[u8]>,
    relay_signing_pubkey: Option<&str>,
) -> Propagated {
    // relay_source can arrive on any DC channel — check before label filter.
    // When relay_auth_secret is Some, the message MUST contain a valid roomToken JWT
    // issued by oxpulse-chat signaling. This closes the privilege-escalation path where
    // any connected peer could self-promote to relay status by sending
    // {"type":"relay_source","upstreamUrl":"..."} over DataChannel.
    if let Ok(s) = std::str::from_utf8(data) {
        if extract_str_value(s, "type") == Some("relay_source") {
            let Some(upstream_url) = extract_str_value(s, "upstreamUrl") else {
                tracing::warn!(
                    client = *client_id,
                    "relay_source DC: missing upstreamUrl, rejecting"
                );
                return Propagated::Noop;
            };

            // Token gating: require a valid roomToken when any auth credential is configured.
            // EdDSA (Ed25519) is preferred when relay_signing_pubkey is set (Phase 2).
            // HS256 is used when only relay_auth_secret is set (legacy).
            // Neither set → allow unauthenticated relay (dev/test only).
            let auth_required = relay_signing_pubkey.is_some() || relay_auth_secret.is_some();
            if auth_required {
                let Some(token) = extract_str_value(s, "roomToken") else {
                    tracing::warn!(
                        client = *client_id,
                        upstream_url = upstream_url,
                        "relay_source DC: missing roomToken (auth configured) — rejecting"
                    );
                    return Propagated::Noop;
                };
                // Extract room ID from the upstream URL (last path segment).
                // URL format: wss://host/.../ROOM_ID
                let room_id = upstream_url.rsplit('/').next().unwrap_or("");
                if room_id.is_empty() {
                    tracing::warn!(
                        client = *client_id,
                        upstream_url = upstream_url,
                        "relay_source DC: cannot extract room_id from upstreamUrl — rejecting"
                    );
                    return Propagated::Noop;
                }
                // Prefer EdDSA when the public key is available, fall back to HS256.
                let verify_result = if let Some(pubkey) = relay_signing_pubkey {
                    room_auth::verify_room_token_ed25519(token, room_id, pubkey)
                } else if let Some(secret) = relay_auth_secret {
                    room_auth::verify_room_token(token, room_id, secret)
                } else {
                    unreachable!("auth_required guarantees at least one credential");
                };
                if let Err(e) = verify_result {
                    tracing::warn!(
                        client = *client_id,
                        upstream_url = upstream_url,
                        error = %e,
                        "relay_source DC: roomToken verification failed — rejecting"
                    );
                    return Propagated::Noop;
                }
                tracing::debug!(
                    client = *client_id,
                    upstream_url = upstream_url,
                    room_id = room_id,
                    "relay_source DC: roomToken verified — marking as cascade relay"
                );
            } else {
                // No credentials configured — allow unauthenticated relay (dev/test only).
                // Production deployments MUST set SFU_SIGNING_PUBLIC_KEY or SIGNALING_SFU_SECRET.
                tracing::debug!(
                    client = *client_id,
                    upstream_url = upstream_url,
                    "relay_source DC: no auth configured — allowing unauthenticated (dev mode)"
                );
            }

            return Propagated::MarkRelaySource(client_id, upstream_url.to_string());
        }
    }

    if label != BUDGET_CHANNEL_LABEL {
        return Propagated::Noop;
    }

    let text = match std::str::from_utf8(data) {
        Ok(s) => s,
        Err(_) => {
            tracing::warn!(
                client = *client_id,
                "sfu-budget DC: non-UTF-8 payload, dropping"
            );
            return Propagated::Noop;
        }
    };

    // VFM temporal-layer cap: `{ "type": "max_temporal_layer", "vfm": N }`.
    #[cfg(feature = "vfm")]
    if extract_str_value(text, "type").as_deref() == Some("max_temporal_layer") {
        match extract_num_value(text, "vfm") {
            Some(max_tid) => return Propagated::VfmLayerCap(client_id, max_tid as u8),
            None => {
                tracing::warn!(
                    client = *client_id,
                    payload = text,
                    "sfu-budget DC: max_temporal_layer missing vfm field, dropping"
                );
                return Propagated::Noop;
            }
        }
    }

    match parse_budget_bps(text) {
        Some(bps) => Propagated::ClientBudgetHint(client_id, bps),
        None => {
            tracing::warn!(
                client = *client_id,
                payload = text,
                "sfu-budget DC: unrecognised payload, dropping"
            );
            Propagated::Noop
        }
    }
}

/// Parse `{ "type": "budget", "bps": <u64> }` without serde.
///
/// Accepts any ordering of the two keys and tolerates extra whitespace
/// around colons and values. Returns `None` when `type` is absent,
/// not `"budget"`, or `bps` is absent/non-numeric.
fn parse_budget_bps(s: &str) -> Option<u64> {
    // Quick sanity: must contain both keys.
    if !s.contains("\"type\"") || !s.contains("\"bps\"") {
        return None;
    }

    // Extract "type" value — expect the string literal "budget".
    let type_ok = extract_str_value(s, "type")
        .map(|v| v == "budget")
        .unwrap_or(false);
    if !type_ok {
        return None;
    }

    // Extract "bps" numeric value.
    extract_num_value(s, "bps")
}

/// Find `"<key>": "<value>"` and return the inner `<value>` string.
fn extract_str_value<'a>(json: &'a str, key: &str) -> Option<&'a str> {
    let needle = format!("\"{key}\"");
    let start = json.find(needle.as_str())?;
    let after_key = &json[start + needle.len()..];
    // Skip optional whitespace + colon + optional whitespace + opening quote.
    let colon = after_key.find(':')?;
    let after_colon = after_key[colon + 1..].trim_start();
    if !after_colon.starts_with('"') {
        return None;
    }
    let inner = &after_colon[1..];
    let end = inner.find('"')?;
    Some(&inner[..end])
}

/// Find `"<key>": <number>` and return the parsed `u64`.
fn extract_num_value(json: &str, key: &str) -> Option<u64> {
    let needle = format!("\"{key}\"");
    let start = json.find(needle.as_str())?;
    let after_key = &json[start + needle.len()..];
    let colon = after_key.find(':')?;
    let after_colon = after_key[colon + 1..].trim_start();
    // Collect digit characters.
    let digits: String = after_colon
        .chars()
        .take_while(|c| c.is_ascii_digit())
        .collect();
    if digits.is_empty() {
        return None;
    }
    digits.parse().ok()
}

// ── unit tests ───────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::parse_budget_bps;

    #[test]
    fn parses_well_formed_budget() {
        let s = r#"{"type":"budget","bps":500000}"#;
        assert_eq!(parse_budget_bps(s), Some(500_000));
    }

    #[test]
    fn parses_reversed_key_order() {
        let s = r#"{"bps":1234567,"type":"budget"}"#;
        assert_eq!(parse_budget_bps(s), Some(1_234_567));
    }

    #[test]
    fn rejects_wrong_type() {
        let s = r#"{"type":"stats","bps":500000}"#;
        assert_eq!(parse_budget_bps(s), None);
    }

    #[test]
    fn rejects_missing_bps() {
        let s = r#"{"type":"budget"}"#;
        assert_eq!(parse_budget_bps(s), None);
    }

    #[test]
    fn rejects_non_numeric_bps() {
        let s = r#"{"type":"budget","bps":"fast"}"#;
        assert_eq!(parse_budget_bps(s), None);
    }

    #[test]
    fn rejects_empty_string() {
        assert_eq!(parse_budget_bps(""), None);
    }

    #[test]
    fn parses_with_extra_whitespace() {
        let s = r#"{ "type" : "budget" , "bps" : 300000 }"#;
        assert_eq!(parse_budget_bps(s), Some(300_000));
    }

    // relay_source tests use handle_channel_data directly
    use super::handle_channel_data;
    use crate::propagate::{ClientId, Propagated};

    #[test]
    fn relay_source_returns_mark_relay_on_any_channel() {
        let data = br#"{"type":"relay_source","upstreamUrl":"wss://eu-1.example/sfu"}"#;
        let result = handle_channel_data(ClientId(42), "some-other-channel", data, None, None);
        match result {
            Propagated::MarkRelaySource(id, url) => {
                assert_eq!(*id, 42);
                assert_eq!(url, "wss://eu-1.example/sfu");
            }
            other => panic!("expected MarkRelaySource, got {other:?}"),
        }
    }

    #[test]
    fn relay_source_missing_url_returns_noop() {
        let data = br#"{"type":"relay_source"}"#;
        let result = handle_channel_data(ClientId(43), "sfu-budget", data, None, None);
        assert!(matches!(result, Propagated::Noop));
    }

    #[test]
    fn relay_source_on_budget_channel_wins_over_budget_parse() {
        // If somehow both type=relay_source and bps are present,
        // relay_source takes priority since it is checked first.
        let data =
            br#"{"type":"relay_source","upstreamUrl":"wss://eu-1.example/sfu","bps":500000}"#;
        let result = handle_channel_data(ClientId(44), "sfu-budget", data, None, None);
        assert!(matches!(result, Propagated::MarkRelaySource(..)));
    }

    // ── relay_source token-gating tests ─────────────────────────────────────

    use jsonwebtoken::{encode, EncodingKey, Header};
    use crate::room_auth::RoomClaims;

    fn make_room_token(room: &str, sub: u64, secret: &[u8], exp_delta_secs: i64) -> String {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs();
        let exp = (now as i64 + exp_delta_secs).max(0) as u64;
        let claims = RoomClaims { sub, room: room.to_string(), iat: now, exp };
        encode(&Header::default(), &claims, &EncodingKey::from_secret(secret)).unwrap()
    }

    #[test]
    fn relay_source_with_valid_token_accepted() {
        let secret = b"test-secret-32-bytes-long-enough!";
        // URL ending with /room-abc — room_id extracted as "room-abc"
        let token = make_room_token("room-abc", 99, secret, 3600);
        let payload = format!(
            r#"{{"type":"relay_source","upstreamUrl":"wss://us.oxpulse.chat/ws/sfu/room-abc","roomToken":"{}"}}"#,
            token
        );
        let result = handle_channel_data(ClientId(50), "any", payload.as_bytes(), Some(secret), None);
        assert!(matches!(result, Propagated::MarkRelaySource(..)));
    }

    #[test]
    fn relay_source_missing_token_when_secret_set_rejected() {
        let secret = b"test-secret-32-bytes-long-enough!";
        let data = br#"{"type":"relay_source","upstreamUrl":"wss://us.oxpulse.chat/ws/sfu/room-abc"}"#;
        let result = handle_channel_data(ClientId(51), "any", data, Some(secret), None);
        assert!(matches!(result, Propagated::Noop));
    }

    #[test]
    fn relay_source_wrong_secret_rejected() {
        let secret = b"correct-secret-32-bytes-long!!!!";
        let token = make_room_token("room-abc", 1, b"other-secret-32-bytes-long!!!!!!!", 3600);
        let payload = format!(
            r#"{{"type":"relay_source","upstreamUrl":"wss://us.oxpulse.chat/ws/sfu/room-abc","roomToken":"{}"}}"#,
            token
        );
        let result = handle_channel_data(ClientId(52), "any", payload.as_bytes(), Some(secret), None);
        assert!(matches!(result, Propagated::Noop));
    }

    #[test]
    fn relay_source_expired_token_rejected() {
        let secret = b"test-secret-32-bytes-long-enough!";
        let token = make_room_token("room-abc", 1, secret, -60); // expired 60s ago
        let payload = format!(
            r#"{{"type":"relay_source","upstreamUrl":"wss://us.oxpulse.chat/ws/sfu/room-abc","roomToken":"{}"}}"#,
            token
        );
        let result = handle_channel_data(ClientId(53), "any", payload.as_bytes(), Some(secret), None);
        assert!(matches!(result, Propagated::Noop));
    }

    #[test]
    fn relay_source_wrong_room_rejected() {
        let secret = b"test-secret-32-bytes-long-enough!";
        // Token is for room-xyz but URL ends with room-abc
        let token = make_room_token("room-xyz", 1, secret, 3600);
        let payload = format!(
            r#"{{"type":"relay_source","upstreamUrl":"wss://us.oxpulse.chat/ws/sfu/room-abc","roomToken":"{}"}}"#,
            token
        );
        let result = handle_channel_data(ClientId(54), "any", payload.as_bytes(), Some(secret), None);
        assert!(matches!(result, Propagated::Noop));
    }

    // --- EdDSA relay_source tests ---

    fn generate_test_keypair_dc() -> (String, String) {
        use ed25519_dalek::SigningKey as DalekKey;
        use ed25519_dalek::pkcs8::{EncodePrivateKey, EncodePublicKey};
        use pkcs8::LineEnding;
        let key = DalekKey::generate(&mut rand::rngs::OsRng);
        let priv_pem = key.to_pkcs8_pem(LineEnding::LF).unwrap().to_string();
        let pub_pem = key.verifying_key().to_public_key_pem(LineEnding::LF).unwrap();
        (priv_pem, pub_pem)
    }

    fn make_ed25519_room_token_dc(room: &str, sub: u64, priv_pem: &str, exp_delta: i64) -> String {
        use jsonwebtoken::{encode, EncodingKey, Header, Algorithm};
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs();
        let exp = (now as i64 + exp_delta).max(0) as u64;
        let claims = RoomClaims { sub, room: room.to_string(), iat: now, exp };
        let key = EncodingKey::from_ed_pem(priv_pem.as_bytes()).unwrap();
        encode(&Header::new(Algorithm::EdDSA), &claims, &key).unwrap()
    }

    #[test]
    fn relay_source_eddsa_valid_token_accepted() {
        let (priv_pem, pub_pem) = generate_test_keypair_dc();
        let token = make_ed25519_room_token_dc("room-abc", 77, &priv_pem, 3600);
        let payload = format!(
            r#"{{"type":"relay_source","upstreamUrl":"wss://us.oxpulse.chat/ws/sfu/room-abc","roomToken":"{}"}}"#,
            token
        );
        let result = handle_channel_data(
            ClientId(60),
            "any",
            payload.as_bytes(),
            None,
            Some(pub_pem.as_str()),
        );
        assert!(matches!(result, Propagated::MarkRelaySource(..)));
    }

    #[test]
    fn relay_source_eddsa_missing_token_when_pubkey_set_rejected() {
        let (_priv, pub_pem) = generate_test_keypair_dc();
        let data = br#"{"type":"relay_source","upstreamUrl":"wss://us.oxpulse.chat/ws/sfu/room-abc"}"#;
        let result = handle_channel_data(
            ClientId(61),
            "any",
            data,
            None,
            Some(pub_pem.as_str()),
        );
        assert!(matches!(result, Propagated::Noop));
    }

    #[test]
    fn relay_source_eddsa_wrong_pubkey_rejected() {
        let (priv_pem, _pub1) = generate_test_keypair_dc();
        let (_priv2, pub_pem2) = generate_test_keypair_dc();
        let token = make_ed25519_room_token_dc("room-abc", 1, &priv_pem, 3600);
        let payload = format!(
            r#"{{"type":"relay_source","upstreamUrl":"wss://us.oxpulse.chat/ws/sfu/room-abc","roomToken":"{}"}}"#,
            token
        );
        let result = handle_channel_data(
            ClientId(62),
            "any",
            payload.as_bytes(),
            None,
            Some(pub_pem2.as_str()),
        );
        assert!(matches!(result, Propagated::Noop));
    }

    #[test]
    fn relay_source_eddsa_prefers_eddsa_over_hs256() {
        // When both pubkey and hs256 secret are set, EdDSA must succeed with a valid EdDSA token
        // even if the HS256 secret would reject it (wrong secret doesn't matter).
        let (priv_pem, pub_pem) = generate_test_keypair_dc();
        let token = make_ed25519_room_token_dc("room-abc", 5, &priv_pem, 3600);
        let payload = format!(
            r#"{{"type":"relay_source","upstreamUrl":"wss://us.oxpulse.chat/ws/sfu/room-abc","roomToken":"{}"}}"#,
            token
        );
        let result = handle_channel_data(
            ClientId(63),
            "any",
            payload.as_bytes(),
            Some(b"some-hs256-secret"),   // present but irrelevant — EdDSA wins
            Some(pub_pem.as_str()),
        );
        assert!(matches!(result, Propagated::MarkRelaySource(..)));
    }

}
