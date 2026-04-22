//! Delay-gradient Kalman filter + multiplicative rate control — the
//! "delay-based" half of GCC.
//!
//! Split from [`mod.rs`][super] because it owns a self-contained
//! concern: given a stream of (Δarrival, Δsend) pairs, produce a
//! bitrate estimate in bps. No knowledge of TWCC, subscribers, or
//! loss. Ported fresh from the Chromium `ModifiedTrendline` +
//! `AimdRateControl` spec; references in the parent module.
//!
//! References:
//! * Chromium `modules/congestion_controller/goog_cc/trendline_estimator.cc`
//! * Pion `pkg/gcc/send_side_bwe.go`

use std::time::{Duration, Instant};

/// Lower clamp (bps). Below this we consider the link unusable for
/// video; the [`crate::pacer`] drops to audio-only at a similar cutoff.
pub const MIN_ESTIMATE_BPS: u64 = 50_000;
/// Upper clamp (bps). Keeps arithmetic well-behaved even if a test
/// feeds in near-zero delay gradients.
pub const MAX_ESTIMATE_BPS: u64 = 10_000_000;
/// Bootstrap estimate before any feedback has arrived.
pub const INITIAL_ESTIMATE_BPS: u64 = 300_000;

/// Multiplicative-decrease factor applied on overuse.
const DELAY_DECREASE_FACTOR: f64 = 0.85;
/// Multiplicative-increase factor applied in the deep-normal band.
pub(super) const DELAY_INCREASE_FACTOR: f64 = 1.05;
/// Overuse threshold for the filter output, µs. Chromium default.
const OVERUSE_THRESHOLD_US: f64 = 12_500.0;
/// Underuse band boundary as a fraction of [`OVERUSE_THRESHOLD_US`].
/// Tracks Chromium `trendline_estimator`'s underuse factor: below this
/// band the link is considered "deep-normal" and the bitrate grows.
const UNDERUSE_THRESHOLD_FACTOR: f64 = 0.25;
/// Process-noise variance for the 1-D Kalman step.
const PROCESS_NOISE_VAR: f64 = 1e-3;
/// Measurement-noise variance for the 1-D Kalman step.
const MEASUREMENT_NOISE_VAR: f64 = 1.0;
/// Minimum interval between rate-control updates — prevents a burst
/// of TWCC feedback from compounding the multiplicative factor.
const RATE_UPDATE_INTERVAL: Duration = Duration::from_millis(100);

/// Per-subscriber delay-based estimator state.
#[derive(Debug)]
pub(crate) struct DelayEstimator {
    /// 1-D Kalman estimate of the delay gradient (µs).
    gradient_us: f64,
    /// Kalman variance.
    gradient_var: f64,
    /// Current bitrate output (bps).
    bitrate_bps: f64,
    /// Last time the bitrate was multiplicatively scaled.
    last_update: Option<Instant>,
}

impl DelayEstimator {
    pub(super) fn new() -> Self {
        Self {
            gradient_us: 0.0,
            gradient_var: MEASUREMENT_NOISE_VAR,
            bitrate_bps: INITIAL_ESTIMATE_BPS as f64,
            last_update: None,
        }
    }

    /// One Kalman step given a fresh delay-gradient sample in µs.
    pub(super) fn update_kalman(&mut self, gradient_us: f64) {
        // Predict: add process noise to variance.
        self.gradient_var += PROCESS_NOISE_VAR;
        // Update: standard 1-D Kalman gain.
        let gain = self.gradient_var / (self.gradient_var + MEASUREMENT_NOISE_VAR);
        self.gradient_us += gain * (gradient_us - self.gradient_us);
        self.gradient_var *= 1.0 - gain;
    }

    /// Apply the multiplicative rate-control step. Neutral middle
    /// band holds the estimate; only deep-normal expands and overuse
    /// contracts. Matches Chromium's three-zone AIMD.
    pub(super) fn apply_rate_control(&mut self, now: Instant) {
        if let Some(last) = self.last_update {
            if now.saturating_duration_since(last) < RATE_UPDATE_INTERVAL {
                return;
            }
        }
        self.last_update = Some(now);

        let abs_grad = self.gradient_us.abs();
        if abs_grad > OVERUSE_THRESHOLD_US {
            self.bitrate_bps *= DELAY_DECREASE_FACTOR;
        } else if abs_grad < OVERUSE_THRESHOLD_US * UNDERUSE_THRESHOLD_FACTOR {
            self.bitrate_bps *= DELAY_INCREASE_FACTOR;
        }

        self.bitrate_bps = self
            .bitrate_bps
            .clamp(MIN_ESTIMATE_BPS as f64, MAX_ESTIMATE_BPS as f64);
    }

    pub(super) fn bitrate_bps(&self) -> f64 {
        self.bitrate_bps
    }
}
