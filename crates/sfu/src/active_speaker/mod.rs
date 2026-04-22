//! Dominant speaker detection — port of mediasoup's C++
//! `ActiveSpeakerObserver` (itself Jitsi `DominantSpeakerIdentification`,
//! Volfin & Cohen 2012). Sources: `worker/{src,include}/RTC/
//! ActiveSpeakerObserver.{cpp,hpp}` in versatica/mediasoup. Wire
//! audio-level extraction lives in the registry; this module is pure
//! algorithm. Per-peer single-audio-track assumption (same as M1.3);
//! multi-device merge is deferred.
//!
//! Split into concern-aligned files per CLAUDE.md:
//! * [`numerics`] — pure math helpers (`binomial_coefficient`,
//!   `compute_activity_score`, `compute_bigs`).
//! * [`speaker`] — per-peer `Speaker` state and score evaluation.
//! * [`detector`] — room-level `ActiveSpeakerDetector` (public API).

use std::time::Duration;

mod detector;
mod numerics;
mod speaker;

pub use detector::ActiveSpeakerDetector;

// Constants — ported verbatim. mediasoup names in trailing comments.
// `pub(super)` so both `speaker.rs` and `detector.rs` (siblings) can
// reach them via `use super::*`.
pub(super) const C1: f64 = 3.0; // mediasoup: C1
pub(super) const C2: f64 = 2.0; // mediasoup: C2
pub(super) const C3: f64 = 0.0; // mediasoup: C3 (production-tuned to zero)
pub(super) const N1: u32 = 13; // mediasoup: N1
pub(super) const N2: u32 = 5; // mediasoup: N2
pub(super) const N3: u32 = 10; // mediasoup: N3
pub(super) const LEVEL_IDLE_TIMEOUT_MS: u64 = 40; // mediasoup: LevelIdleTimeout
pub(super) const SPEAKER_IDLE_TIMEOUT_MS: u64 = 60 * 60 * 1000; // mediasoup: SpeakerIdleTimeout
pub(super) const LONG_THRESHOLD: u8 = 4; // mediasoup: LongThreashold
pub(super) const MAX_LEVEL: u8 = 127; // mediasoup: MaxLevel
pub(super) const MIN_LEVEL: u8 = 0; // mediasoup: MinLevel
pub(super) const MIN_LEVEL_WINDOW_LEN: u32 = 750; // mediasoup: MinLevelWindowLen = 15*1000/20
pub(super) const MEDIUM_THRESHOLD: u8 = 7; // mediasoup: MediumThreshold
pub(super) const SUBUNIT_LENGTH_N1: u8 = 10; // mediasoup: SubunitLengthN1 = (127-0+13-1)/13
pub(super) const IMMEDIATE_BUFF_LEN: usize = 50; // mediasoup: ImmediateBuffLen = 1*10*5
pub(super) const MEDIUMS_BUFF_LEN: usize = 10; // mediasoup: MediumsBuffLen = 1*10
pub(super) const LONGS_BUFF_LEN: usize = 1; // mediasoup: LongsBuffLen = 1
pub(super) const LEVELS_BUFF_LEN: usize = 50; // mediasoup: LevelsBuffLen = 1*10*5
pub(super) const MIN_ACTIVITY_SCORE: f64 = 1.0e-10; // mediasoup: MinActivityScore

/// Timer cadence mediasoup uses in production.
pub const TICK_INTERVAL: Duration = Duration::from_millis(300);
