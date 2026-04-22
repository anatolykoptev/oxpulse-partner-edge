//! Unit tests for the M5.4.1 client-hint ceiling in
//! [`super::BandwidthEstimator`].

use std::time::{Duration, Instant};

use super::{BandwidthEstimator, INITIAL_ESTIMATE_BPS};
use crate::propagate::ClientId;

fn client(n: u64) -> ClientId {
    ClientId(n)
}

/// Seed delay/loss to a healthy estimate via a flat link, then record a
/// restrictive client hint. The hint should become the ceiling. After the
/// 10-second stale window the hint is dropped and the delay/loss estimate
/// resumes.
#[test]
fn client_hint_becomes_ceiling() {
    let mut est = BandwidthEstimator::new();
    let start = Instant::now();

    // Warm a delay-based estimate (flat link → stays near INITIAL).
    for i in 0..30u64 {
        let send = start + Duration::from_millis(i * 10);
        let arr = send + Duration::from_millis(5);
        est.record_sent(client(1), i, send);
        est.on_arrival(client(1), i, Some(arr), true, arr);
    }
    let hint_time = start + Duration::from_millis(30 * 10);

    // Capture the un-hinted estimate; the hint must be below it to bind.
    let pre_hint = est
        .estimate_bps(&client(1), hint_time)
        .expect("estimate set");

    // 50 kbps is well below any realistic output of the flat-link warmup.
    let hint_bps: u64 = 50_000;
    assert!(
        pre_hint > hint_bps,
        "pre-hint estimate ({pre_hint}) must exceed hint ({hint_bps}) for ceiling test to be valid"
    );
    est.record_client_hint(client(1), hint_bps, hint_time);

    // Fresh hint → estimate must be capped at hint_bps.
    let with_hint = est
        .estimate_bps(&client(1), hint_time)
        .expect("estimate set");
    assert_eq!(
        with_hint, hint_bps,
        "fresh client hint must be the ceiling (got {with_hint})"
    );

    // Advance past the stale window (10 s + 1 ms). Hint is discarded;
    // estimate should return to the delay/loss value (pre_hint).
    let after_stale = hint_time + Duration::from_millis(10_001);
    let stale = est
        .estimate_bps(&client(1), after_stale)
        .expect("estimate set");
    assert!(
        stale > hint_bps,
        "stale hint must be ignored; estimate should recover above {hint_bps} bps (got {stale})"
    );
    assert_eq!(
        stale, pre_hint,
        "after stale window estimate should return to the un-hinted value (got {stale}, expected {pre_hint})"
    );
}

/// When the client hint is *higher* than the delay/loss estimate the hint
/// is irrelevant — the delay/loss path binds.
#[test]
fn client_hint_ignored_when_higher() {
    let mut est = BandwidthEstimator::new();
    let start = Instant::now();

    // Drive the estimate down via heavy loss (~20%).
    for i in 0..100u64 {
        let received = i % 5 != 0;
        let now = start + Duration::from_millis(i * 10);
        let arr = if received {
            Some(now + Duration::from_millis(5))
        } else {
            None
        };
        est.on_arrival(client(1), i, arr, received, now);
    }
    let now = start + Duration::from_millis(100 * 10);

    let low_est = est.estimate_bps(&client(1), now).expect("estimate set");
    assert!(
        low_est < INITIAL_ESTIMATE_BPS,
        "loss should have lowered the estimate (got {low_est})"
    );

    // Record a generous client hint (2 Mbps > low_est).
    est.record_client_hint(client(1), 2_000_000, now);

    let after_hint = est.estimate_bps(&client(1), now).expect("estimate set");
    assert_eq!(
        after_hint, low_est,
        "generous hint must not raise the estimate above delay/loss floor (got {after_hint})"
    );
}
