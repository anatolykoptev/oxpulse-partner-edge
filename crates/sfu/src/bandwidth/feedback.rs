//! TWCC feedback ingestion — concern-clean split from [`mod.rs`][super].
//!
//! str0m 0.18 exposes `str0m::rtp::rtcp::Twcc` publicly but its
//! iteration API (`Twcc::into_iter`) requires `TwccSeq` and yields
//! `PacketStatus`, neither of which is reachable from downstream
//! crates (they live in `rtp_` private modules). We therefore define
//! an in-crate [`TwccFeedback`] / [`TwccSample`] shape here that the
//! estimator consumes; glue that decodes a native `Twcc` packet into
//! `TwccFeedback` is deferred to M5.x (when we also own the sending
//! `TwccSendRegister` needed to reconstruct send times).
//!
//! The shape matches what the iterator would yield: one sample per
//! TWCC-sequenced packet, with `arrival = None` for `NotReceived` and
//! `arrival = Some(_)` for received packets.

use std::time::Instant;

use super::subscriber::PerSubscriber;
use super::BandwidthEstimator;
use crate::propagate::ClientId;

/// Single per-packet TWCC observation. `arrival.is_some()` encodes
/// "received" (maps to str0m's `ReceivedSmallDelta` / `ReceivedLargeOrNegativeDelta`);
/// `arrival.is_none()` encodes "lost" (maps to `NotReceived`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TwccSample {
    pub seq: u64,
    pub arrival: Option<Instant>,
}

/// Parsed TWCC feedback — a batch of per-packet samples produced by
/// one RTCP transport-wide-feedback packet from a receiver.
#[derive(Debug, Clone, Default)]
pub struct TwccFeedback {
    pub samples: Vec<TwccSample>,
}

impl TwccFeedback {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_samples(samples: Vec<TwccSample>) -> Self {
        Self { samples }
    }
}

/// Push every sample in `feedback` through [`ingest_arrival`].
pub(super) fn ingest_twcc(
    est: &mut BandwidthEstimator,
    subscriber: ClientId,
    feedback: &TwccFeedback,
    now: Instant,
) {
    for s in &feedback.samples {
        let received = s.arrival.is_some();
        ingest_arrival(est, subscriber, s.seq, s.arrival, received, now);
    }
}

/// Record a single (seq, arrival, received) sample for `subscriber`.
pub(super) fn ingest_arrival(
    est: &mut BandwidthEstimator,
    subscriber: ClientId,
    seq: u64,
    arrival: Option<Instant>,
    received: bool,
    now: Instant,
) {
    let state = est.sub_mut(subscriber);
    state.loss.record(now, received);
    if received {
        if let Some(arrival_time) = arrival {
            apply_delay_sample(state, seq, arrival_time, now);
        }
    }
    state.loss.apply_rate_control(now);
}

/// Update the delay-based estimator from a fresh arrival. Requires
/// a previous arrival plus (optionally) matching send-time entries
/// for both seqs. Without send times we fall back to a zero-gradient
/// baseline so the Kalman state only moves when arrival-jitter is
/// asymmetric — a graceful degradation per the module docs.
fn apply_delay_sample(state: &mut PerSubscriber, seq: u64, arrival: Instant, now: Instant) {
    if let Some((prev_seq, prev_arrival)) = state.last_arrival {
        let d_arr = arrival.saturating_duration_since(prev_arrival).as_micros() as f64;
        let d_send = match (
            state.send_times.get(&prev_seq).copied(),
            state.send_times.get(&seq).copied(),
        ) {
            (Some(s0), Some(s1)) => {
                let dur: std::time::Duration = s1.saturating_duration_since(s0);
                dur.as_micros() as f64
            }
            _ => d_arr,
        };
        let gradient_us = d_arr - d_send;
        state.delay.update_kalman(gradient_us);
        state.delay.apply_rate_control(now);

        if let Some(send_t) = state.send_times.get(&seq).copied() {
            let rtt = arrival.saturating_duration_since(send_t) * 2;
            state.rtt = Some(rtt);
        }
        // Evict the predecessor's send-time — it's been consumed. We
        // KEEP the current seq's entry because the NEXT arrival will
        // need it as its predecessor.
        state.send_times.remove(&prev_seq);
    }
    state.last_arrival = Some((seq, arrival));
}
