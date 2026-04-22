//! Per-peer speaker state — mirrors mediasoup's C++ `Speaker` struct.
//!
//! Four rolling buffers at different time granularities (`immediates`
//! at 20ms, `mediums` at 200ms, `longs` at 2s, `levels` as raw inputs)
//! get re-evaluated on every tick. The three resulting scores feed the
//! room-level log-ratio hysteresis test in
//! [`super::detector::ActiveSpeakerDetector::calculate_active_speaker`].

use std::time::Instant;

use super::numerics::{compute_activity_score, compute_bigs};
use super::{
    IMMEDIATE_BUFF_LEN, LEVELS_BUFF_LEN, LONGS_BUFF_LEN, LONG_THRESHOLD, MAX_LEVEL,
    MEDIUMS_BUFF_LEN, MEDIUM_THRESHOLD, MIN_ACTIVITY_SCORE, MIN_LEVEL, MIN_LEVEL_WINDOW_LEN, N1,
    N2, N3, SUBUNIT_LENGTH_N1,
};

#[derive(Debug)]
pub(super) struct Speaker {
    pub(super) paused: bool,
    pub(super) immediate_score: f64,
    pub(super) medium_score: f64,
    pub(super) long_score: f64,
    pub(super) last_level_change: Instant,
    min_level: u8,
    next_min_level: u8,
    next_min_level_window_len: u32,
    immediates: [u8; IMMEDIATE_BUFF_LEN],
    mediums: [u8; MEDIUMS_BUFF_LEN],
    longs: [u8; LONGS_BUFF_LEN],
    levels: [u8; LEVELS_BUFF_LEN],
    next_level_index: usize,
}

impl Speaker {
    pub(super) fn new(now: Instant) -> Self {
        Self {
            paused: false,
            immediate_score: MIN_ACTIVITY_SCORE,
            medium_score: MIN_ACTIVITY_SCORE,
            long_score: MIN_ACTIVITY_SCORE,
            last_level_change: now,
            min_level: MIN_LEVEL,
            next_min_level: MIN_LEVEL,
            next_min_level_window_len: 0,
            immediates: [0; IMMEDIATE_BUFF_LEN],
            mediums: [0; MEDIUMS_BUFF_LEN],
            longs: [0; LONGS_BUFF_LEN],
            levels: [0; LEVELS_BUFF_LEN],
            next_level_index: 0,
        }
    }

    pub(super) fn score(&self, interval: u8) -> f64 {
        match interval {
            0 => self.immediate_score,
            1 => self.medium_score,
            _ => self.long_score,
        }
    }

    // mediasoup: C++ `LevelChanged`.
    pub(super) fn level_changed(&mut self, level: u8, now: Instant) {
        if now < self.last_level_change {
            return;
        }
        let elapsed_ms = now.duration_since(self.last_level_change).as_millis() as u64;
        self.last_level_change = now;
        let b = level.min(MAX_LEVEL);
        // 20ms cadence expected; replay sample on longer gaps, cap at buf len.
        let n = ((elapsed_ms / 20).max(1) as usize).min(LEVELS_BUFF_LEN);
        for _ in 0..n {
            self.levels[self.next_level_index] = b;
            self.next_level_index = (self.next_level_index + 1) % LEVELS_BUFF_LEN;
        }
        self.update_min_level(b);
    }

    // mediasoup: C++ `UpdateMinLevel`.
    fn update_min_level(&mut self, level: u8) {
        if level == MIN_LEVEL {
            return;
        }
        if self.min_level == MIN_LEVEL || self.min_level > level {
            self.min_level = level;
            self.next_min_level = MIN_LEVEL;
            self.next_min_level_window_len = 0;
        } else if self.next_min_level == MIN_LEVEL {
            self.next_min_level = level;
            self.next_min_level_window_len = 1;
        } else {
            self.next_min_level = self.next_min_level.min(level);
            self.next_min_level_window_len += 1;
            if self.next_min_level_window_len >= MIN_LEVEL_WINDOW_LEN {
                let m = (self.min_level as f64 * self.next_min_level as f64)
                    .sqrt()
                    .clamp(MIN_LEVEL as f64, MAX_LEVEL as f64);
                self.min_level = m as u8;
                self.next_min_level = MIN_LEVEL;
                self.next_min_level_window_len = 0;
            }
        }
    }

    // mediasoup: C++ `ComputeImmediates`.
    fn compute_immediates(&mut self) -> bool {
        let thresh = self.min_level.saturating_add(SUBUNIT_LENGTH_N1);
        let mut changed = false;
        for i in 0..IMMEDIATE_BUFF_LEN {
            let idx = if self.next_level_index > i {
                self.next_level_index - i - 1
            } else {
                self.next_level_index + LEVELS_BUFF_LEN - i - 1
            };
            let mut lvl = self.levels[idx];
            if lvl < thresh {
                lvl = MIN_LEVEL;
            }
            let imm = lvl / SUBUNIT_LENGTH_N1;
            if self.immediates[i] != imm {
                self.immediates[i] = imm;
                changed = true;
            }
        }
        changed
    }

    // mediasoup: C++ `EvalActivityScores`.
    pub(super) fn eval_scores(&mut self) {
        if !self.compute_immediates() {
            return;
        }
        self.immediate_score = compute_activity_score(self.immediates[0], N1, 0.5, 0.78);
        let imm = self.immediates;
        if !compute_bigs(&imm, &mut self.mediums, MEDIUM_THRESHOLD) {
            return;
        }
        self.medium_score = compute_activity_score(self.mediums[0], N2, 0.5, 24.0);
        let med = self.mediums;
        if !compute_bigs(&med, &mut self.longs, LONG_THRESHOLD) {
            return;
        }
        self.long_score = compute_activity_score(self.longs[0], N3, 0.5, 47.0);
    }
}
