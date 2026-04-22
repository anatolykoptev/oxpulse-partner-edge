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
//! bitrate floors and the budget→tier mapping live in [`ladder`];
//! this module owns only the stateful hysteresis machine.
//!
//! Below [`AUDIO_ONLY_THRESHOLD_BPS`] the pacer signals *audio-only*
//! via [`Pacer::should_forward_audio_only`] (Dynacast).

mod ladder;

use std::collections::HashMap;

use str0m::media::Rid;

use crate::propagate::ClientId;

pub use ladder::{F_FLOOR_BPS, H_FLOOR_BPS, Q_FLOOR_BPS};

/// Bitrate floor below which a link is too poor to carry any video —
/// forwarder drops video frames and keeps audio flowing.
pub const AUDIO_ONLY_THRESHOLD_BPS: u64 = 100_000;

/// Consecutive at-or-above-floor observations required before the
/// pacer will upgrade to a higher tier. Downgrades are immediate.
pub const UPGRADE_CONSECUTIVE: u32 = 3;

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

        let target = ladder::tier_for_budget(budget_bps, available_rids);
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

        let cur_rank = ladder::rank_of(current);
        let tgt_rank = ladder::rank_of(target);

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

#[cfg(test)]
mod tests;
