//! Pure conf-merge logic: replace AWG obfuscation params in a `awg0.conf`
//! string while leaving everything else byte-identical.
//!
//! Strategy: per-key regex replacement on the raw text, matching the
//! orchestrator's `renderAwgConf` in `cmd/orchestrator/awg_params.go`.
//! Each param line is `^Key = <digits>$` (multiline).  Peer sections are
//! untouched because WireGuard peer keys are base64, not bare digits.

use crate::error::Result;
use crate::params::AwgParams;
use once_cell::sync::Lazy;
use regex::Regex;
use std::collections::HashMap;

/// Compiled regexes for all 10 AWG obfuscation params.
/// Multiline flag ensures `^`/`$` match individual lines, not the whole string.
static AWG_PARAM_RE: Lazy<HashMap<&'static str, Regex>> = Lazy::new(|| {
    let mut m = HashMap::new();
    for key in &["Jc", "Jmin", "Jmax", "S1", "S2", "S4", "H1", "H2", "H3", "H4"] {
        let pattern = format!(r"(?m)^{} = \d+$", regex::escape(key));
        m.insert(*key, Regex::new(&pattern).expect("static regex is valid"));
    }
    m
});

/// Replace the 10 AWG obfuscation params in `conf` with values from `params`.
///
/// Returns `Err` if any of the 10 keys is absent from the conf text — this
/// prevents a silent no-op when the conf shape has changed or is corrupted.
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
            .expect("all 10 keys are in AWG_PARAM_RE");
        if !re.is_match(&result) {
            return Err(crate::error::anyhow!(
                "conf merge: key {:?} not found in conf (conf structure changed or corrupted)",
                key
            ));
        }
        let new_line = format!("{} = {}", key, val);
        result = re.replace_all(&result, new_line.as_str()).into_owned();
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Minimal valid awg0.conf fixture with all 10 params and a [Peer] block.
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
    }
}
