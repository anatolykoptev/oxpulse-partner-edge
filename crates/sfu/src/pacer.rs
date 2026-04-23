//! Per-subscriber rate shaping and simulcast-tier chooser (M5.3).
//!
//! Given a bandwidth budget (from [`crate::BandwidthEstimator`]) and
//! the set of simulcast RIDs the publisher is offering, pick the
//! highest tier that fits. Asymmetric hysteresis (LiveKit Dynacast
//! pattern):
//!
//! * **Upgrade** — require `UPGRADE_CONSECUTIVE` consecutive observations
//!   at or above the target tier's floor before switching up.
//! * **Downgrade** — any single observation below the current tier's
//!   floor switches down immediately.
//!
//! The asymmetry matters: under real network wobble we'd rather drop a
//! frame of quality than thrash between layers (keyframe reseeks are
//! visually costly).
//!
//! Simulcast layers use LiveKit / mediasoup / Jitsi's RID convention
//! (`q` / `h` / `f`) — see [`crate::client::layer`]. Per-layer
//! bitrate floors and the budget→tier mapping are inlined in this file;
//! this module owns the stateful hysteresis machine.
//!
//! Below [`AUDIO_ONLY_THRESHOLD_BPS`] the pacer signals *audio-only*
//! via [`Pacer::should_forward_audio_only`] (Dynacast).
//!
//! Previously split across `pacer/mod.rs`, `pacer/ladder.rs`, and
//! `pacer/tests.rs`; merged into a single file in Task 11 to remove
//! the directory structure without changing behaviour. Constants are
//! intentionally kept at partner-edge values (not aligned to kit's
//! different thresholds) to avoid a silent behaviour change.

use std::collections::HashMap;

use str0m::media::Rid;

use crate::client::layer::{HIGH, LOW, MEDIUM};
use crate::propagate::ClientId;

// ── ladder constants ──────────────────────────────────────────────────────────

/// Expected bitrate floor of the lowest simulcast layer (`q`).
pub const Q_FLOOR_BPS: u64 = 150_000;
/// Expected bitrate floor of the mid simulcast layer (`h`).
pub const H_FLOOR_BPS: u64 = 500_000;
/// Expected bitrate floor of the full simulcast layer (`f`).
pub const F_FLOOR_BPS: u64 = 1_500_000;

/// Bitrate floor below which a link is too poor to carry any video —
/// forwarder drops video frames and keeps audio flowing.
pub const AUDIO_ONLY_THRESHOLD_BPS: u64 = 100_000;

/// Consecutive at-or-above-floor observations required before the
/// pacer will upgrade to a higher tier. Downgrades are immediate.
pub const UPGRADE_CONSECUTIVE: u32 = 3;

// ── ladder (pure functions) ───────────────────────────────────────────────────

/// Pick the best tier available for `budget_bps`. Ladder-walks
/// `available_rids` from highest to lowest and returns the first that
/// fits. Falls back to the lowest available if none fit.
fn tier_for_budget(budget_bps: u64, available_rids: &[Rid]) -> Rid {
    for &(rid, floor) in &[
        (HIGH, F_FLOOR_BPS),
        (MEDIUM, H_FLOOR_BPS),
        (LOW, Q_FLOOR_BPS),
    ] {
        if budget_bps >= floor && available_rids.contains(&rid) {
            return rid;
        }
    }
    lowest_available(available_rids)
}

/// Return the lowest-rank available RID. Falls back to the first
/// element if none match the `q/h/f` ladder (defensive path keeps
/// callers panic-free).
fn lowest_available(available_rids: &[Rid]) -> Rid {
    for &rid in &[LOW, MEDIUM, HIGH] {
        if available_rids.contains(&rid) {
            return rid;
        }
    }
    available_rids[0]
}

/// 0 = lowest (`q`), 1 = mid (`h`), 2 = high (`f`). Anything
/// unrecognised ranks as 0 (defensive) so a stray RID never upgrades
/// past `q`.
fn rank_of(rid: Rid) -> u8 {
    if rid == HIGH {
        2
    } else if rid == MEDIUM {
        1
    } else {
        0
    }
}

// ── Pacer ────────────────────────────────────────────────────────────────────

#[derive(Debug, Default)]
struct PerSubscriber {
    /// Last RID the pacer chose for this subscriber. `None` until
    /// [`Pacer::preferred_rid`] has been called at least once.
    current: Option<Rid>,
    /// Consecutive observations eligible for upgrading to a *higher*
    /// tier than `current`. Reset to 0 on any downgrade, or when the
    /// observation does not meet the next tier's floor.
    consecutive_up: u32,
    /// Cached "candidate higher tier" — `consecutive_up` is counted
    /// against this. Reset when it changes.
    candidate_up: Option<Rid>,
}

/// Per-subscriber rate shaper. One instance lives on [`crate::Registry`].
#[derive(Debug, Default)]
pub struct Pacer {
    subs: HashMap<ClientId, PerSubscriber>,
}

impl Pacer {
    pub fn new() -> Self {
        Self::default()
    }

    /// Pick the highest simulcast RID whose floor fits `budget_bps`.
    /// If `budget_bps` is below the lowest available layer's floor
    /// we still return that lowest layer (forwarding one layer is
    /// always better than none, up to the audio-only cutoff).
    ///
    /// `available_rids` should contain only layers the publisher is
    /// actively producing. Returns `None` iff `available_rids` is
    /// empty (nothing to choose).
    pub fn preferred_rid(
        &mut self,
        subscriber: ClientId,
        budget_bps: u64,
        available_rids: &[Rid],
    ) -> Option<Rid> {
        if available_rids.is_empty() {
            return None;
        }

        let target = tier_for_budget(budget_bps, available_rids);
        let state = self.subs.entry(subscriber).or_default();

        let current = match state.current {
            Some(c) => c,
            None => {
                state.current = Some(target);
                state.consecutive_up = 0;
                state.candidate_up = None;
                return Some(target);
            }
        };

        let cur_rank = rank_of(current);
        let tgt_rank = rank_of(target);

        if tgt_rank < cur_rank {
            // Downgrade immediately — no hysteresis.
            state.current = Some(target);
            state.consecutive_up = 0;
            state.candidate_up = None;
            return Some(target);
        }

        if tgt_rank == cur_rank {
            // Hold — clear upgrade candidate.
            state.consecutive_up = 0;
            state.candidate_up = None;
            return Some(current);
        }

        // tgt_rank > cur_rank → candidate upgrade.
        if state.candidate_up == Some(target) {
            state.consecutive_up = state.consecutive_up.saturating_add(1);
        } else {
            state.candidate_up = Some(target);
            state.consecutive_up = 1;
        }

        if state.consecutive_up >= UPGRADE_CONSECUTIVE {
            state.current = Some(target);
            state.consecutive_up = 0;
            state.candidate_up = None;
            Some(target)
        } else {
            Some(current)
        }
    }

    /// True when the subscriber's budget is below the audio-only
    /// threshold. Callers drop video forwarding entirely for that
    /// subscriber and keep Opus audio flowing.
    pub fn should_forward_audio_only(&self, budget_bps: u64) -> bool {
        budget_bps < AUDIO_ONLY_THRESHOLD_BPS
    }

    /// Drop subscriber state on disconnect.
    pub fn remove(&mut self, subscriber: &ClientId) {
        self.subs.remove(subscriber);
    }

    /// Number of tracked subscribers.
    pub fn len(&self) -> usize {
        self.subs.len()
    }

    /// Convenience — true when no subscribers have been seen.
    pub fn is_empty(&self) -> bool {
        self.subs.is_empty()
    }

    /// Test helper: read the currently-held tier without mutating state.
    #[cfg(any(test, feature = "test-utils"))]
    pub fn current_rid(&self, subscriber: &ClientId) -> Option<Rid> {
        self.subs.get(subscriber).and_then(|s| s.current)
    }
}

// ── unit tests ───────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::{Pacer, AUDIO_ONLY_THRESHOLD_BPS};
    use crate::client::layer::{HIGH, LOW, MEDIUM};
    use crate::propagate::ClientId;

    fn client(n: u64) -> ClientId {
        ClientId(n)
    }

    #[test]
    fn low_budget_picks_q() {
        let mut pacer = Pacer::new();
        let rids = [LOW, MEDIUM, HIGH];
        let chosen = pacer.preferred_rid(client(1), 120_000, &rids);
        assert_eq!(chosen, Some(LOW));
    }

    #[test]
    fn mid_budget_picks_h() {
        let mut pacer = Pacer::new();
        let rids = [LOW, MEDIUM, HIGH];
        let chosen = pacer.preferred_rid(client(1), 600_000, &rids);
        assert_eq!(chosen, Some(MEDIUM));
    }

    #[test]
    fn high_budget_picks_f() {
        let mut pacer = Pacer::new();
        let rids = [LOW, MEDIUM, HIGH];
        let chosen = pacer.preferred_rid(client(1), 2_000_000, &rids);
        assert_eq!(chosen, Some(HIGH));
    }

    #[test]
    fn below_q_floor_still_returns_q_for_video_path() {
        // Below Q_FLOOR but above audio-only — caller is expected to fall
        // back to audio-only independently; `preferred_rid` returns the
        // lowest video layer.
        let mut pacer = Pacer::new();
        let rids = [LOW, MEDIUM, HIGH];
        let chosen = pacer.preferred_rid(client(1), 80_000, &rids);
        assert_eq!(chosen, Some(LOW));
    }

    #[test]
    fn should_forward_audio_only_below_threshold() {
        let pacer = Pacer::new();
        assert!(pacer.should_forward_audio_only(50_000));
        assert!(!pacer.should_forward_audio_only(AUDIO_ONLY_THRESHOLD_BPS));
        assert!(!pacer.should_forward_audio_only(200_000));
    }

    #[test]
    fn upgrade_requires_three_consecutive_then_promotes() {
        let mut pacer = Pacer::new();
        let rids = [LOW, MEDIUM, HIGH];

        // Start at LOW under tight budget.
        assert_eq!(pacer.preferred_rid(client(1), 120_000, &rids), Some(LOW));

        // Budget lifts to MEDIUM tier: first two obs still return LOW.
        assert_eq!(pacer.preferred_rid(client(1), 600_000, &rids), Some(LOW));
        assert_eq!(pacer.preferred_rid(client(1), 600_000, &rids), Some(LOW));
        // Third consecutive → promotes to MEDIUM.
        assert_eq!(pacer.preferred_rid(client(1), 600_000, &rids), Some(MEDIUM));
    }

    #[test]
    fn downgrade_is_immediate_no_hysteresis() {
        let mut pacer = Pacer::new();
        let rids = [LOW, MEDIUM, HIGH];

        // Start HIGH.
        assert_eq!(pacer.preferred_rid(client(1), 2_000_000, &rids), Some(HIGH));
        // Single low budget → snap to LOW.
        assert_eq!(pacer.preferred_rid(client(1), 120_000, &rids), Some(LOW));
    }

    #[test]
    fn interrupted_upgrade_resets_counter() {
        let mut pacer = Pacer::new();
        let rids = [LOW, MEDIUM, HIGH];

        // Seed at LOW.
        assert_eq!(pacer.preferred_rid(client(1), 120_000, &rids), Some(LOW));

        // Two at-MEDIUM obs, then one back at LOW — resets.
        pacer.preferred_rid(client(1), 600_000, &rids);
        pacer.preferred_rid(client(1), 600_000, &rids);
        assert_eq!(pacer.preferred_rid(client(1), 120_000, &rids), Some(LOW));
        // Now two MEDIUM — still at LOW.
        assert_eq!(pacer.preferred_rid(client(1), 600_000, &rids), Some(LOW));
        assert_eq!(pacer.preferred_rid(client(1), 600_000, &rids), Some(LOW));
    }

    #[test]
    fn empty_available_rids_returns_none() {
        let mut pacer = Pacer::new();
        assert_eq!(pacer.preferred_rid(client(1), 1_000_000, &[]), None);
    }

    #[test]
    fn remove_subscriber_drops_state() {
        let mut pacer = Pacer::new();
        let rids = [LOW, MEDIUM, HIGH];
        pacer.preferred_rid(client(1), 120_000, &rids);
        assert_eq!(pacer.len(), 1);
        pacer.remove(&client(1));
        assert_eq!(pacer.len(), 0);
    }
}
