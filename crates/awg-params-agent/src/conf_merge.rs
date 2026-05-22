//! Pure conf-merge logic: replace AWG obfuscation params in a `awg0.conf`
//! string while leaving everything else byte-identical.
//!
//! Strategy: per-key regex replacement on the raw text, matching the
//! orchestrator's `renderAwgConf` in `cmd/orchestrator/awg_params.go`.
//! Numeric params use `^Key = \d+$`; I1 (InitString) uses `^I1 = .+$`
//! because its value contains angle brackets and hex literals.
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

/// Replace the 11 AWG obfuscation params in `conf` with values from `params`.
///
/// Returns `Err` if any of the 10 numeric keys is absent from the conf text,
/// or if I1 is `Some` but absent from the conf — prevents a silent no-op
/// when the conf shape has changed or is corrupted.
/// I1 is `None` → skip (backward compat for pre-I1 DB rows).
/// All other content ([Peer] sections, PrivateKey, Address, comments,
/// whitespace) is preserved byte-for-byte.
pub fn merge_obfuscation_params(conf: &str, params: &AwgParams) -> Result<String> {
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
        if !re.is_match(&result) {
            return Err(crate::error::anyhow!(
                "conf merge: key {:?} not found in conf (conf structure changed or corrupted)",
                key
            ));
        }
        let new_line = format!("{} = {}", key, val);
        result = re.replace_all(&result, new_line.as_str()).into_owned();
    }

    // I1 (InitString) — string value, handled separately after numeric loop.
    // `None` → skip (old DB rows without I1 field).
    if let Some(i1_val) = &params.i1 {
        if !AWG_I1_RE.is_match(&result) {
            return Err(crate::error::anyhow!(
                "conf merge: key \"I1\" not found in conf (conf structure changed or corrupted)"
            ));
        }
        let new_line = format!("I1 = {}", i1_val);
        result = AWG_I1_RE
            .replace_all(&result, new_line.as_str())
            .into_owned();
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
    fn merge_obfuscation_params_errors_on_missing_key() {
        // conf missing Jc line → merge must return Err, not silently skip.
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
        let err = merge_obfuscation_params(conf_no_jc, &params).unwrap_err();
        assert!(
            err.to_string().contains("Jc"),
            "error should name the missing key, got: {}",
            err
        );
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

    /// T1.3.x: I1=Some but absent from conf → Err (not silent no-op).
    #[test]
    fn merge_obfuscation_params_errors_on_missing_i1_when_some() {
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
        let err = merge_obfuscation_params(conf_no_i1, &params).unwrap_err();
        assert!(
            err.to_string().contains("I1"),
            "error must name missing key I1, got: {}",
            err
        );
    }
}
