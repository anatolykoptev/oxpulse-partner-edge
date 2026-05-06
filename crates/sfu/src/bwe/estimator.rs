//! GoogCC v2 bandwidth estimator combining trendline delay detector and
//! loss-based AIMD controller.

use str0m::media::Rid;

use crate::bwe::aimd::AimdController;
use crate::bwe::trendline::TrendlineDetector;

// Bitrate tiers (must match Pacer floor constants)
const H_LAYER_BPS: u64 = 400_000; // 400 kbps — h (medium)
const F_LAYER_BPS: u64 = 1_200_000; // 1.2 Mbps — f (full)

#[derive(Debug)]
pub struct GoogCcEstimator {
    trendline: TrendlineDetector,
    aimd: AimdController,
    last_arrival_ms: Option<f64>,
    last_send_ms: Option<f64>,
}

impl GoogCcEstimator {
    pub fn new() -> Self {
        Self {
            trendline: TrendlineDetector::new(),
            aimd: AimdController::new(500_000, 100_000, 2_500_000),
            last_arrival_ms: None,
            last_send_ms: None,
        }
    }

    /// Feed incoming packet timing. Returns updated target bitrate.
    pub fn on_receive(&mut self, arrival_ms: f64, send_ms: f64, loss_fraction: f32) -> u64 {
        if let (Some(la), Some(ls)) = (self.last_arrival_ms, self.last_send_ms) {
            let arr_delta = arrival_ms - la;
            let snd_delta = send_ms - ls;
            self.trendline.update(arr_delta, snd_delta);

            if self.trendline.overuse() {
                self.last_arrival_ms = Some(arrival_ms);
                self.last_send_ms = Some(send_ms);
                return self.aimd.on_overuse();
            }
        }
        self.last_arrival_ms = Some(arrival_ms);
        self.last_send_ms = Some(send_ms);
        self.aimd.update_loss(loss_fraction)
    }

    /// Select simulcast layer based on current estimated bitrate.
    pub fn preferred_rid(&self) -> Rid {
        let bps = self.aimd.current();
        if bps >= F_LAYER_BPS {
            crate::client::layer::HIGH
        } else if bps >= H_LAYER_BPS {
            crate::client::layer::MEDIUM
        } else {
            crate::client::layer::LOW
        }
    }

    pub fn current_bps(&self) -> u64 {
        self.aimd.current()
    }

    /// Test-only: pin the AIMD controller bitrate directly so integration
    /// tests can assert GoogCC-conservative-merge behaviour without needing
    /// to inject real TWCC packets. Does NOT touch the trendline state.
    #[cfg(any(test, feature = "test-utils"))]
    pub fn force_high_bps_for_tests(&mut self, bps: u64) {
        self.aimd = AimdController::new(bps, 100_000, 2_500_000);
    }
}

impl Default for GoogCcEstimator {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::client::layer::{HIGH, LOW, MEDIUM};

    #[test]
    fn initial_preferred_rid_is_medium() {
        let est = GoogCcEstimator::new();
        // Initial bitrate is 500kbps >= H_LAYER_BPS (400k) but < F_LAYER_BPS (1.2M)
        assert_eq!(est.preferred_rid(), MEDIUM);
    }

    #[test]
    fn low_loss_raises_bitrate_to_high_layer() {
        let mut est = GoogCcEstimator::new();
        // Push bitrate up with many low-loss updates using stable timing
        for i in 0u32..30 {
            let t = 20.0 * (1.0 + i as f64);
            est.on_receive(t, t, 0.001);
        }
        assert_eq!(est.preferred_rid(), HIGH);
    }

    #[test]
    fn overuse_signal_decreases_bitrate() {
        let mut est = GoogCcEstimator::new();
        // First get to a high bitrate with stable timing
        for i in 0u32..30 {
            let t = 20.0 * (1.0 + i as f64);
            est.on_receive(t, t, 0.001);
        }
        let high_bps = est.current_bps();
        // Now feed growing delay (overuse) — arrival grows faster than send
        for i in 0u32..30 {
            let base = 20.0 * (31.0 + i as f64);
            est.on_receive(base + i as f64 * 50.0, base, 0.001);
        }
        assert!(
            est.current_bps() < high_bps,
            "overuse should reduce bitrate"
        );
    }

    #[test]
    fn high_loss_keeps_bitrate_low() {
        let mut est = GoogCcEstimator::new();
        // Repeated high-loss updates should hold or decrease
        for i in 0u32..10 {
            let t = 20.0 * (1.0 + i as f64);
            est.on_receive(t, t, 0.05); // 5% loss
        }
        // Should be at or below initial 500kbps (decreasing on high loss)
        assert!(est.current_bps() <= 500_000);
    }

    #[test]
    fn low_bitrate_selects_low_layer() {
        let mut est = GoogCcEstimator::new();
        // Force high loss to drive bitrate down below H_LAYER_BPS (400k)
        for i in 0u32..20 {
            let t = 20.0 * (1.0 + i as f64);
            est.on_receive(t, t, 0.05);
        }
        assert_eq!(est.preferred_rid(), LOW);
    }
}
