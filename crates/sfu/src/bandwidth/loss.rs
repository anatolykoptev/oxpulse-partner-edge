//! Loss-based estimator — the second half of GCC.
//!
//! Split from [`mod.rs`][super] because the loss-window bookkeeping
//! and the canonical three-band response (< 2% / 2-10% / > 10%) form
//! a distinct concern from the Kalman delay machinery. See the parent
//! module for the references and the combining rule.

use std::collections::VecDeque;
use std::time::{Duration, Instant};

use super::kalman::{
    DELAY_INCREASE_FACTOR, INITIAL_ESTIMATE_BPS, MAX_ESTIMATE_BPS, MIN_ESTIMATE_BPS,
};

/// Minimum interval between rate-control updates. Without this, a
/// packet-rate of 1000 pps would compound the multiplicative factor
/// a thousand times per second — the estimate would saturate at
/// [`MAX_ESTIMATE_BPS`] on any link with < 2% loss after < 100ms.
const RATE_UPDATE_INTERVAL: Duration = Duration::from_millis(200);

/// Fractions at which the loss-based estimator reacts, per
/// `draft-ietf-rmcat-gcc` §5.
const LOSS_INCREASE_CEILING: f32 = 0.02;
const LOSS_DECREASE_FLOOR: f32 = 0.10;

/// Multiplicative-decrease factor when sustained loss is observed.
const LOSS_DECREASE_FACTOR: f64 = 0.5;

/// Sliding window for the loss ratio. Shorter = more reactive, noisier;
/// longer = stable but slow.
pub(super) const LOSS_WINDOW: Duration = Duration::from_millis(1000);

#[derive(Debug)]
pub(crate) struct LossEstimator {
    samples: VecDeque<(Instant, bool)>,
    bitrate_bps: f64,
    last_fraction: f32,
    last_update: Option<Instant>,
}

impl LossEstimator {
    pub(super) fn new() -> Self {
        Self {
            samples: VecDeque::new(),
            bitrate_bps: INITIAL_ESTIMATE_BPS as f64,
            last_fraction: 0.0,
            last_update: None,
        }
    }

    /// Record one received/lost sample.
    pub(super) fn record(&mut self, now: Instant, received: bool) {
        self.samples.push_back((now, received));
    }

    /// Recompute the loss ratio and apply the rate-control step.
    /// Window eviction runs on every call; the multiplicative step is
    /// gated by [`RATE_UPDATE_INTERVAL`] so packet-rate changes don't
    /// compound the factor.
    pub(super) fn apply_rate_control(&mut self, now: Instant) {
        // Evict samples older than the window.
        while let Some(&(ts, _)) = self.samples.front() {
            if now.saturating_duration_since(ts) > LOSS_WINDOW {
                self.samples.pop_front();
            } else {
                break;
            }
        }
        if self.samples.is_empty() {
            return;
        }
        let total = self.samples.len() as f32;
        let lost = self.samples.iter().filter(|(_, r)| !*r).count() as f32;
        let frac = lost / total;
        self.last_fraction = frac;

        if let Some(last) = self.last_update {
            if now.saturating_duration_since(last) < RATE_UPDATE_INTERVAL {
                return;
            }
        }
        self.last_update = Some(now);

        if frac >= LOSS_DECREASE_FLOOR {
            self.bitrate_bps *= LOSS_DECREASE_FACTOR;
        } else if frac < LOSS_INCREASE_CEILING {
            self.bitrate_bps *= DELAY_INCREASE_FACTOR;
        }
        // 2–10% band: hold.

        self.bitrate_bps = self
            .bitrate_bps
            .clamp(MIN_ESTIMATE_BPS as f64, MAX_ESTIMATE_BPS as f64);
    }

    pub(super) fn bitrate_bps(&self) -> f64 {
        self.bitrate_bps
    }

    pub(super) fn last_fraction(&self) -> f32 {
        self.last_fraction
    }
}
