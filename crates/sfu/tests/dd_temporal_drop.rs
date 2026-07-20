//! G3 Phase 1 — Dependency Descriptor temporal-layer drop integration test.
//!
//! Drives the REAL `handle_media_data_out` fanout path with synthetic DD
//! byte vectors (no live encoder) and asserts:
//!  (a) the parser extracts the correct `temporal_id` per frame;
//!  (b) with `cap=1`, `temporal_id=2` frames DROP and `temporal_id` 0/1
//!      FORWARD;
//!  (c) a template-only DD before any structure → fail-soft FORWARD;
//!  (d) malformed/truncated bytes → `None` → FORWARD, no panic.
//!
//! The drop is observed via `Registry::delivered_media_count` (which reads
//! `layer_passed_count` — the test-only counter that ticks BEFORE the
//! writer.write call on unnegotiated Rtc). A DROPPED packet never reaches
//! the layer filter, so its count stays flat; a FORWARDED packet ticks +1.
//!
//! Falsification: reverting the temporal-drop wiring in `fanout.rs` makes
//! test (b) go RED (all frames forward regardless of cap).

use oxpulse_sfu::client::test_seed::{make_media_data, new_client, seed_track_in};
use oxpulse_sfu::svc::DdPresent;
use oxpulse_sfu::{ClientId, Propagated, Registry};
use str0m::media::{MediaData, MediaKind};

// ─── Synthetic DD byte-vector builders (mirror dd_parse unit tests) ─────────

/// MSB-first bit writer for constructing synthetic DD byte vectors.
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
        if n <= 1 {
            return;
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
}

/// Build a minimal L1T3 keyframe DD: 3 templates (T0, T1, T2), 3 decode
/// targets, 1 chain. The frame itself is at template_id → temporal_id.
fn build_l1t3_keyframe_dd(frame_number: u16, template_id: u8) -> Vec<u8> {
    let mut w = BitWriter::new();
    w.push_bool(true); // start_of_frame
    w.push_bool(true); // end_of_frame
    w.push_bits(template_id as u32, 6);
    w.push_bits(frame_number as u32, 16);
    // extended
    w.push_bool(true); // template_dependency_structure_present
    w.push_bool(false); // active_decode_targets_present
    w.push_bool(false); // custom_dtis
    w.push_bool(false); // custom_fdiffs
    w.push_bool(false); // custom_chains
                        // structure
    w.push_bits(0, 6); // template_id_offset
    w.push_bits(2, 5); // dt_cnt_minus_one = 2 (DtCnt=3)
                       // template_layers: 3 templates
    w.push_bits(1, 2); // T0 → next: T++
    w.push_bits(1, 2); // T1 → next: T++
    w.push_bits(3, 2); // T2 → stop
                       // template_dtis: 3×3×2 bits
    w.push_bits(3, 2);
    w.push_bits(3, 2);
    w.push_bits(3, 2); // T0: R R R
    w.push_bits(2, 2);
    w.push_bits(1, 2);
    w.push_bits(0, 2); // T1: S D -
    w.push_bits(1, 2);
    w.push_bits(0, 2);
    w.push_bits(0, 2); // T2: D - -
                       // template_fdiffs
    w.push_bool(false); // T0: none
    w.push_bool(true);
    w.push_bits(1, 4);
    w.push_bool(false); // T1: fdiff=2
    w.push_bool(true);
    w.push_bits(0, 4);
    w.push_bool(false); // T2: fdiff=1
                        // template_chains
    w.push_ns(4, 1); // chain_cnt=1
                     // decode_target_protected_by: 3 × ns(1) = 0 bits
    w.push_bits(0, 4); // T0 chain_fdiff
    w.push_bits(2, 4); // T1 chain_fdiff
    w.push_bits(1, 4); // T2 chain_fdiff
    w.push_bool(false); // resolutions_present = false
    w.to_bytes()
}

/// Build a template-only DD (no attached structure).
fn build_template_only_dd(frame_number: u16, template_id: u8) -> Vec<u8> {
    let mut w = BitWriter::new();
    w.push_bool(true); // start_of_frame
    w.push_bool(true); // end_of_frame
    w.push_bits(template_id as u32, 6);
    w.push_bits(frame_number as u32, 16);
    w.push_bool(false); // no structure
    w.push_bool(false); // no active_decode_targets
    w.push_bool(false); // no custom_dtis
    w.push_bool(false); // no custom_fdiffs
    w.push_bool(false); // no custom_chains
    w.to_bytes()
}

/// Build a `MediaData` carrying a DD in `ext_vals.user_values`.
fn make_dd_media_data(mid_tag: u8, dd_bytes: Vec<u8>) -> MediaData {
    let mut data = make_media_data(mid_tag, None);
    data.ext_vals.user_values.set(DdPresent(dd_bytes));
    data
}

// ─── Tests ──────────────────────────────────────────────────────────────────

#[test]
fn temporal_drop_cap1_drops_tid2_forwards_tid01() {
    let mut registry = Registry::new_for_tests();

    // Publisher A (ClientId 10) with a video track on mid tag 1.
    let mut a = new_client(ClientId(10));
    let _arc = seed_track_in(&mut a, 1, MediaKind::Video);
    registry.insert(a);

    // Subscriber B (ClientId 11).
    let b = new_client(ClientId(11));
    registry.insert(b);

    // B is at registry index 1 (A=0, B=1).
    const B: usize = 1;

    // Set B's temporal cap to 1 — drop temporal_id > 1 (i.e. T2).
    registry.set_max_vfm_temporal_layer_for_tests(B, 1);

    // ── (1) Keyframe at T0 (template_id=0) → carries structure, forwards. ──
    let kf = build_l1t3_keyframe_dd(0, 0);
    let data = make_dd_media_data(1, kf);
    registry.fanout_for_tests(&Propagated::MediaData(ClientId(10), data));
    assert_eq!(
        registry.delivered_media_count(B),
        1,
        "keyframe T0 (tid=0 ≤ cap=1) must FORWARD"
    );

    // ── (2) Template-only frame at T0 (template_id=0) → forwards. ───────────
    let f_t0 = build_template_only_dd(1, 0);
    let data = make_dd_media_data(1, f_t0);
    registry.fanout_for_tests(&Propagated::MediaData(ClientId(10), data));
    assert_eq!(
        registry.delivered_media_count(B),
        2,
        "T0 (tid=0 ≤ cap=1) must FORWARD"
    );

    // ── (3) Template-only frame at T1 (template_id=1) → forwards. ───────────
    let f_t1 = build_template_only_dd(2, 1);
    let data = make_dd_media_data(1, f_t1);
    registry.fanout_for_tests(&Propagated::MediaData(ClientId(10), data));
    assert_eq!(
        registry.delivered_media_count(B),
        3,
        "T1 (tid=1 ≤ cap=1) must FORWARD"
    );

    // ── (4) Template-only frame at T2 (template_id=2) → DROPS. ──────────────
    let f_t2 = build_template_only_dd(3, 2);
    let data = make_dd_media_data(1, f_t2);
    registry.fanout_for_tests(&Propagated::MediaData(ClientId(10), data));
    assert_eq!(
        registry.delivered_media_count(B),
        3,
        "T2 (tid=2 > cap=1) must DROP — count stays at 3"
    );

    // ── (5) Another T0 → forwards (stream continues decodable after drop). ─
    let f_t0b = build_template_only_dd(4, 0);
    let data = make_dd_media_data(1, f_t0b);
    registry.fanout_for_tests(&Propagated::MediaData(ClientId(10), data));
    assert_eq!(
        registry.delivered_media_count(B),
        4,
        "T0 after T2 drop must FORWARD — decode-safe invariant"
    );
}

#[test]
fn template_only_dd_before_structure_forwards_fail_soft() {
    let mut registry = Registry::new_for_tests();
    let mut a = new_client(ClientId(20));
    let _arc = seed_track_in(&mut a, 1, MediaKind::Video);
    registry.insert(a);
    let b = new_client(ClientId(21));
    registry.insert(b);
    const B: usize = 1;

    registry.set_max_vfm_temporal_layer_for_tests(B, 1);

    // Template-only DD at T1 BEFORE any keyframe structure was cached.
    // temporal_id is unresolvable → fail-soft FORWARD (no drop, no crash).
    let f = build_template_only_dd(0, 1);
    let data = make_dd_media_data(1, f);
    registry.fanout_for_tests(&Propagated::MediaData(ClientId(20), data));
    assert_eq!(
        registry.delivered_media_count(B),
        1,
        "template-only DD before structure → fail-soft FORWARD"
    );
}

#[test]
fn malformed_dd_forwards_fail_soft() {
    let mut registry = Registry::new_for_tests();
    let mut a = new_client(ClientId(30));
    let _arc = seed_track_in(&mut a, 1, MediaKind::Video);
    registry.insert(a);
    let b = new_client(ClientId(31));
    registry.insert(b);
    const B: usize = 1;

    registry.set_max_vfm_temporal_layer_for_tests(B, 0);

    // Malformed: too short for mandatory descriptor.
    let data = make_dd_media_data(1, vec![0x00, 0x01]);
    registry.fanout_for_tests(&Propagated::MediaData(ClientId(30), data));
    assert_eq!(
        registry.delivered_media_count(B),
        1,
        "malformed DD (too short) → fail-soft FORWARD"
    );

    // Truncated structure: valid keyframe DD with last bytes chopped.
    let full = build_l1t3_keyframe_dd(0, 0);
    let truncated: Vec<u8> = full[..full.len() - 3].to_vec();
    let data = make_dd_media_data(1, truncated);
    registry.fanout_for_tests(&Propagated::MediaData(ClientId(30), data));
    assert_eq!(
        registry.delivered_media_count(B),
        2,
        "truncated DD structure → fail-soft FORWARD, no panic"
    );
}

#[test]
fn no_cap_forwards_all_temporal_layers() {
    let mut registry = Registry::new_for_tests();
    let mut a = new_client(ClientId(40));
    let _arc = seed_track_in(&mut a, 1, MediaKind::Video);
    registry.insert(a);
    let b = new_client(ClientId(41));
    registry.insert(b);
    const B: usize = 1;

    // Default cap is u8::MAX (no cap) — all temporal layers forward.
    // First send keyframe to cache the structure.
    let kf = build_l1t3_keyframe_dd(0, 0);
    let data = make_dd_media_data(1, kf);
    registry.fanout_for_tests(&Propagated::MediaData(ClientId(40), data));
    assert_eq!(registry.delivered_media_count(B), 1, "keyframe forwards");

    // T2 with no cap → forwards.
    let f_t2 = build_template_only_dd(1, 2);
    let data = make_dd_media_data(1, f_t2);
    registry.fanout_for_tests(&Propagated::MediaData(ClientId(40), data));
    assert_eq!(
        registry.delivered_media_count(B),
        2,
        "T2 with no cap (u8::MAX) must FORWARD"
    );
}
