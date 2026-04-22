//! Pure math helpers ported from mediasoup's ActiveSpeakerObserver.
//! No state — every function is a deterministic mapping of inputs to
//! outputs, which makes the algorithm core unit-testable without any
//! `Instant` / `HashMap` scaffolding.

use super::MIN_ACTIVITY_SCORE;

// mediasoup: C++ `ComputeBinomialCoefficient`.
pub(super) fn binomial_coefficient(n: i32, r: i32) -> i64 {
    let r = r.max(n - r);
    let (mut t, mut i, mut j): (i64, i64, i64) = (1, n as i64, 1);
    while i > r as i64 {
        t = t * i / j;
        i -= 1;
        j += 1;
    }
    t
}

// mediasoup: C++ `ComputeActivityScore`.
pub(super) fn compute_activity_score(v_l: u8, n_r: u32, p: f64, lambda: f64) -> f64 {
    let bc = binomial_coefficient(n_r as i32, v_l as i32).max(1) as f64;
    let s = bc.ln() + (v_l as f64) * p.ln() + ((n_r - v_l as u32) as f64) * (1.0 - p).ln()
        - lambda.ln()
        + lambda * (v_l as f64);
    s.max(MIN_ACTIVITY_SCORE)
}

// mediasoup: C++ `ComputeBigs` — downsamples a `littles` array into a
// smaller `bigs` by counting how many samples per bucket exceed
// `threshold`. Returns `true` if any bucket actually changed.
pub(super) fn compute_bigs(littles: &[u8], bigs: &mut [u8], threshold: u8) -> bool {
    let per = littles.len() / bigs.len();
    let mut changed = false;
    let mut l = 0usize;
    for slot in bigs.iter_mut() {
        let mut sum: u8 = 0;
        let end = l + per;
        while l < end {
            if littles[l] > threshold {
                sum += 1;
            }
            l += 1;
        }
        if *slot != sum {
            *slot = sum;
            changed = true;
        }
    }
    changed
}

#[cfg(test)]
mod tests {
    use super::super::N1;
    use super::*;

    #[test]
    fn binomial_and_activity_score_sanity() {
        assert_eq!(binomial_coefficient(20, 10), 184_756);
        // All-silent sample floors at MIN_ACTIVITY_SCORE.
        let s = compute_activity_score(0, N1, 0.5, 0.78);
        assert!((s - MIN_ACTIVITY_SCORE).abs() < 1e-20, "got {s}");
    }

    #[test]
    fn compute_bigs_counts_above_threshold() {
        let littles = [0u8, 8, 9, 10, 0, 0, 0, 0, 0, 0];
        let mut bigs = [0u8; 2];
        // bucket 0: {0,8,9,10,0} — three samples > 7 (8, 9, 10) → 3.
        // bucket 1: all zeros → 0.
        assert!(compute_bigs(&littles, &mut bigs, 7));
        assert_eq!(bigs, [3, 0]);
        // Running again with the same data must NOT report change.
        assert!(!compute_bigs(&littles, &mut bigs, 7));
    }
}
