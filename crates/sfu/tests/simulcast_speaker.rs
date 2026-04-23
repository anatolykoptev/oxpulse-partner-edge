//! M1.3 simulcast layer filter + M1.4 dominant-speaker integration tests.
//!
//! Simulcast: A publishes q/h/f layers; B and C subscribe at different
//! tiers. Asserts that the per-subscriber layer filter in
//! `client::fanout::handle_media_data_out` passes only the desired RID.
//!
//! Dominant speaker: verifies Registry→detector→fanout wiring including
//! hysteresis and skip-self. Algorithm unit tests live in
//! `active_speaker::detector::tests`.

use std::time::{Duration, Instant};

use oxpulse_sfu::client::layer;
use oxpulse_sfu::client::test_seed::{make_media_data, new_client, seed_track_in};
use oxpulse_sfu::{ClientId, Propagated, Registry};
use str0m::media::MediaKind;

#[test]
fn simulcast_rid_filter_drops_mismatched_layers() {
    let mut registry = Registry::new_for_tests();

    let mut a = new_client(ClientId(30));
    let _arc = seed_track_in(&mut a, 1, MediaKind::Video);
    registry.insert(a);

    let b = new_client(ClientId(31));
    registry.insert(b);
    let c = new_client(ClientId(32));
    registry.insert(c);

    // Both B and C start at LOW (default).
    assert_eq!(
        registry.clients()[1].desired_layer(),
        layer::LOW,
        "B default LOW"
    );
    assert_eq!(
        registry.clients()[2].desired_layer(),
        layer::LOW,
        "C default LOW"
    );

    // RID=q — both match at LOW.
    let prop_q = Propagated::MediaData(ClientId(30), make_media_data(1, Some(layer::LOW)));
    registry.fanout_for_tests(&prop_q);
    assert_eq!(registry.delivered_media_count(1), 1, "B got q");
    assert_eq!(registry.delivered_media_count(2), 1, "C got q");

    // RID=f — neither matches.
    let prop_f = Propagated::MediaData(ClientId(30), make_media_data(1, Some(layer::HIGH)));
    registry.fanout_for_tests(&prop_f);
    assert_eq!(registry.delivered_media_count(1), 1, "B filters out f");
    assert_eq!(registry.delivered_media_count(2), 1, "C filters out f");

    // Flip C to HIGH.
    registry.set_desired_layer_for_tests(2, layer::HIGH);
    assert_eq!(
        registry.clients()[2].desired_layer(),
        layer::HIGH,
        "C now HIGH"
    );

    // RID=f — C matches, B doesn't.
    let prop_f = Propagated::MediaData(ClientId(30), make_media_data(1, Some(layer::HIGH)));
    registry.fanout_for_tests(&prop_f);
    assert_eq!(registry.delivered_media_count(1), 1, "B still filters f");
    assert_eq!(registry.delivered_media_count(2), 2, "C got f");

    // RID=q — B matches (LOW), C doesn't (HIGH).
    let prop_q = Propagated::MediaData(ClientId(30), make_media_data(1, Some(layer::LOW)));
    registry.fanout_for_tests(&prop_q);
    assert_eq!(registry.delivered_media_count(1), 2, "B got second q");
    assert_eq!(
        registry.delivered_media_count(2),
        2,
        "C filters q while HIGH"
    );

    // rid=None bypasses the filter — both receive regardless of preference.
    let prop_none = Propagated::MediaData(ClientId(30), make_media_data(1, None));
    registry.fanout_for_tests(&prop_none);
    assert_eq!(registry.delivered_media_count(1), 3, "B got non-simulcast");
    assert_eq!(registry.delivered_media_count(2), 3, "C got non-simulcast");
}

#[test]
fn active_speaker_dominance_and_hysteresis_and_skip_self() {
    let mut registry = Registry::new_for_tests();
    let mut a = new_client(ClientId(1));
    a.id = ClientId(1);
    let mut b = new_client(ClientId(2));
    b.id = ClientId(2);
    let mut c = new_client(ClientId(3));
    c.id = ClientId(3);
    registry.insert(a);
    registry.insert(b);
    registry.insert(c);

    // Bootstrap: first tick elects some peer (v0.3 uses HashMap + score-based
    // bootstrap; order is non-deterministic when all scores are equal).
    let t0 = Instant::now();
    registry.force_active_speaker_tick_for_tests(t0);
    let bootstrap_winner = registry
        .current_active_speaker()
        .expect("bootstrap → some peer elected");
    assert!(
        [1u64, 2, 3].contains(&bootstrap_winner),
        "bootstrap winner is one of the inserted peers"
    );

    // Skip-self: the elected speaker should not receive their own notification.
    // Map peer_id to registry index (insertion order: A=0, B=1, C=2).
    let winner_idx = (bootstrap_winner - 1) as usize;
    assert_eq!(
        registry.delivered_active_speaker_count(winner_idx),
        0,
        "elected speaker skip-self"
    );
    // Every non-winner client must have been notified.
    for idx in 0..3usize {
        if idx != winner_idx {
            assert!(
                registry.delivered_active_speaker_count(idx) >= 1,
                "non-winner idx={idx} notified"
            );
        }
    }

    // Hysteresis: 3 more ticks without audio → incumbent persists.
    for step in 1..=3 {
        registry.force_active_speaker_tick_for_tests(t0 + Duration::from_millis(300 * step));
    }
    assert_eq!(
        registry.current_active_speaker(),
        Some(bootstrap_winner),
        "incumbent holds"
    );

    // Skip-self on flip to peer 2: B must not receive its own dominance event.
    let [a0, b0, c0] = [
        registry.delivered_active_speaker_count(0),
        registry.delivered_active_speaker_count(1),
        registry.delivered_active_speaker_count(2),
    ];
    registry.fanout_for_tests(&Propagated::ActiveSpeakerChanged {
        peer_id: 2,
        confidence: 0.0,
    });
    assert_eq!(
        registry.delivered_active_speaker_count(1),
        b0,
        "B skip-self on flip"
    );
    assert_eq!(
        registry.delivered_active_speaker_count(0),
        a0 + 1,
        "A notified"
    );
    assert_eq!(
        registry.delivered_active_speaker_count(2),
        c0 + 1,
        "C notified"
    );
}
