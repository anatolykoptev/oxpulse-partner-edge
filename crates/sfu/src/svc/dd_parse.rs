//! AV1 Dependency Descriptor (DD) bit-parser — G3 Phase 1.
//!
//! Pure, zero-str0m-coupling bit-parser for the AV1 RTP Dependency Descriptor
//! header extension (Appendix A of the AV1 RTP spec):
//! <https://aomediacodec.github.io/av1-rtp-spec/#dependency-descriptor-rtp-header-extension>.
//!
//! The DD is a **cleartext** RTP header extension — readable under SFrame
//! (RFC 9605) E2EE because we do NOT perform CryptEx / RFC 9335 header-
//! extension encryption. This parser never touches the encrypted payload.
//!
//! ## Design goals
//!
//! * **Never panic.** A relay/SFU must not crash on adversarial or malformed
//!   header extensions. Every parse error → `None` (fail-soft: the caller
//!   forwards the packet as if no layer info were available).
//! * **Zero str0m coupling.** This module takes `&[u8]` and an optional prior
//!   structure, returns `Option<DependencyDescriptor>`. No `MediaData`, no
//!   `ExtensionValues`, no `Mid` — the stream-keyed structure cache lives in
//!   [`super::dd_ext`] (`DdStructureCache`), which is the layer that has stream
//!   context. This keeps the parser unit-testable in isolation.
//! * **P1 scope.** Resolves `temporal_id` (acted on by the fanout temporal
//!   drop) and `spatial_id` (parsed + stored for P2, NOT acted on). DTIs,
//!   fdiffs, and chains are parsed and stored so the structure round-trips
//!   correctly and P2 can act on them without re-implementing the parser.
//!
//! ## Decode-safety invariant (temporal-layer drop)
//!
//! Temporal-layer drop is decode-safe because in temporal SVC (e.g. L1T3) a
//! frame at `temporal_id = T` references **only** frames at `temporal_id ≤ T`
//! (AV1 spec §3: "a temporal layer with temporal_id T … is only allowed to
//! reference previously coded video data having temporal_id T' and spatial_id
//! S', where T' <= T and S' <= S"). Dropping every frame with
//! `temporal_id > cap` therefore leaves a self-consistent, decodable
//! lower-rate stream — no remaining frame depends on a dropped one. The
//! fanout never drops a frame the remaining stream depends on. **Spatial**
//! drop is out of scope (P2) and is NOT performed here.

// ─── Bit reader ─────────────────────────────────────────────────────────────

/// MSB-first bit reader over a byte slice. All DD fields are big-endian /
/// most-significant-bit-first per the AV1 RTP spec.
///
/// Every method returns `Option<T>`; `None` signals "not enough bits"
/// (short input). The parser propagates `None` as a fail-soft `None` result
/// — never panics.
struct BitReader<'a> {
    bytes: &'a [u8],
    /// Bit offset from the start of `bytes` (0 = MSB of byte 0).
    bit_pos: usize,
}

impl<'a> BitReader<'a> {
    fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, bit_pos: 0 }
    }

    /// Total bits available.
    fn total_bits(&self) -> usize {
        self.bytes.len() * 8
    }

    /// Bits remaining from the current position.
    fn remaining(&self) -> usize {
        self.total_bits().saturating_sub(self.bit_pos)
    }

    /// Read `n` bits as a `u32` (MSB-first). Returns `None` if not enough bits.
    /// `n` must be ≤ 32; `n == 0` returns `Some(0)` without advancing.
    fn read_bits(&mut self, n: u32) -> Option<u32> {
        if n == 0 {
            return Some(0);
        }
        if n > 32 || self.remaining() < n as usize {
            return None;
        }
        let mut result: u32 = 0;
        for _ in 0..n {
            let byte_idx = self.bit_pos / 8;
            let bit_idx = 7 - (self.bit_pos % 8); // MSB-first
            let bit = (self.bytes[byte_idx] >> bit_idx) & 1;
            result = (result << 1) | bit as u32;
            self.bit_pos += 1;
        }
        Some(result)
    }

    /// Read 1 bit as a `bool`.
    fn read_bool(&mut self) -> Option<bool> {
        self.read_bits(1).map(|v| v != 0)
    }

    /// Read a non-symmetric unsigned integer with maximum value count `n`
    /// (output in range `0..=n-1`). Implements `ns(n)` from the AV1 RTP spec
    /// Appendix A.8.2.
    fn read_ns(&mut self, n: u32) -> Option<u32> {
        if n <= 1 {
            // ns(0) and ns(1) both consume 0 bits and return 0.
            // ns(0) is undefined by the spec but chain_cnt=ns(DtCnt+1) where
            // DtCnt≥1, so n≥2 in practice. Guard anyway for robustness.
            return Some(0);
        }
        // w = ceil(log2(n)) — computed by counting shifts until x == 0.
        let mut w: u32 = 0;
        let mut x = n;
        while x != 0 {
            x >>= 1;
            w += 1;
        }
        let m = (1u32 << w) - n;
        let v = self.read_bits(w - 1)?;
        if v < m {
            Some(v)
        } else {
            let extra = self.read_bits(1)?;
            Some((v << 1) - m + extra)
        }
    }
}

// ─── Data types ─────────────────────────────────────────────────────────────

/// A parsed Dependency Descriptor.
///
/// `temporal_id` / `spatial_id` are `None` when the frame's template could not
/// be resolved against either an attached structure (this frame is a keyframe
/// carrying `structure`) or the prior cached structure (template-only frame).
/// The fanout treats `None` as fail-soft: **forward** (do not drop).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DependencyDescriptor {
    pub start_of_frame: bool,
    pub end_of_frame: bool,
    /// 6-bit template id from the mandatory descriptor.
    pub frame_dependency_template_id: u8,
    /// 16-bit frame number from the mandatory descriptor.
    pub frame_number: u16,
    /// Resolved temporal layer id, or `None` if unresolvable.
    pub temporal_id: Option<u8>,
    /// Resolved spatial layer id, or `None` if unresolvable. Parsed + stored
    /// for P2; P1 does NOT act on it.
    pub spatial_id: Option<u8>,
    /// The attached `template_dependency_structure`, present only on
    /// keyframes (when `template_dependency_structure_present_flag == 1`).
    /// The caller should cache this per-stream for resolving subsequent
    /// template-only DDs.
    pub structure: Option<TemplateDependencyStructure>,
}

/// A frame dependency template: one entry in the `template_dependency_structure`.
///
/// DTIs, fdiffs, and chain fdiffs are parsed and stored for P2 (spatial drop,
/// chain/decode-target integrity). P1 only reads `temporal_id` and `spatial_id`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FrameDependencyTemplate {
    pub temporal_id: u8,
    pub spatial_id: u8,
    /// `DtCnt` entries, each 2 bits. Values: 0=NotPresent, 1=Discardable,
    /// 2=Switch, 3=Required.
    pub dtis: Vec<u8>,
    /// Frame differences (fdiff values, each = `fdiff_minus_one + 1`).
    pub fdiffs: Vec<u8>,
    /// `chain_cnt` entries, each 4 bits (template_chain_fdiff).
    pub chain_fdiffs: Vec<u8>,
}

/// The `template_dependency_structure` — the "attached structure" sent on
/// keyframes. Describes the set of templates and their layer/dependency info.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TemplateDependencyStructure {
    /// 6-bit offset; templateIndex = (frame_template_id + 64 - offset) % 64.
    pub template_id_offset: u8,
    /// Number of templates (`TemplateCnt`).
    pub template_count: u8,
    /// `DtCnt = dt_cnt_minus_one + 1`.
    pub dt_cnt: u8,
    /// `chain_cnt` from `template_chains()`.
    pub chain_cnt: u8,
    /// Highest temporal id across all templates.
    pub max_temporal_id: u8,
    /// Highest spatial id across all templates.
    pub max_spatial_id: u8,
    /// The templates, indexed 0..template_count.
    pub templates: Vec<FrameDependencyTemplate>,
}

// ─── Parser ─────────────────────────────────────────────────────────────────

/// Parse a Dependency Descriptor from raw extension bytes.
///
/// `prior_structure` is the most-recently-seen `TemplateDependencyStructure`
/// for the same stream (used to resolve template-only DDs that carry only a
/// `frame_dependency_template_id` and no attached structure). Pass `None` for
/// the first packet of a stream (or when no structure has been cached yet);
/// the parser will still succeed if the frame carries its own structure.
///
/// Returns `None` on malformed / short / invalid input — **never panics**.
/// The caller must treat `None` as fail-soft: forward the packet without
/// layer info (do not drop, do not crash).
pub fn parse_dependency_descriptor(
    bytes: &[u8],
    prior_structure: Option<&TemplateDependencyStructure>,
) -> Option<DependencyDescriptor> {
    let sz = bytes.len();
    // The mandatory descriptor alone is 24 bits = 3 bytes. The spec requires
    // `sz >= 3` for a valid DD (mandatory_descriptor_fields consumes 24 bits).
    // `sz > 3` gates the extended fields (5 flag bits + structure + overrides).
    if sz < 3 {
        return None;
    }
    let mut r = BitReader::new(bytes);

    // ── mandatory_descriptor_fields ──────────────────────────────────────
    let start_of_frame = r.read_bool()?;
    let end_of_frame = r.read_bool()?;
    let frame_dependency_template_id = r.read_bits(6)? as u8;
    let frame_number = r.read_bits(16)? as u16;

    // ── extended / no-extended descriptor fields ─────────────────────────
    let mut structure: Option<TemplateDependencyStructure> = None;
    // active_decode_targets_bitmask defaults to "all active" per the spec:
    //   if template_dependency_structure_present_flag: bitmask = (1<<DtCnt)-1
    // We don't expose it in P1 (P2 will use it for decode-target filtering).
    let mut _active_decode_targets_bitmask: u32 = 0;
    let custom_dtis_flag;
    let custom_fdiffs_flag;
    let custom_chains_flag;

    if sz > 3 {
        let template_dependency_structure_present = r.read_bool()?;
        let active_decode_targets_present = r.read_bool()?;
        custom_dtis_flag = r.read_bool()?;
        custom_fdiffs_flag = r.read_bool()?;
        custom_chains_flag = r.read_bool()?;

        if template_dependency_structure_present {
            let parsed_structure = parse_template_dependency_structure(&mut r)?;
            // active_decode_targets_bitmask defaults to all-active when the
            // structure is present and active_decode_targets_present is false.
            _active_decode_targets_bitmask = (1u32 << parsed_structure.dt_cnt) - 1;
            if active_decode_targets_present {
                _active_decode_targets_bitmask = r.read_bits(parsed_structure.dt_cnt as u32)?;
            }
            structure = Some(parsed_structure);
        } else if active_decode_targets_present {
            // active_decode_targets_present without a structure requires a
            // prior structure to know DtCnt. If we have one, read the bitmask;
            // otherwise this is malformed (can't know the width).
            let ps = prior_structure?;
            _active_decode_targets_bitmask = r.read_bits(ps.dt_cnt as u32)?;
        }
    } else {
        // no_extended_descriptor_fields: all custom flags default to 0.
        custom_dtis_flag = false;
        custom_fdiffs_flag = false;
        custom_chains_flag = false;
    }

    // ── frame_dependency_definition ──────────────────────────────────────
    // Resolve the frame's template against the attached structure (if any)
    // or the prior cached structure. If neither is available, temporal_id
    // and spatial_id remain None (fail-soft: forward).
    let resolve_structure = structure.as_ref().or(prior_structure);

    let (temporal_id, spatial_id) = match resolve_structure {
        Some(s) => {
            let template_index = ((frame_dependency_template_id as u32 + 64
                - s.template_id_offset as u32)
                % 64) as usize;
            if template_index >= s.template_count as usize {
                // template_id out of range — malformed per spec ("return // error").
                return None;
            }
            let tpl = &s.templates[template_index];
            (Some(tpl.temporal_id), Some(tpl.spatial_id))
        }
        None => (None, None),
    };

    // Consume the per-frame override fields (custom_dtis / custom_fdiffs /
    // custom_chains) so the bit stream is fully parsed. These are NOT stored
    // on the DependencyDescriptor in P1 — P2 will use them for decode-target
    // integrity. We must still consume them to validate the DD is well-formed.
    if let Some(s) = resolve_structure {
        if custom_dtis_flag {
            // frame_dtis(): DtCnt × 2 bits
            for _ in 0..s.dt_cnt {
                let _dti = r.read_bits(2)?;
            }
        }
        if custom_fdiffs_flag {
            // frame_fdiffs(): next_fdiff_size (2 bits) loop
            loop {
                let next_fdiff_size = r.read_bits(2)?;
                if next_fdiff_size == 0 {
                    break;
                }
                let _fdiff = r.read_bits(4 * next_fdiff_size)?;
            }
        }
        if custom_chains_flag {
            // frame_chains(): chain_cnt × 8 bits
            for _ in 0..s.chain_cnt {
                let _chain_fdiff = r.read_bits(8)?;
            }
        }
    } else if custom_dtis_flag || custom_fdiffs_flag || custom_chains_flag {
        // Custom overrides without any structure (neither attached nor prior)
        // — can't know DtCnt / chain_cnt to parse them. Malformed.
        return None;
    }

    // The spec pads the remaining bits to `sz * 8` with zero_padding. We
    // don't verify the padding is zero (some encoders emit non-zero garbage;
    // failing on that would be over-strict for a relay). Successful parse.
    let _ = r.remaining();

    Some(DependencyDescriptor {
        start_of_frame,
        end_of_frame,
        frame_dependency_template_id,
        frame_number,
        temporal_id,
        spatial_id,
        structure,
    })
}

/// Parse `template_dependency_structure()` from the bit reader.
fn parse_template_dependency_structure(r: &mut BitReader) -> Option<TemplateDependencyStructure> {
    let template_id_offset = r.read_bits(6)? as u8;
    let dt_cnt_minus_one = r.read_bits(5)? as u8;
    let dt_cnt = dt_cnt_minus_one.checked_add(1)?;
    // DtCnt is a 5-bit field (`dt_cnt_minus_one`), so `dt_cnt` ∈ 1..=32.
    // Reject `dt_cnt >= 32`: 32 decode targets is absurd (no real AV1 SVC
    // stream uses more than a handful), AND `(1u32 << 32)` panics on
    // shift-overflow in debug builds (the caller computes
    // `(1u32 << dt_cnt) - 1` for the active-decode-targets bitmask). A
    // crafted keyframe with `dt_cnt_minus_one == 0b11111` would otherwise
    // panic-exit the SFU (debug/CI) or silently mask a wrong bitmask
    // (release). 31 is the realistic ceiling.
    if dt_cnt >= 32 {
        return None;
    }

    // template_layers(): produces TemplateCnt templates with (spatial_id, temporal_id).
    let (templates_layers, max_temporal_id, max_spatial_id) = parse_template_layers(r)?;

    let template_count = templates_layers.len() as u8;
    if template_count == 0 {
        return None; // spec: at least one template (next_layer_idc=3 terminates after ≥1)
    }

    // Per the AV1-RTP spec `frame_dependency_structure()`, the per-template
    // fields are read as THREE SEPARATE FULL BLOCKS over ALL templates, in
    // this fixed order:
    //   1. template_dtis()    — loop ALL templates × ALL decode-targets
    //   2. template_fdiffs()  — THEN loop ALL templates
    //   3. template_chains()  — THEN loop ALL templates (if chain_cnt > 0)
    // Reading them per-template-interleaved (tpl0.dtis, tpl0.fdiffs,
    // tpl1.dtis, tpl1.fdiffs, …) desyncs the bit position when
    // `template_count > 1`: on real browser DD (L1T3/L2T3) the keyframe
    // structure parse fails → parse returns None → structure never cached
    // → every subsequent template-only frame is unresolvable → the
    // temporal drop silently no-ops. This matches libwebrtc
    // `RtpDependencyDescriptorReader::ReadTemplateDependencyStructure`.
    let mut templates: Vec<FrameDependencyTemplate> = templates_layers
        .into_iter()
        .map(|(sid, tid)| FrameDependencyTemplate {
            temporal_id: tid,
            spatial_id: sid,
            dtis: Vec::with_capacity(dt_cnt as usize),
            fdiffs: Vec::new(),
            chain_fdiffs: Vec::new(),
        })
        .collect();

    // 1. template_dtis(): template_count × dt_cnt × 2 bits — one full block.
    for tpl in templates.iter_mut() {
        for _ in 0..dt_cnt {
            tpl.dtis.push(r.read_bits(2)? as u8);
        }
    }

    // 2. template_fdiffs(): template_count × template_fdiffs() — one full block.
    for tpl in templates.iter_mut() {
        tpl.fdiffs = parse_template_fdiffs(r)?;
    }

    // 3. template_chains(): chain_cnt = ns(DtCnt + 1)
    let chain_cnt = r.read_ns(dt_cnt as u32 + 1)? as u8;
    if chain_cnt > 0 {
        // decode_target_protected_by: DtCnt × ns(chain_cnt)
        for _ in 0..dt_cnt {
            let _protected_by = r.read_ns(chain_cnt as u32)?;
        }
        // template_chain_fdiff: template_count × chain_cnt × 4 bits — one full block.
        for tpl in templates.iter_mut() {
            let mut chain_fdiffs = Vec::with_capacity(chain_cnt as usize);
            for _ in 0..chain_cnt {
                chain_fdiffs.push(r.read_bits(4)? as u8);
            }
            tpl.chain_fdiffs = chain_fdiffs;
        }
    }

    // decode_target_layers(): no bits consumed (computed from templates).

    // resolutions_present_flag
    let resolutions_present = r.read_bool()?;
    if resolutions_present {
        // render_resolutions(): (max_spatial_id + 1) × (16 + 16) bits
        for _ in 0..=max_spatial_id {
            let _w = r.read_bits(16)?;
            let _h = r.read_bits(16)?;
        }
    }

    Some(TemplateDependencyStructure {
        template_id_offset,
        template_count,
        dt_cnt,
        chain_cnt,
        max_temporal_id,
        max_spatial_id,
        templates,
    })
}

/// Result of [`parse_template_layers`]: the per-template `(spatial_id,
/// temporal_id)` pairs plus the structure-wide maxima.
type TemplateLayers = (Vec<(u8, u8)>, u8, u8);

/// Parse `template_layers()` — returns `Vec<(spatial_id, temporal_id)>`,
/// plus `max_temporal_id` and `max_spatial_id`.
fn parse_template_layers(r: &mut BitReader) -> Option<TemplateLayers> {
    let mut temporal_id: u8 = 0;
    let mut spatial_id: u8 = 0;
    let mut max_temporal_id: u8 = 0;
    let mut templates: Vec<(u8, u8)> = Vec::new();

    loop {
        templates.push((spatial_id, temporal_id));
        let next_layer_idc = r.read_bits(2)?;
        match next_layer_idc {
            0 => {
                // same sid and tid — continue
            }
            1 => {
                temporal_id = temporal_id.checked_add(1)?;
                if temporal_id > max_temporal_id {
                    max_temporal_id = temporal_id;
                }
            }
            2 => {
                temporal_id = 0;
                spatial_id = spatial_id.checked_add(1)?;
            }
            3 => break,          // no more templates
            _ => unreachable!(), // 2-bit read → 0..=3
        }
        // Guard against runaway structures (spec allows up to 64 templates
        // since template_id is 6 bits). Prevents adversarial infinite loops.
        if templates.len() >= 64 {
            return None;
        }
    }

    let max_spatial_id = spatial_id;
    Some((templates, max_temporal_id, max_spatial_id))
}

/// Parse `template_fdiffs()` for a single template — returns the list of
/// fdiff values (each = `fdiff_minus_one + 1`).
fn parse_template_fdiffs(r: &mut BitReader) -> Option<Vec<u8>> {
    let mut fdiffs: Vec<u8> = Vec::new();
    let mut follows = r.read_bool()?;
    while follows {
        let fdiff_minus_one = r.read_bits(4)? as u8;
        fdiffs.push(fdiff_minus_one.checked_add(1)?);
        follows = r.read_bool()?;
        // Guard: a template can reference at most 7 frames (AV1 has 8 ref
        // slots, one is the frame itself). Cap at 8 to prevent adversarial
        // loops.
        if fdiffs.len() >= 8 {
            return None;
        }
    }
    Some(fdiffs)
}

// ─── Unit tests ─────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// MSB-first bit writer for constructing synthetic DD byte vectors in tests.
    struct BitWriter {
        bits: Vec<bool>,
    }

    impl BitWriter {
        fn new() -> Self {
            Self { bits: Vec::new() }
        }
        fn push_bits(&mut self, value: u32, n: u32) {
            for i in (0..n).rev() {
                self.bits.push((value >> i) & 1 != 0);
            }
        }
        fn push_bool(&mut self, v: bool) {
            self.bits.push(v);
        }
        fn push_ns(&mut self, n: u32, v: u32) {
            // Inverse of read_ns.
            if n <= 1 {
                return; // 0 bits
            }
            let mut w: u32 = 0;
            let mut x = n;
            while x != 0 {
                x >>= 1;
                w += 1;
            }
            let m = (1u32 << w) - n;
            if v < m {
                self.push_bits(v, w - 1);
            } else {
                let encoded = (v + m) >> 1;
                let extra = (v + m) & 1;
                self.push_bits(encoded, w - 1);
                self.push_bits(extra, 1);
            }
        }
        fn to_bytes(&self) -> Vec<u8> {
            let mut bytes = vec![0u8; self.bits.len().div_ceil(8)];
            for (i, &bit) in self.bits.iter().enumerate() {
                if bit {
                    bytes[i / 8] |= 1 << (7 - (i % 8));
                }
            }
            bytes
        }
        fn bit_count(&self) -> usize {
            self.bits.len()
        }
    }

    /// Build a minimal L1T3 keyframe DD: 3 templates (T0, T1, T2), 3 decode
    /// targets, 1 chain. Returns the raw DD bytes.
    ///
    /// Template layout (simplified 3-template L1T3):
    ///   Template 0: S=0, T=0  (keyframe base)
    ///   Template 1: S=0, T=1
    ///   Template 2: S=0, T=2
    fn build_l1t3_keyframe_dd(frame_number: u16, template_id: u8) -> Vec<u8> {
        let mut w = BitWriter::new();

        // mandatory_descriptor_fields
        w.push_bool(true); // start_of_frame
        w.push_bool(true); // end_of_frame
        w.push_bits(template_id as u32, 6); // frame_dependency_template_id
        w.push_bits(frame_number as u32, 16); // frame_number

        // extended_descriptor_fields
        w.push_bool(true); // template_dependency_structure_present
        w.push_bool(false); // active_decode_targets_present (all active)
        w.push_bool(false); // custom_dtis_flag
        w.push_bool(false); // custom_fdiffs_flag
        w.push_bool(false); // custom_chains_flag

        // template_dependency_structure
        w.push_bits(0, 6); // template_id_offset = 0
        w.push_bits(2, 5); // dt_cnt_minus_one = 2 (DtCnt=3)

        // template_layers: 3 templates
        // Template 0: S=0, T=0, next_layer_idc=1 (T++)
        w.push_bits(1, 2);
        // Template 1: S=0, T=1, next_layer_idc=1 (T++)
        w.push_bits(1, 2);
        // Template 2: S=0, T=2, next_layer_idc=3 (stop)
        w.push_bits(3, 2);

        // template_dtis: 3 templates × 3 DTs × 2 bits
        // Template 0 (T0): R R R = 3 3 3
        w.push_bits(3, 2);
        w.push_bits(3, 2);
        w.push_bits(3, 2);
        // Template 1 (T1): S D - = 2 1 0
        w.push_bits(2, 2);
        w.push_bits(1, 2);
        w.push_bits(0, 2);
        // Template 2 (T2): D - - = 1 0 0
        w.push_bits(1, 2);
        w.push_bits(0, 2);
        w.push_bits(0, 2);

        // template_fdiffs: 3 templates
        // Template 0: no fdiffs → fdiff_follows=0
        w.push_bool(false);
        // Template 1: fdiff=2 → fdiff_follows=1, fdiff_minus_one=1, fdiff_follows=0
        w.push_bool(true);
        w.push_bits(1, 4);
        w.push_bool(false);
        // Template 2: fdiff=1 → fdiff_follows=1, fdiff_minus_one=0, fdiff_follows=0
        w.push_bool(true);
        w.push_bits(0, 4);
        w.push_bool(false);

        // template_chains: chain_cnt = ns(4)
        // ns(4): w=3, m=4. value=1 < 4 → write 2 bits: 01
        w.push_ns(4, 1); // chain_cnt = 1
                         // decode_target_protected_by: 3 × ns(1) = 3 × 0 bits = nothing
                         // template_chain_fdiff: 3 templates × 1 chain × 4 bits
        w.push_bits(0, 4); // Template 0: chain_fdiff=0
        w.push_bits(2, 4); // Template 1: chain_fdiff=2
        w.push_bits(1, 4); // Template 2: chain_fdiff=1

        // resolutions_present_flag = 0
        w.push_bool(false);

        // frame_dependency_definition: no custom overrides → no extra bits.
        // zero_padding: pad to byte boundary.
        let _ = w.bit_count();

        w.to_bytes()
    }

    /// Build a template-only DD (no attached structure): just mandatory fields
    /// plus extended flags (all false). Used for non-keyframe frames that rely
    /// on the cached structure for resolution.
    fn build_template_only_dd(frame_number: u16, template_id: u8) -> Vec<u8> {
        let mut w = BitWriter::new();
        // mandatory_descriptor_fields
        w.push_bool(true); // start_of_frame
        w.push_bool(true); // end_of_frame
        w.push_bits(template_id as u32, 6);
        w.push_bits(frame_number as u32, 16);
        // extended_descriptor_fields (sz > 3 → must be present)
        w.push_bool(false); // template_dependency_structure_present
        w.push_bool(false); // active_decode_targets_present
        w.push_bool(false); // custom_dtis_flag
        w.push_bool(false); // custom_fdiffs_flag
        w.push_bool(false); // custom_chains_flag
        w.to_bytes()
    }

    #[test]
    fn parse_l1t3_keyframe_resolves_temporal_id_0() {
        let bytes = build_l1t3_keyframe_dd(0, 0);
        let dd = parse_dependency_descriptor(&bytes, None).expect("keyframe DD must parse");
        assert_eq!(dd.frame_number, 0);
        assert_eq!(dd.frame_dependency_template_id, 0);
        assert_eq!(dd.temporal_id, Some(0));
        assert_eq!(dd.spatial_id, Some(0));
        assert!(dd.structure.is_some(), "keyframe must carry structure");
        let s = dd.structure.unwrap();
        assert_eq!(s.template_count, 3);
        assert_eq!(s.dt_cnt, 3);
        assert_eq!(s.max_temporal_id, 2);
        assert_eq!(s.max_spatial_id, 0);
        // Template 0: T0, Template 1: T1, Template 2: T2
        assert_eq!(s.templates[0].temporal_id, 0);
        assert_eq!(s.templates[1].temporal_id, 1);
        assert_eq!(s.templates[2].temporal_id, 2);
    }

    #[test]
    fn parse_template_only_dd_resolves_against_prior_structure() {
        let keyframe = build_l1t3_keyframe_dd(0, 0);
        let kf_dd = parse_dependency_descriptor(&keyframe, None).unwrap();
        let structure = kf_dd.structure.unwrap();

        // Template-only frame at template_id=2 → temporal_id=2
        let frame_t2 = build_template_only_dd(1, 2);
        let dd = parse_dependency_descriptor(&frame_t2, Some(&structure))
            .expect("template-only DD with prior structure must parse");
        assert_eq!(dd.temporal_id, Some(2));
        assert_eq!(dd.spatial_id, Some(0));
        assert!(
            dd.structure.is_none(),
            "template-only DD carries no structure"
        );

        // Template-only frame at template_id=1 → temporal_id=1
        let frame_t1 = build_template_only_dd(2, 1);
        let dd = parse_dependency_descriptor(&frame_t1, Some(&structure)).unwrap();
        assert_eq!(dd.temporal_id, Some(1));

        // Template-only frame at template_id=0 → temporal_id=0
        let frame_t0 = build_template_only_dd(3, 0);
        let dd = parse_dependency_descriptor(&frame_t0, Some(&structure)).unwrap();
        assert_eq!(dd.temporal_id, Some(0));
    }

    #[test]
    fn template_only_dd_before_any_structure_fails_soft() {
        // No prior structure → temporal_id unresolvable → None (fail-soft).
        let frame = build_template_only_dd(0, 1);
        let dd = parse_dependency_descriptor(&frame, None)
            .expect("template-only DD with no structure must still parse (fail-soft)");
        assert_eq!(dd.temporal_id, None);
        assert_eq!(dd.spatial_id, None);
    }

    #[test]
    fn malformed_truncated_bytes_return_none() {
        // Too short for even the mandatory descriptor (3 bytes).
        assert!(parse_dependency_descriptor(&[0x00, 0x01], None).is_none());
        // Empty.
        assert!(parse_dependency_descriptor(&[], None).is_none());
        // Exactly 3 bytes (mandatory only, no extended) — valid if it parses.
        // Build a valid 3-byte DD: SOF=1, EOF=1, template_id=0, frame_number=0.
        // Bits: 1 1 000000 0000000000000000 = 0xC0 0x00 0x00
        let dd = parse_dependency_descriptor(&[0xC0, 0x00, 0x00], None);
        assert!(dd.is_some(), "3-byte mandatory-only DD is valid");
        let dd = dd.unwrap();
        assert_eq!(dd.temporal_id, None); // no structure → unresolvable
    }

    #[test]
    fn truncated_structure_returns_none() {
        // A keyframe DD whose structure is truncated mid-parse.
        // Start with a valid keyframe DD then chop off the last few bytes.
        let full = build_l1t3_keyframe_dd(0, 0);
        let truncated = &full[..full.len() - 2];
        assert!(
            parse_dependency_descriptor(truncated, None).is_none(),
            "truncated structure must return None, not panic"
        );
    }

    #[test]
    fn out_of_range_template_id_returns_none() {
        let keyframe = build_l1t3_keyframe_dd(0, 0);
        let kf_dd = parse_dependency_descriptor(&keyframe, None).unwrap();
        let structure = kf_dd.structure.unwrap();

        // template_id=5 but structure only has 3 templates (0..2).
        let frame = build_template_only_dd(1, 5);
        assert!(
            parse_dependency_descriptor(&frame, Some(&structure)).is_none(),
            "out-of-range template_id must return None"
        );
    }

    #[test]
    fn parser_never_panics_on_random_bytes() {
        // Feed adversarial random-ish bytes — must never panic, only return
        // Some or None.
        let mut state: u32 = 0xDEAD_BEEF;
        for _ in 0..1000 {
            // LCG for deterministic but varied input.
            state = state.wrapping_mul(1664525).wrapping_add(1013904223);
            let len = (state % 20) as usize + 1;
            let bytes: Vec<u8> = (0..len)
                .map(|i| {
                    ((state.wrapping_add((i as u32).wrapping_mul(2654435761))) >> (i % 24)) as u8
                })
                .collect();
            let _ = parse_dependency_descriptor(&bytes, None);
        }
    }

    /// Build a 2-template keyframe DD with DISTINCT dti and fdiff values per
    /// template, so a per-template-interleaved read desyncs the bit position
    /// and corrupts `templates[1].dtis` / `templates[1].fdiffs`. The spec
    /// mandates `template_dtis()` and `template_fdiffs()` as TWO SEPARATE
    /// FULL BLOCKS over ALL templates — see
    /// `frame_dependency_structure()` in the AV1-RTP spec.
    ///
    /// Layout:
    ///   dt_cnt = 2, template_count = 2
    ///   Template 0: S=0, T=0, dtis=[1,2], fdiffs=[2]
    ///   Template 1: S=0, T=1, dtis=[3,0], fdiffs=[3,1]
    fn build_two_template_distinct_dti_fdiff_dd() -> Vec<u8> {
        let mut w = BitWriter::new();
        // mandatory_descriptor_fields
        w.push_bool(true); // SOF
        w.push_bool(true); // EOF
        w.push_bits(0, 6); // template_id = 0
        w.push_bits(0, 16); // frame_number = 0
                            // extended_descriptor_fields
        w.push_bool(true); // structure_present
        w.push_bool(false); // active_decode_targets_present
        w.push_bool(false); // custom_dtis
        w.push_bool(false); // custom_fdiffs
        w.push_bool(false); // custom_chains
                            // template_dependency_structure
        w.push_bits(0, 6); // template_id_offset = 0
        w.push_bits(1, 5); // dt_cnt_minus_one = 1 (DtCnt = 2)
                           // template_layers: 2 templates
                           // Template 0: S=0, T=0, next_layer_idc=1 (T++)
        w.push_bits(1, 2);
        // Template 1: S=0, T=1, next_layer_idc=3 (stop)
        w.push_bits(3, 2);
        // template_dtis(): SEPARATE BLOCK — template_count × dt_cnt × 2 bits
        // Template 0: [1, 2]
        w.push_bits(1, 2);
        w.push_bits(2, 2);
        // Template 1: [3, 0]
        w.push_bits(3, 2);
        w.push_bits(0, 2);
        // template_fdiffs(): SEPARATE BLOCK — template_count × template_fdiffs()
        // Template 0: fdiffs=[2] → follows=1, fdiff_minus_one=1, follows=0
        w.push_bool(true);
        w.push_bits(1, 4);
        w.push_bool(false);
        // Template 1: fdiffs=[3,1] → follows=1, fdiff_minus_one=2, follows=1,
        //                            fdiff_minus_one=0, follows=0
        w.push_bool(true);
        w.push_bits(2, 4);
        w.push_bool(true);
        w.push_bits(0, 4);
        w.push_bool(false);
        // template_chains(): chain_cnt = ns(3). ns(3): w=2, m=1, v=0 < 1 → 1 bit: 0
        w.push_ns(3, 0); // chain_cnt = 0 → no protected_by, no chain_fdiffs
                         // resolutions_present_flag = 0
        w.push_bool(false);
        w.to_bytes()
    }

    /// BLOCKER guarding test: with template_count ≥ 2 and DISTINCT dti/fdiff
    /// values, the parser MUST store the exact spec-mandated values. A
    /// per-template-interleaved read (tpl0.dtis, tpl0.fdiffs, tpl1.dtis, …)
    /// desyncs the bit position and corrupts `templates[1]`. This test
    /// asserts the EXACT stored dti/fdiff VALUES (not just lengths/counts),
    /// which the original test suite never did.
    #[test]
    fn two_template_structure_preserves_distinct_dti_fdiff_values() {
        let bytes = build_two_template_distinct_dti_fdiff_dd();
        let dd =
            parse_dependency_descriptor(&bytes, None).expect("2-template keyframe DD must parse");
        let s = dd.structure.expect("keyframe carries structure");
        assert_eq!(s.template_count, 2);
        assert_eq!(s.dt_cnt, 2);
        // Template 0: S=0, T=0
        assert_eq!(s.templates[0].spatial_id, 0);
        assert_eq!(s.templates[0].temporal_id, 0);
        assert_eq!(s.templates[0].dtis, vec![1, 2], "tpl0 dtis exact values");
        assert_eq!(s.templates[0].fdiffs, vec![2], "tpl0 fdiffs exact values");
        // Template 1: S=0, T=1 — the load-bearing assertions.
        assert_eq!(s.templates[1].spatial_id, 0);
        assert_eq!(s.templates[1].temporal_id, 1);
        assert_eq!(
            s.templates[1].dtis,
            vec![3, 0],
            "tpl1 dtis exact values (interleave bug corrupts these)"
        );
        assert_eq!(
            s.templates[1].fdiffs,
            vec![3, 1],
            "tpl1 fdiffs exact values (interleave bug corrupts these)"
        );
    }

    /// MAJOR guarding test: a crafted keyframe with
    /// `dt_cnt_minus_one == 0b11111` (dt_cnt = 32) must return `None` and
    /// MUST NOT panic. Pre-fix, the guard was `> 32` (let 32 through) and
    /// the structure parsed fully, then `(1u32 << 32) - 1` panicked on
    /// shift-overflow in debug builds (exit 101). The buffer below carries
    /// a COMPLETE 1-template structure (template_layers + 32×2 dtis + 1
    /// fdiff-follows=0 + chain_cnt=ns(33)=0 + resolutions=0) so pre-fix the
    /// parse reaches the shift; post-fix the `>= 32` guard returns `None`
    /// before reading template_layers. Run in debug (default `cargo test`).
    #[test]
    fn dt_cnt_32_keyframe_returns_none_no_panic() {
        let mut w = BitWriter::new();
        // mandatory_descriptor_fields
        w.push_bool(true);
        w.push_bool(true);
        w.push_bits(0, 6);
        w.push_bits(0, 16);
        // extended_descriptor_fields
        w.push_bool(true); // structure_present
        w.push_bool(false); // active_decode_targets_present
        w.push_bool(false); // custom_dtis
        w.push_bool(false); // custom_fdiffs
        w.push_bool(false); // custom_chains
                            // template_dependency_structure
        w.push_bits(0, 6); // template_id_offset = 0
        w.push_bits(0b11111, 5); // dt_cnt_minus_one = 31 → dt_cnt = 32
                                 // template_layers: 1 template, next_layer_idc=3 (stop)
        w.push_bits(3, 2);
        // template_dtis: 1 × 32 × 2 bits = 64 bits (all NotPresent=0)
        for _ in 0..32 {
            w.push_bits(0, 2);
        }
        // template_fdiffs: 1 template, follows=0 (no fdiffs)
        w.push_bool(false);
        // template_chains: chain_cnt = ns(33). ns(33): w=6, m=64-33=31,
        // v=0 < 31 → write w-1=5 bits: 00000. chain_cnt=0.
        w.push_ns(33, 0);
        // resolutions_present_flag = 0
        w.push_bool(false);
        let bytes = w.to_bytes();
        let result = parse_dependency_descriptor(&bytes, None);
        assert!(
            result.is_none(),
            "dt_cnt=32 must be rejected (absurd + shift-overflow), got Some"
        );
    }

    /// Multi-spatial-layer structure (next_layer_idc=2 → S++): verifies the
    /// parser handles the spatial-layer transition and stores per-template
    /// spatial_id / dtis correctly. L2T1: Template 0 (S=0,T=0), Template 1
    /// (S=1,T=0).
    #[test]
    fn multi_spatial_layer_structure_parses() {
        let mut w = BitWriter::new();
        // mandatory_descriptor_fields
        w.push_bool(true);
        w.push_bool(true);
        w.push_bits(0, 6);
        w.push_bits(0, 16);
        // extended_descriptor_fields
        w.push_bool(true);
        w.push_bool(false);
        w.push_bool(false);
        w.push_bool(false);
        w.push_bool(false);
        // template_dependency_structure
        w.push_bits(0, 6); // offset = 0
        w.push_bits(1, 5); // dt_cnt_minus_one = 1 (DtCnt = 2)
                           // template_layers: 2 templates with a spatial transition
                           // Template 0: S=0, T=0, next_layer_idc=2 (T=0, S++)
        w.push_bits(2, 2);
        // Template 1: S=1, T=0, next_layer_idc=3 (stop)
        w.push_bits(3, 2);
        // template_dtis(): SEPARATE BLOCK
        // Template 0: [3, 3]
        w.push_bits(3, 2);
        w.push_bits(3, 2);
        // Template 1: [2, 1]
        w.push_bits(2, 2);
        w.push_bits(1, 2);
        // template_fdiffs(): SEPARATE BLOCK
        // Template 0: no fdiffs → follows=0
        w.push_bool(false);
        // Template 1: fdiffs=[1] → follows=1, fdiff_minus_one=0, follows=0
        w.push_bool(true);
        w.push_bits(0, 4);
        w.push_bool(false);
        // template_chains: chain_cnt = ns(3) = 0
        w.push_ns(3, 0);
        // resolutions_present_flag = 0
        w.push_bool(false);
        let bytes = w.to_bytes();
        let dd = parse_dependency_descriptor(&bytes, None).expect("L2T1 keyframe DD must parse");
        let s = dd.structure.expect("keyframe carries structure");
        assert_eq!(s.template_count, 2);
        assert_eq!(s.max_spatial_id, 1, "spatial transition to S=1");
        assert_eq!(s.max_temporal_id, 0);
        assert_eq!(s.templates[0].spatial_id, 0);
        assert_eq!(s.templates[1].spatial_id, 1);
        assert_eq!(s.templates[0].dtis, vec![3, 3]);
        assert_eq!(s.templates[1].dtis, vec![2, 1]);
        assert_eq!(s.templates[0].fdiffs, Vec::<u8>::new());
        assert_eq!(s.templates[1].fdiffs, vec![1]);
    }

    /// Strengthened adversarial/fuzz battery: deterministic cases for the
    /// known panic/corruption vectors alongside the random LCG sweep.
    #[test]
    fn parser_adversarial_battery_never_panics() {
        // 1) dt_cnt = 32 panic vector (MAJOR) — full 1-template structure so
        //    pre-fix the parse reaches `(1u32 << 32) - 1`; must not panic.
        {
            let mut w = BitWriter::new();
            w.push_bool(true);
            w.push_bool(true);
            w.push_bits(0, 6);
            w.push_bits(0, 16);
            w.push_bool(true); // structure_present
            w.push_bool(false);
            w.push_bool(false);
            w.push_bool(false);
            w.push_bool(false);
            w.push_bits(0, 6);
            w.push_bits(0b11111, 5); // dt_cnt = 32
            w.push_bits(3, 2); // 1 template, stop
            for _ in 0..32 {
                w.push_bits(0, 2); // 32 dtis
            }
            w.push_bool(false); // no fdiffs
            w.push_ns(33, 0); // chain_cnt = 0
            w.push_bool(false); // no resolutions
            let bytes = w.to_bytes();
            let _ = parse_dependency_descriptor(&bytes, None); // must not panic
        }
        // 2) Multi-spatial (next_layer_idc=2) structure — must not panic.
        {
            let bytes = {
                let mut w = BitWriter::new();
                w.push_bool(true);
                w.push_bool(true);
                w.push_bits(0, 6);
                w.push_bits(0, 16);
                w.push_bool(true);
                w.push_bool(false);
                w.push_bool(false);
                w.push_bool(false);
                w.push_bool(false);
                w.push_bits(0, 6);
                w.push_bits(1, 5); // dt_cnt = 2
                w.push_bits(2, 2); // next_layer_idc=2 (S++)
                w.push_bits(3, 2); // stop
                for _ in 0..8 {
                    w.push_bits(0, 8);
                }
                w.to_bytes()
            };
            let _ = parse_dependency_descriptor(&bytes, None); // must not panic
        }
        // 3) Distinct-dti/fdiff structure — must not panic (values checked
        //    in the dedicated test above).
        {
            let bytes = build_two_template_distinct_dti_fdiff_dd();
            let _ = parse_dependency_descriptor(&bytes, None);
        }
        // 4) Random LCG sweep — never panic.
        let mut state: u32 = 0xDEAD_BEEF;
        for _ in 0..2000 {
            state = state.wrapping_mul(1664525).wrapping_add(1013904223);
            let len = (state % 24) as usize + 1;
            let bytes: Vec<u8> = (0..len)
                .map(|i| {
                    ((state.wrapping_add((i as u32).wrapping_mul(2654435761))) >> (i % 24)) as u8
                })
                .collect();
            let _ = parse_dependency_descriptor(&bytes, None);
        }
    }

    #[test]
    fn l1t3_full_stream_temporal_resolution() {
        // Simulate a full L1T3 stream: keyframe + 5 subsequent frames cycling
        // through T0, T1, T2, T0, T1. Verify temporal_id per frame.
        let keyframe = build_l1t3_keyframe_dd(0, 0);
        let kf_dd = parse_dependency_descriptor(&keyframe, None).unwrap();
        let structure = kf_dd.structure.unwrap();

        let sequence = [(1u16, 0u8, 0u8), (2, 1, 1), (3, 2, 2), (4, 0, 0), (5, 1, 1)];
        for (frame_num, template_id, expected_tid) in sequence {
            let bytes = build_template_only_dd(frame_num, template_id);
            let dd = parse_dependency_descriptor(&bytes, Some(&structure))
                .unwrap_or_else(|| panic!("frame {} must parse", frame_num));
            assert_eq!(
                dd.temporal_id,
                Some(expected_tid),
                "frame {} (template {}) expected temporal_id {}",
                frame_num,
                template_id,
                expected_tid
            );
        }
    }
}
