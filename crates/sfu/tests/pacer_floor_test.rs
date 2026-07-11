//! Pacer min-tick-floor + softened-suspend behaviour (fork-collapse task #18).
//!
//! ISOLATION: this test flips the *process-global* `pacer_floor::ENABLED_OVERRIDE`
//! at runtime (`set_pacer_floor_for_tests(true)` in Half B). Under CI's
//! `cargo test --features test-utils,vfm` the thread-pool runs all tests in a
//! binary concurrently — so a neighbour that reads the flag (e.g. any
//! `force_pacer_refresh_for_tests` caller) would be corrupted while the override
//! is held true. Each `tests/*.rs` is its own binary/process, so keeping this
//! test alone here gives it real isolation (`#[serial]` would NOT suffice — the
//! neighbours it corrupts are not themselves serial). Do NOT co-locate other
//! tests here.

// Proves BOTH directions: the legacy/default-off cadence still reproduces the
// bug (proves the harness actually exercises the bug, not just the fix), and the
// floored cadence resists the same burst but still suspends on sustained low BWE.
#[test]
fn pacer_floor_prevents_burst_suspend_but_legacy_cadence_still_suspends() {
    use oxpulse_sfu::client::test_seed::{new_client, seed_track_in};
    use oxpulse_sfu::pacer_floor::{reset_pacer_floor_for_tests, set_pacer_floor_for_tests};
    use oxpulse_sfu::propagate::SuspendTier;
    use oxpulse_sfu::{ClientId, Registry};
    use std::time::{Duration, Instant};
    use str0m::media::MediaKind;

    // Below kit SUSPEND_VIDEO_BPS (10_000) -- drives the suspend-streak branch.
    const BELOW_SUSPEND_BPS: u64 = 5_000;

    // ── Half A: legacy cadence (flag off, the pre-fix default) reproduces the
    // bug -- 2 ticks 20ms apart (nominal MediaData spacing) suspend video.
    reset_pacer_floor_for_tests();
    set_pacer_floor_for_tests(false);
    {
        let mut registry = Registry::new_for_tests();
        let mut publisher = new_client(ClientId(920));
        let _arc = seed_track_in(&mut publisher, 1, MediaKind::Video);
        registry.insert(publisher);
        registry.insert(new_client(ClientId(921)));

        // Native-estimate ceiling only (the real prod signal path per
        // registry/poll.rs's `Propagated::BandwidthEstimate` wiring) --
        // deliberately NOT `drive_subscriber_bandwidth_for_tests`, whose
        // `force_high_estimate_for_tests` seeds the Kalman/loss estimators
        // via `DelayEstimator::new`/`LossEstimator::new`, both of which
        // clamp to `MIN_BITRATE_BPS` (30_000) -- well above
        // `SUSPEND_VIDEO_BPS` (10_000), so it can never reach the suspend
        // region and would land in GoAudioOnly territory instead.
        registry.cap_subscriber_bandwidth_for_tests(ClientId(921), BELOW_SUSPEND_BPS);

        let t0 = Instant::now();
        registry.force_pacer_refresh_at_for_tests(ClientId(920), t0);
        registry.force_pacer_refresh_at_for_tests(ClientId(920), t0 + Duration::from_millis(20));

        assert_eq!(
            registry.last_emitted_tier_for_tests(1),
            Some(SuspendTier::AudioNormal),
            "legacy per-MediaData cadence (SFU_PACER_FLOOR off) must reproduce \
             the bug: 2 ticks 20ms apart satisfy kit SUSPEND_STREAK=2 and \
             suspend video on a transient burst"
        );
    }
    reset_pacer_floor_for_tests();

    // ── Half B: floored + softened cadence (flag on) resists the same burst,
    // but still suspends once BWE stays low across real floor-spaced ticks.
    set_pacer_floor_for_tests(true);
    {
        let mut registry = Registry::new_for_tests();
        let mut publisher = new_client(ClientId(930));
        let _arc = seed_track_in(&mut publisher, 1, MediaKind::Video);
        registry.insert(publisher);
        registry.insert(new_client(ClientId(931)));

        // See Half A's comment: native-estimate ceiling only, not
        // force_high_estimate_for_tests (30_000 floor would defeat the
        // suspend-region scenario).
        registry.cap_subscriber_bandwidth_for_tests(ClientId(931), BELOW_SUSPEND_BPS);

        let t0 = Instant::now();
        // Same 20ms-spaced burst as Half A: tick 1 is a real advance
        // (suspend_streak -> 1); tick 2 lands inside the 100ms floor and must
        // be throttled to a no-op (suspend_streak stays at 1).
        registry.force_pacer_refresh_at_for_tests(ClientId(930), t0);
        registry.force_pacer_refresh_at_for_tests(ClientId(930), t0 + Duration::from_millis(20));

        assert_eq!(
            registry.last_emitted_tier_for_tests(1),
            None,
            "floored cadence: the 20ms-spaced burst must NOT suspend -- the \
             100ms floor must throttle the 2nd tick before it reaches the \
             pacer FSM"
        );

        // Two more real (>=100ms-spaced) ticks: suspend_streak 1 -> 2 -> 3,
        // reaching SOFTENED_SUSPEND_STREAK=3 on sustained low BWE.
        registry.force_pacer_refresh_at_for_tests(
            ClientId(930),
            t0 + oxpulse_sfu_kit::bwe::PACER_MIN_TICK_INTERVAL,
        );
        assert_eq!(
            registry.last_emitted_tier_for_tests(1),
            None,
            "2nd real advance (suspend_streak=2) must not yet suspend under \
             SOFTENED_SUSPEND_STREAK=3"
        );

        registry.force_pacer_refresh_at_for_tests(
            ClientId(930),
            t0 + oxpulse_sfu_kit::bwe::PACER_MIN_TICK_INTERVAL * 2,
        );
        assert_eq!(
            registry.last_emitted_tier_for_tests(1),
            Some(SuspendTier::AudioNormal),
            "3rd real advance (suspend_streak=3) must suspend -- sustained low \
             BWE across the softened debounce window still suspends video, \
             just at a ~300ms horizon instead of ~40ms"
        );
    }
    reset_pacer_floor_for_tests();
}
