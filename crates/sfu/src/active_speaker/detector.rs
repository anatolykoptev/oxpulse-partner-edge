//! Room-level dominant-speaker detector — owns a `Speaker` per peer and
//! runs mediasoup's hysteresis election on every tick.
//!
//! Public surface: [`ActiveSpeakerDetector::new`],
//! [`add_peer`](ActiveSpeakerDetector::add_peer),
//! [`remove_peer`](ActiveSpeakerDetector::remove_peer),
//! [`record_level`](ActiveSpeakerDetector::record_level),
//! [`tick`](ActiveSpeakerDetector::tick). Test seams (`#[cfg]`-gated)
//! let integration tests drive the state machine deterministically.
//! Unit tests live in the sibling [`tests`] submodule.

use std::collections::BTreeMap;
use std::time::Instant;

use prometheus::Histogram;

use super::speaker::Speaker;
use super::{C1, C2, C3, LEVEL_IDLE_TIMEOUT_MS, MAX_LEVEL, MIN_LEVEL, SPEAKER_IDLE_TIMEOUT_MS};

#[cfg(test)]
mod tests;

/// Per-room dominant-speaker detector.
///
/// Uses `BTreeMap` rather than `HashMap` so the bootstrap "seed" pick
/// in [`calculate_active_speaker`] is deterministic — mediasoup's C++
/// impl uses `std::map`, which is also ordered. The number of peers
/// per room is tiny (tens), so the O(log n) cost is noise.
///
/// M6.1: `last_speaker_change` tracks when the last dominant-speaker
/// change was emitted. On the next change the inter-change interval is
/// observed into `hysteresis_histogram` (if provided) as a proxy for
/// the effective hysteresis window.
#[derive(Debug, Default)]
pub struct ActiveSpeakerDetector {
    speakers: BTreeMap<u64, Speaker>,
    current_dominant: Option<u64>,
    last_level_idle_time: Option<Instant>,
    /// Wall-clock time of the most recent `ActiveSpeakerChanged` emission.
    last_speaker_change: Option<Instant>,
    /// M6.1 histogram handle — None in tests that don't care about metrics.
    hysteresis_histogram: Option<Histogram>,
}

impl ActiveSpeakerDetector {
    pub fn new() -> Self {
        Self::default()
    }

    /// Attach a Prometheus histogram to record hysteresis intervals. Must be
    /// called before the first `tick` that produces a change — safe to call
    /// at any time (idempotent; later calls replace the handle).
    pub fn set_hysteresis_histogram(&mut self, h: Histogram) {
        self.hysteresis_histogram = Some(h);
    }

    pub fn add_peer(&mut self, peer_id: u64, now: Instant) {
        self.speakers
            .entry(peer_id)
            .or_insert_with(|| Speaker::new(now));
    }

    pub fn remove_peer(&mut self, peer_id: u64) {
        self.speakers.remove(&peer_id);
        if self.current_dominant == Some(peer_id) {
            self.current_dominant = None;
        }
    }

    /// `level_raw` is 0-127 dBov per RFC 6464; mediasoup inverts to
    /// `volume = 127 - level` internally.
    pub fn record_level(&mut self, peer_id: u64, level_raw: u8, now: Instant) {
        let vol = MAX_LEVEL.saturating_sub(level_raw.min(MAX_LEVEL));
        self.speakers
            .entry(peer_id)
            .or_insert_with(|| Speaker::new(now))
            .level_changed(vol, now);
    }

    // mediasoup: C++ `TimeoutIdleLevels`.
    fn timeout_idle_levels(&mut self, now: Instant) {
        let dom = self.current_dominant;
        for (&id, sp) in self.speakers.iter_mut() {
            let idle = now.duration_since(sp.last_level_change).as_millis() as u64;
            if SPEAKER_IDLE_TIMEOUT_MS < idle && dom != Some(id) {
                sp.paused = true;
            } else if LEVEL_IDLE_TIMEOUT_MS < idle {
                sp.level_changed(MIN_LEVEL, now);
            }
        }
    }

    /// Advance the detector. Returns `Some(peer_id)` only on change.
    pub fn tick(&mut self, now: Instant) -> Option<u64> {
        match self.last_level_idle_time {
            Some(t) if now.duration_since(t).as_millis() as u64 >= LEVEL_IDLE_TIMEOUT_MS => {
                self.timeout_idle_levels(now);
                self.last_level_idle_time = Some(now);
            }
            None => self.last_level_idle_time = Some(now),
            _ => {}
        }
        if self.speakers.is_empty() {
            return None;
        }
        self.calculate_active_speaker()
    }

    /// Port of mediasoup's `CalculateActiveSpeaker`. Hysteresis:
    /// challenger must beat incumbent on all three log-ratios AND have
    /// the highest medium ratio in the room.
    fn calculate_active_speaker(&mut self) -> Option<u64> {
        let new_id = if self.speakers.len() == 1 {
            self.speakers.keys().next().copied()
        } else {
            let incumbent = self.current_dominant;
            // Bootstrap: arbitrary seed when no incumbent — any real
            // activity will overwrite via the ratio test below.
            let seed = incumbent.or_else(|| self.speakers.keys().next().copied())?;
            if let Some(s) = self.speakers.get_mut(&seed) {
                s.eval_scores();
            }
            let dom = {
                let s = self.speakers.get(&seed)?;
                [s.score(0), s.score(1), s.score(2)]
            };
            let mut best_c2 = C2;
            let mut winner: Option<u64> = if incumbent.is_none() {
                Some(seed)
            } else {
                None
            };
            let ids: Vec<u64> = self.speakers.keys().copied().collect();
            for id in ids {
                if Some(id) == incumbent {
                    continue;
                }
                let Some(sp) = self.speakers.get_mut(&id) else {
                    continue;
                };
                if sp.paused {
                    continue;
                }
                sp.eval_scores();
                let c1 = (sp.score(0) / dom[0]).ln();
                let c2 = (sp.score(1) / dom[1]).ln();
                let c3 = (sp.score(2) / dom[2]).ln();
                if c1 > C1 && c2 > C2 && c3 > C3 && c2 > best_c2 {
                    best_c2 = c2;
                    winner = Some(id);
                }
            }
            winner
        };
        match (new_id, self.current_dominant) {
            (Some(n), Some(c)) if n == c => None,
            (Some(n), _) => {
                self.current_dominant = Some(n);
                Some(n)
            }
            _ => None,
        }
    }

    /// Record the hysteresis histogram observation for a speaker change at `now`.
    /// Called by [`Registry::tick_active_speaker`] immediately after `tick`
    /// returns `Some(peer_id)`, so the interval is between consecutive changes.
    pub(crate) fn record_hysteresis_observation(&mut self, now: Instant) {
        if let Some(prev) = self.last_speaker_change {
            let ms = now.duration_since(prev).as_secs_f64() * 1_000.0;
            if let Some(ref h) = self.hysteresis_histogram {
                h.observe(ms);
            }
        }
        self.last_speaker_change = Some(now);
    }

    /// Read-only access to the current dominant peer, if any. Useful
    /// for tests and observability.
    pub fn current_dominant(&self) -> Option<u64> {
        self.current_dominant
    }
}

#[cfg(any(test, feature = "test-utils"))]
impl ActiveSpeakerDetector {
    #[doc(hidden)]
    pub fn inject_level_for_tests(&mut self, peer_id: u64, level_raw: u8, now: Instant) {
        self.record_level(peer_id, level_raw, now);
    }
    #[doc(hidden)]
    pub fn force_tick_for_tests(&mut self, now: Instant) -> Option<u64> {
        self.tick(now)
    }
}
