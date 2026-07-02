//! Pure conf-merge logic: replace-or-insert AWG obfuscation params in a
//! `awg0.conf` string while leaving everything else byte-identical.
//!
//! Strategy: per-key regex replacement on the raw text, matching the
//! orchestrator's `renderAwgConf` in `cmd/orchestrator/awg_params.go`.
//! Numeric params use `^Key = \d+$`; I1 (InitString) uses `^I1 = .+$`
//! because its value contains angle brackets and hex literals.
//!
//! Absent params are INSERTED into the `[Interface]` section rather than
//! erroring — edges are dumb caches (roadmap invariant), so a bootstrap-only
//! conf carrying no obfuscation params is valid input. This also self-heals
//! legacy edges whose `awg0.conf` predates the I1 line: the agent tops up the
//! missing line on its own, with no installer migration needed.
//! Peer sections are untouched because WireGuard peer keys are base64.

use crate::error::Result;
use crate::params::AwgParams;
use once_cell::sync::Lazy;
use regex::Regex;
use std::collections::HashMap;

/// Compiled regexes for the 10 numeric AWG obfuscation params.
/// Multiline flag ensures `^`/`$` match individual lines, not the whole string.
static AWG_PARAM_RE: Lazy<HashMap<&'static str, Regex>> = Lazy::new(|| {
    let mut m = HashMap::new();
    for key in &[
        "Jc", "Jmin", "Jmax", "S1", "S2", "S4", "H1", "H2", "H3", "H4",
    ] {
        let pattern = format!(r"(?m)^{} = \d+$", regex::escape(key));
        m.insert(*key, Regex::new(&pattern).expect("static regex is valid"));
    }
    m
});

/// Compiled regex for I1 (InitString) — value is arbitrary chars, not digits.
static AWG_I1_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"(?m)^I1 = .+$").expect("static regex is valid"));

/// Compiled regex for the `[Interface]` section header line. Used to locate
/// the insertion point for params that are absent from the conf.
static AWG_INTERFACE_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"(?m)^\[Interface\][^\n]*$").expect("static regex is valid"));

/// Insert `line` immediately after the `[Interface]` header line, preserving
/// all other bytes. Returns `Err` only if `conf` has no `[Interface]` section.
fn insert_into_interface(conf: &str, line: &str) -> Result<String> {
    let Some(m) = AWG_INTERFACE_RE.find(conf) else {
        return Err(crate::error::anyhow!(
            "conf merge: no [Interface] section found (cannot insert {:?})",
            line
        ));
    };
    // `m.end()` is the position just before the header line's newline (or EOF
    // if it is the last line). Splice `\n{line}` in right after the header.
    let header_end = m.end();
    let mut result = String::with_capacity(conf.len() + line.len() + 1);
    result.push_str(&conf[..header_end]);
    result.push('\n');
    result.push_str(line);
    result.push_str(&conf[header_end..]);
    Ok(result)
}

/// Replace-or-insert the 11 AWG obfuscation params in `conf` with values from
/// `params`.
///
/// For each of the 10 numeric keys (and I1 when `Some` and non-empty): if the
/// key's line is present it is REPLACED; if absent it is INSERTED immediately
/// after the `[Interface]` header. This supports bootstrap-only confs (edges
/// are dumb caches) and self-heals legacy edges whose `awg0.conf` lacks an I1
/// line — no installer top-up needed.
///
/// Returns `Err` only if `conf` has no `[Interface]` section to insert into.
/// I1 is `None` or `Some("")` → skip (backward compat for pre-I1 DB rows and
/// empty-string writer regressions).
/// All other content ([Peer] sections, PrivateKey, Address, comments,
/// whitespace) is preserved byte-for-byte.
pub fn merge_obfuscation_params(conf: &str, params: &AwgParams) -> Result<String> {
    // SECURITY (T4, crypto_invariant): reject any central-sourced string param
    // that carries a conf-injection primitive BEFORE it is spliced into
    // awg0.conf and piped through `awg-quick strip | awg syncconf` (agent.rs
    // apply path) into the kernel WireGuard peer table. Without this, a hostile
    // or MITM'd central server could set a multi-line I1 whose embedded
    // newline + `[Peer]` header injects an attacker peer (AllowedIPs=0.0.0.0/0,
    // Endpoint=attacker). TLS+bearer authenticates the connection, NOT the
    // field content — so the guard lives at this splice choke point, the single
    // path every central-sourced param takes to the kernel. On `Err` the caller
    // (tick) fails the apply and logs; the Task 12 exporter bumps
    // `awg_params_agent_param_rejected_total{field="i1"}` (alert critical).
    params.validate()?;

    let replacements: [(&'static str, i64); 10] = [
        ("Jc", params.jc),
        ("Jmin", params.jmin),
        ("Jmax", params.jmax),
        ("S1", params.s1),
        ("S2", params.s2),
        ("S4", params.s4),
        ("H1", params.h1),
        ("H2", params.h2),
        ("H3", params.h3),
        ("H4", params.h4),
    ];

    let mut result = conf.to_owned();
    for (key, val) in &replacements {
        let re = AWG_PARAM_RE
            .get(key)
            .expect("all 10 numeric keys are in AWG_PARAM_RE");
        let new_line = format!("{} = {}", key, val);
        if re.is_match(&result) {
            result = re.replace_all(&result, new_line.as_str()).into_owned();
        } else {
            // Absent → insert into [Interface] (bootstrap / self-heal path).
            result = insert_into_interface(&result, &new_line)?;
        }
    }

    // I1 (InitString) — string value, handled separately after numeric loop.
    // `None` OR `Some("")` → skip. Mirrors orchestrator Go-side semantics:
    // empty-string I1 (e.g. writer regression emits `"I1": ""`) MUST be
    // treated identically to JSON-omitted I1 — otherwise the agent would
    // write a malformed `I1 = ` line while motherly's conf stays clean,
    // creating exactly the silent-drift class that T1.3.x closes.
    if let Some(i1_val) = params.i1.as_deref().filter(|s| !s.is_empty()) {
        let new_line = format!("I1 = {}", i1_val);
        if AWG_I1_RE.is_match(&result) {
            result = AWG_I1_RE
                .replace_all(&result, new_line.as_str())
                .into_owned();
        } else {
            // Absent → insert into [Interface] (self-heals I1-less legacy confs).
            result = insert_into_interface(&result, &new_line)?;
        }
    }

    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Minimal valid awg0.conf fixture with all 11 params and a [Peer] block.
    fn fixture_conf() -> &'static str {
        "[Interface]\n\
         PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n\
         Address = 10.9.0.2/32\n\
         ListenPort = 43801\n\
         Jc = 11\n\
         Jmin = 50\n\
         Jmax = 1000\n\
         S1 = 17\n\
         S2 = 18\n\
         S4 = 18\n\
         H1 = 123456789\n\
         H2 = 234567890\n\
         H3 = 345678901\n\
         H4 = 456789012\n\
         I1 = <r 2><b 0x0100><b 0x0001><b 0x0000><b 0x0000><b 0x0000>\n\
         Table = off\n\
         MTU = 1300\n\
         \n\
         # This is a comment about the peer below.\n\
         [Peer]\n\
         PublicKey = BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=\n\
         Endpoint = motherly.example.com:51820\n\
         AllowedIPs = 10.9.0.1/32\n\
         PersistentKeepalive = 25\n"
    }

    /// sample_params with I1=None (backward-compat — old DB rows without I1).
    fn sample_params(jc: i64) -> AwgParams {
        AwgParams {
            jc,
            jmin: 50,
            jmax: 1000,
            s1: 17,
            s2: 18,
            s4: 18,
            h1: 123456789,
            h2: 234567890,
            h3: 345678901,
            h4: 456789012,
            i1: None,
        }
    }

    /// sample_params with an I1 value set.
    fn sample_params_with_i1(jc: i64, i1: &str) -> AwgParams {
        AwgParams {
            i1: Some(i1.to_owned()),
            ..sample_params(jc)
        }
    }

    #[test]
    fn merge_obfuscation_params_replaces_jc() {
        let conf = fixture_conf();
        let params = sample_params(99);
        let out = merge_obfuscation_params(conf, &params).unwrap();
        assert!(out.contains("Jc = 99\n"), "Jc should be 99, got:\n{}", out);
        assert!(!out.contains("Jc = 11"), "old Jc should be gone");
    }

    #[test]
    fn merge_obfuscation_params_preserves_peer_section() {
        let conf = fixture_conf();
        let params = sample_params(99);
        let out = merge_obfuscation_params(conf, &params).unwrap();

        // The entire [Peer] block must be byte-identical.
        let peer_start = conf.find("[Peer]").expect("fixture has [Peer]");
        let expected_peer = &conf[peer_start..];
        assert!(
            out.contains(expected_peer),
            "[Peer] section changed:\nexpected suffix:\n{}\ngot:\n{}",
            expected_peer,
            &out[out.find("[Peer]").unwrap_or(0)..]
        );
    }

    #[test]
    fn merge_obfuscation_params_preserves_comments_and_whitespace() {
        let conf = fixture_conf();
        let params = sample_params(7);
        let out = merge_obfuscation_params(conf, &params).unwrap();

        // Comment line must survive.
        assert!(
            out.contains("# This is a comment about the peer below."),
            "comment was dropped:\n{}",
            out
        );
        // PrivateKey (base64, not digits) must be untouched.
        assert!(
            out.contains("PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="),
            "PrivateKey changed"
        );
        // Table and MTU must survive.
        assert!(out.contains("Table = off"), "Table = off dropped");
        assert!(out.contains("MTU = 1300"), "MTU = 1300 dropped");
    }

    #[test]
    fn merge_inserts_missing_numeric_key() {
        // conf missing Jc line → merge must INSERT it into [Interface], not Err.
        // Self-heal path: edges are dumb caches, a bootstrap conf may lack params.
        let conf_no_jc = "[Interface]\n\
                          PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n\
                          Address = 10.9.0.2/32\n\
                          Jmin = 50\n\
                          Jmax = 1000\n\
                          S1 = 17\n\
                          S2 = 18\n\
                          S4 = 18\n\
                          H1 = 1\n\
                          H2 = 2\n\
                          H3 = 3\n\
                          H4 = 4\n";
        let params = sample_params(99);
        let out = merge_obfuscation_params(conf_no_jc, &params).unwrap();
        assert!(
            out.contains("Jc = 99\n"),
            "missing Jc must be inserted, got:\n{}",
            out
        );
        // Inserted into the [Interface] section.
        let hdr = out.find("[Interface]").expect("has [Interface]");
        let jc = out.find("Jc = 99").expect("has inserted Jc");
        assert!(jc > hdr, "inserted Jc must be inside [Interface]:\n{}", out);
    }

    /// Regression: base64 peer keys must not be mistaken for digit-only lines.
    /// Also covers that S1/S2/S4 with values that appear in base64 are safe.
    #[test]
    fn merge_obfuscation_params_all_params_replaced() {
        let params = AwgParams {
            jc: 7,
            jmin: 42,
            jmax: 999,
            s1: 5,
            s2: 6,
            s4: 7,
            h1: 11111111,
            h2: 22222222,
            h3: 33333333,
            h4: 44444444,
            i1: None, // I1 absent — backward compat path
        };
        let out = merge_obfuscation_params(fixture_conf(), &params).unwrap();
        assert!(out.contains("Jc = 7\n"));
        assert!(out.contains("Jmin = 42\n"));
        assert!(out.contains("Jmax = 999\n"));
        assert!(out.contains("S1 = 5\n"));
        assert!(out.contains("S2 = 6\n"));
        assert!(out.contains("S4 = 7\n"));
        assert!(out.contains("H1 = 11111111\n"));
        assert!(out.contains("H2 = 22222222\n"));
        assert!(out.contains("H3 = 33333333\n"));
        assert!(out.contains("H4 = 44444444\n"));
        // I1=None → existing I1 line preserved unchanged.
        assert!(
            out.contains("I1 = <r 2><b 0x0100>"),
            "I1 line must be preserved when i1 is None"
        );
    }

    /// T1.3.x: I1 (InitString) is replaced correctly.
    /// Value contains angle brackets and hex literals — not digits.
    #[test]
    fn merge_obfuscation_params_replaces_i1() {
        let params = sample_params_with_i1(11, "<r 3><b 0x0200><b 0x0002>");
        let out = merge_obfuscation_params(fixture_conf(), &params).unwrap();
        assert!(
            out.contains("I1 = <r 3><b 0x0200><b 0x0002>\n"),
            "I1 must be replaced, got:\n{}",
            out
        );
        assert!(
            !out.contains("I1 = <r 2><b 0x0100>"),
            "old I1 must not remain"
        );
    }

    /// T1.3.x: I1=None leaves existing I1 line unchanged (backward compat
    /// for pre-I1 DB rows).
    #[test]
    fn merge_obfuscation_params_i1_none_preserves_existing_line() {
        let params = sample_params(11); // i1: None
        let out = merge_obfuscation_params(fixture_conf(), &params).unwrap();
        assert!(
            out.contains("I1 = <r 2><b 0x0100><b 0x0001><b 0x0000><b 0x0000><b 0x0000>\n"),
            "existing I1 line must survive when i1 is None:\n{}",
            out
        );
    }

    /// T1.3.x (reviewer MAJOR): I1=Some("") MUST be treated like None — skip
    /// apply, leave existing I1 line untouched. Otherwise the agent writes a
    /// malformed `I1 = ` line while motherly's Go-side `if params.I1 != ""`
    /// skip keeps motherly clean — the exact silent-drift class T1.3.x closes.
    #[test]
    fn merge_obfuscation_params_i1_empty_string_skipped() {
        let params = sample_params_with_i1(11, ""); // i1: Some("")
        let out = merge_obfuscation_params(fixture_conf(), &params).unwrap();
        // Existing I1 line MUST survive — empty I1 must skip, not overwrite.
        assert!(
            out.contains("I1 = <r 2><b 0x0100><b 0x0001><b 0x0000><b 0x0000><b 0x0000>\n"),
            "existing I1 line must survive when i1 is Some(empty):\n{}",
            out
        );
        // Output must NOT contain a malformed `I1 = ` line (trailing space, no value).
        assert!(
            !out.contains("I1 = \n"),
            "must not write malformed empty `I1 = ` line:\n{}",
            out
        );
    }

    /// Self-heal: I1=Some but absent from conf → INSERT it (not Err).
    /// Closes the legacy-edge gap where an `awg0.conf` predates the I1 line —
    /// the agent tops it up itself, no installer migration needed.
    #[test]
    fn merge_inserts_i1_when_missing() {
        // Build a conf without the I1 line.
        let conf_no_i1 = "[Interface]\n\
                           PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n\
                           Address = 10.9.0.2/32\n\
                           Jc = 11\n\
                           Jmin = 50\n\
                           Jmax = 1000\n\
                           S1 = 17\n\
                           S2 = 18\n\
                           S4 = 18\n\
                           H1 = 1\n\
                           H2 = 2\n\
                           H3 = 3\n\
                           H4 = 4\n";
        let params = sample_params_with_i1(11, "<r 3><b 0x0200>");
        let out = merge_obfuscation_params(conf_no_i1, &params).unwrap();
        assert!(
            out.contains("I1 = <r 3><b 0x0200>\n"),
            "missing I1 must be inserted, got:\n{}",
            out
        );
        let hdr = out.find("[Interface]").expect("has [Interface]");
        let i1 = out.find("I1 = <r 3>").expect("has inserted I1");
        assert!(i1 > hdr, "inserted I1 must be inside [Interface]:\n{}", out);
    }

    /// Bootstrap-only conf: an `[Interface]` carrying only the base WireGuard
    /// keys (no obfuscation params) + a `[Peer]` block. After merge, all 10
    /// numeric params and an I1 line must be inserted into `[Interface]`, and
    /// the `[Peer]` block must survive intact.
    #[test]
    fn merge_bootstrap_conf_inserts_all_params() {
        let bootstrap = "[Interface]\n\
                         PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n\
                         Address = 10.9.0.2/32\n\
                         ListenPort = 43801\n\
                         Table = off\n\
                         MTU = 1300\n\
                         \n\
                         [Peer]\n\
                         PublicKey = BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=\n\
                         Endpoint = motherly.example.com:51820\n\
                         AllowedIPs = 10.9.0.1/32\n\
                         PersistentKeepalive = 25\n";
        let params = sample_params_with_i1(11, "<r 3><b 0x0200>");
        let out = merge_obfuscation_params(bootstrap, &params).unwrap();

        // All 10 numeric params inserted.
        for &line in &[
            "Jc = 11",
            "Jmin = 50",
            "Jmax = 1000",
            "S1 = 17",
            "S2 = 18",
            "S4 = 18",
            "H1 = 123456789",
            "H2 = 234567890",
            "H3 = 345678901",
            "H4 = 456789012",
        ] {
            assert!(
                out.contains(line),
                "missing inserted param {:?}:\n{}",
                line,
                out
            );
        }
        // I1 inserted.
        assert!(
            out.contains("I1 = <r 3><b 0x0200>"),
            "I1 must be inserted:\n{}",
            out
        );

        // [Peer] block intact.
        assert!(out.contains("PublicKey = BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB="));
        assert!(out.contains("Endpoint = motherly.example.com:51820"));
        assert!(out.contains("AllowedIPs = 10.9.0.1/32"));
        assert!(out.contains("PersistentKeepalive = 25"));

        // Inserted params must land in [Interface], not leak into [Peer].
        let peer_pos = out.find("[Peer]").expect("has [Peer]");
        let jc_pos = out.find("Jc = 11").expect("has inserted Jc");
        assert!(
            jc_pos < peer_pos,
            "inserted Jc leaked into [Peer]:\n{}",
            out
        );
    }

    /// FINDING REPRO (crypto_invariant/critical): a multi-line I1 carrying an
    /// embedded `[Peer]` block MUST be REJECTED at the splice site and NEVER
    /// reach the conf — otherwise `awg-quick strip | awg syncconf` would install
    /// an attacker peer (AllowedIPs=0.0.0.0/0, Endpoint=attacker) into the kernel
    /// WireGuard peer table. Multi-line fixture; current single-line fixtures do
    /// not cover this. FAILS today (merge splices it and returns Ok).
    #[test]
    fn merge_rejects_multiline_i1_peer_injection() {
        let malicious = "<r 2><b 0x0100>\n\
                         [Peer]\n\
                         PublicKey = ATTACKERAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n\
                         AllowedIPs = 0.0.0.0/0\n\
                         Endpoint = attacker.example.com:51820";
        let params = sample_params_with_i1(11, malicious);
        let result = merge_obfuscation_params(fixture_conf(), &params);
        assert!(
            result.is_err(),
            "multi-line I1 [Peer] injection must be REJECTED, got Ok:\n{:?}",
            result
        );
    }

    /// Belt-and-suspenders: even a single-line I1 that merely contains a bare
    /// `[` (section-header primitive) is rejected — no injected content survives
    /// into an output conf, because merge returns Err before splicing anything.
    #[test]
    fn merge_rejects_bracket_in_i1_no_conf_produced() {
        let params = sample_params_with_i1(11, "<r 2>[Peer]");
        let result = merge_obfuscation_params(fixture_conf(), &params);
        assert!(result.is_err(), "bracketed I1 must be rejected");
        // The original conf's single legit I1 line is the only [Peer]-free
        // interface content; the malicious value produced no conf at all.
        assert!(
            result.err().unwrap().to_string().contains("field=i1"),
            "rejection must name field=i1 for the Task 12 counter label"
        );
    }

    /// Regression: a legit single-line I1 is STILL applied after the guard —
    /// the charset guard must not reject valid `<r N><b 0xHH>` obfuscation
    /// params (angle brackets are legit; only `\n\r[]` are forbidden).
    #[test]
    fn merge_still_applies_valid_single_line_i1_after_guard() {
        let params = sample_params_with_i1(11, "<r 3><b 0x0200><b 0x0002>");
        let out = merge_obfuscation_params(fixture_conf(), &params).unwrap();
        assert!(
            out.contains("I1 = <r 3><b 0x0200><b 0x0002>\n"),
            "valid single-line I1 must still be applied, got:\n{}",
            out
        );
    }
}
