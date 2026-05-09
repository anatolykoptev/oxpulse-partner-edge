//! M1.2 multi-client fanout and registry cross-advertisement tests.
//!
//! Fanout semantics: `Propagated::MediaData` from A reaches B and C,
//! not A (origin skip). Cross-advertisement: a late-joiner's
//! `tracks_out` is pre-populated with every already-open track.
//!
//! M5.3: capped-500kbps receiver sees only `q` layer forwarded; an
//! uncapped receiver sees `f`. Exercises registry → pacer →
//! client/fanout plumbing end-to-end against synthetic media.
//!
//! Simulcast layer filter → `tests/simulcast_speaker.rs`.
//! UDP-loop + Prometheus metrics → `tests/metrics_integration.rs`.

use std::sync::Arc;

use oxpulse_sfu::client::layer;
use oxpulse_sfu::client::test_seed::{make_media_data, new_client, seed_track_in};
use oxpulse_sfu::client::TrackIn;
use oxpulse_sfu::{ClientId, Propagated, Registry};
use str0m::media::MediaKind;

#[test]
fn fanout_every_to_every_excludes_origin() {
    let (a_id, b_id, c_id) = (ClientId(10), ClientId(11), ClientId(12));

    let mut a = new_client(a_id);
    let mut b = new_client(b_id);
    let mut c = new_client(c_id);

    // A publishes a video track. B and C subscribe.
    let track_in: Arc<TrackIn> = seed_track_in(&mut a, 1, MediaKind::Video);
    b.handle_track_open(Arc::downgrade(&track_in));
    c.handle_track_open(Arc::downgrade(&track_in));

    let data = make_media_data(1, None);
    let prop = Propagated::MediaData(a_id, data);

    let mut peers = vec![a, b, c];
    oxpulse_sfu::fanout::fanout_for_tests(&prop, &mut peers);

    assert_eq!(peers[0].layer_passed_count(), 0, "A is origin — skipped");
    assert_eq!(peers[1].layer_passed_count(), 1, "B receives fanout");
    assert_eq!(peers[2].layer_passed_count(), 1, "C receives fanout");
}

#[test]
fn registry_insert_cross_advertises_existing_tracks() {
    // Late-joiner C must learn about A's and B's tracks via insert().
    let mut registry = Registry::new_for_tests();

    let mut a = new_client(ClientId(20));
    let _arc_a = seed_track_in(&mut a, 1, MediaKind::Video);
    registry.insert(a);

    let mut b = new_client(ClientId(21));
    let _arc_b = seed_track_in(&mut b, 2, MediaKind::Audio);
    registry.insert(b);

    let c = new_client(ClientId(22));
    registry.insert(c);

    assert_eq!(registry.len(), 3);

    // Fanout from A: B and C tick; A is origin.
    let prop = Propagated::MediaData(ClientId(20), make_media_data(1, None));
    registry.fanout_for_tests(&prop);
    assert_eq!(registry.delivered_media_count(0), 0, "A origin");
    assert_eq!(registry.delivered_media_count(1), 1, "B saw A's media");
    assert_eq!(registry.delivered_media_count(2), 1, "C saw A's media");

    // Fanout from B: A and C tick.
    let prop = Propagated::MediaData(ClientId(21), make_media_data(2, None));
    registry.fanout_for_tests(&prop);
    assert_eq!(registry.delivered_media_count(0), 1, "A saw B's media");
    assert_eq!(registry.delivered_media_count(1), 1, "B origin (unchanged)");
    assert_eq!(registry.delivered_media_count(2), 2, "C saw A+B media");
}

#[test]
fn m53_capped_receiver_sees_q_uncapped_sees_f() {
    // Publisher A emits `q`, `h`, `f` layers. Receiver B's downlink
    // is capped at 200 kbps (below `h`'s 500 kbps floor → pacer
    // targets `q`). Receiver C's delay + loss estimators are driven
    // high enough that the pacer upgrades all the way to `f`.
    let mut registry = Registry::new_for_tests();

    let mut a = new_client(ClientId(40));
    let _arc = seed_track_in(&mut a, 1, MediaKind::Video);
    registry.insert(a);

    let b = new_client(ClientId(41));
    registry.insert(b);
    let c = new_client(ClientId(42));
    registry.insert(c);

    // B: capped (native ceiling binds).
    registry.cap_subscriber_bandwidth_for_tests(ClientId(41), 200_000);
    // C: drive the internal estimator above F_FLOOR. This exercises
    // the full zero-gradient / zero-loss convergence path — the
    // ceiling semantics of `record_native_estimate` mean we can't
    // just "pin" C's estimate high, we have to actually feed samples.
    registry.drive_subscriber_bandwidth_for_tests(ClientId(42), 2_000_000);

    // GoogCC v2 conservative merge: the per-registry GoogCC estimator caps
    // the pacer choice at its own preferred_rid(). Without driving GoogCC
    // above F_LAYER_BPS (1.2 Mbps) it stays at its initial 500 kbps →
    // MEDIUM, which silently caps C at MEDIUM regardless of BWE estimate.
    // Pin GoogCC above F_LAYER_BPS (1.2M) so the conservative merge allows
    // the pacer's choice through. GoogCC is registry-wide; B's capped BWE
    // alone ensures it stays at LOW — the GoogCC floor only bites HIGH.
    registry.drive_googcc_for_tests(2_000_000);

    // Hysteresis: 3 consecutive observations needed to upgrade. B
    // starts at the default LOW and stays there (downgrades are
    // immediate, no hysteresis); C must upgrade LOW → MEDIUM → HIGH
    // across multiple refresh cycles. Run 6 to land all promotions.
    // The publisher (A) hasn't seeded any active_rids yet, so
    // force_pacer_refresh_for_tests falls back to the full
    // `[LOW, MEDIUM, HIGH]` ladder — matches pre-fix behaviour.
    for _ in 0..6 {
        registry.force_pacer_refresh_for_tests(ClientId(40));
    }

    // Pre-fanout invariant: B's desired layer is LOW, C's is HIGH.
    // (This is the actual spec contract — media-forwarding counts
    // only verify the layer filter is honoured downstream.)
    assert_eq!(
        registry.clients()[1].desired_layer(),
        layer::LOW,
        "B (capped) pacer-picked LOW",
    );
    assert_eq!(
        registry.clients()[2].desired_layer(),
        layer::HIGH,
        "C (uncapped) pacer-upgraded to HIGH",
    );

    // Emit q/h/f. B filter keeps only q; C filter keeps only f.
    for rid in [layer::LOW, layer::MEDIUM, layer::HIGH] {
        let prop = Propagated::MediaData(ClientId(40), make_media_data(1, Some(rid)));
        registry.fanout_for_tests(&prop);
    }

    assert_eq!(
        registry.delivered_media_count(1),
        1,
        "B received exactly 1 packet (the q layer)",
    );
    assert_eq!(
        registry.delivered_media_count(2),
        1,
        "C received exactly 1 packet (the f layer)",
    );
}

#[test]
fn m53_screenshare_publisher_q_only_subscriber_stays_at_q() {
    // Regression for M5.3 review: if the publisher is emitting only
    // `q` (e.g. a screenshare), a subscriber with a 2 Mbps budget must
    // NOT have the pacer pick `f` — doing so would silently drop every
    // incoming `q` packet at the M1.3 layer filter (desired != emitted).
    //
    // With the active-RID plumbing the pacer sees `available = [q]`
    // and returns `q`; subscriber's `desired_layer` stays LOW; packets
    // flow. Counterpart to `m53_capped_receiver_sees_q_uncapped_sees_f`
    // which exercises the full-simulcast case.
    let mut registry = Registry::new_for_tests();

    let mut a = new_client(ClientId(50));
    let _arc = seed_track_in(&mut a, 1, MediaKind::Video);
    registry.insert(a);

    let b = new_client(ClientId(51));
    registry.insert(b);

    // A (publisher) only emits `q` — screenshare shape.
    registry.seed_active_rid_for_tests(ClientId(50), layer::LOW);

    // B has a healthy 2 Mbps estimate — pre-fix, pacer would pick `f`.
    registry.drive_subscriber_bandwidth_for_tests(ClientId(51), 2_000_000);

    // Hysteresis: same 6-cycle ladder as the companion test.
    for _ in 0..6 {
        registry.force_pacer_refresh_for_tests(ClientId(50));
    }

    assert_eq!(
        registry.clients()[1].desired_layer(),
        layer::LOW,
        "screenshare publisher only emits q → pacer must cap subscriber at LOW",
    );

    // End-to-end forwarding: fanout of a `q` packet reaches B.
    let prop = Propagated::MediaData(ClientId(50), make_media_data(1, Some(layer::LOW)));
    registry.fanout_for_tests(&prop);
    assert_eq!(
        registry.delivered_media_count(1),
        1,
        "B must receive the q packet that the screenshare publisher emitted",
    );
}
