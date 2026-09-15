use crate::error::{anyhow, Result};
use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
use serde::{Deserialize, Deserializer, Serialize, Serializer};

/// AmneziaWG obfuscation parameters — the v2 superset of the server's
/// `awg_params_epoch.params` JSONB schema and the orchestrator's `AwgParams`
/// struct in `cmd/orchestrator/awg_params.go` (ADR-004 per-surface field
/// table).
///
/// v2 (AWG 3.1): the must-match set grows by S3 + HeaderProtectionKey +
/// RandomTrailers; H1-H4 widen from bare ints to [`IntOrRange`] (single
/// `123` or range `"123-456"`); the client-side set gains I2-I5,
/// ContentPaddingAddition, the five timing ranges, and DisableCookies.
/// Every v2 field is `Option` + `default` so pre-3.1 epoch JSONB rows decode
/// unchanged (absent = `None` = preserve; D4), and Jc/Jmin/Jmax are `Option`
/// as well so Phase E can stop emitting them without another agent release.
/// Zero-form remove-signals (syncconf can't clear a kernel param by
/// omission — ipc-uapi.h): `s3: 0`, `random_trailers: false`,
/// `header_protection_key` = base64(32 zero bytes).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct AwgParams {
    /// Junk-packet counts — `Option` since v2 so a future central can omit
    /// them (Phase E); absent resolves to conf line, then ClientDefaults.
    #[serde(rename = "Jc", default)]
    pub jc: Option<i64>,
    #[serde(rename = "Jmin", default)]
    pub jmin: Option<i64>,
    #[serde(rename = "Jmax", default)]
    pub jmax: Option<i64>,
    /// Junk-before-initiation / -before-response sizes (must-match,
    /// required — an epoch always carries the full must-match snapshot).
    #[serde(rename = "S1")]
    pub s1: i64,
    #[serde(rename = "S2")]
    pub s2: i64,
    /// Junk-before-cookie size — v3.1 must-match, `Option` so pre-3.1 epochs
    /// decode (absent = preserve; explicit `0` is the remove-signal).
    #[serde(rename = "S3", default)]
    pub s3: Option<i64>,
    #[serde(rename = "S4")]
    pub s4: i64,
    /// Initiation/response/cookie/data message-type tags (must-match,
    /// required). v2 accepts `123` or `"123-456"` — see [`IntOrRange`].
    #[serde(rename = "H1")]
    pub h1: IntOrRange,
    #[serde(rename = "H2")]
    pub h2: IntOrRange,
    #[serde(rename = "H3")]
    pub h3: IntOrRange,
    #[serde(rename = "H4")]
    pub h4: IntOrRange,
    /// Junk-packet tag literals — edge-side validation is charset guard +
    /// the upstream `newObfChain` tag grammar (see [`validate_i_tag`]).
    #[serde(rename = "I1", default)]
    pub i1: Option<String>,
    #[serde(rename = "I2", default)]
    pub i2: Option<String>,
    #[serde(rename = "I3", default)]
    pub i3: Option<String>,
    #[serde(rename = "I4", default)]
    pub i4: Option<String>,
    #[serde(rename = "I5", default)]
    pub i5: Option<String>,
    /// base64(32B) header-protection key (must-match). base64(32 zeros) is
    /// the legal explicit-OFF signal — "off" means a real 32-byte key of
    /// zeros, not a missing value (D4).
    #[serde(rename = "HeaderProtectionKey", default)]
    pub header_protection_key: Option<String>,
    /// `N` or `N-M` padding range appended to data packets (client-side:
    /// edge-defaulted when absent from epoch AND conf, overridable by epoch).
    #[serde(rename = "ContentPaddingAddition", default)]
    pub content_padding_addition: Option<String>,
    /// Timing ranges — `N` or `N-M` seconds (client-side, central-emitted
    /// only; NEVER edge-generated per D1 — band correlations are the
    /// riskiest DPI fingerprint for the least gain).
    #[serde(rename = "RekeyAfterTime", default)]
    pub rekey_after_time: Option<String>,
    #[serde(rename = "RekeyTimeout", default)]
    pub rekey_timeout: Option<String>,
    #[serde(rename = "RejectAfterTime", default)]
    pub reject_after_time: Option<String>,
    #[serde(rename = "KeepaliveTimeout", default)]
    pub keepalive_timeout: Option<String>,
    #[serde(rename = "MaxHandshakeAttempts", default)]
    pub max_handshake_attempts: Option<String>,
    /// Random trailer bytes appended to data packets (must-match — the flag
    /// is wire-unsafe one-sided: an RT-on peer still SENDS trailers that an
    /// RT-off receiver's exact-size gate drops).
    #[serde(rename = "RandomTrailers", default)]
    pub random_trailers: Option<bool>,
    /// Inbound-only cookie-DoS gate (client-side; inert on outbound-only
    /// spoke edges — absent = cookies on = the mitigation stays).
    #[serde(rename = "DisableCookies", default)]
    pub disable_cookies: Option<bool>,
}

/// An H-class message-type value: either a single tag `123` or an inclusive
/// range `123-456`. The epoch JSON carries the bare number or the bare
/// string (`"H1": 123` vs `"H1": "123-456"`) — untagged, and motherly must
/// match this shape byte-for-byte (ADR-004).
///
/// Decode is deliberately SHAPE-only (`\d+` or `\d+-\d+` plus negatives so
/// they can be named): out-of-band values like `"5-3"` or `3` stay
/// representable so the FIELD_SPECS grammar check rejects them with a
/// `field=hN` marker (metrics.rs `param_rejected_total`) instead of dying
/// here as a field-less decode error. Truly unrepresentable JSON (garbage
/// strings, arrays, floats) still fails the whole poll response — fail
/// closed via the decode path.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IntOrRange {
    Single(i64),
    Range { lo: i64, hi: i64 },
}

impl IntOrRange {
    /// Parse `123` or `123-456`. Shape-only — see the enum's doc comment for
    /// why grammar bounds are NOT enforced here. Returns `Err` on any other
    /// shape (non-digit members, extra `-` separators, empty parts).
    pub(crate) fn parse(s: &str) -> Result<Self> {
        let parse_part = |part: &str| {
            part.parse::<i64>()
                .map_err(|_| anyhow!("bad IntOrRange member {part:?} in {s:?}"))
        };
        match s.split_once('-') {
            Some((lo, hi)) => Ok(IntOrRange::Range {
                lo: parse_part(lo)?,
                hi: parse_part(hi)?,
            }),
            None => Ok(IntOrRange::Single(parse_part(s)?)),
        }
    }
}

impl<'de> Deserialize<'de> for IntOrRange {
    fn deserialize<D>(deserializer: D) -> std::result::Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        // Untagged decode: JSON number → Single, JSON string → parse.
        #[derive(Deserialize)]
        #[serde(untagged)]
        enum Repr {
            Num(i64),
            Str(String),
        }
        match Repr::deserialize(deserializer)? {
            Repr::Num(n) => Ok(IntOrRange::Single(n)),
            Repr::Str(s) => IntOrRange::parse(&s).map_err(serde::de::Error::custom),
        }
    }
}

impl Serialize for IntOrRange {
    fn serialize<S>(&self, serializer: S) -> std::result::Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        match *self {
            IntOrRange::Single(n) => serializer.serialize_i64(n),
            IntOrRange::Range { lo, hi } => serializer.serialize_str(&format!("{lo}-{hi}")),
        }
    }
}

/// Characters forbidden in ANY central-sourced conf string value.
///
/// `\n`/`\r` = the line-break primitive (start a new conf directive);
/// `[`/`]` = the section-header primitive (open a `[Peer]`/`[Interface]`
/// block). A hostile or MITM'd central server (the TLS+bearer transport
/// authenticates the connection, NOT the field content) could otherwise set
/// a multi-line string field whose embedded newline + `[Peer]` header
/// splices an attacker peer (`AllowedIPs = 0.0.0.0/0`, `Endpoint =
/// attacker`) into the kernel WireGuard peer table when the merged conf is
/// piped through `awg-quick strip | awg syncconf` (see `agent.rs` apply
/// path). Legit AWG values — I-tag literals (`<r N><b 0xHH>...`), base64
/// HPK, `N-M` ranges — are single-line and contain none of these.
///
/// Generalized in v2 from the original I1-only guard: EVERY string field
/// shares this single grammar authority so no central-sourced byte reaches
/// the conf unscreened (security#1/boundaries#2). Mirrors the
/// newline-reject guard shipped for the sibling central-sourced secret in
/// `opec/src/secrets/sfu_key.rs` — applied here to a FAR more sensitive
/// target (the kernel peer table).
const FORBIDDEN_CONF_CHARS: &[char] = &['\n', '\r', '[', ']'];

/// Reject a central-sourced conf string carrying any conf-injection
/// primitive. Shared by every `Option<String>` field in the FIELD_SPECS
/// table — public so the splice site (`conf_merge`) shares this single
/// grammar authority rather than re-deriving the charset.
///
/// A rejection is a hostile-central / MITM signal. This function's contract
/// is to reject and to NAME the field in the returned error — the error
/// carries the stable `field=<name>` marker so the log/metrics extractor
/// (`metrics::extract_rejected_field`) can key on it. No counter is bumped
/// here; the agent records `param_rejected_total{field=...}` at the merge
/// call site.
pub fn validate_conf_string(field: &'static str, value: &str) -> Result<()> {
    if let Some(bad) = value.chars().find(|c| FORBIDDEN_CONF_CHARS.contains(c)) {
        return Err(anyhow!(
            "awg param rejected: field={} contains forbidden character {:?} \
             (conf-injection guard) — refusing to splice into awg0.conf",
            field,
            bad
        ));
    }
    Ok(())
}

/// Junk-trio grammar: `jc`/`jmin`/`jmax` are `ParseUint(value, 10, 32)`
/// upstream (device/uapi.go handleDeviceLine @ v3.1) — `0..=4294967295`.
/// A negative or >u32 value fails `awg syncconf` with IpcErrorInvalid,
/// leaving the device half-configured. The `jmin <= jmax` pair invariant is
/// checked cross-field in conf_merge — upstream never checks it at uapi
/// time; it detonates later inside `Device.JunkPackets()`
/// (`min + fastrandn(max-min)` underflows uint32 to a ~4GiB allocation).
pub fn validate_junk_value(field: &'static str, n: i64) -> Result<()> {
    if !(0..=u32::MAX as i64).contains(&n) {
        return Err(anyhow!(
            "awg param rejected: field={} value {} outside junk grammar 0..={} \
             (upstream ParseUint(10,32)) — refusing to splice into awg0.conf",
            field,
            n,
            u32::MAX
        ));
    }
    Ok(())
}

/// I-tag grammar — a mirror of upstream `newObfChain` (device/obf.go @
/// v3.1). The spec is a sequence of `<key [arg]>` tags; text between tags is
/// ignored upstream. Known keys: `b` `t` `r` `rc` `rd` `d` `ds` `dz`.
/// Per-tag arg grammar (upstream builders, device/obf_*.go):
///
/// - `b` — hex string, `0x` prefix optional, non-empty, even digit count
/// - `r`/`rc`/`rd`/`dz` — non-negative integer length (upstream accepts any
///   `Atoi` value, but a negative then PANICS the daemon at send —
///   `dst[:n]` on n<0 — so the edge bound is deliberately stricter than
///   upstream's parser)
/// - `t`/`d`/`ds` — arg ignored upstream
///
/// An unknown key, an empty `<>`, an unterminated `<`, or a malformed arg
/// errors out the WHOLE `awg syncconf` set op (IpcErrorInvalid) — the conf
/// the agent just wrote is then un-appliable. A value with no `<` at all
/// parses to an inert nil chain upstream — meaningless config, rejected.
pub fn validate_i_tag(field: &'static str, value: &str) -> Result<()> {
    validate_conf_string(field, value)?;
    if value.is_empty() {
        // Absent-equivalent — upstream parses "" to a nil chain; nothing to
        // validate. Callers treat Some("") as absent anyway.
        return Ok(());
    }
    let reject = |reason: String| -> Result<()> {
        Err(anyhow!(
            "awg param rejected: field={} value {:?} {} — refusing to splice into awg0.conf",
            field,
            value,
            reason
        ))
    };
    let mut rest = value;
    let mut saw_tag = false;
    while let Some(start) = rest.find('<') {
        let Some(end) = rest[start..].find('>') else {
            return reject("has an unterminated `<` (upstream: missing enclosing >)".to_string());
        };
        let end = start + end;
        let tag = &rest[start + 1..end];
        let mut parts = tag.split_whitespace();
        let Some(key) = parts.next() else {
            return reject("has an empty `<>` tag".to_string());
        };
        let arg = parts.next();
        saw_tag = true;
        match key {
            "b" => {
                let Some(arg) = arg else {
                    return reject("tag <b> requires a hex argument".to_string());
                };
                let digits = arg.strip_prefix("0x").unwrap_or(arg);
                if digits.is_empty()
                    || digits.len() % 2 != 0
                    || !digits.chars().all(|c| c.is_ascii_hexdigit())
                {
                    return reject(
                        "tag <b> argument must be non-empty even-length hex".to_string(),
                    );
                }
            }
            "r" | "rc" | "rd" | "dz" => {
                let Some(arg) = arg else {
                    return reject(format!("tag <{key}> requires a length argument"));
                };
                match arg.parse::<u64>() {
                    Ok(n) if n <= 65535 => {}
                    _ => {
                        return reject(format!(
                            "tag <{key}> argument must be a length in 0..=65535 \
                             (upstream Atoi accepts negatives that panic the daemon at send)"
                        ))
                    }
                }
            }
            "t" | "d" | "ds" => {}
            other => return reject(format!("has unknown tag <{other}>")),
        }
        rest = &rest[end + 1..];
    }
    if !saw_tag {
        return reject(
            "contains no <tag> elements (upstream parses it to an inert nil chain)".to_string(),
        );
    }
    Ok(())
}

/// S-class junk-size grammar: u16 range `0..=65535` (upstream S fields are
/// 16-bit padding sizes). `0` is legal — it's the D4 zero-form
/// remove-signal and means "no junk padding" on the wire.
pub fn validate_s_value(field: &'static str, n: i64) -> Result<()> {
    if !(0..=65535).contains(&n) {
        return Err(anyhow!(
            "awg param rejected: field={} value {} outside S grammar 0..=65535 \
             (u16 junk-size bound) — refusing to splice into awg0.conf",
            field,
            n
        ));
    }
    Ok(())
}

/// H-class message-type grammar: every bound in `5..=4294967295` (u32) and
/// `lo <= hi`. Bounds 1-4 are the vanilla WireGuard message types — an H
/// value there would shadow real packet types; the u32 ceiling is the wire
/// width of the type field.
pub fn validate_h_value(field: &'static str, v: IntOrRange) -> Result<()> {
    let (lo, hi) = match v {
        IntOrRange::Single(n) => (n, n),
        IntOrRange::Range { lo, hi } => (lo, hi),
    };
    if lo < 5 || hi > 4_294_967_295 || lo > hi {
        return Err(anyhow!(
            "awg param rejected: field={} range {lo}-{hi} violates H grammar \
             (need 5 <= lo <= hi <= 4294967295; 1-4 are vanilla WG message types) \
             — refusing to splice into awg0.conf",
            field
        ));
    }
    Ok(())
}

/// Timing/CPA range grammar: `N` or `N-M` with `lo <= hi` — the
/// `^\d+(-\d+)?$` shape upstream's `a-b` seconds/padding ranges take.
/// Charset guard runs first (a range value can never legitimately carry
/// `\n`/`\r`/`[`/`]`); then digit-shape + ordering. u64-parseable only —
/// overflow rejects as a grammar failure.
pub fn validate_range_string(field: &'static str, value: &str) -> Result<()> {
    validate_conf_string(field, value)?;
    let (lo_s, hi_s) = match value.split_once('-') {
        Some((lo, hi)) => (lo, hi),
        None => (value, value),
    };
    let digits = |s: &str| !s.is_empty() && s.chars().all(|c| c.is_ascii_digit());
    if digits(lo_s) && digits(hi_s) {
        if let (Ok(lo), Ok(hi)) = (lo_s.parse::<u64>(), hi_s.parse::<u64>()) {
            if lo <= hi {
                return Ok(());
            }
        }
    }
    Err(anyhow!(
        "awg param rejected: field={} value {:?} is not a `N`/`N-M` range with \
         lo <= hi — refusing to splice into awg0.conf",
        field,
        value
    ))
}

/// HPK grammar: the value must base64-decode to exactly 32 bytes — the wire
/// width of the header-protection key upstream XORs into the type field.
/// The all-zero key is LEGAL: it's the D4 explicit remove-signal, not a
/// validation failure. Returns the decoded key so callers can distinguish
/// live-key from off-signal without re-decoding.
pub fn decode_hpk(field: &'static str, value: &str) -> Result<[u8; 32]> {
    // Charset first: base64 itself would reject the forbidden bytes anyway,
    // but the injection-shaped error message is the better signal and the
    // uniform ordering keeps every string field on one guard contract.
    validate_conf_string(field, value)?;
    let bytes = BASE64.decode(value).map_err(|e| {
        anyhow!(
            "awg param rejected: field={} value is not valid base64 ({e}) \
             — refusing to splice into awg0.conf",
            field
        )
    })?;
    <[u8; 32]>::try_from(bytes.as_slice()).map_err(|_| {
        anyhow!(
            "awg param rejected: field={} base64-decodes to {} bytes, need \
             exactly 32 — refusing to splice into awg0.conf",
            field,
            bytes.len()
        )
    })
}

/// Whether a resolved HPK string means header protection is ON.
/// `false` only for the base64(32-zeros) off-signal; an UNDECODABLE
/// non-empty value counts as active — motherly would treat those bytes as a
/// key, so the post-merge `S >= 12` precondition must hold for it too
/// (fail closed).
pub fn hpk_is_active(value: &str) -> bool {
    match BASE64.decode(value) {
        Ok(b) => !(b.len() == 32 && b.iter().all(|x| *x == 0)),
        Err(_) => true,
    }
}

/// Response shape from `GET /api/partner/awg-params/latest?component=awg&schema=2`.
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

    /// A baseline valid v2 params set — every required field populated, all
    /// Option fields absent (the pre-3.1 epoch shape minus nothing).
    fn base_params() -> AwgParams {
        AwgParams {
            jc: Some(11),
            jmin: Some(50),
            jmax: Some(1000),
            s1: 17,
            s2: 18,
            s3: None,
            s4: 18,
            h1: IntOrRange::Single(123456789),
            h2: IntOrRange::Single(234567890),
            h3: IntOrRange::Single(345678901),
            h4: IntOrRange::Single(456789012),
            i1: None,
            i2: None,
            i3: None,
            i4: None,
            i5: None,
            header_protection_key: None,
            content_padding_addition: None,
            rekey_after_time: None,
            rekey_timeout: None,
            reject_after_time: None,
            keepalive_timeout: None,
            max_handshake_attempts: None,
            random_trailers: None,
            disable_cookies: None,
        }
    }

    /// A legit single-line angle-bracket I1 value must validate clean.
    #[test]
    fn validate_accepts_legit_single_line_i1() {
        let ok = "<r 2><b 0x0100><b 0x0001><b 0x0000><b 0x0000><b 0x0000>";
        assert!(
            validate_conf_string("i1", ok).is_ok(),
            "legit I1 rejected: {ok:?}"
        );
        assert!(validate_conf_string("i1", ok).is_ok());
    }

    /// Empty strings carry no injection surface — they pass the charset
    /// guard (downstream treats `Some("")` as absent anyway).
    #[test]
    fn validate_accepts_empty_string() {
        assert!(validate_conf_string("i1", "").is_ok());
        assert!(validate_conf_string("i2", "").is_ok());
    }

    /// FINDING REPRO (crypto_invariant/critical): a multi-line string
    /// carrying an embedded `[Peer]` block with a wildcard AllowedIPs +
    /// attacker Endpoint MUST be rejected — otherwise it splices an
    /// attacker peer into the kernel WireGuard peer table via
    /// `awg-quick strip | awg syncconf`.
    #[test]
    fn validate_rejects_multiline_peer_injection() {
        let malicious = "<r 2><b 0x0100>\n\
                         [Peer]\n\
                         PublicKey = ATTACKERAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n\
                         AllowedIPs = 0.0.0.0/0\n\
                         Endpoint = attacker.example.com:51820";
        assert!(
            validate_conf_string("i1", malicious).is_err(),
            "multi-line [Peer] injection must be REJECTED"
        );
    }

    /// The injection guard now covers EVERY string field — one shared
    /// helper, one charset, `field=<name>` on every rejection so the
    /// metrics extractor labels each field separately.
    #[test]
    fn validate_rejects_injection_on_every_string_field() {
        let bad = "x\n[Peer]";
        for field in [
            "i1",
            "i2",
            "i3",
            "i4",
            "i5",
            "header_protection_key",
            "content_padding_addition",
            "rekey_after_time",
            "rekey_timeout",
            "reject_after_time",
            "keepalive_timeout",
            "max_handshake_attempts",
        ] {
            let err = validate_conf_string(field, bad).unwrap_err().to_string();
            assert!(
                err.contains(&format!("field={field}")),
                "rejection must name field={field}, got: {err}"
            );
        }
    }

    /// Each individual injection primitive is rejected on its own — newline,
    /// carriage return, and the `[`/`]` section-header brackets.
    #[test]
    fn validate_rejects_each_forbidden_char() {
        for bad in ["a\nb", "a\rb", "<r 2>[", "<r 2>]"] {
            assert!(
                validate_conf_string("i1", bad).is_err(),
                "forbidden-char value must be rejected: {bad:?}"
            );
        }
    }

    /// The rejection error names the field so the exporter can label
    /// `awg_params_agent_param_rejected_total{field="i1"}`.
    #[test]
    fn validate_error_names_field_i1() {
        let err = validate_conf_string("i1", "boom\n[Peer]")
            .unwrap_err()
            .to_string();
        assert!(
            err.contains("field=i1"),
            "rejection error must carry field=i1 for the counter label, got: {err}"
        );
    }

    // ── S-class grammar (u16) ────────────────────────────────────────────

    #[test]
    fn s_value_grammar_matrix() {
        for ok in [0, 1, 56, 65535] {
            assert!(validate_s_value("s1", ok).is_ok(), "{ok} must pass");
        }
        for (bad, field) in [(-1, "s1"), (65536, "s2"), (i64::MAX, "s3")] {
            let err = validate_s_value(field, bad).unwrap_err().to_string();
            assert!(
                err.contains(&format!("field={field}")),
                "{bad} must reject with field={field}, got: {err}"
            );
        }
    }

    // ── H-class grammar (u32 range, lo >= 5) ─────────────────────────────

    #[test]
    fn h_value_grammar_matrix() {
        assert!(validate_h_value("h1", IntOrRange::Single(123456789)).is_ok());
        assert!(validate_h_value("h1", IntOrRange::Single(5)).is_ok());
        assert!(
            validate_h_value(
                "h1",
                IntOrRange::Range {
                    lo: 5,
                    hi: 4_294_967_295
                }
            )
            .is_ok(),
            "full-width u32 range must pass"
        );
        // 1-4 are vanilla WireGuard message types — must reject.
        for bad in [
            IntOrRange::Single(4),
            IntOrRange::Single(0),
            IntOrRange::Single(-7),
            IntOrRange::Range { lo: 4, hi: 100 },
            IntOrRange::Range { lo: 100, hi: 50 }, // lo > hi
            IntOrRange::Range {
                lo: 5,
                hi: 4_294_967_296,
            }, // past u32 max
            IntOrRange::Single(4_294_967_296),
        ] {
            let err = validate_h_value("h2", bad).unwrap_err().to_string();
            assert!(
                err.contains("field=h2"),
                "{bad:?} must reject with field=h2, got: {err}"
            );
        }
    }

    // ── Timing/CPA range grammar (`N` or `N-M`, lo <= hi) ────────────────

    #[test]
    fn range_string_grammar_matrix() {
        for ok in ["100", "100-140", "0", "8-64", "3-6"] {
            assert!(
                validate_range_string("rekey_after_time", ok).is_ok(),
                "{ok:?} must pass"
            );
        }
        for bad in [
            "",
            "abc",
            "10-5",
            "5-10-15",
            "-5",
            "5-",
            "5 -10",
            "99999999999999999999999-99999999999999999999999",
        ] {
            let err = validate_range_string("content_padding_addition", bad)
                .unwrap_err()
                .to_string();
            assert!(
                err.contains("field=content_padding_addition"),
                "{bad:?} must reject with field=, got: {err}"
            );
        }
    }

    // ── HPK grammar (base64 → exactly 32 bytes; all-zero = legal off) ────

    #[test]
    fn hpk_grammar_matrix() {
        let good = BASE64.encode([7u8; 32]);
        assert_eq!(
            decode_hpk("header_protection_key", &good).unwrap(),
            [7u8; 32]
        );
        // All-zero key = the explicit D4 off-signal — must validate.
        let zeros = BASE64.encode([0u8; 32]);
        assert_eq!(
            decode_hpk("header_protection_key", &zeros).unwrap(),
            [0u8; 32],
            "zero key is the legal off-signal"
        );
        for bad in [
            BASE64.encode([1u8; 16]), // 16 bytes — wrong width
            BASE64.encode([1u8; 33]), // 33 bytes
            "not base64!!!".to_string(),
            String::new(),
        ] {
            let err = decode_hpk("header_protection_key", &bad)
                .unwrap_err()
                .to_string();
            assert!(
                err.contains("field=header_protection_key"),
                "{bad:?} must reject with field=header_protection_key, got: {err}"
            );
        }
    }

    #[test]
    fn hpk_is_active_distinguishes_live_zero_and_garbage() {
        assert!(hpk_is_active(&BASE64.encode([7u8; 32])));
        assert!(!hpk_is_active(&BASE64.encode([0u8; 32])));
        // Undecodable counts as active — fail closed on the precondition.
        assert!(hpk_is_active("!!!not-base64!!!"));
    }

    // ── IntOrRange serde ─────────────────────────────────────────────────

    /// Both epoch-JSON forms: `"H1": 123` (number) and `"H1": "123-456"`
    /// (string) decode; `"H1": "123"` (bare-numeric string) is tolerated to
    /// the same single-int value.
    #[test]
    fn int_or_range_decodes_number_and_range_string() {
        let single: IntOrRange = serde_json::from_str("123").unwrap();
        assert_eq!(single, IntOrRange::Single(123));
        let range: IntOrRange = serde_json::from_str("\"123-456\"").unwrap();
        assert_eq!(range, IntOrRange::Range { lo: 123, hi: 456 });
        let bare: IntOrRange = serde_json::from_str("\"123\"").unwrap();
        assert_eq!(bare, IntOrRange::Single(123));
    }

    /// Grammar-invalid but shape-valid values still decode — the FIELD_SPECS
    /// grammar layer must get the chance to name the field.
    #[test]
    fn int_or_range_decodes_inverted_range_for_field_naming() {
        let v: IntOrRange = serde_json::from_str("\"50-5\"").unwrap();
        assert_eq!(v, IntOrRange::Range { lo: 50, hi: 5 });
        assert!(validate_h_value("h3", v).is_err());
    }

    /// Round-trip: Single → number, Range → "lo-hi" string.
    #[test]
    fn int_or_range_serializes_both_forms() {
        assert_eq!(serde_json::to_string(&IntOrRange::Single(7)).unwrap(), "7");
        assert_eq!(
            serde_json::to_string(&IntOrRange::Range { lo: 7, hi: 9 }).unwrap(),
            "\"7-9\""
        );
    }

    /// Backward compat: a pre-v2 epoch (11 numeric fields, H as bare
    /// numbers, no new keys) must decode with all v2 Options = None — old
    /// DB rows / schema-1 epochs keep working identically (D4/D6).
    #[test]
    fn v1_epoch_json_decodes_with_v2_fields_none() {
        let json = r#"{"Jc":11,"Jmin":50,"Jmax":1000,"S1":17,"S2":18,"S4":18,
                      "H1":123456789,"H2":234567890,"H3":345678901,"H4":456789012}"#;
        let p: AwgParams = serde_json::from_str(json).unwrap();
        assert_eq!(p.jc, Some(11));
        assert_eq!(p.s1, 17);
        assert_eq!(p.h1, IntOrRange::Single(123456789));
        assert!(p.s3.is_none());
        assert!(p.header_protection_key.is_none());
        assert!(p.random_trailers.is_none());
        assert!(p.i2.is_none() && p.i5.is_none());
        assert!(p.content_padding_addition.is_none());
        assert!(p.rekey_after_time.is_none() && p.max_handshake_attempts.is_none());
        assert!(p.disable_cookies.is_none());
    }

    /// Phase E readiness: a v2 epoch that omits the jc trio decodes with
    /// them as None (the merge then resolves conf-line → default).
    #[test]
    fn epoch_without_jc_trio_decodes() {
        let json = r#"{"S1":17,"S2":18,"S4":18,
                      "H1":"5-10","H2":20,"H3":30,"H4":40}"#;
        let p: AwgParams = serde_json::from_str(json).unwrap();
        assert!(p.jc.is_none() && p.jmin.is_none() && p.jmax.is_none());
        assert_eq!(p.h1, IntOrRange::Range { lo: 5, hi: 10 });
        assert_eq!(p.h2, IntOrRange::Single(20));
    }

    /// base_params stays a compile-time anchor that every field exists.
    #[test]
    fn base_params_is_constructible() {
        let p = base_params();
        assert_eq!(p.s2, 18);
    }

    // ── Junk-trio grammar (u32 — upstream ParseUint(10,32)) ─────────────

    #[test]
    fn junk_value_grammar_matrix() {
        for ok in [0, 1, 3, 1024, u32::MAX as i64] {
            assert!(validate_junk_value("jc", ok).is_ok(), "{ok} must pass");
        }
        for (bad, field) in [
            (-1, "jc"),
            (-1000, "jmin"),
            (u32::MAX as i64 + 1, "jmax"),
            (i64::MAX, "jc"),
        ] {
            let err = validate_junk_value(field, bad).unwrap_err().to_string();
            assert!(
                err.contains(&format!("field={field}")),
                "{bad} must reject with field={field}, got: {err}"
            );
        }
    }

    // ── I-tag grammar (mirror of upstream newObfChain @ v3.1) ────────────

    #[test]
    fn i_tag_grammar_accepts_legit_chains() {
        for ok in [
            // The documented WG-initiation-mimic signature.
            "<r 2><b 0x0100><b 0x0001><b 0x0000><b 0x0000><b 0x0000>",
            "<r 128>",               // generated ClientDefaults shape
            "<t>",                   // timestamp tag, arg ignored
            "<d><ds>",               // data passthrough / base64 string
            "<rc 16><rd 4><dz 8>",   // char/digit/datasize tags
            "<b 0100>",              // hex without 0x prefix is legal upstream
            "junk between <r 5> ok", // inter-tag text is ignored upstream
            "",                      // empty = absent-equivalent
        ] {
            assert!(
                validate_i_tag("i1", ok).is_ok(),
                "{ok:?} must pass the tag grammar"
            );
        }
    }

    /// Every wedge shape upstream `newObfChain` errors on — plus the
    /// negative-length form upstream parses but then panics on at send.
    #[test]
    fn i_tag_grammar_rejects_wedge_shapes() {
        for bad in [
            "arbitrary string", // no <tag> at all → inert nil chain
            "<bogus>",          // unknown tag key
            "<r",               // unterminated tag
            "<>",               // empty tag
            "<r>",              // missing arg
            "<r abc>",          // non-numeric arg
            "<r -5>",           // negative — upstream Atoi accepts, daemon PANICS
            "<r 99999>",        // over the 65535 edge bound
            "<b>",              // b requires hex arg
            "<b 0x123>",        // odd hex length
            "<b 0xzz>",         // non-hex
            "<b 0x>",           // empty hex
            "<r 5>bad<q 1>",    // unknown tag mid-chain
        ] {
            let err = validate_i_tag("i2", bad).unwrap_err().to_string();
            assert!(
                err.contains("field=i2"),
                "{bad:?} must reject with field=i2, got: {err}"
            );
        }
    }
}
