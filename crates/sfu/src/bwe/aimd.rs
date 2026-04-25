//! Loss-based AIMD bandwidth control — GoogCC component 2.
//!
//! Increase rate (AI) when loss < 0.5%, decrease (MD) when loss > 2%.
//! Multiplicative decrease is 0.85x (RFC 3448 recommendation).

const LOSS_LOW_THRESHOLD: f32 = 0.005; // 0.5% — increase
const LOSS_HIGH_THRESHOLD: f32 = 0.02; // 2.0% — decrease
const AI_FRACTION: f64 = 0.08; // 8% additive increase per interval
const MD_FACTOR: f64 = 0.85; // multiplicative decrease

#[derive(Debug, Clone)]
pub struct AimdController {
    bitrate_bps: u64,
    min_bps: u64,
    max_bps: u64,
}

impl AimdController {
    pub fn new(initial_bps: u64, min_bps: u64, max_bps: u64) -> Self {
        Self {
            bitrate_bps: initial_bps,
            min_bps,
            max_bps,
        }
    }

    /// Update target bitrate based on observed loss fraction [0.0, 1.0].
    pub fn update_loss(&mut self, loss_fraction: f32) -> u64 {
        if loss_fraction < LOSS_LOW_THRESHOLD {
            // Additive increase
            let increase = (self.bitrate_bps as f64 * AI_FRACTION) as u64;
            self.bitrate_bps = (self.bitrate_bps + increase.max(8_000)).min(self.max_bps);
        } else if loss_fraction > LOSS_HIGH_THRESHOLD {
            // Multiplicative decrease
            self.bitrate_bps = ((self.bitrate_bps as f64 * MD_FACTOR) as u64).max(self.min_bps);
        }
        // Between thresholds: hold
        self.bitrate_bps
    }

    pub fn on_overuse(&mut self) -> u64 {
        self.bitrate_bps = ((self.bitrate_bps as f64 * MD_FACTOR) as u64).max(self.min_bps);
        self.bitrate_bps
    }

    pub fn current(&self) -> u64 {
        self.bitrate_bps
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn low_loss_increases_bitrate() {
        let mut c = AimdController::new(500_000, 100_000, 2_000_000);
        let before = c.current();
        c.update_loss(0.001); // 0.1% loss
        assert!(c.current() > before);
    }

    #[test]
    fn high_loss_decreases_bitrate() {
        let mut c = AimdController::new(500_000, 100_000, 2_000_000);
        let before = c.current();
        c.update_loss(0.05); // 5% loss
        assert!(c.current() < before);
    }

    #[test]
    fn overuse_decreases_bitrate() {
        let mut c = AimdController::new(1_000_000, 100_000, 2_000_000);
        let before = c.current();
        c.on_overuse();
        assert!(c.current() < before);
    }
}
