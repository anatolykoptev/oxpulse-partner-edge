//! Data-channel ingestion for the SFU-side subscriber path.
//!
//! Currently handles one channel:
//!   * DC id:2, label `sfu-budget` (negotiated, unordered) — the
//!     receiver's self-reported bandwidth budget. Wire format:
//!     `{ "type": "budget", "bps": <u64> }`. Parsed without serde;
//!     malformed messages are logged at WARN and dropped.
//!
//! Returns `Propagated::ClientBudgetHint(client_id, bps)` when a valid
//! budget message is parsed, `Propagated::Noop` otherwise.

use crate::propagate::{ClientId, Propagated};

/// Label of the pre-negotiated budget data channel.
const BUDGET_CHANNEL_LABEL: &str = "sfu-budget";

/// Handle an incoming `Event::ChannelData` from str0m.
///
/// `label` is pre-resolved by the caller (via `rtc.channel(id)`) because
/// `Rtc::channel` requires `&mut self`, which can't be borrowed alongside
/// the event data in a match arm. Label mismatch → `Noop`.
pub(super) fn handle_channel_data(client_id: ClientId, label: &str, data: &[u8]) -> Propagated {
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
}
