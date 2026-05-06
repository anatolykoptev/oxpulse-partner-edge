//! Incident 2026-05-06 (motherly1 group-call outage post-mortem):
//! `active_rooms` was `set(1)` at registry init and never updated, masking
//! mis-deployed feature gates because alerts on the gauge could never reach
//! 0 even when the SFU had no clients. This test pins the new semantics for
//! a single-room SFU:
//!
//!   `active_rooms = 1` ⇔ at least one client is registered, else `0`.
//!
//! Wired in `Registry::insert` (set 1) and the eviction paths
//! (`reap_dead` / `evict_for_steal`) which set 0 when `clients` becomes
//! empty. Mirrors the cardinality-scrub pattern in `bwe_metrics_integration.rs`.

use std::sync::Arc;

use oxpulse_sfu::client::test_seed::new_client;
use oxpulse_sfu::metrics::SfuMetrics;
use oxpulse_sfu::{ClientId, Registry};

#[test]
fn active_rooms_tracks_registry_population() {
    let metrics = Arc::new(SfuMetrics::new().expect("metrics build"));
    let mut registry = Registry::new(metrics.clone());

    // Empty registry — gauge must be 0.
    assert_eq!(
        metrics.active_rooms.get(),
        0,
        "fresh registry has no clients → active_rooms must be 0"
    );

    // First insert — single-room SFU now has an active room.
    let a = new_client(ClientId(900));
    registry.insert(a);
    assert_eq!(
        metrics.active_rooms.get(),
        1,
        "after first insert active_rooms must flip to 1"
    );

    // Second insert — still one room (single-room SFU).
    let b = new_client(ClientId(901));
    registry.insert(b);
    assert_eq!(
        metrics.active_rooms.get(),
        1,
        "second insert: still a single room, gauge stays at 1"
    );

    // Drop one client — room still populated.
    registry.disconnect_client_for_tests(ClientId(900));
    registry.reap_dead_for_tests();
    assert_eq!(
        metrics.active_rooms.get(),
        1,
        "one client remaining → active_rooms must stay 1"
    );

    // Drop the last client — room empties.
    registry.disconnect_client_for_tests(ClientId(901));
    registry.reap_dead_for_tests();
    assert_eq!(
        metrics.active_rooms.get(),
        0,
        "registry now empty → active_rooms must drop to 0"
    );
}
