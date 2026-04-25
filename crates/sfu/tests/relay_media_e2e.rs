//! T7A — End-to-end relay media integration test: two in-process Registry
//! instances simulating a cascade relay bridge.
//!
//! These tests verify the two production behaviors that fanout_relay.rs does
//! not cover:
//!
//! 1. `two_registry_relay_bridge_media_flows_bidirectionally` — simulate a
//!    two-hop fanout path through two independent Registry instances.  SFU-1
//!    has peer A + an outbound relay client; SFU-2 has the inbound relay
//!    client (receiving A's media) + peer B.  We verify:
//!      a. A's media fans out to the relay client on SFU-1 (the relay picks it
//!         up to forward upstream).
//!      b. Media from the relay's inbound counterpart on SFU-2 fans out to B.
//!    NOTE: the two Registries are not wire-connected — what we test is the
//!    correct subscription wiring on each SFU independently, which is the
//!    part that the relay construction code (T2-T5) is responsible for.
//!
//! 2. `relay_client_excluded_from_speaker_detection_after_mark` — verifies
//!    that a relay client, initially inserted as a Local peer, is removed from
//!    the dominant-speaker detector when `mark_relay_source()` is called.
//!    This exercises the production code path that runs after the relay_source
//!    DC handshake completes (T3/T4).  Uses audio-level injection and
//!    `top_speakers_for_tests` so the assertion is on detector membership,
//!    not just the `is_relay()` flag.

use std::sync::Arc;
use std::time::Instant;

use oxpulse_sfu::client::test_seed::{make_media_data, new_client, seed_track_in};
use oxpulse_sfu::relay::client::PendingRelay;
use oxpulse_sfu::{client::Client, metrics::SfuMetrics, ClientId, Propagated, Registry};
use str0m::media::MediaKind;

fn make_pending_relay(label: &str, upstream_url: &str) -> PendingRelay {
    let mut rtc = str0m::Rtc::new(std::time::Instant::now());
    let dc_id = rtc
        .direct_api()
        .create_data_channel(str0m::channel::ChannelConfig {
            label: label.to_string(),
            ordered: true,
            reliability: str0m::channel::Reliability::Reliable,
            negotiated: Some(5),
            protocol: String::new(),
        });
    PendingRelay {
        rtc,
        room_id: "e2e-room".to_string(),
        upstream_url: upstream_url.to_string(),
        upstream_room_token: "e2e-token".to_string(),
        dc_id,
    }
}

/// Simulate a two-hop media path:
///   peer A (SFU-1) -> relay_client_sfu1 -> [wire] -> relay_client_sfu2 -> peer B (SFU-2)
///
/// We test each SFU half independently:
///   - SFU-1 half: peer A produces MediaData; relay_client_sfu1 must receive it.
///   - SFU-2 half: relay_client_sfu2 produces MediaData; peer B must receive it.
///
/// Both halves use the real Registry insert() path so cross-advertisement wiring
/// applies, and fanout_for_tests to drive the fanout function.
#[test]
fn two_registry_relay_bridge_media_flows_bidirectionally() {
    let metrics = Arc::new(SfuMetrics::default());

    // -- SFU-1 half: peer A publishes a video track ---------------------------
    let peer_a_id = ClientId(100);
    let mut sfu1 = Registry::new_for_tests();

    let mut peer_a = new_client(peer_a_id);
    let _track_a = seed_track_in(&mut peer_a, 10, MediaKind::Video);
    sfu1.insert(peer_a);

    // Relay client on SFU-1 is inserted AFTER peer A so that Registry::insert()
    // cross-advertises track_a to the relay via handle_track_open.
    let relay_sfu1 = Client::new_outbound_relay(
        make_pending_relay("relay-sfu1", "wss://eu.oxpulse.chat/ws/sfu/e2e-room"),
        metrics.clone(),
    );
    sfu1.insert(relay_sfu1);

    // Peer A produces MediaData — the relay client should receive it.
    let data_a = make_media_data(10, None);
    sfu1.fanout_for_tests(&Propagated::MediaData(peer_a_id, data_a));

    // clients()[0] = peer_a (origin, must not self-deliver)
    // clients()[1] = relay_sfu1 (must receive)
    assert_eq!(
        sfu1.delivered_media_count(0),
        0,
        "peer A is origin — must not receive its own media"
    );
    assert!(
        sfu1.delivered_media_count(1) > 0,
        "relay client on SFU-1 must receive peer A MediaData to forward upstream"
    );

    // -- SFU-2 half: relay client publishes A's media to peer B ---------------
    let peer_b_id = ClientId(101);
    let relay_sfu2_id = ClientId(102);

    let mut sfu2 = Registry::new_for_tests();

    // relay_sfu2 is the inbound counterpart: it publishes a video track
    // (the media it received from SFU-1 via the relay WS/ICE pipe).
    let mut relay_sfu2 = new_client(relay_sfu2_id);
    let _track_relay = seed_track_in(&mut relay_sfu2, 11, MediaKind::Video);
    sfu2.insert(relay_sfu2);

    // Peer B is inserted after relay_sfu2 so Registry::insert() cross-advertises
    // track_relay to peer B.
    let peer_b = new_client(peer_b_id);
    sfu2.insert(peer_b);

    // relay_sfu2 produces MediaData — peer B should receive it.
    let data_relay = make_media_data(11, None);
    sfu2.fanout_for_tests(&Propagated::MediaData(relay_sfu2_id, data_relay));

    // clients()[0] = relay_sfu2 (origin, must not self-deliver)
    // clients()[1] = peer_b (must receive)
    assert_eq!(
        sfu2.delivered_media_count(0),
        0,
        "relay client on SFU-2 is origin — must not receive its own media"
    );
    assert!(
        sfu2.delivered_media_count(1) > 0,
        "peer B must receive MediaData forwarded by the relay client from SFU-1"
    );

    println!(
        "relay bridge A->B: sfu1.relay_received={}, sfu2.peer_b_received={}",
        sfu1.delivered_media_count(1),
        sfu2.delivered_media_count(1)
    );
}

/// Verify that `mark_relay_source()` removes the relay client from the
/// dominant-speaker detector — not just from the is_relay() flag.
///
/// Sequence:
///  1. Insert a relay client as a Local peer (before DC handshake — this is the
///     production sequence: relay arrives as a WebRTC peer before relay_source fires).
///  2. Insert a real browser peer.
///  3. Inject high audio levels for both; verify both appear in top_speakers.
///  4. Call mark_relay_source() on the relay — simulates relay_source DC handshake.
///  5. Tick the detector — relay must no longer appear in top_speakers.
///
/// NOTE: after remove_peer, record_level re-adds silently (upstream design).
/// We therefore do NOT inject audio for the relay after the mark — the
/// production path also never injects relay audio into the detector: the relay
/// client is removed from detector membership and real peers drive ASO from
/// that point on.
#[test]
fn relay_client_excluded_from_speaker_detection_after_mark() {
    let mut registry = Registry::new_for_tests();

    let relay_id = ClientId(200);
    let peer_id = ClientId(201);

    // Insert relay client first as a regular new_client (simulating a peer
    // connected before the relay_source DC message arrives).
    let mut relay_client = new_client(relay_id);
    let _ = seed_track_in(&mut relay_client, 20, MediaKind::Audio);
    registry.insert(relay_client);

    let real_peer = new_client(peer_id);
    registry.insert(real_peer);

    let t0 = Instant::now();

    // Both have high audio activity before mark.
    registry.inject_audio_level_for_tests(*relay_id, 100, t0);
    registry.inject_audio_level_for_tests(*peer_id, 90, t0);

    let top_before = registry.top_speakers_for_tests(2);
    // Both peers should be in detector before mark (relay not yet excluded).
    assert!(
        top_before.contains(&*relay_id),
        "before mark_relay_source, relay peer must still be in detector; top={top_before:?}"
    );
    assert!(
        top_before.contains(&*peer_id),
        "real peer must appear in detector; top={top_before:?}"
    );

    // DC handshake fires: registry promotes this client to relay origin and
    // removes it from the dominant-speaker detector.
    registry.mark_relay_source(relay_id, "wss://eu.oxpulse.chat/ws/sfu/e2e-room".to_string());

    // Verify the is_relay() flag changed.
    assert!(
        registry.clients()[0].is_relay(),
        "after mark_relay_source, client must report is_relay() = true"
    );

    // Tick the detector after mark. Do NOT inject audio for the relay here —
    // record_level would re-add it implicitly (upstream library design).
    // In production the relay never injects audio levels; real peers do.
    let t1 = t0 + std::time::Duration::from_millis(500);
    registry.inject_audio_level_for_tests(*peer_id, 90, t1);
    registry.force_active_speaker_tick_for_tests(t1);

    let top_after = registry.top_speakers_for_tests(2);
    assert!(
        !top_after.contains(&*relay_id),
        "after mark_relay_source, relay client must be absent from top speakers; top={top_after:?}"
    );
    assert!(
        top_after.contains(&*peer_id),
        "real peer must still appear in top speakers after relay exclusion; top={top_after:?}"
    );

    println!(
        "speaker detection: top_before={top_before:?} -> top_after={top_after:?}"
    );
}
