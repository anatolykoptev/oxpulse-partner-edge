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

use oxpulse_sfu_kit::bwe::PacerConfig;

/// Return the partner-edge production [`PacerConfig`].
///
/// Used by [`crate::client::Client::new`] to seed every
/// [`oxpulse_sfu_kit::SubscriberPacer`] with the battle-tested thresholds.
pub fn oxpulse_partner_edge_pacer_config() -> PacerConfig {
    PacerConfig {
        audio_only_bps: 100_000,
        medium_min_bps: 500_000,
        high_min_bps: 1_500_000,
        ..PacerConfig::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn partner_edge_config_has_expected_values() {
        let cfg = oxpulse_partner_edge_pacer_config();
        assert_eq!(cfg.audio_only_bps, 100_000);
        assert_eq!(cfg.medium_min_bps, 500_000);
        assert_eq!(cfg.high_min_bps, 1_500_000);
        // Inherited defaults
        assert_eq!(cfg.suspend_video_bps, oxpulse_sfu_kit::bwe::SUSPEND_VIDEO_BPS);
        assert_eq!(cfg.low_min_bps, oxpulse_sfu_kit::bwe::LOW_MIN_BPS);
        assert_eq!(cfg.suspend_streak, oxpulse_sfu_kit::bwe::SUSPEND_STREAK);
        assert_eq!(cfg.upgrade_streak, oxpulse_sfu_kit::bwe::UPGRADE_STREAK);
    }
}
