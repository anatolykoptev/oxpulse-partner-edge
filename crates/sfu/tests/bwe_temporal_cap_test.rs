//! G3 P3b — SFU-BWE-driven per-subscriber temporal-layer cap integration tests.
//!
//! Drives the REAL `update_pacer_layers` → `bwe_select_temporal_cap` path
//! and the REAL `handle_media_data_out` fanout drop path to verify:
//!  (1) Schmitt engage/release/sticky semantics on the 0↔1 edge;
//!  (2) MIN precedence between client DC cap and BWE cap;
//!  (3) no-flap damping via the shared min-tick floor on the 1↔MAX edge;
//!  (4) cap engages even when SFU_PACER_FLOOR is on (NOT dead under prod config);
//!  (5) kill-switch OFF → cap stays u8::MAX regardless of budget;
//!  (6) only-T0 traffic on an L1T3 structure + cap=0 → no drops, metric shows decision;
//!  (7) cap-engage (MAX→<MAX) invalidates the DD structure cache; uncap does NOT.
//!
//! ISOLATION: each test flips the process-global `bwe_temporal_cap::ENABLED_OVERRIDE`
//! (and test 4 also flips `pacer_floor::ENABLED_OVERRIDE`). All tests are `#[serial]`
//! so they run one at a time within this binary. Each test resets both overrides
//! on exit. Each `tests/*.rs` is a separate process, so no cross-binary corruption.

use serial_test::serial;

use oxpulse_sfu::client::test_seed::{make_media_data, new_client, seed_track_in};
use oxpulse_sfu::svc::DdPresent;
use oxpulse_sfu::{ClientId, Propagated, Registry};
use str0m::media::{MediaData, MediaKind};

// ─── Synthetic DD byte-vector builders (mirror dd_temporal_drop tests) ───────

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
    w.push_bool(true); // template_dependency_structure_present
    w.push_bool(false); // active_decode_targets_present
    w.push_bool(false); // custom_dtis
    w.push_bool(false); // custom_fdiffs
    w.push_bool(false); // custom_chains
    w.push_bits(0, 6); // template_id_offset
    w.push_bits(2, 5); // dt_cnt_minus_one = 2 (DtCnt=3)
    w.push_bits(1, 2); // T0 → next: T++
    w.push_bits(1, 2); // T1 → next: T++
    w.push_bits(3, 2); // T2 → stop
    w.push_bits(3, 2);
    w.push_bits(3, 2);
    w.push_bits(3, 2); // T0: R R R
    w.push_bits(2, 2);
    w.push_bits(1, 2);
    w.push_bits(0, 2); // T1: S D -
    w.push_bits(1, 2);
    w.push_bits(0, 2);
    w.push_bits(0, 2); // T2: D - -
    w.push_bool(false); // T0: none
    w.push_bool(true);
    w.push_bits(1, 4);
    w.push_bool(false); // T1: fdiff=2
    w.push_bool(true);
    w.push_bits(0, 4);
    w.push_bool(false); // T2: fdiff=1
    w.push_ns(4, 1); // chain_cnt=1
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

fn make_dd_media_data(mid_tag: u8, dd_bytes: Vec<u8>) -> MediaData {
    let mut data = make_media_data(mid_tag, None);
    data.ext_vals.user_values.set(DdPresent(dd_bytes));
    data
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

/// Set up a 2-client registry: publisher A + subscriber B. Returns the
/// registry and the index of subscriber B (always 1).
fn setup_pub_sub(pub_id: u64, sub_id: u64) -> Registry {
    let mut registry = Registry::new_for_tests();
    let mut a = new_client(ClientId(pub_id));
    let _arc = seed_track_in(&mut a, 1, MediaKind::Video);
    registry.insert(a);
    registry.insert(new_client(ClientId(sub_id)));
    registry
}

/// Drive the budget for `subscriber` to exactly `bps` by setting the native
/// estimate ceiling and forcing GoogCC high so neither is binding above it.
fn set_budget(registry: &mut Registry, subscriber: ClientId, bps: u64) {
    registry.drive_googcc_for_tests(10_000_000);
    registry.cap_subscriber_bandwidth_for_tests(subscriber, bps);
}

const SUB: usize = 1; // subscriber B is always at index 1.

// ─── Test 1: Engage / release / sticky ───────────────────────────────────────

/// Schmitt semantics: 120k→1 (grace band), 60k→0 (deepest degrade),
/// 200k→u8::MAX (recovered). After 60k (→0), 120k stays 0 (sticky cap=0
/// until budget clears low_min=150k). 160k→u8::MAX (exits sticky).
#[test]
#[serial]
fn bwe_temporal_cap_engage_release_sticky() {
    use std::time::{Duration, Instant};

    oxpulse_sfu::bwe_temporal_cap::set_bwe_temporal_cap_for_tests(true);
    {
        let mut r = setup_pub_sub(100, 101);
        let sub = ClientId(101);
        let origin = ClientId(100);

        // Use explicit Instant spacing (≥100ms) so the shared min-tick floor
        // doesn't throttle the cap selection. Each tick is a real advance.
        let t0 = Instant::now();
        let step = Duration::from_millis(100);

        // 120k → grace band [100k, 150k) → cap=1
        set_budget(&mut r, sub, 120_000);
        r.force_pacer_refresh_at_for_tests(origin, t0);
        assert_eq!(
            r.bwe_vfm_temporal_cap_for_tests(SUB),
            1,
            "120k in grace band → cap=1"
        );

        // 60k → below lo=100k → cap=0 (deepest degrade)
        set_budget(&mut r, sub, 60_000);
        r.force_pacer_refresh_at_for_tests(origin, t0 + step);
        assert_eq!(
            r.bwe_vfm_temporal_cap_for_tests(SUB),
            0,
            "60k < lo=100k → cap=0"
        );

        // 120k → still in grace band, but cap=0 is STICKY until budget ≥ hi=150k
        set_budget(&mut r, sub, 120_000);
        r.force_pacer_refresh_at_for_tests(origin, t0 + step * 2);
        assert_eq!(
            r.bwe_vfm_temporal_cap_for_tests(SUB),
            0,
            "120k after 60k(→0) stays 0 — Schmitt hold on 0↔1 edge"
        );

        // 200k → ≥ hi=150k → uncap (exits sticky)
        set_budget(&mut r, sub, 200_000);
        r.force_pacer_refresh_at_for_tests(origin, t0 + step * 3);
        assert_eq!(
            r.bwe_vfm_temporal_cap_for_tests(SUB),
            u8::MAX,
            "200k ≥ hi=150k → uncap (exits sticky)"
        );

        // 160k → ≥ hi=150k → still uncap
        set_budget(&mut r, sub, 160_000);
        r.force_pacer_refresh_at_for_tests(origin, t0 + step * 4);
        assert_eq!(
            r.bwe_vfm_temporal_cap_for_tests(SUB),
            u8::MAX,
            "160k ≥ hi=150k → uncap"
        );
    }
    oxpulse_sfu::bwe_temporal_cap::reset_bwe_temporal_cap_for_tests();
}

// ─── Test 2: Precedence MIN ──────────────────────────────────────────────────

/// effective_temporal_cap = min(max_vfm_temporal_layer, bwe_vfm_temporal_cap).
/// client=0 + BWE=1 → drops tid>0; client=MAX + BWE=1 → drops tid>1.
#[test]
#[serial]
fn bwe_temporal_cap_precedence_min() {
    oxpulse_sfu::bwe_temporal_cap::set_bwe_temporal_cap_for_tests(true);
    {
        // ── Half A: client cap=0, BWE cap=1 → effective=0 → drops tid>0 ──
        let mut r = setup_pub_sub(200, 201);
        let sub = ClientId(201);

        // Set BWE cap=1 via 120k budget (grace band).
        set_budget(&mut r, sub, 120_000);
        r.force_pacer_refresh_for_tests(ClientId(200));
        assert_eq!(r.bwe_vfm_temporal_cap_for_tests(SUB), 1, "BWE cap=1");

        // Set client cap=0 (more restrictive).
        r.set_max_vfm_temporal_layer_for_tests(SUB, 0);

        // effective = min(0, 1) = 0 → tid>0 drops, tid=0 forwards.
        // Send keyframe (T0) to cache structure.
        let kf = build_l1t3_keyframe_dd(0, 0);
        r.fanout_for_tests(&Propagated::MediaData(
            ClientId(200),
            make_dd_media_data(1, kf),
        ));
        assert_eq!(
            r.delivered_media_count(SUB),
            1,
            "T0 (tid=0 ≤ effective=0) must FORWARD"
        );

        // T1 (tid=1 > effective=0) → DROP.
        let f_t1 = build_template_only_dd(1, 1);
        r.fanout_for_tests(&Propagated::MediaData(
            ClientId(200),
            make_dd_media_data(1, f_t1),
        ));
        assert_eq!(
            r.delivered_media_count(SUB),
            1,
            "T1 (tid=1 > effective=min(0,1)=0) must DROP — precedence MIN"
        );

        // ── Half B: client cap=MAX, BWE cap=1 → effective=1 → drops tid>1 ──
        let mut r2 = setup_pub_sub(210, 211);
        let sub2 = ClientId(211);

        set_budget(&mut r2, sub2, 120_000);
        r2.force_pacer_refresh_for_tests(ClientId(210));
        assert_eq!(r2.bwe_vfm_temporal_cap_for_tests(SUB), 1, "BWE cap=1");

        // Client cap=MAX (default, no client DC cap).
        // effective = min(MAX, 1) = 1 → tid>1 drops, tid=0/1 forward.

        // Keyframe T0 → cache structure, forwards.
        let kf = build_l1t3_keyframe_dd(0, 0);
        r2.fanout_for_tests(&Propagated::MediaData(
            ClientId(210),
            make_dd_media_data(1, kf),
        ));
        assert_eq!(r2.delivered_media_count(SUB), 1, "T0 forwards");

        // T1 (tid=1 ≤ effective=1) → forwards.
        let f_t1 = build_template_only_dd(1, 1);
        r2.fanout_for_tests(&Propagated::MediaData(
            ClientId(210),
            make_dd_media_data(1, f_t1),
        ));
        assert_eq!(r2.delivered_media_count(SUB), 2, "T1 forwards (≤ cap=1)");

        // T2 (tid=2 > effective=1) → drops.
        let f_t2 = build_template_only_dd(2, 2);
        r2.fanout_for_tests(&Propagated::MediaData(
            ClientId(210),
            make_dd_media_data(1, f_t2),
        ));
        assert_eq!(
            r2.delivered_media_count(SUB),
            2,
            "T2 (tid=2 > effective=min(MAX,1)=1) must DROP"
        );
    }
    oxpulse_sfu::bwe_temporal_cap::reset_bwe_temporal_cap_for_tests();
}

// ─── Test 3: No-flap damping via min-tick floor ──────────────────────────────

/// Budget oscillates 139k/151k/139k/151k across throttled+non-throttled
/// ticks. 139k < hi_reenter=140k → re-cap to 1; 151k ≥ hi=150k → uncap.
/// The shared min-tick floor (≥100ms) damps the 1↔MAX edge so the cap
/// changes at most once (MAX→1 on the first real tick; throttled ticks
/// skip the cap update entirely). Uses 139k (not 149k) because 149k now
/// falls inside the [hi_reenter,hi) hysteresis hold — it would NOT re-cap
/// from uncapped, so it can no longer exercise the tick-floor damper on
/// this edge (see test 8 for the hysteresis-band damping of 149k/151k).
#[test]
#[serial]
fn bwe_temporal_cap_no_flap_via_tick_floor() {
    use std::time::{Duration, Instant};

    oxpulse_sfu::bwe_temporal_cap::set_bwe_temporal_cap_for_tests(true);
    {
        let mut r = setup_pub_sub(300, 301);
        let sub = ClientId(301);
        let origin = ClientId(300);

        let t0 = Instant::now();

        // Tick 1 (real, first tick): 139k < hi_reenter=140k → re-cap → cap=1
        // (change 1: MAX→1).
        set_budget(&mut r, sub, 139_000);
        r.force_pacer_refresh_at_for_tests(origin, t0);
        let cap_after_1 = r.bwe_vfm_temporal_cap_for_tests(SUB);
        assert_eq!(cap_after_1, 1, "139k < hi_reenter → cap=1");

        // Tick 2 (throttled, 10ms < 100ms): 151k → tick_ready=false → cap stays 1
        set_budget(&mut r, sub, 151_000);
        r.force_pacer_refresh_at_for_tests(origin, t0 + Duration::from_millis(10));
        let cap_after_2 = r.bwe_vfm_temporal_cap_for_tests(SUB);
        assert_eq!(
            cap_after_2, 1,
            "151k on throttled tick → cap stays 1 (no flap)"
        );

        // Tick 3 (real, ≥100ms): 139k → cap=1 (no change, already 1)
        set_budget(&mut r, sub, 139_000);
        r.force_pacer_refresh_at_for_tests(origin, t0 + Duration::from_millis(100));
        let cap_after_3 = r.bwe_vfm_temporal_cap_for_tests(SUB);
        assert_eq!(cap_after_3, 1, "139k on real tick → cap stays 1");

        // Tick 4 (throttled, 110ms < 200ms): 151k → tick_ready=false → cap stays 1
        set_budget(&mut r, sub, 151_000);
        r.force_pacer_refresh_at_for_tests(origin, t0 + Duration::from_millis(110));
        let cap_after_4 = r.bwe_vfm_temporal_cap_for_tests(SUB);
        assert_eq!(
            cap_after_4, 1,
            "151k on throttled tick → cap stays 1 (no flap)"
        );

        // Count cap changes: track the previous cap across the four ticks
        // and increment on each observed change. Only MAX→1 on tick 1 is
        // expected (then throttled ticks skip the update and tick 3 stays
        // at 1) → ≤1 change total. Replaces the prior `let changes = 0`
        // tautology with a real transition count.
        let mut changes = 0u32;
        let mut prev = u8::MAX; // initial cap before tick 1 is uncapped.
        for cap in [cap_after_1, cap_after_2, cap_after_3, cap_after_4] {
            if cap != prev {
                changes += 1;
                prev = cap;
            }
        }
        assert!(
            changes <= 1,
            "no-flap: at most 1 cap change across throttled+non-throttled ticks (saw {changes})"
        );
    }
    oxpulse_sfu::bwe_temporal_cap::reset_bwe_temporal_cap_for_tests();
}

// ─── Test 4: Floor-on-liveness ───────────────────────────────────────────────

/// `set_pacer_floor_for_tests(true)` + cap-enabled → cap engages at 120k.
/// Proves the cap is NOT dead under the prod config where SFU_PACER_FLOOR=1.
/// The draft's double-call of pacer_tick_ready coupled the cap's floor to
/// the wrong flag, making the feature DEAD under the intended prod config.
#[test]
#[serial]
fn bwe_temporal_cap_engages_with_pacer_floor_on() {
    oxpulse_sfu::bwe_temporal_cap::set_bwe_temporal_cap_for_tests(true);
    oxpulse_sfu::pacer_floor::set_pacer_floor_for_tests(true);
    {
        let mut r = setup_pub_sub(400, 401);
        let sub = ClientId(401);
        let origin = ClientId(400);

        // 120k → grace band → cap=1, even with SFU_PACER_FLOOR=1.
        set_budget(&mut r, sub, 120_000);
        r.force_pacer_refresh_for_tests(origin);
        assert_eq!(
            r.bwe_vfm_temporal_cap_for_tests(SUB),
            1,
            "cap engages at 120k even with SFU_PACER_FLOOR=1 — NOT dead under prod config"
        );
    }
    oxpulse_sfu::pacer_floor::reset_pacer_floor_for_tests();
    oxpulse_sfu::bwe_temporal_cap::reset_bwe_temporal_cap_for_tests();
}

// ─── Test 5: Kill-switch OFF ─────────────────────────────────────────────────

/// Kill-switch OFF (default) → cap stays u8::MAX regardless of budget.
/// `bwe_select_temporal_cap` is never called; the metric never increments.
#[test]
#[serial]
fn bwe_temporal_cap_kill_switch_off_stays_uncapped() {
    oxpulse_sfu::bwe_temporal_cap::set_bwe_temporal_cap_for_tests(false);
    {
        let mut r = setup_pub_sub(500, 501);
        let sub = ClientId(501);
        let origin = ClientId(500);

        // Drive a very low budget (60k) — would cap=0 if the feature were on.
        set_budget(&mut r, sub, 60_000);
        r.force_pacer_refresh_for_tests(origin);

        assert_eq!(
            r.bwe_vfm_temporal_cap_for_tests(SUB),
            u8::MAX,
            "kill-switch OFF → cap stays u8::MAX regardless of budget"
        );

        // Metric should show zero increments (cap selection never ran).
        // Clone the Arc so we don't hold an immutable borrow of `r`.
        let metrics = r.clients()[SUB].metrics_for_tests().clone();
        assert_eq!(
            metrics
                .bwe_temporal_cap_total
                .with_label_values(&["0"])
                .get(),
            0,
            "kill-switch OFF → bwe_temporal_cap_total{{cap=\"0\"}} stays 0"
        );
        assert_eq!(
            metrics
                .bwe_temporal_cap_total
                .with_label_values(&["1"])
                .get(),
            0,
            "kill-switch OFF → bwe_temporal_cap_total{{cap=\"1\"}} stays 0"
        );
        assert_eq!(
            metrics
                .bwe_temporal_cap_total
                .with_label_values(&["uncapped"])
                .get(),
            0,
            "kill-switch OFF → bwe_temporal_cap_total{{cap=\"uncapped\"}} stays 0"
        );
    }
    oxpulse_sfu::bwe_temporal_cap::reset_bwe_temporal_cap_for_tests();
}

// ─── Test 6: only-T0 traffic on an L1T3 structure (cap=0 no-op) ─────────────

/// Only-T0 traffic on an L1T3 structure (`build_l1t3_keyframe_dd`,
/// max_temporal_id=2) + cap=0 → no drops. Even though the structure
/// advertises T0/T1/T2 templates, every frame sent is at template_id=0
/// (tid=0), so none exceeds cap=0. The metric shows the cap=0 decision,
/// but dd_temporal_drops_total stays flat because no frame exceeds tid=0.
#[test]
#[serial]
fn bwe_temporal_cap_only_t0_on_l1t3_noop_with_cap0() {
    oxpulse_sfu::bwe_temporal_cap::set_bwe_temporal_cap_for_tests(true);
    {
        let mut r = setup_pub_sub(600, 601);
        let sub = ClientId(601);
        let origin = ClientId(600);

        // Drive budget below lo=100k → cap=0.
        set_budget(&mut r, sub, 60_000);
        r.force_pacer_refresh_for_tests(origin);
        assert_eq!(r.bwe_vfm_temporal_cap_for_tests(SUB), 0, "60k < lo → cap=0");

        // Clone the Arc<SfuMetrics> so the immutable borrow on `r` is
        // released before the mutable `fanout_for_tests` calls below.
        let metrics = r.clients()[SUB].metrics_for_tests().clone();

        // Verify the metric recorded the cap=0 decision.
        let cap0_metric_before = metrics
            .bwe_temporal_cap_total
            .with_label_values(&["0"])
            .get();
        assert!(
            cap0_metric_before >= 1,
            "bwe_temporal_cap_total{{cap=\"0\"}} must increment — metric shows decision"
        );

        // Send an L1T3 keyframe at template_id=0 (T0, tid=0) → forwards
        // (tid=0 ≤ cap=0).
        let kf = build_l1t3_keyframe_dd(0, 0);
        r.fanout_for_tests(&Propagated::MediaData(
            ClientId(600),
            make_dd_media_data(1, kf),
        ));
        assert_eq!(
            r.delivered_media_count(SUB),
            1,
            "L1T3 keyframe T0 (tid=0 ≤ cap=0) must FORWARD"
        );

        // Send another T0 template-only frame → forwards.
        let f_t0 = build_template_only_dd(1, 0);
        r.fanout_for_tests(&Propagated::MediaData(
            ClientId(600),
            make_dd_media_data(1, f_t0),
        ));
        assert_eq!(
            r.delivered_media_count(SUB),
            2,
            "L1T3 T0 (tid=0 ≤ cap=0) must FORWARD"
        );

        // dd_temporal_drops_total must stay flat — no frame exceeded tid=0.
        let drops = metrics
            .sfu_dd_temporal_drops_total
            .with_label_values(&["0"])
            .get()
            + metrics
                .sfu_dd_temporal_drops_total
                .with_label_values(&["1"])
                .get()
            + metrics
                .sfu_dd_temporal_drops_total
                .with_label_values(&["2"])
                .get()
            + metrics
                .sfu_dd_temporal_drops_total
                .with_label_values(&["3plus"])
                .get();
        assert_eq!(
            drops, 0,
            "only-T0 traffic on L1T3 + cap=0 → zero drops (no frame exceeds tid=0)"
        );
    }
    oxpulse_sfu::bwe_temporal_cap::reset_bwe_temporal_cap_for_tests();
}

// ─── Test 7: cap-engage invalidates the DD structure cache ───────────────────

/// P3b LOOP-FIX guarding test: a MAX→<MAX effective-cap transition (cap
/// ENGAGE) MUST clear the per-subscriber DD structure cache so a stale
/// structure from a prior capped window — which the perf guard skipped
/// re-parsing while UNCAPPED — can never misresolve a template-only frame
/// into an unsafe drop. Uncap (<MAX→MAX) must NOT clear (only engage does).
///
/// Falsification: removing the `invalidate_dd_cache_on_cap_engage` call
/// from `bwe_select_temporal_cap` makes step (c) fail (cache stays 1
/// instead of being cleared on re-engage).
#[test]
#[serial]
fn bwe_temporal_cap_engage_invalidates_dd_structure_cache() {
    oxpulse_sfu::bwe_temporal_cap::set_bwe_temporal_cap_for_tests(true);
    {
        let mut r = setup_pub_sub(700, 701);
        let origin = ClientId(700);

        // (a) ENGAGE cap: 120k → grace band → cap=1, then send a KEYFRAME
        // DD through the real fanout path so the structure caches.
        // Assert dd_cache_len_for_tests(SUB) == 1.
        r.bwe_select_temporal_cap_for_tests(SUB, Some(120_000));
        assert_eq!(
            r.bwe_vfm_temporal_cap_for_tests(SUB),
            1,
            "120k → cap=1 (engage)"
        );
        let kf = build_l1t3_keyframe_dd(0, 0);
        r.fanout_for_tests(&Propagated::MediaData(origin, make_dd_media_data(1, kf)));
        assert_eq!(
            r.dd_cache_len_for_tests(SUB),
            1,
            "(a) after engage + keyframe DD, structure cache holds 1 entry"
        );

        // (b) UNCAP: 200k → ≥ hi=150k → cap=u8::MAX. Assert the cache is
        // STILL 1 — uncap must NOT clear (only engage does).
        r.bwe_select_temporal_cap_for_tests(SUB, Some(200_000));
        assert_eq!(
            r.bwe_vfm_temporal_cap_for_tests(SUB),
            u8::MAX,
            "200k → uncap"
        );
        assert_eq!(
            r.dd_cache_len_for_tests(SUB),
            1,
            "(b) uncap must NOT clear the cache — only engage does"
        );

        // (c) RE-ENGAGE: 120k → cap=1. Assert dd_cache_len_for_tests(SUB)
        // == 0 — the fix cleared it on the MAX→<MAX transition.
        r.bwe_select_temporal_cap_for_tests(SUB, Some(120_000));
        assert_eq!(
            r.bwe_vfm_temporal_cap_for_tests(SUB),
            1,
            "120k → cap=1 (re-engage)"
        );
        assert_eq!(
            r.dd_cache_len_for_tests(SUB),
            0,
            "(c) re-engage (MAX→<MAX) MUST clear the cache — stale-structure window closed"
        );
    }
    oxpulse_sfu::bwe_temporal_cap::reset_bwe_temporal_cap_for_tests();
}

// ─── Test 8: #473 — no-flap in the 1↔uncapped hysteresis band ───────────────
//
// The `1 ↔ u8::MAX` edge used the SAME threshold `hi=150k` both directions
// (enter 1 when b<hi, exit to MAX when b≥hi) → NO hysteresis → a budget
// hovering ~145k flapped T2 on/off up to 10Hz. The fix adds a re-enter rail
// `hi_reenter = hi - (hi-lo)/5` (=140k for prod rails 100k/150k): uncap still
// at b≥hi, re-cap from uncapped only when b<hi_reenter. The band
// [hi_reenter, hi) = [140k,150k) becomes history-stable (Schmitt hold).
//
// Falsification: against the OLD match (no `hi_reenter` arm), the uncapped
// 145k case drops to 1 on the first tick (flap). With the fix it stays MAX.
// The capped-1 control case stays 1 under both (the band is a hold, not a
// force-uncap) — it pins that the fix doesn't over-correct.

#[test]
#[serial]
fn bwe_temporal_cap_no_flap_in_reenter_band() {
    oxpulse_sfu::bwe_temporal_cap::set_bwe_temporal_cap_for_tests(true);
    {
        // ── Half A: from UNCAPPED start, steady 145k → stays MAX (0 changes) ──
        let mut r = setup_pub_sub(800, 801);
        // Default client state is u8::MAX (uncapped); confirm the invariant.
        assert_eq!(
            r.bwe_vfm_temporal_cap_for_tests(SUB),
            u8::MAX,
            "fixture: subscriber starts uncapped"
        );

        let mut changes_a = 0u32;
        let mut prev = u8::MAX;
        // Feed steady 145k (inside [hi_reenter=140k, hi=150k)) across 5 ticks.
        for _ in 0..5 {
            let cap = r.bwe_select_temporal_cap_for_tests(SUB, Some(145_000));
            assert_eq!(
                cap,
                u8::MAX,
                "145k in [hi_reenter,hi) from uncapped → hold MAX (no flap)"
            );
            if cap != prev {
                changes_a += 1;
                prev = cap;
            }
        }
        assert_eq!(
            changes_a, 0,
            "uncapped + steady 145k across the band → 0 cap changes (pre-fix flaps to 1)"
        );

        // ── Half B: from CAPPED-1 start, steady 145k → stays 1 (0 changes) ──
        let mut r2 = setup_pub_sub(810, 811);
        // Drive to cap=1 first via 130k (grace band, below hi_reenter).
        let cap1 = r2.bwe_select_temporal_cap_for_tests(SUB, Some(130_000));
        assert_eq!(cap1, 1, "130k from uncapped → cap=1 (drive to capped-1)");

        let mut changes_b = 0u32;
        let mut prev = 1u8;
        for _ in 0..5 {
            let cap = r2.bwe_select_temporal_cap_for_tests(SUB, Some(145_000));
            assert_eq!(
                cap, 1,
                "145k in [hi_reenter,hi) from capped-1 → hold 1 (band is a hold, not force-uncap)"
            );
            if cap != prev {
                changes_b += 1;
                prev = cap;
            }
        }
        assert_eq!(
            changes_b, 0,
            "capped-1 + steady 145k across the band → 0 cap changes"
        );
    }
    oxpulse_sfu::bwe_temporal_cap::reset_bwe_temporal_cap_for_tests();
}

// ─── Test 9: 149k/151k oscillation damped by the hysteresis band ────────────
//
// Pre-fix, alternating 149k/151k across the hi=150k rail flapped the cap
// every tick (MAX↔1). Post-fix, 149k ≥ hi_reenter=140k so an UNCAPPED client
// holds MAX across both sides of the rail → ≤1 change total across 6 ticks.
//
// Falsification: against the OLD match, tick1 149k drops MAX→1 (change),
// tick2 151k lifts 1→MAX (change), … → 6 changes, fails the ≤1 bound.

#[test]
#[serial]
fn bwe_temporal_cap_oscillation_149_151_damped() {
    oxpulse_sfu::bwe_temporal_cap::set_bwe_temporal_cap_for_tests(true);
    {
        let mut r = setup_pub_sub(820, 821);
        // Subscriber starts uncapped (u8::MAX).
        let mut changes = 0u32;
        let mut prev = u8::MAX;
        // Alternate 149k / 151k for 6 ticks. 149k ∈ [hi_reenter, hi) → hold
        // MAX; 151k ≥ hi → MAX. No transition expected.
        for bps in [149_000u64, 151_000, 149_000, 151_000, 149_000, 151_000] {
            let cap = r.bwe_select_temporal_cap_for_tests(SUB, Some(bps));
            if cap != prev {
                changes += 1;
                prev = cap;
            }
        }
        assert!(
            changes <= 1,
            "149k/151k oscillation from uncapped → ≤1 cap change across 6 ticks (saw {changes}); pre-fix flaps every tick"
        );
    }
    oxpulse_sfu::bwe_temporal_cap::reset_bwe_temporal_cap_for_tests();
}

// ─── Test 10: re-enter rail exactness (pins hi_reenter = 140k) ──────────────
//
// From uncapped: 141k (≥ hi_reenter=140k) → hold MAX; 139k (< hi_reenter) →
// re-cap to 1. Pins the re-enter rail at exactly 140k (= hi - (hi-lo)/5 =
// 150k - 10k) for the prod rails.
//
// Falsification: against the OLD match, the 141k assertion fails — 141k < hi
// → cap drops to 1 (no re-enter band). The 139k assertion passes under both
// (139k was always below the grace-band ceiling); the 141k row is the RED.

#[test]
#[serial]
fn bwe_temporal_cap_reenter_rail_exactness() {
    oxpulse_sfu::bwe_temporal_cap::set_bwe_temporal_cap_for_tests(true);
    {
        let mut r = setup_pub_sub(830, 831);
        // Subscriber starts uncapped.

        // 141k → ≥ hi_reenter=140k → hold MAX (the hysteresis band).
        let cap_141 = r.bwe_select_temporal_cap_for_tests(SUB, Some(141_000));
        assert_eq!(
            cap_141,
            u8::MAX,
            "141k ≥ hi_reenter=140k from uncapped → hold MAX (pre-fix drops to 1)"
        );

        // 139k → < hi_reenter=140k → re-cap to 1.
        let cap_139 = r.bwe_select_temporal_cap_for_tests(SUB, Some(139_000));
        assert_eq!(
            cap_139, 1,
            "139k < hi_reenter=140k from uncapped → re-cap to 1"
        );
    }
    oxpulse_sfu::bwe_temporal_cap::reset_bwe_temporal_cap_for_tests();
}

// ─── Test 11: preserve existing semantics (regression guard) ────────────────
//
// The new `hi_reenter` arm must NOT disturb the existing rails:
//  * uncap at 155k (≥ hi) from capped-1 → MAX (shared exit rail).
//  * deepest degrade: 90k (< lo) from any state → 0.
//  * sticky-0: at cap=0, 145k stays 0; 155k → MAX (exits sticky).
//  * grace band: 120k from uncapped → 1 (120k < hi_reenter=140k → re-cap).
//
// All four rows pass under BOTH the old and new match (regression guard,
// not a RED differentiator) — they pin that the fix is surgical.

#[test]
#[serial]
fn bwe_temporal_cap_preserves_existing_semantics() {
    oxpulse_sfu::bwe_temporal_cap::set_bwe_temporal_cap_for_tests(true);
    {
        // (a) uncap at 155k from capped-1.
        let mut r = setup_pub_sub(840, 841);
        r.bwe_select_temporal_cap_for_tests(SUB, Some(120_000));
        assert_eq!(r.bwe_vfm_temporal_cap_for_tests(SUB), 1, "120k → cap=1");
        let cap = r.bwe_select_temporal_cap_for_tests(SUB, Some(155_000));
        assert_eq!(cap, u8::MAX, "155k ≥ hi=150k from capped-1 → uncap");

        // (b) deepest degrade: 90k from uncapped → 0.
        let mut r2 = setup_pub_sub(841, 842);
        let cap = r2.bwe_select_temporal_cap_for_tests(SUB, Some(90_000));
        assert_eq!(
            cap, 0,
            "90k < lo=100k from uncapped → cap=0 (deepest degrade)"
        );

        // (c) sticky-0: at cap=0, 145k stays 0; 155k → MAX.
        let mut r3 = setup_pub_sub(842, 843);
        r3.bwe_select_temporal_cap_for_tests(SUB, Some(90_000));
        assert_eq!(r3.bwe_vfm_temporal_cap_for_tests(SUB), 0, "90k → cap=0");
        let cap_145 = r3.bwe_select_temporal_cap_for_tests(SUB, Some(145_000));
        assert_eq!(
            cap_145, 0,
            "145k in [lo,hi) at cap=0 → sticky 0 (Schmitt hold on 0↔1 edge)"
        );
        let cap_155 = r3.bwe_select_temporal_cap_for_tests(SUB, Some(155_000));
        assert_eq!(
            cap_155,
            u8::MAX,
            "155k ≥ hi=150k at cap=0 → uncap (exits sticky)"
        );

        // (d) grace band: 120k from uncapped → 1 (120k < hi_reenter=140k).
        let mut r4 = setup_pub_sub(843, 844);
        let cap = r4.bwe_select_temporal_cap_for_tests(SUB, Some(120_000));
        assert_eq!(
            cap, 1,
            "120k < hi_reenter=140k from uncapped → re-cap to 1 (grace band)"
        );
    }
    oxpulse_sfu::bwe_temporal_cap::reset_bwe_temporal_cap_for_tests();
}
