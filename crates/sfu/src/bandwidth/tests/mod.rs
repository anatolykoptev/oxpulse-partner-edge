//! Unit tests for [`super::BandwidthEstimator`].

use std::time::{Duration, Instant};

use super::{
    BandwidthEstimator, TwccFeedback, TwccSample, INITIAL_ESTIMATE_BPS, MAX_ESTIMATE_BPS,
    MIN_ESTIMATE_BPS,
};
use crate::propagate::ClientId;

fn client(n: u64) -> ClientId {
    ClientId(n)
}

#[test]
fn initial_estimate_none_until_feedback() {
    let est = BandwidthEstimator::new();
    assert!(est.estimate_bps(&client(1), Instant::now()).is_none());
}

#[test]
fn steady_arrivals_hold_initial_estimate() {
    let mut est = BandwidthEstimator::new();
    let start = Instant::now();
    for i in 0..20u64 {
        let seq: u64 = i;
        let send = start + Duration::from_millis(i * 10);
        let arr = send + Duration::from_millis(5); // constant one-way delay
        est.record_sent(client(1), seq, send);
        est.on_arrival(
            client(1),
            seq,
            Some(arr),
            true,
            start + Duration::from_millis(i * 10 + 5),
        );
    }
    let now = start + Duration::from_millis(20 * 10 + 5);
    let bps = est.estimate_bps(&client(1), now).expect("estimate set");
    assert!(
        bps >= INITIAL_ESTIMATE_BPS,
        "steady link should not downgrade (got {bps})"
    );
    assert!(bps <= MAX_ESTIMATE_BPS);
}

#[test]
fn increasing_delay_lowers_estimate() {
    let mut est = BandwidthEstimator::new();
    let start = Instant::now();
    // Bufferbloat shape: each packet +15 ms extra delay. Inter-arrival
    // gap is then (10 + 15) ms and inter-send gap is 10 ms, producing
    // a +15 000 µs gradient per packet — well above the 12 500 µs
    // overuse threshold.
    for i in 0..60u64 {
        let seq: u64 = i;
        let send = start + Duration::from_millis(i * 10);
        let arr = send + Duration::from_millis(5 + i * 15);
        est.record_sent(client(1), seq, send);
        est.on_arrival(client(1), seq, Some(arr), true, arr);
    }
    let now = start + Duration::from_millis(60 * 10);
    let bps = est.estimate_bps(&client(1), now).expect("estimate set");
    assert!(
        bps < INITIAL_ESTIMATE_BPS,
        "ramping delay should lower estimate (got {bps})"
    );
    assert!(bps >= MIN_ESTIMATE_BPS);
}

#[test]
fn steady_loss_kicks_loss_estimator() {
    let mut est = BandwidthEstimator::new();
    let start = Instant::now();
    // 100 samples, 20% loss evenly spread.
    for i in 0..100u64 {
        let seq: u64 = i;
        let received = i % 5 != 0;
        let now = start + Duration::from_millis(i * 10);
        let arr = if received {
            Some(now + Duration::from_millis(5))
        } else {
            None
        };
        est.on_arrival(client(1), seq, arr, received, now);
    }
    let now = start + Duration::from_millis(100 * 10);
    let loss = est.observed_loss_pct(&client(1)).expect("loss set");
    assert!(
        loss >= 15.0,
        "loss window should reflect ~20% (got {loss}%)"
    );
    let bps = est.estimate_bps(&client(1), now).expect("estimate set");
    assert!(
        bps < INITIAL_ESTIMATE_BPS,
        "20% loss should trigger loss-based decrease (got {bps})"
    );
}

#[test]
fn native_estimate_acts_as_ceiling() {
    let mut est = BandwidthEstimator::new();
    let start = Instant::now();
    // Warm a delay-based estimate via a zero-gradient link.
    for i in 0..10u64 {
        let seq: u64 = i;
        let send = start + Duration::from_millis(i * 10);
        let arr = send + Duration::from_millis(5);
        est.record_sent(client(1), seq, send);
        est.on_arrival(client(1), seq, Some(arr), true, arr);
    }
    let now = start + Duration::from_millis(10 * 10);
    est.record_native_estimate(client(1), 200_000);
    let bps = est.estimate_bps(&client(1), now).expect("estimate set");
    assert_eq!(bps, 200_000, "native ceiling binds the combined estimate");
}

#[test]
fn twcc_batch_matches_single_arrival_ingestion() {
    // Feeding a TwccFeedback batch should produce the same estimate
    // state as feeding its samples one-by-one.
    let start = Instant::now();
    let samples: Vec<TwccSample> = (0..20u64)
        .map(|i| TwccSample {
            seq: i,
            arrival: Some(start + Duration::from_millis(i * 10 + 5)),
        })
        .collect();

    let mut est_batch = BandwidthEstimator::new();
    for i in 0..20u64 {
        est_batch.record_sent(client(1), i, start + Duration::from_millis(i * 10));
    }
    let now = start + Duration::from_millis(20 * 10);
    est_batch.on_twcc_feedback(client(1), &TwccFeedback::with_samples(samples.clone()), now);

    let mut est_single = BandwidthEstimator::new();
    for i in 0..20u64 {
        est_single.record_sent(client(1), i, start + Duration::from_millis(i * 10));
    }
    for s in &samples {
        est_single.on_arrival(client(1), s.seq, s.arrival, s.arrival.is_some(), now);
    }

    assert_eq!(
        est_batch.estimate_bps(&client(1), now),
        est_single.estimate_bps(&client(1), now),
        "batch and single-arrival paths must produce identical estimates"
    );
}

#[test]
fn remove_subscriber_drops_state() {
    let mut est = BandwidthEstimator::new();
    let now = Instant::now();
    est.on_arrival(client(1), 0u64, Some(now), true, now);
    assert_eq!(est.len(), 1);
    est.remove(&client(1));
    assert_eq!(est.len(), 0);
    assert!(est.estimate_bps(&client(1), now).is_none());
}

mod tests_client_hint;
