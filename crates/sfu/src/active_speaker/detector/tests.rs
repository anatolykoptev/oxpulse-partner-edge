//! Unit tests for the dominant-speaker detector. Pulled out of
//! `detector.rs` so the production file stays under 200 LOC.

use super::*;
use std::time::Duration;

fn feed(d: &mut ActiveSpeakerDetector, p: u64, lvl: u8, from: Instant, ms: u64) {
    let mut t = from;
    let end = from + Duration::from_millis(ms);
    while t < end {
        d.record_level(p, lvl, t);
        t += Duration::from_millis(20);
    }
}

#[test]
fn single_speaker() {
    let mut d = ActiveSpeakerDetector::new();
    let t0 = Instant::now();
    d.add_peer(1, t0);
    assert_eq!(d.tick(t0 + Duration::from_millis(300)), Some(1));
    assert_eq!(d.tick(t0 + Duration::from_millis(600)), None);
}

#[test]
fn silence_then_speech_switches() {
    let mut d = ActiveSpeakerDetector::new();
    let t0 = Instant::now();
    d.add_peer(1, t0);
    d.add_peer(2, t0);
    feed(&mut d, 1, 5, t0, 2000);
    feed(&mut d, 2, 127, t0, 2000);
    assert_eq!(d.tick(t0 + Duration::from_millis(2050)), Some(1));
}

#[test]
fn hysteresis_prevents_brief_flap() {
    let mut d = ActiveSpeakerDetector::new();
    let t0 = Instant::now();
    d.add_peer(1, t0);
    d.add_peer(2, t0);
    feed(&mut d, 1, 5, t0, 2000);
    feed(&mut d, 2, 127, t0, 2000);
    assert_eq!(d.tick(t0 + Duration::from_millis(2050)), Some(1));
    let t1 = t0 + Duration::from_millis(2050);
    feed(&mut d, 1, 127, t1, 400);
    feed(&mut d, 2, 5, t1, 400);
    assert_eq!(d.tick(t1 + Duration::from_millis(450)), None);
}

/// M6.1: verify hysteresis histogram records an observation on the second
/// `record_hysteresis_observation` call (the first call sets the baseline;
/// the second measures the interval between consecutive changes).
#[test]
fn hysteresis_histogram_records_interval() {
    use prometheus::{Histogram, HistogramOpts};
    let hist = Histogram::with_opts(
        HistogramOpts::new("test_h", "test").buckets(vec![100.0, 500.0, 2_000.0]),
    )
    .expect("histogram");
    let mut d = ActiveSpeakerDetector::new();
    d.set_hysteresis_histogram(hist.clone());
    let t0 = Instant::now();

    // First call — sets `last_speaker_change`, no sample produced yet.
    d.record_hysteresis_observation(t0);
    assert_eq!(hist.get_sample_count(), 0, "first call: no sample yet");

    // Second call 1500 ms later — records the interval (should land in the
    // 500–2000 ms bucket).
    let t1 = t0 + Duration::from_millis(1500);
    d.record_hysteresis_observation(t1);
    assert_eq!(
        hist.get_sample_count(),
        1,
        "second call: one interval sample"
    );
    // Interval of 1500 ms lands above the 500 ms bucket boundary.
    assert!(
        hist.get_sample_sum() > 500.0,
        "interval should be > 500 ms, got {}",
        hist.get_sample_sum()
    );
}

#[test]
fn idle_removal_clears_dominance() {
    let mut d = ActiveSpeakerDetector::new();
    let t0 = Instant::now();
    d.add_peer(1, t0);
    assert_eq!(d.tick(t0 + Duration::from_millis(300)), Some(1));
    d.remove_peer(1);
    assert_eq!(d.tick(t0 + Duration::from_millis(600)), None);
}
