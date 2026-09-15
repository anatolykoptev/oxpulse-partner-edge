//! Pure conf-merge logic: table-driven replace-or-insert of AWG obfuscation
//! params in an `awg0.conf` string while leaving everything else
//! byte-identical.
//!
//! v2 rework (ADR-004, decisions D1/D3/D5): `FIELD_SPECS` is the D1
//! sourcing-policy table made reviewable DATA — one row per mergeable key
//! carrying its conf spelling (= the epoch-JSON member name), its conf
//! section (all `[Interface]`-only by upstream grammar, config.c:520-581),
//! its merge class (must-match vs client-side — that IS the reject-mode),
//! its grammar validator, and its default source.
//!
//! The merge pipeline is resolve-effective → validate → splice:
//!   * RESOLVE: each key's effective value = epoch `Some` > existing conf
//!     line > default/0. This is the only form in which the post-merge
//!     cross-field preconditions are expressible — a pre-merge params-only
//!     validate cannot see conf-carried S values ("HPK present ⇒ all
//!     S1-S4 ≥ 12" needs the POST-merge set; boundaries#3).
//!   * VALIDATE: charset+grammar on every value about to be WRITTEN, plus
//!     cross-field preconditions on the resolved set mirroring upstream
//!     `mergeWithDevice` (checked BEFORE any Store there — a bad epoch is
//!     rejected atomically here, never partially applied).
//!   * SPLICE: write = replace-or-insert preserving `[Interface]` placement;
//!     absent = preserve the existing line. There is NO delete path —
//!     syncconf can't clear a kernel param by omission (ipc-uapi.h), so
//!     removal is expressed by central's explicit zero-forms (D4).
//!
//! Failure split per class (D5): a must-match validation or precondition
//! failure rejects the WHOLE merge with a `field=` error (fail closed — a
//! partially-applied must-match set is a dead link anyway); a client-side
//! failure omits ONLY that field (degrade the feature, keep the link) and
//! logs a warning.
//!
//! Absent params are INSERTED into the `[Interface]` section rather than
//! erroring — edges are dumb caches (roadmap invariant), so a bootstrap-only
//! conf carrying no obfuscation params is valid input. Peer sections are
//! untouched because WireGuard peer keys are base64. (Section scoping is
//! deliberately NOT enforced on replace — the deferred YAGNI from the spec
//! risk table; the `apply_failures_total` metric makes the stray-line stall
//! visible instead.)

use crate::error::{anyhow, Context, Result};
use crate::params::{self, AwgParams, IntOrRange};
use once_cell::sync::Lazy;
use regex::Regex;
use std::collections::HashMap;
use tracing::warn;

/// The D1 sourcing-policy axis — what a validation failure on this field
/// costs. The class IS the reject-mode.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum MergeClass {
    /// MUST-MATCH, central-sourced only (S/H/HPK/RT): the two ends of the
    /// wire must agree byte-for-byte or the link is dead, so a bad value
    /// rejects the whole merge — fail closed, never partially apply.
    MustMatch,
    /// CLIENT-SIDE (jc trio, I-tags, CPA, timings, DisableCookies): may
    /// legitimately differ per edge without breaking the wire, so a bad
    /// value omits ONLY this field — degrade the feature, keep the link.
    ClientSide,
}

/// The conf section a spec'd key is legal in. Upstream grammar makes every
/// mergeable key `[Interface]`-only (config.c:520-581); the column is data
/// so a future peer-scoped key (e.g. PersistentKeepalive) visibly violates
/// the assumption at review time instead of hiding it in control flow.
/// The splice reads it to pick the insert target (inserts group by section).
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub(crate) enum Section {
    Interface,
}

impl Section {
    /// Section-header line matcher — the insert target for absent keys.
    fn header_re(&self) -> &'static Regex {
        match self {
            Section::Interface => &AWG_INTERFACE_RE,
        }
    }
}

/// Which grammar validator a spec'd field gets — the "validator" column of
/// the D1 table, expressed as data so the test matrix can enumerate it.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum SpecKind {
    /// u16 junk-size class (S1-S4): `0..=65535`.
    SInt,
    /// u32 message-type class (H1-H4): IntOrRange, `5 <= lo <= hi <=
    /// 4294967295`; 1-4 are the vanilla WireGuard message types.
    HRange,
    /// `N` or `N-M` seconds/padding range (the five timings + CPA).
    RangeString,
    /// Opaque junk-tag literal (I1-I5): charset guard only — the tag
    /// grammar is upstream's, the edge never interprets it.
    TagLiteral,
    /// base64(32B) header-protection key; all-zero = the legal off-signal.
    HeaderProtectionKey,
    /// `on`/`off` (RandomTrailers, DisableCookies). `Option<bool>` is a
    /// total type — the bool itself is the grammar.
    OnOff,
    /// Uninterpreted i64 (the jc trio) — the contract carries no grammar
    /// layer for these; rendered as digits, exactly as the v1 merge did.
    JunkCount,
}

/// A resolved value for one spec'd key — the currency of the
/// resolve→validate→splice pipeline.
#[derive(Clone, Debug, PartialEq)]
pub(crate) enum FieldValue {
    /// Numeric literal (S/Jc classes, single-int H).
    Int(i64),
    /// Inclusive `lo-hi` range (H ranges only — timing/CPA ranges stay
    /// string-typed end-to-end since no cross-field precondition reads
    /// them, and verbatim rendering preserves central's spelling).
    Range(i64, i64),
    /// Opaque string literal (I-tags, HPK, timing/CPA ranges).
    Str(String),
    /// on/off (RandomTrailers, DisableCookies).
    Bool(bool),
}

impl From<IntOrRange> for FieldValue {
    fn from(v: IntOrRange) -> Self {
        match v {
            IntOrRange::Single(n) => FieldValue::Int(n),
            IntOrRange::Range { lo, hi } => FieldValue::Range(lo, hi),
        }
    }
}

/// One row of the D1 sourcing table — every mergeable conf key and the
/// policy it follows.
pub(crate) struct FieldSpec {
    /// Conf key spelling — also the epoch-JSON member name (the PascalCase
    /// convention is one name on both surfaces per ADR-004).
    pub(crate) key: &'static str,
    /// snake_case `AwgParams` field name — the `field=` marker in errors and
    /// the `param_rejected_total{field=...}` label.
    pub(crate) field: &'static str,
    /// Conf section the key is legal in (all Interface today).
    pub(crate) section: Section,
    /// Sourcing class — drives the reject-mode (must-match ⇒ reject the
    /// whole merge; client-side ⇒ omit just this field).
    pub(crate) class: MergeClass,
    /// Grammar validator.
    pub(crate) kind: SpecKind,
    /// Extract this field's epoch value (`None` = absent OR empty-string —
    /// the v1 I1 rule, kept uniform so `"I2": ""` from a writer regression
    /// can never stamp a malformed `I2 = ` line).
    pub(crate) epoch: fn(&AwgParams) -> Option<FieldValue>,
    /// Client-class default source — `None` for must-match fields (never
    /// edge-generated) and for central-only client fields (timings,
    /// DisableCookies, I2-I5 content — D1 forbids edge-defaulting them).
    pub(crate) default: fn(&ClientDefaults) -> Option<FieldValue>,
}

impl FieldSpec {
    /// Whitespace-tolerant line matcher `^Key[ \t]*=[ \t]*(value)$` —
    /// tolerates cosmetic hand-edits like `S1  =  17` so the replace path
    /// still finds the line instead of inserting a duplicate
    /// (boundaries#11).
    fn line_re(&self) -> &'static Regex {
        FIELD_LINE_RES
            .get(self.key)
            .expect("every FIELD_SPECS key has a compiled line regex")
    }

    /// Extract the current conf-line value for precondition resolution.
    /// Lenient by design: an unparseable or empty conf value yields `None`
    /// (treated as absent ⇒ 0 in cross-field checks — fail closed). The raw
    /// line is still preserved on the splice side; only precondition math
    /// consumes this parse.
    fn parse_conf_value(&self, raw: &str) -> Option<FieldValue> {
        let raw = raw.trim();
        if raw.is_empty() {
            return None;
        }
        match self.kind {
            SpecKind::SInt | SpecKind::JunkCount => raw.parse::<i64>().ok().map(FieldValue::Int),
            SpecKind::HRange => IntOrRange::parse(raw).ok().map(FieldValue::from),
            SpecKind::OnOff => match raw {
                "on" => Some(FieldValue::Bool(true)),
                "off" => Some(FieldValue::Bool(false)),
                _ => None,
            },
            // Presence is all the resolved set needs for string kinds — only
            // HPK feeds a precondition, and it inspects the raw string.
            SpecKind::TagLiteral | SpecKind::HeaderProtectionKey | SpecKind::RangeString => {
                Some(FieldValue::Str(raw.to_owned()))
            }
        }
    }

    /// Run this field's grammar validator over a value about to be WRITTEN
    /// (epoch-sourced or generated-default). Errors carry `field=<name>` —
    /// the marker the metrics extractor keys on.
    fn validate(&self, v: &FieldValue) -> Result<()> {
        match (self.kind, v) {
            (SpecKind::SInt, FieldValue::Int(n)) => params::validate_s_value(self.field, *n),
            (SpecKind::HRange, FieldValue::Int(n)) => {
                params::validate_h_value(self.field, IntOrRange::Single(*n))
            }
            (SpecKind::HRange, FieldValue::Range(lo, hi)) => {
                params::validate_h_value(self.field, IntOrRange::Range { lo: *lo, hi: *hi })
            }
            (SpecKind::RangeString, FieldValue::Str(s)) => {
                params::validate_range_string(self.field, s)
            }
            (SpecKind::TagLiteral, FieldValue::Str(s)) => params::validate_i_tag(self.field, s),
            (SpecKind::HeaderProtectionKey, FieldValue::Str(s)) => {
                params::decode_hpk(self.field, s).map(|_| ())
            }
            // `Option<bool>` is total — no grammar to violate.
            (SpecKind::OnOff, FieldValue::Bool(_)) => Ok(()),
            // u32 bound mirrors upstream `ParseUint(value, 10, 32)`; the
            // jmin<=jmax pair invariant is a post-merge precondition below.
            (SpecKind::JunkCount, FieldValue::Int(n)) => {
                params::validate_junk_value(self.field, *n)
            }
            _ => Err(anyhow!(
                "awg param rejected: field={} internal type mismatch — \
                 validator {:?} can't hold {:?} (table bug)",
                self.field,
                self.kind,
                v
            )),
        }
    }

    /// Render the conf line `Key = value` for a validated value.
    /// Bool → `on`/`off` (upstream `parse_bool`, config.c:414-445); a
    /// one-element range renders as the bare number (`50-50` ≡ `50` on the
    /// wire, and the bare spelling is the cleaner canonical form).
    fn render(&self, v: &FieldValue) -> String {
        match v {
            FieldValue::Int(n) => format!("{} = {}", self.key, n),
            FieldValue::Range(lo, hi) if lo == hi => format!("{} = {}", self.key, lo),
            FieldValue::Range(lo, hi) => format!("{} = {}-{}", self.key, lo, hi),
            FieldValue::Str(s) => format!("{} = {}", self.key, s),
            FieldValue::Bool(b) => {
                format!("{} = {}", self.key, if *b { "on" } else { "off" })
            }
        }
    }
}

/// Shared epoch-side accessor for `Option<String>` fields — the uniform
/// `Some("")` ⇒ `None` rule, mirroring the v1 Go-side `if params.I1 != ""`
/// skip so an empty-string writer regression can never stamp a malformed
/// `Key = ` line (the exact silent-drift class T1.3.x closed).
fn epoch_str(p: &AwgParams, get: fn(&AwgParams) -> &Option<String>) -> Option<FieldValue> {
    get(p)
        .as_deref()
        .filter(|s| !s.is_empty())
        .map(|s| FieldValue::Str(s.to_owned()))
}

/// The D1 sourcing table — every mergeable key, its class (reject-mode),
/// its grammar validator, and its default source. Order matters: absent
/// keys insert under `[Interface]` in table order. That order mirrors the
/// installer template (lib/install-awg.sh) EXCEPT `s3`, which the table
/// groups with its S-family (s1 s2 s3 s4) while the installer emits it at
/// the head of the optional block — same key, different line position;
/// conf semantics don't care, byte-diffs do, so call it out.
///
/// MUST-MATCH (central-sourced, never edge-generated): S1-S4, H1-H4,
/// HeaderProtectionKey, RandomTrailers.
/// CLIENT-SIDE edge-generated (D2's sole generator): I1, CPA, jc trio —
/// only when absent from epoch AND conf.
/// CLIENT-SIDE central-only (epoch Option, never edge-defaulted): I2-I5,
/// the five timing ranges, DisableCookies.
pub(crate) static FIELD_SPECS: &[FieldSpec] = &[
    FieldSpec {
        key: "Jc",
        field: "jc",
        section: Section::Interface,
        class: MergeClass::ClientSide,
        kind: SpecKind::JunkCount,
        epoch: |p| p.jc.map(FieldValue::Int),
        default: |d| Some(FieldValue::Int(d.jc)),
    },
    FieldSpec {
        key: "Jmin",
        field: "jmin",
        section: Section::Interface,
        class: MergeClass::ClientSide,
        kind: SpecKind::JunkCount,
        epoch: |p| p.jmin.map(FieldValue::Int),
        default: |d| Some(FieldValue::Int(d.jmin)),
    },
    FieldSpec {
        key: "Jmax",
        field: "jmax",
        section: Section::Interface,
        class: MergeClass::ClientSide,
        kind: SpecKind::JunkCount,
        epoch: |p| p.jmax.map(FieldValue::Int),
        default: |d| Some(FieldValue::Int(d.jmax)),
    },
    FieldSpec {
        key: "S1",
        field: "s1",
        section: Section::Interface,
        class: MergeClass::MustMatch,
        kind: SpecKind::SInt,
        epoch: |p| Some(FieldValue::Int(p.s1)),
        default: |_| None,
    },
    FieldSpec {
        key: "S2",
        field: "s2",
        section: Section::Interface,
        class: MergeClass::MustMatch,
        kind: SpecKind::SInt,
        epoch: |p| Some(FieldValue::Int(p.s2)),
        default: |_| None,
    },
    FieldSpec {
        key: "S3",
        field: "s3",
        section: Section::Interface,
        class: MergeClass::MustMatch,
        kind: SpecKind::SInt,
        epoch: |p| p.s3.map(FieldValue::Int),
        default: |_| None,
    },
    FieldSpec {
        key: "S4",
        field: "s4",
        section: Section::Interface,
        class: MergeClass::MustMatch,
        kind: SpecKind::SInt,
        epoch: |p| Some(FieldValue::Int(p.s4)),
        default: |_| None,
    },
    FieldSpec {
        key: "H1",
        field: "h1",
        section: Section::Interface,
        class: MergeClass::MustMatch,
        kind: SpecKind::HRange,
        epoch: |p| Some(FieldValue::from(p.h1)),
        default: |_| None,
    },
    FieldSpec {
        key: "H2",
        field: "h2",
        section: Section::Interface,
        class: MergeClass::MustMatch,
        kind: SpecKind::HRange,
        epoch: |p| Some(FieldValue::from(p.h2)),
        default: |_| None,
    },
    FieldSpec {
        key: "H3",
        field: "h3",
        section: Section::Interface,
        class: MergeClass::MustMatch,
        kind: SpecKind::HRange,
        epoch: |p| Some(FieldValue::from(p.h3)),
        default: |_| None,
    },
    FieldSpec {
        key: "H4",
        field: "h4",
        section: Section::Interface,
        class: MergeClass::MustMatch,
        kind: SpecKind::HRange,
        epoch: |p| Some(FieldValue::from(p.h4)),
        default: |_| None,
    },
    FieldSpec {
        key: "I1",
        field: "i1",
        section: Section::Interface,
        class: MergeClass::ClientSide,
        kind: SpecKind::TagLiteral,
        epoch: |p| epoch_str(p, |p| &p.i1),
        default: |d| Some(FieldValue::Str(d.i1.clone())),
    },
    FieldSpec {
        key: "I2",
        field: "i2",
        section: Section::Interface,
        class: MergeClass::ClientSide,
        kind: SpecKind::TagLiteral,
        epoch: |p| epoch_str(p, |p| &p.i2),
        // I2-I5 content is central-only ("if themed", D1) — the edge
        // generates I1 only; I2-I5 stay absent = empty, per Amnezia
        // convention.
        default: |_| None,
    },
    FieldSpec {
        key: "I3",
        field: "i3",
        section: Section::Interface,
        class: MergeClass::ClientSide,
        kind: SpecKind::TagLiteral,
        epoch: |p| epoch_str(p, |p| &p.i3),
        default: |_| None,
    },
    FieldSpec {
        key: "I4",
        field: "i4",
        section: Section::Interface,
        class: MergeClass::ClientSide,
        kind: SpecKind::TagLiteral,
        epoch: |p| epoch_str(p, |p| &p.i4),
        default: |_| None,
    },
    FieldSpec {
        key: "I5",
        field: "i5",
        section: Section::Interface,
        class: MergeClass::ClientSide,
        kind: SpecKind::TagLiteral,
        epoch: |p| epoch_str(p, |p| &p.i5),
        default: |_| None,
    },
    FieldSpec {
        key: "HeaderProtectionKey",
        field: "header_protection_key",
        section: Section::Interface,
        class: MergeClass::MustMatch,
        kind: SpecKind::HeaderProtectionKey,
        epoch: |p| epoch_str(p, |p| &p.header_protection_key),
        default: |_| None,
    },
    FieldSpec {
        key: "ContentPaddingAddition",
        field: "content_padding_addition",
        section: Section::Interface,
        class: MergeClass::ClientSide,
        kind: SpecKind::RangeString,
        epoch: |p| epoch_str(p, |p| &p.content_padding_addition),
        default: |d| Some(FieldValue::Str(d.content_padding_addition.clone())),
    },
    FieldSpec {
        key: "RekeyAfterTime",
        field: "rekey_after_time",
        section: Section::Interface,
        class: MergeClass::ClientSide,
        kind: SpecKind::RangeString,
        epoch: |p| epoch_str(p, |p| &p.rekey_after_time),
        default: |_| None,
    },
    FieldSpec {
        key: "RekeyTimeout",
        field: "rekey_timeout",
        section: Section::Interface,
        class: MergeClass::ClientSide,
        kind: SpecKind::RangeString,
        epoch: |p| epoch_str(p, |p| &p.rekey_timeout),
        default: |_| None,
    },
    FieldSpec {
        key: "RejectAfterTime",
        field: "reject_after_time",
        section: Section::Interface,
        class: MergeClass::ClientSide,
        kind: SpecKind::RangeString,
        epoch: |p| epoch_str(p, |p| &p.reject_after_time),
        default: |_| None,
    },
    FieldSpec {
        key: "KeepaliveTimeout",
        field: "keepalive_timeout",
        section: Section::Interface,
        class: MergeClass::ClientSide,
        kind: SpecKind::RangeString,
        epoch: |p| epoch_str(p, |p| &p.keepalive_timeout),
        default: |_| None,
    },
    FieldSpec {
        key: "MaxHandshakeAttempts",
        field: "max_handshake_attempts",
        section: Section::Interface,
        class: MergeClass::ClientSide,
        kind: SpecKind::RangeString,
        epoch: |p| epoch_str(p, |p| &p.max_handshake_attempts),
        default: |_| None,
    },
    FieldSpec {
        key: "RandomTrailers",
        field: "random_trailers",
        section: Section::Interface,
        class: MergeClass::MustMatch,
        kind: SpecKind::OnOff,
        epoch: |p| p.random_trailers.map(FieldValue::Bool),
        default: |_| None,
    },
    FieldSpec {
        key: "DisableCookies",
        field: "disable_cookies",
        section: Section::Interface,
        class: MergeClass::ClientSide,
        kind: SpecKind::OnOff,
        epoch: |p| p.disable_cookies.map(FieldValue::Bool),
        default: |_| None,
    },
];

/// Whitespace-tolerant per-key line matchers generated from FIELD_SPECS —
/// `(?m)^Key[ \t]*=[ \t]*(value)$`. Multiline flag makes `^`/`$` match
/// individual lines, not the whole string. The capture group feeds the
/// resolve stage's conf-side value.
static FIELD_LINE_RES: Lazy<HashMap<&'static str, Regex>> = Lazy::new(|| {
    FIELD_SPECS
        .iter()
        .map(|spec| {
            let pattern = format!(r"(?m)^{}[ \t]*=[ \t]*([^\n]*)$", regex::escape(spec.key));
            (
                spec.key,
                Regex::new(&pattern).expect("generated regex is valid"),
            )
        })
        .collect()
});

/// Compiled regex for the `[Interface]` section header line. Used to locate
/// the insertion point for params that are absent from the conf.
static AWG_INTERFACE_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"(?m)^\[Interface\][^\n]*$").expect("static regex is valid"));

/// Edge-generated client-class defaults — the SOLE generator of the
/// client-param set (D2: one implementation, nothing to drift). Generated
/// ONCE per process start and passed into every merge; each default fires
/// only when the field is absent from BOTH the epoch and the conf, so the
/// conf itself is the persistence (nothing re-randomizes once written).
///
/// The startup top-up (`merge(conf, None, &defaults)`) lands the v3.1
/// client posture at binary delivery rather than at the first post-gate
/// epoch — which the central writer-gate deliberately withholds (D3/D6).
///
/// Bands are consts next to FIELD_SPECS per D2 (ported from the 3x-ui
/// GenerateObfuscation31 reference, trimmed to the edge-generated set;
/// ADR-004 mirrors them informatively).
pub struct ClientDefaults {
    /// I1 junk-tag literal — `<r N>` with N drawn in [32,256] per node
    /// (3x-ui's GenerateObfuscation31 emits `randInt(32,256)` inside the
    /// tag — the band is the draw range, NOT the literal; a literal
    /// `32-256` fails upstream `Atoi` and wedges syncconf). I2-I5 stay
    /// absent = empty per Amnezia convention (themed content is
    /// central-only, D1).
    pub i1: String,
    /// ContentPaddingAddition rendered `lo-hi`: lo ∈ [8,24], hi = lo +
    /// [8,40] — max 24+40 = 64, so the ≤64 total ceiling holds by
    /// construction (no clamp).
    pub content_padding_addition: String,
    /// Jc ∈ [3,6], Jmin ∈ [40,89], Jmax = Jmin + [50,250].
    pub jc: i64,
    pub jmin: i64,
    pub jmax: i64,
}

// D2 band consts — the spec's authoritative edge-generation ranges.
const I1_RAND_LO: i64 = 32;
const I1_RAND_HI: i64 = 256;
const JC_LO: i64 = 3;
const JC_HI: i64 = 6;
const JMIN_LO: i64 = 40;
const JMIN_HI: i64 = 89;
const JMAX_DELTA_LO: i64 = 50;
const JMAX_DELTA_HI: i64 = 250;
const CPA_LO_LO: i64 = 8;
const CPA_LO_HI: i64 = 24;
const CPA_DELTA_LO: i64 = 8;
const CPA_DELTA_HI: i64 = 40;

impl ClientDefaults {
    /// Draw a fresh set of client-side defaults from OS entropy.
    ///
    /// RNG is rustix `getrandom(2)` (the pinned primitive — security#11;
    /// NEVER shell-$RANDOM-style LCGs). These are obfuscation-diversity
    /// params, not keys, but cheap crypto-grade entropy is free.
    pub fn generate() -> Result<Self> {
        let jc = rand_inclusive(JC_LO, JC_HI)?;
        let jmin = rand_inclusive(JMIN_LO, JMIN_HI)?;
        let jmax = jmin + rand_inclusive(JMAX_DELTA_LO, JMAX_DELTA_HI)?;
        let cpa_lo = rand_inclusive(CPA_LO_LO, CPA_LO_HI)?;
        let cpa_hi = cpa_lo + rand_inclusive(CPA_DELTA_LO, CPA_DELTA_HI)?;
        debug_assert!(cpa_hi <= 64, "CPA band invariant: hi <= 64 by construction");
        Ok(Self {
            i1: format!("<r {}>", rand_inclusive(I1_RAND_LO, I1_RAND_HI)?),
            content_padding_addition: format!("{cpa_lo}-{cpa_hi}"),
            jc,
            jmin,
            jmax,
        })
    }
}

/// Uniform draw from `[lo, hi]` via OS entropy. Modulo reduction of a
/// 64-bit draw is unbiased far past any DPI-relevant precision at these
/// spans (security#11: predictability here costs obfuscation diversity,
/// not key material).
fn rand_inclusive(lo: i64, hi: i64) -> Result<i64> {
    debug_assert!(lo <= hi);
    let span = (hi - lo + 1) as u64;
    let mut buf = [0u8; 8];
    fill_random(&mut buf)?;
    Ok(lo + (u64::from_le_bytes(buf) % span) as i64)
}

/// Fill `buf` with OS entropy. The production target is Linux, where
/// rustix's `getrandom(2)` wrapper is the pinned primitive.
#[cfg(target_os = "linux")]
fn fill_random(buf: &mut [u8]) -> Result<()> {
    rustix::rand::getrandom(buf, rustix::rand::GetRandomFlags::empty())
        .map(|_| ())
        .context("getrandom(2) for client defaults")
}

/// Non-Linux fallback (dev hosts run `cargo test` on macOS): /dev/urandom
/// is the same entropy pool getrandom reads. The agent binary only ever
/// deploys to Linux; this arm exists so the crate compiles and tests run
/// on developer machines.
#[cfg(not(target_os = "linux"))]
fn fill_random(buf: &mut [u8]) -> Result<()> {
    use std::io::Read;
    std::fs::File::open("/dev/urandom")
        .and_then(|mut f| f.read_exact(buf))
        .context("read /dev/urandom for client defaults")
}

/// Replace-or-insert the mergeable AWG params in `conf`, driven by
/// `FIELD_SPECS`. `params` is the epoch payload — `None` on the startup
/// top-up path (D3), where only client-class insert-if-absent defaults can
/// write (required must-match fields can't be faked because the `Option`
/// wrapper sits at the params level, not per-field).
///
/// For each spec'd key: an epoch `Some` (validated) replaces-or-inserts;
/// `None` preserves the existing conf line — or, for client-class keys
/// with a default source, inserts the generated default when the conf
/// lacks the line entirely. Nothing is ever deleted (no syncconf omission
/// semantics).
///
/// Returns `Err` — with a `field=` marker — when a must-match value fails
/// validation or a cross-field precondition fails on the resolved set;
/// the merge produces no conf in that case (fail closed). Client-side
/// failures only omit that field.
///
/// `Err` is also returned if `conf` has no `[Interface]` section to insert
/// into. All other content ([Peer] sections, PrivateKey, Address,
/// comments, whitespace) is preserved byte-for-byte.
///
/// Test-only compat wrapper: the production caller uses the
/// `_reporting` variant for its dropped-field list; the suite's ~40 call
/// sites predate it and don't need the list.
#[cfg(test)]
pub fn merge_obfuscation_params(
    conf: &str,
    params: Option<&AwgParams>,
    defaults: &ClientDefaults,
) -> Result<String> {
    merge_obfuscation_params_reporting(conf, params, defaults).map(|(conf, _)| conf)
}

/// Reporting variant of [`merge_obfuscation_params`]: same merge, but also
/// returns the names of every client-class field whose epoch value failed
/// validation and was omitted. The agent feeds the list to
/// `param_rejected_total{field=...}` — without it a hostile/MITM central can
/// fuzz the freeform-string surface (I1–I5, CPA, timings) forever with zero
/// alert-visible signal: those omissions return `Ok`, so the `field=` marker
/// contract on `Err` never sees them.
pub fn merge_obfuscation_params_reporting(
    conf: &str,
    params: Option<&AwgParams>,
    defaults: &ClientDefaults,
) -> Result<(String, Vec<&'static str>)> {
    // ── PASS 1: resolve-effective + per-field validate ───────────────────
    //
    // For each spec: epoch Some > existing conf line > default. The write
    // decision (replace / insert / preserve) and the effective value (for
    // cross-field preconditions) are recorded here; the splice happens in
    // pass 2.
    let mut effective: HashMap<&'static str, FieldValue> = HashMap::new();
    let mut replaces: Vec<(&'static FieldSpec, String)> = Vec::new();
    let mut inserts: Vec<(&'static FieldSpec, String)> = Vec::new();
    let mut dropped: Vec<&'static str> = Vec::new();

    for spec in FIELD_SPECS {
        // First match anywhere in the text — deliberately unscoped by
        // section (v1 parity; the deferred YAGNI above).
        let conf_raw = spec
            .line_re()
            .captures(conf)
            .map(|c| c.get(1).expect("capture group exists").as_str());
        let conf_val = conf_raw.and_then(|raw| spec.parse_conf_value(raw));

        if let Some(v) = params.and_then(|p| (spec.epoch)(p)) {
            match spec.validate(&v) {
                Ok(()) => {
                    let line = spec.render(&v);
                    if conf_raw.is_some() {
                        replaces.push((spec, line));
                    } else {
                        inserts.push((spec, line));
                    }
                    effective.insert(spec.field, v);
                }
                Err(e) => match spec.class {
                    // SECURITY (T4/crypto_invariant, D5): a must-match field
                    // failing charset OR grammar validation rejects the whole
                    // merge — the offending bytes never reach awg0.conf and
                    // no partial must-match set is applied. The `field=`
                    // marker rides the error chain up to the
                    // param_rejected_total counter in agent.rs.
                    MergeClass::MustMatch => return Err(e),
                    MergeClass::ClientSide => {
                        // Degrade the feature, keep the link: the bad epoch
                        // value is omitted; the existing conf line (if any)
                        // is preserved and remains the effective value. A
                        // bad epoch value does NOT fall through to the
                        // generated default — "absent from epoch AND conf"
                        // is the default's only trigger, and an invalid
                        // epoch was still PRESENT.
                        // The field name rides `dropped` out to the caller so
                        // the param_rejected_total counter sees client-side
                        // rejections, not only the must-match Err path.
                        warn!(
                            field = spec.field,
                            error = %e,
                            "omitting invalid client-side field — keeping existing conf line"
                        );
                        dropped.push(spec.field);
                        if let Some(v) = conf_val {
                            effective.insert(spec.field, v);
                        }
                    }
                },
            }
        } else if conf_raw.is_some() {
            // Epoch absent → preserve the existing line (no delete path).
            if let Some(v) = conf_val {
                effective.insert(spec.field, v);
            }
        } else if let Some(v) = (spec.default)(defaults) {
            // Epoch absent AND conf line absent → client-class
            // insert-if-absent. The generated default still goes through
            // the field's own validator — a band bug must not stamp an
            // invalid line.
            match spec.validate(&v) {
                Ok(()) => {
                    inserts.push((spec, spec.render(&v)));
                    effective.insert(spec.field, v);
                }
                Err(e) => warn!(
                    field = spec.field,
                    error = %e,
                    "generated client default failed its own validator — omitting (bug)"
                ),
            }
        }
        // else: epoch absent, conf absent, no default → nothing written,
        // effective stays unset (counts as 0 in precondition math).
    }

    // ── PASS 1.5: cross-field preconditions on the RESOLVED set ──────────
    //
    // Mirrors ALL of upstream mergeWithDevice's pre-Store checks (D5 /
    // security#2): S1+56 != S2, pairwise H non-overlap, HPK-nonzero ⇒ every
    // S1-S4 >= 12 (absent counts as 0). All three are must-match
    // invariants, so a failure rejects the whole merge with a `field=`
    // error — the epoch (or the hostile conf it resolved against) fails
    // closed instead of stalling at IpcSet.
    let s_val = |field: &str| -> i64 {
        match effective.get(field) {
            Some(FieldValue::Int(n)) => *n,
            _ => 0,
        }
    };
    let (s1, s2, s3, s4) = (s_val("s1"), s_val("s2"), s_val("s3"), s_val("s4"));
    if s1 + 56 == s2 {
        return Err(anyhow!(
            "awg param rejected: field=s2 post-merge S2={} equals S1+56 \
             (S1={}) — reserved size pair upstream mergeWithDevice refuses; \
             rejecting whole merge",
            s2,
            s1
        ));
    }
    let h_range = |field: &str| -> Option<(i64, i64)> {
        match effective.get(field) {
            Some(FieldValue::Int(n)) => Some((*n, *n)),
            Some(FieldValue::Range(lo, hi)) => Some((*lo, *hi)),
            _ => None,
        }
    };
    let h_fields = ["h1", "h2", "h3", "h4"];
    let hs: Vec<Option<(i64, i64)>> = h_fields.iter().map(|f| h_range(f)).collect();
    for i in 0..hs.len() {
        for j in (i + 1)..hs.len() {
            if let (Some((alo, ahi)), Some((blo, bhi))) = (hs[i], hs[j]) {
                if alo <= bhi && blo <= ahi {
                    return Err(anyhow!(
                        "awg param rejected: field={} post-merge H range {}-{} \
                         overlaps {} {}-{} — pairwise H non-overlap violated; \
                         rejecting whole merge",
                        h_fields[j],
                        blo,
                        bhi,
                        h_fields[i],
                        alo,
                        ahi
                    ));
                }
            }
        }
    }
    if let Some(FieldValue::Str(hpk)) = effective.get("header_protection_key") {
        if params::hpk_is_active(hpk) && (s1 < 12 || s2 < 12 || s3 < 12 || s4 < 12) {
            return Err(anyhow!(
                "awg param rejected: field=header_protection_key active HPK \
                 requires all post-merge S1-S4 >= 12 (got s1={} s2={} s3={} \
                 s4={}; absent counts as 0) — upstream mergeWithDevice \
                 precondition; rejecting whole merge",
                s1,
                s2,
                s3,
                s4
            ));
        }
    }
    // jmin <= jmax on the resolved set. Upstream stores both as bare
    // ParseUint(10,32) values and never cross-checks them at uapi time; the
    // violation detonates inside Device.JunkPackets() — `min +
    // fastrandn(max-min)` underflows uint32 to a ~4GiB allocation per junk
    // packet. These are client-class fields, so soften first: drop the
    // epoch-sourced member(s), re-resolve from the existing conf line, and
    // only fail closed if the pair is still inverted — i.e. the
    // pre-existing conf itself is the bad side (daemon already broken;
    // applying fresh values can't fix it, but refusing keeps the bad epoch
    // unrecorded and alert-visible).
    {
        let junk_pair = |eff: &HashMap<&'static str, FieldValue>| -> Option<(i64, i64)> {
            match (eff.get("jmin"), eff.get("jmax")) {
                (Some(FieldValue::Int(lo)), Some(FieldValue::Int(hi))) => Some((*lo, *hi)),
                _ => None,
            }
        };
        if let Some((lo, hi)) = junk_pair(&effective) {
            if lo > hi {
                for f in ["jmin", "jmax"] {
                    let spec = FIELD_SPECS
                        .iter()
                        .find(|s| s.field == f)
                        .expect("jmin/jmax are FIELD_SPECS members");
                    let epoch_sourced = params.and_then(|p| (spec.epoch)(p)).is_some();
                    if !epoch_sourced {
                        continue;
                    }
                    replaces.retain(|(s, _)| s.field != f);
                    inserts.retain(|(s, _)| s.field != f);
                    dropped.push(f);
                    let conf_raw = spec
                        .line_re()
                        .captures(conf)
                        .map(|c| c.get(1).expect("capture group exists").as_str());
                    match conf_raw.and_then(|raw| spec.parse_conf_value(raw)) {
                        Some(v) => {
                            effective.insert(f, v);
                        }
                        None => {
                            effective.remove(f);
                        }
                    }
                }
                if let Some((lo, hi)) = junk_pair(&effective) {
                    if lo > hi {
                        return Err(anyhow!(
                            "awg param rejected: field=jmax post-merge jmin={} > \
                             jmax={} with no epoch-sourced member left to drop \
                             (pre-existing conf is inverted) — JunkPackets would \
                             underflow max-min to a ~4GiB allocation; rejecting \
                             whole merge",
                            lo,
                            hi
                        ));
                    }
                }
                warn!(
                    field = "jmin/jmax",
                    "epoch jmin>jmax violated pair invariant — dropped \
                     epoch-sourced member(s), kept existing conf lines"
                );
            }
        }
    }

    // ── PASS 2: splice ───────────────────────────────────────────────────
    // Replace-in-place first (order irrelevant — per-key regex), then one
    // header-top insert block per section, in spec order (v1 inserted each
    // line separately, reversing the order; the block keeps spec order).
    let mut result = conf.to_owned();
    for (spec, line) in &replaces {
        result = spec
            .line_re()
            .replace_all(&result, |_caps: &regex::Captures<'_>| line.clone())
            .into_owned();
    }
    if !inserts.is_empty() {
        // Group insert lines by their spec's declared section — every row's
        // `section` column picks its insert target (all Interface today; the
        // grouping is what keeps the column a live read rather than a
        // comment claim).
        let mut by_section: Vec<(Section, Vec<&String>)> = Vec::new();
        for (spec, line) in &inserts {
            match by_section.iter_mut().find(|(s, _)| *s == spec.section) {
                Some((_, lines)) => lines.push(line),
                None => by_section.push((spec.section, vec![line])),
            }
        }
        for (section, lines) in &by_section {
            let Some(m) = section.header_re().find(&result) else {
                return Err(anyhow!(
                    "conf merge: no {:?} section found (cannot insert {:?})",
                    section,
                    lines
                ));
            };
            // `m.end()` is the position just before the header line's
            // newline (or EOF if it is the last line). Splice `\n{block}`
            // right after.
            let block = lines
                .iter()
                .map(|l| l.as_str())
                .collect::<Vec<_>>()
                .join("\n");
            let header_end = m.end();
            let mut out = String::with_capacity(result.len() + block.len() + 1);
            out.push_str(&result[..header_end]);
            out.push('\n');
            out.push_str(&block);
            out.push_str(&result[header_end..]);
            result = out;
        }
    }

    Ok((result, dropped))
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::{engine::general_purpose::STANDARD as B64, Engine as _};

    /// Minimal valid awg0.conf fixture with all v1 params and a [Peer] block.
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

    /// Deterministic defaults for tests — the merge never sees RNG.
    fn test_defaults() -> ClientDefaults {
        ClientDefaults {
            i1: "<r 128>".to_owned(),
            content_padding_addition: "10-30".to_owned(),
            jc: 4,
            jmin: 55,
            jmax: 120,
        }
    }

    /// sample_params with all Option fields absent (v1-shape epoch).
    fn sample_params(jc: i64) -> AwgParams {
        AwgParams {
            jc: Some(jc),
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

    /// sample_params with an I1 value set.
    fn sample_params_with_i1(jc: i64, i1: &str) -> AwgParams {
        AwgParams {
            i1: Some(i1.to_owned()),
            ..sample_params(jc)
        }
    }

    /// Epoch-path merge with fixed test defaults.
    fn merge(conf: &str, params: &AwgParams) -> Result<String> {
        merge_obfuscation_params(conf, Some(params), &test_defaults())
    }

    #[test]
    fn merge_obfuscation_params_replaces_jc() {
        let out = merge(fixture_conf(), &sample_params(99)).unwrap();
        assert!(out.contains("Jc = 99\n"), "Jc should be 99, got:\n{}", out);
        assert!(!out.contains("Jc = 11"), "old Jc should be gone");
    }

    #[test]
    fn merge_obfuscation_params_preserves_peer_section() {
        let conf = fixture_conf();
        let out = merge(conf, &sample_params(99)).unwrap();

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
        let out = merge(conf, &sample_params(7)).unwrap();

        assert!(
            out.contains("# This is a comment about the peer below."),
            "comment was dropped:\n{}",
            out
        );
        assert!(
            out.contains("PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="),
            "PrivateKey changed"
        );
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
                          H1 = 100\n\
                          H2 = 200\n\
                          H3 = 300\n\
                          H4 = 400\n";
        let out = merge(conf_no_jc, &sample_params(99)).unwrap();
        assert!(
            out.contains("Jc = 99\n"),
            "missing Jc must be inserted, got:\n{}",
            out
        );
        let hdr = out.find("[Interface]").expect("has [Interface]");
        let jc = out.find("Jc = 99").expect("has inserted Jc");
        assert!(jc > hdr, "inserted Jc must be inside [Interface]:\n{}", out);
    }

    /// Regression: base64 peer keys must not be mistaken for digit-only lines.
    /// Also covers that S1/S2/S4 with values that appear in base64 are safe.
    #[test]
    fn merge_obfuscation_params_all_params_replaced() {
        let params = AwgParams {
            jc: Some(7),
            jmin: Some(42),
            jmax: Some(999),
            s1: 5,
            s2: 6,
            s4: 7,
            h1: IntOrRange::Single(11111111),
            h2: IntOrRange::Single(22222222),
            h3: IntOrRange::Single(33333333),
            h4: IntOrRange::Single(44444444),
            ..sample_params(7)
        };
        let out = merge(fixture_conf(), &params).unwrap();
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
        let out = merge(fixture_conf(), &params).unwrap();
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

    /// I1=None leaves existing I1 line unchanged (backward compat for
    /// pre-I1 DB rows).
    #[test]
    fn merge_obfuscation_params_i1_none_preserves_existing_line() {
        let out = merge(fixture_conf(), &sample_params(11)).unwrap();
        assert!(
            out.contains("I1 = <r 2><b 0x0100><b 0x0001><b 0x0000><b 0x0000><b 0x0000>\n"),
            "existing I1 line must survive when i1 is None:\n{}",
            out
        );
    }

    /// I1=Some("") MUST be treated like None — skip apply, leave the
    /// existing I1 line untouched. Mirrors the Go-side `if params.I1 != ""`
    /// skip; a malformed `I1 = ` line would silently drift from motherly's
    /// clean conf.
    #[test]
    fn merge_obfuscation_params_i1_empty_string_skipped() {
        let params = sample_params_with_i1(11, "");
        let out = merge(fixture_conf(), &params).unwrap();
        assert!(
            out.contains("I1 = <r 2><b 0x0100><b 0x0001><b 0x0000><b 0x0000><b 0x0000>\n"),
            "existing I1 line must survive when i1 is Some(empty):\n{}",
            out
        );
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
        let conf_no_i1 = "[Interface]\n\
                           PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n\
                           Address = 10.9.0.2/32\n\
                           Jc = 11\n\
                           Jmin = 50\n\
                           Jmax = 1000\n\
                           S1 = 17\n\
                           S2 = 18\n\
                           S4 = 18\n\
                           H1 = 100\n\
                           H2 = 200\n\
                           H3 = 300\n\
                           H4 = 400\n";
        let params = sample_params_with_i1(11, "<r 3><b 0x0200>");
        let out = merge(conf_no_i1, &params).unwrap();
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
    /// keys + a `[Peer]` block. After an epoch merge, all must-match params
    /// and the client-class defaults must be inserted into `[Interface]`,
    /// and the `[Peer]` block must survive intact.
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
        let out = merge(bootstrap, &params).unwrap();

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
        assert!(
            out.contains("I1 = <r 3><b 0x0200>"),
            "I1 must be inserted:\n{}",
            out
        );

        assert!(out.contains("PublicKey = BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB="));
        assert!(out.contains("Endpoint = motherly.example.com:51820"));
        assert!(out.contains("AllowedIPs = 10.9.0.1/32"));
        assert!(out.contains("PersistentKeepalive = 25"));

        let peer_pos = out.find("[Peer]").expect("has [Peer]");
        let jc_pos = out.find("Jc = 11").expect("has inserted Jc");
        assert!(
            jc_pos < peer_pos,
            "inserted Jc leaked into [Peer]:\n{}",
            out
        );
    }

    /// FINDING REPRO (crypto_invariant/critical): a multi-line I1 carrying an
    /// embedded `[Peer]` block must NEVER reach the conf — otherwise
    /// `awg-quick strip | awg syncconf` would install an attacker peer
    /// (AllowedIPs=0.0.0.0/0, Endpoint=attacker) into the kernel WireGuard
    /// peer table. Under the v2 failure split I1 is client-side ⇒ the field
    /// is OMITTED (merge succeeds, rest applies, pre-existing I1 preserved)
    /// rather than merge-rejected; the must-match reject path is exercised
    /// by `merge_never_renders_injection_bytes_on_any_string_field` (HPK).
    #[test]
    fn merge_never_renders_multiline_i1_peer_injection() {
        let malicious = "<r 2><b 0x0100>\n\
                         [Peer]\n\
                         PublicKey = ATTACKERAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n\
                         AllowedIPs = 0.0.0.0/0\n\
                         Endpoint = attacker.example.com:51820";
        let params = sample_params_with_i1(11, malicious);
        let out = merge(fixture_conf(), &params).expect("client-side omit must not fail the merge");
        assert!(
            !out.contains("ATTACKER") && !out.contains("AllowedIPs = 0.0.0.0/0"),
            "injected bytes must never reach the conf:\n{out}"
        );
        // The pre-existing legit I1 line is preserved in place of the omit.
        assert!(
            out.contains("I1 = <r 2><b 0x0100>"),
            "existing I1 must survive the omit:\n{out}"
        );
        assert!(out.contains("Jc = 11\n"), "rest of epoch applies:\n{out}");
    }

    /// The injection guard covers EVERY string field now (D5): the hostile
    /// bytes must never reach the conf on either class path. Must-match
    /// (HPK) → the whole merge is rejected with `field=`. Client-side → the
    /// field is omitted (degrade, keep link), the rest of the epoch still
    /// applies, and no `[Peer]` splice survives into the output.
    #[test]
    fn merge_never_renders_injection_bytes_on_any_string_field() {
        let malicious = "v\n[Peer]\nPublicKey = ATTACKERAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\nAllowedIPs = 0.0.0.0/0";
        let conf = fixture_conf();

        // Must-match string field (HPK): whole merge rejected, no output conf.
        let p = AwgParams {
            header_protection_key: Some(malicious.to_owned()),
            ..sample_params(11)
        };
        let res = merge(conf, &p);
        assert!(res.is_err(), "injected HPK must reject the whole merge");
        assert!(res
            .unwrap_err()
            .to_string()
            .contains("field=header_protection_key"));

        // Client-side string fields: field omitted, rest applied, hostile
        // bytes absent from the output.
        for (name, p) in [
            (
                "i1",
                AwgParams {
                    i1: Some(malicious.to_owned()),
                    ..sample_params(11)
                },
            ),
            (
                "i2",
                AwgParams {
                    i2: Some(malicious.to_owned()),
                    ..sample_params(11)
                },
            ),
            (
                "i5",
                AwgParams {
                    i5: Some(malicious.to_owned()),
                    ..sample_params(11)
                },
            ),
            (
                "cpa",
                AwgParams {
                    content_padding_addition: Some(malicious.to_owned()),
                    ..sample_params(11)
                },
            ),
            (
                "rekey",
                AwgParams {
                    rekey_after_time: Some(malicious.to_owned()),
                    ..sample_params(11)
                },
            ),
            (
                "keepalive",
                AwgParams {
                    keepalive_timeout: Some(malicious.to_owned()),
                    ..sample_params(11)
                },
            ),
        ] {
            let out = merge(conf, &p)
                .unwrap_or_else(|e| panic!("client-side {name} must omit not reject: {e}"));
            assert!(
                !out.contains("[Peer]\nPublicKey = ATTACKER"),
                "{name}: injected bytes must never render:\n{out}"
            );
            assert!(
                out.contains("Jc = 11\n"),
                "{name}: rest of merge must still apply:\n{out}"
            );
        }
    }

    /// Belt-and-suspenders: even a single-line I1 that merely contains a bare
    /// `[` (section-header primitive) is omitted — the hostile bytes never
    /// reach the output conf, and the pre-existing legit I1 line is
    /// preserved in place.
    #[test]
    fn merge_omits_bracketed_i1_preserving_existing_line() {
        // I1 is client-side → omit-only. The hostile bytes never render and
        // the existing legit I1 line is preserved.
        let params = sample_params_with_i1(11, "<r 2>[Peer]");
        let out = merge(fixture_conf(), &params).unwrap();
        assert!(
            !out.contains("<r 2>[Peer]"),
            "bracketed I1 must not render:\n{out}"
        );
        assert!(
            out.contains("I1 = <r 2><b 0x0100>"),
            "existing I1 line preserved when epoch value is omitted:\n{out}"
        );
    }

    /// Regression: a legit single-line I1 is STILL applied after the guard —
    /// the charset guard must not reject valid `<r N><b 0xHH>` obfuscation
    /// params (angle brackets are legit; only `\n\r[]` are forbidden).
    #[test]
    fn merge_still_applies_valid_single_line_i1_after_guard() {
        let params = sample_params_with_i1(11, "<r 3><b 0x0200><b 0x0002>");
        let out = merge(fixture_conf(), &params).unwrap();
        assert!(
            out.contains("I1 = <r 3><b 0x0200><b 0x0002>\n"),
            "valid single-line I1 must still be applied, got:\n{}",
            out
        );
    }

    // ── v2: resolve→validate→splice + FIELD_SPECS matrix ─────────────────

    /// Whitespace-tolerant replace: a hand-edited `S1  =  17` still matches
    /// the line regex and is replaced in canonical spelling — no duplicate
    /// `S1` lines (boundaries#11).
    #[test]
    fn merge_whitespace_tolerant_existing_line_replaced() {
        let conf = fixture_conf().replace("S1 = 17", "S1  =  17");
        let params = AwgParams {
            s1: 99,
            ..sample_params(11)
        };
        let out = merge(&conf, &params).unwrap();
        assert!(out.contains("S1 = 99\n"), "got:\n{out}");
        assert!(
            !out.contains("S1  ="),
            "non-canonical line must be gone:\n{out}"
        );
        assert_eq!(out.matches("S1").count(), 1, "exactly one S1 line:\n{out}");
    }

    /// H accepts both epoch forms and renders canonical spellings.
    #[test]
    fn merge_h_int_and_range_forms() {
        let params = AwgParams {
            h1: IntOrRange::Range { lo: 100, hi: 200 },
            h2: IntOrRange::Single(300),
            ..sample_params(11)
        };
        let out = merge(fixture_conf(), &params).unwrap();
        assert!(out.contains("H1 = 100-200\n"), "range form:\n{out}");
        assert!(out.contains("H2 = 300\n"), "single form:\n{out}");
    }

    /// S3 (new must-match): Some → replace-or-insert; None → preserve;
    /// Some(0) → the explicit remove-signal line `S3 = 0` (no delete path).
    #[test]
    fn merge_s3_insert_replace_preserve_and_zero_form() {
        let params = AwgParams {
            s3: Some(30),
            ..sample_params(11)
        };
        let out = merge(fixture_conf(), &params).unwrap();
        assert!(out.contains("S3 = 30\n"), "S3 must be inserted:\n{out}");

        // Second merge with a different value replaces it.
        let p2 = AwgParams {
            s3: Some(44),
            ..sample_params(11)
        };
        let out2 = merge(&out, &p2).unwrap();
        assert!(out2.contains("S3 = 44\n") && !out2.contains("S3 = 30"));

        // Epoch omitting s3 preserves the line (no delete path).
        let out3 = merge(&out2, &sample_params(11)).unwrap();
        assert!(
            out3.contains("S3 = 44\n"),
            "absent s3 must preserve:\n{out3}"
        );

        // Explicit zero-form remove-signal renders and stays.
        let p4 = AwgParams {
            s3: Some(0),
            ..sample_params(11)
        };
        let out4 = merge(&out3, &p4).unwrap();
        assert!(out4.contains("S3 = 0\n"), "zero-form must render:\n{out4}");
    }

    /// Bools render upstream's `on`/`off` spellings; None preserves.
    #[test]
    fn merge_bool_fields_render_on_off_and_preserve() {
        let params = AwgParams {
            random_trailers: Some(true),
            disable_cookies: Some(false),
            ..sample_params(11)
        };
        let out = merge(fixture_conf(), &params).unwrap();
        assert!(
            out.contains("RandomTrailers = on\n"),
            "Some(true) → on:\n{out}"
        );
        assert!(
            out.contains("DisableCookies = off\n"),
            "Some(false) → off:\n{out}"
        );

        let p2 = AwgParams {
            random_trailers: Some(false),
            disable_cookies: Some(true),
            ..sample_params(11)
        };
        let out2 = merge(&out, &p2).unwrap();
        assert!(out2.contains("RandomTrailers = off\n"));
        assert!(out2.contains("DisableCookies = on\n"));

        // Absent → existing lines preserved (zero-form needs explicit Some).
        let out3 = merge(&out2, &sample_params(11)).unwrap();
        assert!(out3.contains("RandomTrailers = off\n"));
        assert!(out3.contains("DisableCookies = on\n"));
    }

    /// A must-match grammar failure (S3 out of u16 range) rejects the whole
    /// merge and names the field — fail closed, never partially apply.
    #[test]
    fn merge_must_match_grammar_failure_rejects_whole_merge() {
        let params = AwgParams {
            s3: Some(70000),
            jc: Some(99),
            ..sample_params(11)
        };
        let res = merge(fixture_conf(), &params);
        let err = res.unwrap_err().to_string();
        assert!(err.contains("field=s3"), "must name field=s3, got: {err}");
    }

    /// A client-side grammar failure omits ONLY that field — the rest of
    /// the epoch still applies (degrade feature, keep link).
    #[test]
    fn merge_client_side_grammar_failure_omits_only_that_field() {
        let params = AwgParams {
            content_padding_addition: Some("garbage-not-a-range".to_owned()),
            rekey_after_time: Some("100-140".to_owned()),
            jc: Some(99),
            ..sample_params(11)
        };
        let out = merge(fixture_conf(), &params).unwrap();
        assert!(
            !out.contains("garbage"),
            "bad CPA must be omitted entirely:\n{out}"
        );
        assert!(out.contains("Jc = 99\n"), "rest must apply:\n{out}");
        assert!(
            out.contains("RekeyAfterTime = 100-140\n"),
            "sibling good field must apply:\n{out}"
        );
    }

    // ── Cross-field preconditions on the resolved set (mergeWithDevice) ──

    /// S1+56==S2 is a hard upstream precondition — an epoch carrying it must
    /// be rejected atomically with a field= error, not partially applied.
    #[test]
    fn merge_rejects_s1_plus_56_eq_s2_epoch() {
        let params = AwgParams {
            s1: 17,
            s2: 73, // 17 + 56
            ..sample_params(11)
        };
        let err = merge(fixture_conf(), &params).unwrap_err().to_string();
        assert!(err.contains("field=s2"), "must name field=s2, got: {err}");
    }

    /// Pairwise H overlap on the resolved set rejects the whole merge.
    /// Covers both epoch-carried ranges and single-vs-range overlap.
    #[test]
    fn merge_rejects_overlapping_h_ranges() {
        let params = AwgParams {
            h1: IntOrRange::Range { lo: 10, hi: 20 },
            h2: IntOrRange::Range { lo: 15, hi: 30 },
            ..sample_params(11)
        };
        let err = merge(fixture_conf(), &params).unwrap_err().to_string();
        assert!(err.contains("field=h2"), "must name field=h2, got: {err}");

        // Single int inside another's range is still an overlap.
        let params2 = AwgParams {
            h1: IntOrRange::Range { lo: 10, hi: 20 },
            h3: IntOrRange::Single(15),
            ..sample_params(11)
        };
        assert!(
            merge(fixture_conf(), &params2).is_err(),
            "single-in-range must reject"
        );
    }

    /// HPK + post-merge S < 12 → reject with field=header_protection_key.
    /// The boundaries#3 trap: conf S1=5 + epoch adds HPK while omitting S —
    /// the resolved (post-merge) S1 is still 5 → must reject.
    #[test]
    fn merge_rejects_hpk_when_resolved_s_below_12() {
        let conf_low_s = fixture_conf().replace("S1 = 17", "S1 = 5");
        // Epoch omits s3 AND conf lacks S3 → resolved s3 = 0 < 12 → reject.
        let params = AwgParams {
            s1: 5, // epoch mirrors the conf's low S1 (must-match is central-driven)
            header_protection_key: Some(B64.encode([9u8; 32])),
            ..sample_params(11)
        };
        let err = merge(&conf_low_s, &params).unwrap_err().to_string();
        assert!(
            err.contains("field=header_protection_key"),
            "must name field=header_protection_key, got: {err}"
        );
    }

    /// jmin > jmax on the resolved set — upstream never checks the pair at
    /// uapi time; JunkPackets underflows `max-min` to a ~4GiB allocation.
    /// Client-class degrade: drop the epoch-sourced member(s), keep the
    /// existing conf lines.
    #[test]
    fn merge_jmin_gt_jmax_drops_epoch_members_keeps_conf() {
        let conf = fixture_conf(); // has Jmin/Jmax lines — see fixture
        let params = AwgParams {
            jmin: Some(9000),
            jmax: Some(10), // inverted pair, both epoch-sourced
            ..sample_params(11)
        };
        let (out, dropped) =
            merge_obfuscation_params_reporting(conf, Some(&params), &test_defaults()).unwrap();
        assert!(
            !out.contains("Jmin = 9000\n") && !out.contains("Jmax = 10\n"),
            "inverted epoch pair must not reach the conf:\n{out}"
        );
        assert!(
            dropped.contains(&"jmin") && dropped.contains(&"jmax"),
            "both dropped members must be reported for the metric: {dropped:?}"
        );
        // The conf's own pair survives untouched.
        assert!(out.contains("Jmin = ") && out.contains("Jmax = "));
    }

    /// Only one epoch member inverts the pair — drop just it.
    #[test]
    fn merge_jmin_gt_jmax_drops_only_epoch_sourced_member() {
        let conf = fixture_conf();
        let params = AwgParams {
            jmin: Some(9_999_999), // epoch raises jmin over conf's jmax
            jmax: None,
            ..sample_params(11)
        };
        let (out, dropped) =
            merge_obfuscation_params_reporting(conf, Some(&params), &test_defaults()).unwrap();
        assert!(!out.contains("9999999"), "epoch jmin must drop:\n{out}");
        assert_eq!(dropped, vec!["jmin"]);
    }

    /// Conf itself is already inverted and the epoch doesn't touch the pair
    /// — nothing epoch-sourced to drop → fail closed.
    #[test]
    fn merge_jmin_gt_jmax_preexisting_inverted_conf_fails_closed() {
        let conf = fixture_conf().replace("Jmin = 50", "Jmin = 5000");
        // Fixture's Jmax stays < 5000 → resolved pair inverted, epoch clean.
        let params = AwgParams {
            jmin: None,
            jmax: None,
            ..sample_params(11)
        };
        let err = merge_obfuscation_params_reporting(&conf, Some(&params), &test_defaults())
            .unwrap_err()
            .to_string();
        assert!(
            err.contains("field=jmax"),
            "must name field=jmax, got: {err}"
        );
    }

    /// Per-field junk bound: negative and >u32 epoch values are client-class
    /// drops, not merge failures — and they land on `dropped` for the metric.
    #[test]
    fn merge_drops_out_of_grammar_junk_values() {
        let params = AwgParams {
            jc: Some(-1),
            jmax: Some(u32::MAX as i64 + 1),
            ..sample_params(11)
        };
        let (out, dropped) =
            merge_obfuscation_params_reporting(fixture_conf(), Some(&params), &test_defaults())
                .unwrap();
        assert!(!out.contains("-1"), "negative Jc must not render:\n{out}");
        assert!(dropped.contains(&"jc") && dropped.contains(&"jmax"));
    }

    /// An invalid I-tag literal is a client-class drop — never reaches conf.
    #[test]
    fn merge_drops_invalid_i_tag() {
        let params = AwgParams {
            i1: Some("<r -5>".to_owned()), // parses upstream, panics at send
            i2: Some("<bogus>".to_owned()),
            ..sample_params(11)
        };
        let (out, dropped) =
            merge_obfuscation_params_reporting(fixture_conf(), Some(&params), &test_defaults())
                .unwrap();
        assert!(!out.contains("bogus") && !out.contains("-5"));
        assert!(dropped.contains(&"i1") && dropped.contains(&"i2"));
    }

    /// The hpk-without-s3 buggy epoch: even with all conf S ≥ 12, an absent
    /// S3 resolves to 0 → reject (the exact regression the spec calls out).
    #[test]
    fn merge_rejects_hpk_without_s3() {
        let conf_hi_s = fixture_conf()
            .replace("S1 = 17", "S1 = 30")
            .replace("S2 = 18", "S2 = 40")
            .replace("S4 = 18", "S4 = 50");
        let params = AwgParams {
            s1: 30,
            s2: 40,
            s4: 50,
            header_protection_key: Some(B64.encode([9u8; 32])),
            ..sample_params(11)
        };
        let err = merge(&conf_hi_s, &params).unwrap_err().to_string();
        assert!(
            err.contains("field=header_protection_key"),
            "hpk-without-s3 must name field=header_protection_key, got: {err}"
        );
    }

    /// Happy path: HPK lands when every resolved S ≥ 12 — incl. the case
    /// where S3 comes from the epoch while S1/S2/S4 come from the conf
    /// (resolve-effective across sources).
    #[test]
    fn merge_hpk_accepted_when_all_resolved_s_gte_12() {
        // Conf carries high S1/S2/S4 and NO S3; epoch supplies S3 + HPK.
        let conf_hi_s = fixture_conf()
            .replace("S1 = 17", "S1 = 30")
            .replace("S2 = 18", "S2 = 40")
            .replace("S4 = 18", "S4 = 50");
        let params = AwgParams {
            s1: 30,
            s2: 40,
            s3: Some(25),
            s4: 50,
            header_protection_key: Some(B64.encode([9u8; 32])),
            ..sample_params(11)
        };
        let out = merge(&conf_hi_s, &params).unwrap();
        assert!(
            out.contains(&format!("HeaderProtectionKey = {}", B64.encode([9u8; 32]))),
            "HPK must be written when all resolved S >= 12:\n{out}"
        );
        assert!(out.contains("S3 = 25\n"));
    }

    /// The zero-form HPK is a legal off-signal — it must validate, render,
    /// and NOT trigger the S≥12 precondition even with low S values.
    #[test]
    fn merge_hpk_zero_key_is_legal_off_signal() {
        let params = AwgParams {
            s1: 5,
            s2: 6,
            s4: 7,
            header_protection_key: Some(B64.encode([0u8; 32])),
            ..sample_params(11)
        };
        let out = merge(fixture_conf(), &params).unwrap();
        assert!(
            out.contains(&format!("HeaderProtectionKey = {}", B64.encode([0u8; 32]))),
            "zero HPK must render — it is the explicit off-signal:\n{out}"
        );
    }

    /// A malformed HPK (bad base64) is a must-match grammar failure → the
    /// whole merge is rejected with field=header_protection_key.
    #[test]
    fn merge_rejects_malformed_hpk() {
        let params = AwgParams {
            header_protection_key: Some("!!!not-base64!!!".to_owned()),
            ..sample_params(11)
        };
        let err = merge(fixture_conf(), &params).unwrap_err().to_string();
        assert!(err.contains("field=header_protection_key"), "got: {err}");
    }

    // ── ClientDefaults: insert-if-absent, precedence, startup top-up ─────

    /// Defaults insert ONLY when the field is absent from BOTH epoch and
    /// conf. Epoch Some wins over conf and default; conf line beats default.
    #[test]
    fn merge_defaults_fire_only_when_absent_from_epoch_and_conf() {
        let conf_bare = "[Interface]\n\
                         PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n\
                         Address = 10.9.0.2/32\n\
                         S1 = 17\n\
                         S2 = 18\n\
                         S4 = 18\n\
                         H1 = 100\n\
                         H2 = 200\n\
                         H3 = 300\n\
                         H4 = 400\n";

        // Epoch omits jc trio entirely (Phase E shape) + conf lacks them →
        // defaults land.
        let mut p = sample_params(11);
        p.jc = None;
        p.jmin = None;
        p.jmax = None;
        let out = merge(conf_bare, &p).unwrap();
        assert!(out.contains("Jc = 4\n"), "default jc must insert:\n{out}");
        assert!(out.contains("Jmin = 55\n"));
        assert!(out.contains("Jmax = 120\n"));
        assert!(out.contains("I1 = <r 128>\n"), "default I1:\n{out}");
        assert!(
            out.contains("ContentPaddingAddition = 10-30\n"),
            "default CPA:\n{out}"
        );

        // Epoch Some beats the default.
        let p2 = AwgParams {
            jc: Some(99),
            content_padding_addition: Some("8-24".to_owned()),
            ..p.clone()
        };
        let out2 = merge(conf_bare, &p2).unwrap();
        assert!(
            out2.contains("Jc = 99\n"),
            "epoch must beat default:\n{out2}"
        );
        assert!(out2.contains("ContentPaddingAddition = 8-24\n"));

        // Conf line beats the default (preserve — no churn).
        let conf_with_jc = conf_bare.to_owned() + "Jc = 77\n";
        let out3 = merge(&conf_with_jc, &p).unwrap();
        assert!(
            out3.contains("Jc = 77\n"),
            "conf must beat default:\n{out3}"
        );
    }

    /// Must-match defaults NEVER fire on the top-up path: merge(conf, None,
    /// &defaults) inserts client-class keys only — S/H/HPK/RT can't be
    /// faked because the Option wrapper sits at the params level (D3).
    #[test]
    fn startup_top_up_inserts_only_client_class_defaults() {
        let conf_bare = "[Interface]\n\
                         PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n\
                         Address = 10.9.0.2/32\n\
                         Jc = 9\n\
                         Jmin = 3\n\
                         Jmax = 500\n\
                         S1 = 17\n\
                         S2 = 18\n\
                         S4 = 18\n\
                         H1 = 100\n\
                         H2 = 200\n\
                         H3 = 300\n\
                         H4 = 400\n\
                         Table = off\n\
                         MTU = 1300\n\
                         \n\
                         [Peer]\n\
                         PublicKey = BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=\n\
                         Endpoint = motherly.example.com:51820\n\
                         AllowedIPs = 10.9.0.1/32\n\
                         PersistentKeepalive = 25\n";
        let out = merge_obfuscation_params(conf_bare, None, &test_defaults()).unwrap();
        // Client-class inserts land (conf lacked I1/CPA; jc trio already
        // present → preserved at their conf values, NOT re-defaulted).
        assert!(out.contains("I1 = <r 128>\n"), "top-up I1:\n{out}");
        assert!(
            out.contains("ContentPaddingAddition = 10-30\n"),
            "top-up CPA:\n{out}"
        );
        assert!(
            out.contains("Jc = 9\n"),
            "conf Jc preserved, not defaulted:\n{out}"
        );
        // Must-match fields are never invented.
        assert!(
            !out.contains("S3 ="),
            "no must-match line may be fabricated:\n{out}"
        );
        assert!(!out.contains("HeaderProtectionKey"));
        assert!(!out.contains("RandomTrailers"));
        assert!(!out.contains("DisableCookies"));
        // I2-I5 stay absent (empty per Amnezia convention — nothing to write).
        for key in ["I2", "I3", "I4", "I5"] {
            assert!(
                !out.contains(&format!("{key} =")),
                "{key} must stay absent:\n{out}"
            );
        }
    }

    /// Idempotent: the conf is the persistence — a second top-up on the
    /// merged output changes nothing (every client key now has a conf line
    /// → all preserved, no re-randomize, no duplicate lines).
    #[test]
    fn startup_top_up_is_idempotent_on_second_run() {
        let conf_bare = "[Interface]\n\
                         PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n\
                         Address = 10.9.0.2/32\n\
                         S1 = 17\n\
                         S2 = 18\n\
                         S4 = 18\n\
                         H1 = 100\n\
                         H2 = 200\n\
                         H3 = 300\n\
                         H4 = 400\n";
        let once = merge_obfuscation_params(conf_bare, None, &test_defaults()).unwrap();
        let twice = merge_obfuscation_params(&once, None, &test_defaults()).unwrap();
        assert_eq!(once, twice, "second top-up must be a byte-identical no-op");
        assert_eq!(once.matches("I1 =").count(), 1);
        assert_eq!(once.matches("ContentPaddingAddition =").count(), 1);
    }

    /// Generation produces values inside the spec'd bands (sampled — the
    /// bands are consts so this is a smoke check, not a distribution test).
    #[test]
    fn client_defaults_generate_within_bands() {
        for _ in 0..50 {
            let d = ClientDefaults::generate().unwrap();
            assert!((3..=6).contains(&d.jc), "jc band: {}", d.jc);
            assert!((40..=89).contains(&d.jmin), "jmin band: {}", d.jmin);
            let delta = d.jmax - d.jmin;
            assert!((50..=250).contains(&delta), "jmax delta band: {delta}");
            let (lo, hi) = d
                .content_padding_addition
                .split_once('-')
                .map(|(a, b)| (a.parse::<i64>().unwrap(), b.parse::<i64>().unwrap()))
                .unwrap();
            assert!((8..=24).contains(&lo), "cpa lo band: {lo}");
            assert!((8..=40).contains(&(hi - lo)), "cpa delta band: {}", hi - lo);
            assert!(hi <= 64, "cpa total <= 64: {hi}");
            // I1 is `<r N>` with N in [32,256] — the band is the draw range
            // (3x-ui emits randInt(32,256) inside the tag), never a literal.
            let n: i64 =
                d.i1.strip_prefix("<r ")
                    .and_then(|s| s.strip_suffix('>'))
                    .and_then(|s| s.parse().ok())
                    .unwrap_or_else(|| panic!("i1 must be `<r N>`: {:?}", d.i1));
            assert!((32..=256).contains(&n), "i1 rand band: {n}");
        }
    }

    /// FIELD_SPECS self-consistency: unique keys, every key reachable in the
    /// table order, must-match fields never carry defaults (D1 — they are
    /// never edge-generated).
    #[test]
    fn field_specs_table_invariants() {
        let mut seen = std::collections::HashSet::new();
        for spec in FIELD_SPECS {
            assert!(seen.insert(spec.key), "duplicate key {}", spec.key);
            assert!(
                matches!(spec.section, Section::Interface),
                "{}: all mergeable keys are [Interface]-only",
                spec.key
            );
            if spec.class == MergeClass::MustMatch {
                let d = test_defaults();
                assert!(
                    (spec.default)(&d).is_none(),
                    "must-match {} must never have an edge default",
                    spec.key
                );
            }
        }
        // The precondition lookup names must resolve to table fields.
        for f in [
            "s1",
            "s2",
            "s3",
            "s4",
            "h1",
            "h2",
            "h3",
            "h4",
            "header_protection_key",
        ] {
            assert!(
                FIELD_SPECS.iter().any(|s| s.field == f),
                "precondition references unknown field {f}"
            );
        }
    }
}
