//! T6 — Bidirectional fanout verification: relay clients ↔ local browser peers.
//!
//! Direction A: a local browser peer publishes MediaData → relay client must
//!   receive it (no `is_relay()` guard blocks outbound delivery to relay clients).
//!
//! Direction B: a relay client publishes MediaData → local browser peer must
//!   receive it (relay origin is not filtered out of fanout).
//!
//! Both tests use the same `fanout_for_tests` seam as `multi_client.rs` so
//! they verify the actual `fanout()` function without the UDP loop.

use std::sync::Arc;

use oxpulse_sfu::client::test_seed::{make_media_data, new_client, seed_track_in};
use oxpulse_sfu::relay::client::PendingRelay;
use oxpulse_sfu::{client::Client, metrics::SfuMetrics, ClientId, Propagated};
use str0m::media::MediaKind;

fn make_pending_relay(label: &str) -> PendingRelay {
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
        room_id: "fanout-test".to_string(),
        upstream_url: format!("wss://eu.oxpulse.chat/ws/sfu/fanout-test"),
        upstream_room_token: "tok".to_string(),
        dc_id,
    }
}

/// Direction A: local browser peer produces MediaData → relay client must
/// receive it (no is_relay() guard should block delivery to relay clients).
#[test]
fn local_media_fans_out_to_relay_client() {
    let local_id = ClientId(10);
    let relay_id = ClientId(11);

    // Local browser peer publishes a video track.
    let mut local_peer = new_client(local_id);
    let track = seed_track_in(&mut local_peer, 1, MediaKind::Video);

    // Build relay client and override its auto-assigned id.
    let metrics = Arc::new(SfuMetrics::default());
    let mut relay_client = Client::new_outbound_relay(make_pending_relay("relay-dir-a"), metrics);
    relay_client.id = relay_id;

    // Wire the relay client as a subscriber of the local peer's track.
    relay_client.handle_track_open(Arc::downgrade(&track));

    let mut clients = vec![local_peer, relay_client];

    let data = make_media_data(1, None);
    let prop = Propagated::MediaData(local_id, data);
    oxpulse_sfu::fanout::fanout_for_tests(&prop, &mut clients);

    assert_eq!(
        clients[0].delivered_media_count(),
        0,
        "local peer is origin — must not receive its own media"
    );
    assert!(
        clients[1].delivered_media_count() > 0,
        "relay client must receive MediaData fanned out from local peer (Direction A)"
    );
}

/// Direction B: relay client produces MediaData → local browser peer must
/// receive it (relay origin must not be blocked by fanout).
#[test]
fn relay_media_fans_out_to_local_peer() {
    let relay_id = ClientId(20);
    let local_id = ClientId(21);

    // Relay client publishes a video track (media received from upstream SFU).
    let metrics = Arc::new(SfuMetrics::default());
    let mut relay_client = Client::new_outbound_relay(make_pending_relay("relay-dir-b"), metrics);
    relay_client.id = relay_id;
    let relay_track = seed_track_in(&mut relay_client, 2, MediaKind::Video);

    // Local browser peer subscribes to the relay's track.
    let mut local_peer = new_client(local_id);
    local_peer.handle_track_open(Arc::downgrade(&relay_track));

    let mut clients = vec![relay_client, local_peer];

    let data = make_media_data(2, None);
    let prop = Propagated::MediaData(relay_id, data);
    oxpulse_sfu::fanout::fanout_for_tests(&prop, &mut clients);

    assert_eq!(
        clients[0].delivered_media_count(),
        0,
        "relay client is origin — must not receive its own media"
    );
    assert!(
        clients[1].delivered_media_count() > 0,
        "local peer must receive MediaData fanned out from relay client (Direction B)"
    );
}
