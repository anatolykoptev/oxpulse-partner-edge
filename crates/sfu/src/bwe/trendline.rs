//! Trendline delay detector — GoogCC component 1.
//!
//! Fits a linear regression (Welch method) over the last N inter-arrival
//! time deltas. Positive slope = delay building = congestion signal.
//! Negative or zero slope = delay stable or decreasing = no congestion.

/// Window size for trendline regression.
const WINDOW: usize = 20;
/// Threshold: slope above this bps/ms indicates overuse.
const OVERUSE_THRESHOLD: f64 = 12.5; // ms/s

#[derive(Debug, Clone)]
pub struct TrendlineDetector {
    /// Rolling window of (arrival_delta_ms, send_delta_ms) pairs.
    deltas: Vec<(f64, f64)>,
    /// Current overuse state.
    pub state: BandwidthState,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum BandwidthState {
    Underuse,
    Normal,
    Overuse,
}

impl TrendlineDetector {
    pub fn new() -> Self {
        Self {
            deltas: Vec::with_capacity(WINDOW + 1),
            state: BandwidthState::Normal,
        }
    }

    /// Feed a new packet's timing information.
    /// `arrival_delta_ms`: difference in arrival time from previous packet.
    /// `send_delta_ms`: difference in send time from previous packet.
    pub fn update(&mut self, arrival_delta_ms: f64, send_delta_ms: f64) {
        self.deltas.push((arrival_delta_ms, send_delta_ms));
        if self.deltas.len() > WINDOW {
            self.deltas.remove(0);
        }
        if self.deltas.len() < 3 {
            return;
        }

        let slope = self.trendline_slope();
        self.state = if slope > OVERUSE_THRESHOLD {
            BandwidthState::Overuse
        } else if slope < -OVERUSE_THRESHOLD {
            BandwidthState::Underuse
        } else {
            BandwidthState::Normal
        };
    }

    fn trendline_slope(&self) -> f64 {
        // Compute delay variation: accumulated_delay[i] = sum of (arrival - send) deltas
        let n = self.deltas.len() as f64;
        let accumulated: Vec<f64> = self
            .deltas
            .iter()
            .scan(0.0f64, |acc, (a, s)| {
                *acc += a - s;
                Some(*acc)
            })
            .collect();

        // Linear regression: y = a*x + b, return slope `a`
        let x_bar = (n - 1.0) / 2.0;
        let y_bar: f64 = accumulated.iter().sum::<f64>() / n;
        let mut num = 0.0f64;
        let mut den = 0.0f64;
        for (i, y) in accumulated.iter().enumerate() {
            let x = i as f64;
            num += (x - x_bar) * (y - y_bar);
            den += (x - x_bar).powi(2);
        }
        if den.abs() < 1e-10 {
            0.0
        } else {
            num / den
        }
    }

    pub fn overuse(&self) -> bool {
        self.state == BandwidthState::Overuse
    }
}

impl Default for TrendlineDetector {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stable_arrival_times_stay_normal() {
        let mut d = TrendlineDetector::new();
        for _ in 0..25 {
            d.update(20.0, 20.0); // equal deltas = no delay accumulation
        }
        assert_eq!(d.state, BandwidthState::Normal);
    }

    #[test]
    fn increasing_delay_triggers_overuse() {
        let mut d = TrendlineDetector::new();
        for i in 0..25 {
            d.update(20.0 + i as f64 * 2.0, 20.0); // arrival grows, send stable
        }
        assert_eq!(d.state, BandwidthState::Overuse);
    }
}
