//! Per-subscriber state for the GCC bandwidth estimator.
//!
//! Owns the delay/loss/native/client-hint fields for one subscriber and
//! the `combined_bps(now)` combination function that produces the final
//! estimate: `min(delay, loss, native_ceiling, client_hint_ceiling)`.
//!
//! Pulled out of [`super`] when the M5.4.1 client-hint additions pushed
//! `mod.rs` past the 200-line target.

use std::collections::HashMap;
use std::time::{Duration, Instant};

use super::kalman::{DelayEstimator, MAX_ESTIMATE_BPS, MIN_ESTIMATE_BPS};
use super::loss::LossEstimator;

/// Client hints older than this window are treated as stale and excluded
/// from the combined estimate.
pub(super) const CLIENT_HINT_STALE_AFTER: Duration = Duration::from_secs(10);

/// Last bandwidth-budget hint received from a subscriber's browser via
/// DC id:2 (`sfu-budget`, negotiated, unordered).
#[derive(Debug)]
pub(super) struct ClientHint {
    pub(super) budget_bps: u64,
    pub(super) recorded_at: Instant,
}

#[derive(Debug)]
pub(crate) struct PerSubscriber {
    /// Known send times keyed by TWCC seq. Caller populates via
    /// [`super::BandwidthEstimator::record_sent`] before feedback arrives.
    /// Seq is `u64` to match the underlying `str0m::rtp` `TwccSeq`
    /// semantics without naming the private type.
    pub(super) send_times: HashMap<u64, Instant>,
    /// Most-recently-seen (seq, arrival) for computing gradients.
    pub(super) last_arrival: Option<(u64, Instant)>,
    pub(super) delay: DelayEstimator,
    pub(super) loss: LossEstimator,
    /// RTT proxy: `(arrival - send_time) × 2`. Populated only when
    /// `record_sent` was called for the same seq.
    pub(super) rtt: Option<Duration>,
    /// str0m's own GCC estimate (bps). Ceiling on our output.
    pub(super) native_estimate_bps: Option<u64>,
    /// Most recent browser-reported bandwidth budget (M5.4.1). Acts as
    /// an additional ceiling — the client knows its inbound capacity
    /// better than the server-side delay/loss probes do.
    pub(super) client_hint: Option<ClientHint>,
}

impl PerSubscriber {
    pub(super) fn new() -> Self {
        Self {
            send_times: HashMap::new(),
            last_arrival: None,
            delay: DelayEstimator::new(),
            loss: LossEstimator::new(),
            rtt: None,
            native_estimate_bps: None,
            client_hint: None,
        }
    }

    /// Combined GCC estimate in bps at time `now`.
    ///
    /// Applies ceilings in order:
    /// 1. `min(delay_based, loss_based)` — core GCC output
    /// 2. Clamped to `[MIN_ESTIMATE_BPS, MAX_ESTIMATE_BPS]`
    /// 3. `native_estimate_bps` ceiling (str0m's own TWCC estimate)
    /// 4. `client_hint.budget_bps` ceiling, if hint is fresh (< 10 s old)
    pub(super) fn combined_bps(&self, now: Instant) -> u64 {
        let base = self.delay.bitrate_bps().min(self.loss.bitrate_bps());
        let mut est = base.clamp(MIN_ESTIMATE_BPS as f64, MAX_ESTIMATE_BPS as f64) as u64;

        if let Some(native) = self.native_estimate_bps {
            est = est.min(native);
        }

        if let Some(hint) = &self.client_hint {
            if now.duration_since(hint.recorded_at) < CLIENT_HINT_STALE_AFTER {
                est = est.min(hint.budget_bps);
            }
        }

        est
    }
}
