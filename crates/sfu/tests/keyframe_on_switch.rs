//! G4 integration test: a pacer-driven simulcast layer switch routes a
//! keyframe request to the publisher on the TARGET RID.
//!
//! Falsification: this test drives the REAL production path
//! `Registry::update_pacer_layers` → `Client::pacer_select_layer` →
//! `Client::emit_keyframe_on_layer_switch` → `Propagated::KeyframeRequest`
//! → `Registry::fanout_pending` → `fanout` → publisher's
//! `Client::handle_keyframe_request`. Revert the G4 wiring call in
//! `registry/bwe.rs` (the `if chosen != Some(prev_layer)` block) and the
//! assertion on `Some(layer::HIGH)` fails — the publisher's
//! `keyframe_requests_received` stays empty because no
//! `Propagated::KeyframeRequest` was ever emitted on the switch.
//!
//! The companion unit tests in `client/keyframe.rs` cover the helper's
//! per-target-RID throttle, audio-skip, and no-publisher edges in
//! isolation; this test proves the helper is actually WIRED into the
//! pacer select path end-to-end.

use oxpulse_sfu::client::layer;
use oxpulse_sfu::client::test_seed::{new_client, seed_track_in};
use oxpulse_sfu::{ClientId, Registry};
use str0m::media::MediaKind;

/// A pacer-driven layer switch (LOW → HIGH) emits exactly one keyframe
/// request on the TARGET RID (HIGH) routed to the publisher, and a
/// second batch of pacer refreshes with no further layer change emits
/// NOTHING (proves the request fires only on an ACTUAL change, not on
/// every pacer tick — no keyframe-request storm).
#[test]
fn pacer_layer_switch_routes_keyframe_request_on_target_rid() {
    let mut registry = Registry::new_for_tests();

    // Publisher A publishes a video track; subscriber B is subscribed
    // via insert()'s cross-advertisement.
    let mut a = new_client(ClientId(500));
    let _arc = seed_track_in(&mut a, 1, MediaKind::Video);
    registry.insert(a);
    let b = new_client(ClientId(501));
    registry.insert(b);

    // B starts at the default LOW.
    assert_eq!(
        registry.clients()[1].desired_layer(),
        layer::LOW,
        "B starts at LOW",
    );

    // Drive B's BWE + GoogCC high enough that the pacer upgrades all the
    // way LOW → MEDIUM → HIGH. Mirrors the multi_client m53 test's setup:
    // drive_subscriber_bandwidth_for_tests seeds the Kalman/loss
    // estimators high, drive_googcc_for_tests pins the registry-wide
    // GoogCC ceiling above F_LAYER_BPS so the conservative merge allows
    // the pacer's choice through.
    registry.drive_subscriber_bandwidth_for_tests(ClientId(501), 2_000_000);
    registry.drive_googcc_for_tests(2_000_000);

    // Hysteresis: 3 consecutive observations per upgrade tier. Run 6
    // refreshes to land both promotions (LOW→MEDIUM→HIGH). Each refresh
    // calls update_pacer_layers which (on an actual switch) pushes a
    // Propagated::KeyframeRequest into to_propagate.
    for _ in 0..6 {
        registry.force_pacer_refresh_for_tests(ClientId(500));
    }

    // B must have reached HIGH.
    assert_eq!(
        registry.clients()[1].desired_layer(),
        layer::HIGH,
        "B pacer-upgraded to HIGH",
    );

    // Drain the queued keyframe requests through fanout_pending — this
    // routes each Propagated::KeyframeRequest to the publisher (A) via
    // fanout(), landing in A.handle_keyframe_request which records the
    // target RID in keyframe_requests_received (test-only capture).
    registry.fanout_pending();

    let received = registry.clients()[0].keyframe_requests_received_for_tests();
    // The final layer switch (→HIGH) must have routed a keyframe request
    // with target RID = HIGH to the publisher. Revert the G4 wiring and
    // this assertion fails (received is empty).
    assert!(
        received.contains(&Some(layer::HIGH)),
        "pacer switch to HIGH routed a keyframe request on HIGH to the \
         publisher; got {:?}",
        received,
    );

    let count_after_switch = received.len();

    // Second batch: 6 more refreshes with B already at HIGH (NoChange).
    // The pacer returns NoChange → chosen == Some(prev_layer) → the G4
    // wiring does NOT emit. Proves the request fires only on an ACTUAL
    // layer change, not on every pacer tick — no storm under a steady
    // high-BWE pacer.
    for _ in 0..6 {
        registry.force_pacer_refresh_for_tests(ClientId(500));
    }
    registry.fanout_pending();

    let received_after_steady = registry.clients()[0].keyframe_requests_received_for_tests();
    assert_eq!(
        received_after_steady.len(),
        count_after_switch,
        "no further keyframe requests when the layer doesn't change \
         (not on every pacer tick); before={}, after={}",
        count_after_switch,
        received_after_steady.len(),
    );
}
