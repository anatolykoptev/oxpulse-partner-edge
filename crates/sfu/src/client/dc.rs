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
//!   * `{ "type": "relay_source", "upstreamUrl": "<url>" }` (any channel) →
//!     `Propagated::MarkRelaySource(client_id, upstream_url)` — marks this
//!     connection as a cascade SFU relay node.
//!
//! Returns `Propagated::Noop` for any unrecognised payload.

use crate::propagate::{ClientId, Propagated};

/// Label of the pre-negotiated budget data channel.
const BUDGET_CHANNEL_LABEL: &str = "sfu-budget";

/// Handle an incoming `Event::ChannelData` from str0m.
///
/// `label` is pre-resolved by the caller (via `rtc.channel(id)`) because
/// `Rtc::channel` requires `&mut self`, which can't be borrowed alongside
/// the event data in a match arm. Label mismatch → `Noop`.
pub(super) fn handle_channel_data(client_id: ClientId, label: &str, data: &[u8]) -> Propagated {
    // relay_source can arrive on any DC channel — check before label filter.
    if let Ok(s) = std::str::from_utf8(data) {
        if extract_str_value(s, "type").as_deref() == Some("relay_source") {
            if let Some(upstream_url) = extract_str_value(s, "upstreamUrl") {
                tracing::debug!(
                    client = *client_id,
                    upstream_url = upstream_url,
                    "relay_source DC: marking as cascade relay"
                );
                return Propagated::MarkRelaySource(client_id, upstream_url.to_string());
            }
            tracing::warn!(
                client = *client_id,
                "relay_source DC: missing upstreamUrl, dropping"
            );
            return Propagated::Noop;
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
    use crate::propagate::{ClientId, Propagated};
    use super::handle_channel_data;

    #[test]
    fn relay_source_returns_mark_relay_on_any_channel() {
        let data = br#"{"type":"relay_source","upstreamUrl":"wss://eu-1.example/sfu"}"#;
        let result = handle_channel_data(ClientId(42), "some-other-channel", data);
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
        let result = handle_channel_data(ClientId(43), "sfu-budget", data);
        assert!(matches!(result, Propagated::Noop));
    }

    #[test]
    fn relay_source_on_budget_channel_wins_over_budget_parse() {
        // If somehow both type=relay_source and bps are present,
        // relay_source takes priority since it is checked first.
        let data = br#"{"type":"relay_source","upstreamUrl":"wss://eu-1.example/sfu","bps":500000}"#;
        let result = handle_channel_data(ClientId(44), "sfu-budget", data);
        assert!(matches!(result, Propagated::MarkRelaySource(..)));
    }
}
