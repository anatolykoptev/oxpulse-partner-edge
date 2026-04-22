//! Simulcast-ladder math — pure functions with no state.
//!
//! Split from [`mod.rs`][super] because the budget → tier mapping is
//! a distinct concern from the stateful hysteresis machinery in
//! [`Pacer`][super::Pacer]. All pure: ideal for focused unit tests.

use str0m::media::Rid;

use crate::client::layer::{HIGH, LOW, MEDIUM};

/// Expected bitrate floor of the lowest simulcast layer (`q`).
pub const Q_FLOOR_BPS: u64 = 150_000;
/// Expected bitrate floor of the mid simulcast layer (`h`).
pub const H_FLOOR_BPS: u64 = 500_000;
/// Expected bitrate floor of the full simulcast layer (`f`).
pub const F_FLOOR_BPS: u64 = 1_500_000;

/// Pick the best tier available for `budget_bps`. Ladder-walks
/// `available_rids` from highest to lowest and returns the first that
/// fits. Falls back to the lowest available if none fit.
pub(super) fn tier_for_budget(budget_bps: u64, available_rids: &[Rid]) -> Rid {
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
pub(super) fn rank_of(rid: Rid) -> u8 {
    if rid == HIGH {
        2
    } else if rid == MEDIUM {
        1
    } else {
        0
    }
}
