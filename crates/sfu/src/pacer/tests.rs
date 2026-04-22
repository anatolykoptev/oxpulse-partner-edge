//! Unit tests for [`super::Pacer`].

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
