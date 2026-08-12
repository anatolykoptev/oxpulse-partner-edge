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
        // separately in `partner_edge_config_suspend_streak_when_flag_off`,
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
    /// This test is `#[serial]` because it reads the process-global
    /// `pacer_floor::ENABLED_OVERRIDE`. Without `#[serial]` it could run
    /// concurrently with `pacer_floor::tests::override_wins_over_env` (which
    /// flips the override between `set(true)` and `set(false)`) and observe
    /// the flag as on, getting `SOFTENED_SUSPEND_STREAK` instead of
    /// `SUSPEND_STREAK`. `#[serial]` serializes this test with all other
    /// `#[serial]` tests in the same binary, including the mutators.
    /// See `crates/sfu/tests/pacer_floor_test.rs:3-11` for the isolation
    /// doctrine: `#[serial]` does NOT protect non-serial readers — so the
    /// reader itself must be serial.
    #[test]
    #[serial]
    fn partner_edge_config_suspend_streak_when_flag_off() {
        // Defensive: ensure the flag is off regardless of what a prior
        // #[serial] test left. Both pacer_floor mutator tests end with
        // reset, so this is belt-and-braces.
        #[cfg(feature = "test-utils")]
        crate::pacer_floor::reset_pacer_floor_for_tests();

        let cfg = oxpulse_partner_edge_pacer_config();
        assert_eq!(
            cfg.suspend_streak,
            oxpulse_sfu_kit::bwe::SUSPEND_STREAK,
            "with pacer_floor off, suspend_streak must be the kit default"
        );
    }
}
