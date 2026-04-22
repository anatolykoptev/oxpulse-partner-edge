//! GCC-based per-subscriber bandwidth estimator (M5.3).
//!
//! Canonical Google Congestion Control shape: two parallel estimators
//! fed by TWCC (draft-holmer-rmcat-transport-wide-cc) feedback,
//! combined via `min(delay_based, loss_based)`.
//!
//! Concern-split modules:
//! * [`kalman`] — 1-D Kalman over the one-way delay gradient
//!   `d(i) = Δarrival - Δsend`, three-zone multiplicative rate control.
//! * [`loss`] — sliding-window loss fraction, three-band response
//!   (< 2% / 2-10% / > 10%).
//! * [`feedback`] — TWCC packet ingestion glue.
//! * [`subscriber`] — per-subscriber state + `combined_bps` combination
//!   (delay / loss / native-ceiling / client-hint ceiling).
//!
//! Port references (fresh implementation, no copied licensed code):
//! webrtc-rs `interceptor/src/twcc/`, pion `pkg/gcc/`, Chromium
//! `modules/congestion_controller/goog_cc/`. str0m 0.18's own BWE is
//! consumed as a ceiling via [`BandwidthEstimator::record_native_estimate`].
//! See ADR § D9 and continuation plan § str0m 0.18 quirks.

mod feedback;
mod kalman;
mod loss;
mod subscriber;

use std::collections::HashMap;
use std::time::{Duration, Instant};

use crate::propagate::ClientId;

pub use feedback::{TwccFeedback, TwccSample};
pub use kalman::{INITIAL_ESTIMATE_BPS, MAX_ESTIMATE_BPS, MIN_ESTIMATE_BPS};

use subscriber::{ClientHint, PerSubscriber};

/// Hard cap on the per-subscriber send-time map so a pathological
/// publisher can't leak memory. 8192 entries ≈ 1 s at 8 k pps — far
/// above any real-world sustained rate.
const SEND_TIMES_CAP: usize = 8_192;

/// Per-subscriber GCC bandwidth estimator. Callers own one instance
/// per [`crate::Registry`] and thread it by `&mut`.
#[derive(Debug, Default)]
pub struct BandwidthEstimator {
    subs: HashMap<ClientId, PerSubscriber>,
}

impl BandwidthEstimator {
    pub fn new() -> Self {
        Self::default()
    }

    /// Record that we transmitted a packet with TWCC seq `seq` at
    /// `send_time`. When TWCC feedback arrives, the feedback module
    /// pairs arrivals with these send times to compute the one-way
    /// delay gradient. Consumed + evicted when the arrival lands.
    pub fn record_sent(&mut self, subscriber: ClientId, seq: u64, send_time: Instant) {
        let state = self
            .subs
            .entry(subscriber)
            .or_insert_with(PerSubscriber::new);
        if state.send_times.len() > SEND_TIMES_CAP {
            let to_drop: Vec<u64> = state
                .send_times
                .keys()
                .take(SEND_TIMES_CAP / 2)
                .copied()
                .collect();
            for k in to_drop {
                state.send_times.remove(&k);
            }
        }
        state.send_times.insert(seq, send_time);
    }

    /// Feed str0m's own `Event::EgressBitrateEstimate(BweKind::Twcc(Bitrate))`
    /// into our estimator as a ceiling. See module docs.
    pub fn record_native_estimate(&mut self, subscriber: ClientId, bitrate_bps: u64) {
        let state = self
            .subs
            .entry(subscriber)
            .or_insert_with(PerSubscriber::new);
        state.native_estimate_bps = Some(bitrate_bps);
    }

    /// Record a client-side bandwidth budget hint (from DC id:2, label
    /// `sfu-budget`). Incorporated into `estimate_bps` as a ceiling
    /// alongside delay / loss / native. Hints older than
    /// [`subscriber::CLIENT_HINT_STALE_AFTER`] (10 s) are silently
    /// dropped from the combination — the client is assumed
    /// unreachable or idle.
    pub fn record_client_hint(&mut self, subscriber: ClientId, budget_bps: u64, now: Instant) {
        let state = self
            .subs
            .entry(subscriber)
            .or_insert_with(PerSubscriber::new);
        state.client_hint = Some(ClientHint {
            budget_bps,
            recorded_at: now,
        });
    }

    /// Ingest a batch of TWCC per-packet samples.
    ///
    /// See [`TwccFeedback`] for the in-crate shape. Glue that decodes
    /// a native `str0m::rtp::rtcp::Twcc` packet into one of these is
    /// deferred to M5.x — `TwccSeq` and `PacketStatus` are private in
    /// str0m 0.18 so the raw `Twcc::into_iter` path is unreachable
    /// from downstream crates. The decoded-samples shape is also what
    /// the unit tests synthesize directly.
    pub fn on_twcc_feedback(
        &mut self,
        subscriber: ClientId,
        feedback_pkt: &TwccFeedback,
        now: Instant,
    ) {
        feedback::ingest_twcc(self, subscriber, feedback_pkt, now);
    }

    /// Test-friendly primitive: record a single (seq, arrival,
    /// received) sample. Equivalent to one iteration step inside
    /// [`on_twcc_feedback`]. When `received` is false, `arrival` is
    /// ignored and should be `None`.
    #[cfg(any(test, feature = "test-utils"))]
    pub fn on_arrival(
        &mut self,
        subscriber: ClientId,
        seq: u64,
        arrival: Option<Instant>,
        received: bool,
        now: Instant,
    ) {
        feedback::ingest_arrival(self, subscriber, seq, arrival, received, now);
    }

    /// Combined GCC estimate in bps at time `now`.
    ///
    /// Returns `None` until at least one sample has been observed for
    /// the subscriber. The estimate is `min(delay, loss, native, hint)`
    /// where `hint` is the client's self-reported budget from DC id:2
    /// (ignored when stale — no hint received in > 10 s).
    pub fn estimate_bps(&self, subscriber: &ClientId, now: Instant) -> Option<u64> {
        self.subs.get(subscriber).map(|s| s.combined_bps(now))
    }

    /// Observed loss fraction in percent over the sliding window.
    ///
    /// Pre-wired accessor; M5.4 RTCP-reporting integration consumes
    /// this for `RTCStats` / receiver-report synthesis. Not exposed on
    /// any public surface yet — intentional, so the internal shape of
    /// [`loss::LossEstimator`] can still evolve.
    pub fn observed_loss_pct(&self, subscriber: &ClientId) -> Option<f32> {
        self.subs
            .get(subscriber)
            .map(|s| s.loss.last_fraction() * 100.0)
    }

    /// Last RTT sample seen via TWCC arrival + `record_sent`.
    ///
    /// Pre-wired accessor; M6 observability surfaces this value as a
    /// Prometheus histogram. Kept here rather than in the metrics
    /// module because the underlying `Duration` sample is produced
    /// per-feedback by the GCC ingestion path.
    pub fn observed_rtt(&self, subscriber: &ClientId) -> Option<Duration> {
        self.subs.get(subscriber).and_then(|s| s.rtt)
    }

    /// Drop subscriber state on disconnect.
    pub fn remove(&mut self, subscriber: &ClientId) {
        self.subs.remove(subscriber);
    }

    /// Number of tracked subscribers.
    pub fn len(&self) -> usize {
        self.subs.len()
    }

    /// Convenience — true when no subscribers have been seen yet.
    pub fn is_empty(&self) -> bool {
        self.subs.is_empty()
    }

    /// Crate-local accessor for the feedback module — mutates state
    /// inside a subscriber, creating it if missing.
    pub(super) fn sub_mut(&mut self, subscriber: ClientId) -> &mut PerSubscriber {
        self.subs
            .entry(subscriber)
            .or_insert_with(PerSubscriber::new)
    }
}

#[cfg(test)]
mod tests;
