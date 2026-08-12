//! Pacer configuration helper for OxPulse partner-edge.
//!
//! The per-subscriber `SubscriberPacer` is now provided by
//! [`oxpulse_sfu_kit`] (v0.11+). Partner-edge keeps this module
//! only to expose [`oxpulse_partner_edge_pacer_config`], which
//! seeds each new [`oxpulse_sfu_kit::SubscriberPacer`] with the
//! battle-tested production thresholds.
//!
//! # Threshold rationale
//!
//! | Field              | Partner-edge | Kit default | Why diverge                      |
//! |--------------------|-------------|-------------|----------------------------------|
//! | `audio_only_bps`   | 100_000     | 80_000      | conservative; validated in prod   |
//! | `medium_min_bps`   | 500_000     | 350_000     | avoids h-layer on weak 3G links  |
//! | `high_min_bps`     | 1_500_000   | 700_000     | requires solid 4G for f-layer    |
//! | others             | kit default | kit default | no observed deviation in prod    |
//!
//! # `SFU_PACER_FLOOR` softened suspend (task #18)
//!
//! When [`crate::pacer_floor::pacer_floor_enabled`] returns `true`,
//! `suspend_streak` is raised from the kit default (2) to
//! [`crate::pacer_floor::SOFTENED_SUSPEND_STREAK`] (3) -- see
//! `crate::pacer_floor` module docs for the fix + research rationale.
//! Default off; unaffected callers keep the kit default.

use oxpulse_sfu_kit::bwe::PacerConfig;

/// Return the partner-edge production [`PacerConfig`].
///
/// Used by [`crate::client::Client::new`] to seed every
/// [`oxpulse_sfu_kit::SubscriberPacer`] with the battle-tested thresholds.
pub fn oxpulse_partner_edge_pacer_config() -> PacerConfig {
    let mut cfg = PacerConfig {
        audio_only_bps: 100_000,
        medium_min_bps: 500_000,
        high_min_bps: 1_500_000,
        ..PacerConfig::default()
    };
    if crate::pacer_floor::pacer_floor_enabled() {
        cfg.suspend_streak = crate::pacer_floor::SOFTENED_SUSPEND_STREAK;
    }
    cfg
}

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;

    #[test]
    fn partner_edge_config_has_expected_values() {
        let cfg = oxpulse_partner_edge_pacer_config();
        assert_eq!(cfg.audio_only_bps, 100_000);
        assert_eq!(cfg.medium_min_bps, 500_000);
        assert_eq!(cfg.high_min_bps, 1_500_000);
        // Inherited defaults
        assert_eq!(
            cfg.suspend_video_bps,
            oxpulse_sfu_kit::bwe::SUSPEND_VIDEO_BPS
        );
        assert_eq!(cfg.low_min_bps, oxpulse_sfu_kit::bwe::LOW_MIN_BPS);
        assert_eq!(cfg.upgrade_streak, oxpulse_sfu_kit::bwe::UPGRADE_STREAK);
        // `suspend_streak` is flag-dependent (raised to
        // SOFTENED_SUSPEND_STREAK when pacer_floor is on) and is asserted
        // separately in `partner_edge_config_suspend_streak_tracks_pacer_floor_flag`,
        // a `#[serial]` test that serializes with the
        // `pacer_floor::tests` mutators which flip the flag at runtime.
    }

    /// `suspend_streak` is the only flag-dependent field of
    /// [`oxpulse_partner_edge_pacer_config`]: it is `SUSPEND_STREAK` while
    /// [`crate::pacer_floor::pacer_floor_enabled`] is off and
    /// `SOFTENED_SUSPEND_STREAK` while it is on. The other five fields are
    /// flag-independent and are asserted by
    /// [`partner_edge_config_has_expected_values`].
    ///
    /// This test is `#[serial]` because it reads — and, under `test-utils`,
    /// writes — the process-global `pacer_floor::ENABLED_OVERRIDE`. Without
    /// `#[serial]` it could run concurrently with
    /// `pacer_floor::tests::override_wins_over_env` (which flips the override
    /// between `set(true)` and `set(false)`) and observe the wrong branch.
    ///
    /// `serial_test`'s bare `#[serial]` is one unnamed group, so this test and
    /// both `pacer_floor::tests` mutators are mutually exclusive today. That is
    /// the whole of the protection: nothing mechanically stops a future mutator
    /// from being added without `#[serial]`, or under a NAMED group, which
    /// would silently reopen this race across three files.
    ///
    /// `crates/sfu/tests/pacer_floor_test.rs:3-11` reaches a different remedy —
    /// a separate test binary — because `#[serial]` cannot protect the
    /// non-serial neighbours it corrupts. That reasoning does not transfer to
    /// `src/` inline tests, which all share one lib binary; here the reader
    /// itself is made serial instead.
    #[test]
    #[serial]
    fn partner_edge_config_suspend_streak_tracks_pacer_floor_flag() {
        // Featureless build: the override machinery is `cfg`'d out, so no
        // mutator exists in-process and only the default branch is reachable.
        #[cfg(not(feature = "test-utils"))]
        {
            assert_eq!(
                oxpulse_partner_edge_pacer_config().suspend_streak,
                oxpulse_sfu_kit::bwe::SUSPEND_STREAK,
                "with pacer_floor off, suspend_streak must be the kit default"
            );
        }

        // With the override available, pin BOTH branches. Asserting only the
        // off-branch would still pass with the `if pacer_floor_enabled()` arm
        // of `oxpulse_partner_edge_pacer_config` deleted outright — while the
        // flag is off that arm is unreachable by construction, so a one-sided
        // assertion guards nothing.
        #[cfg(feature = "test-utils")]
        {
            crate::pacer_floor::set_pacer_floor_for_tests(false);
            assert_eq!(
                oxpulse_partner_edge_pacer_config().suspend_streak,
                oxpulse_sfu_kit::bwe::SUSPEND_STREAK,
                "with pacer_floor off, suspend_streak must be the kit default"
            );

            crate::pacer_floor::set_pacer_floor_for_tests(true);
            assert_eq!(
                oxpulse_partner_edge_pacer_config().suspend_streak,
                crate::pacer_floor::SOFTENED_SUSPEND_STREAK,
                "with pacer_floor on, suspend_streak must be softened"
            );

            crate::pacer_floor::reset_pacer_floor_for_tests();
        }
    }
}
