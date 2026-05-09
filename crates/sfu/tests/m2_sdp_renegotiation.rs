//! Integration tests for M2 SDP renegotiation state machine.
//!
//! Tests the `Negotiating(mid) → Open(mid)` state transition that unblocks
//! fanout SRTP delivery. Uses synthetic `Event::MediaAdded { direction: SendOnly }`
//! via the public `handle_event` seam — no live UDP / DTLS pipeline needed.

use std::sync::Arc;

use str0m::media::{Direction, MediaKind, Mid};
use str0m::Event;

use oxpulse_sfu::client::test_seed::{new_client, seed_track_in};
use oxpulse_sfu::client::{TrackIn, TrackOut, TrackOutState};
use oxpulse_sfu::metrics::SfuMetrics;
use oxpulse_sfu::ClientId;

/// Build a synthetic `Event::MediaAdded` for a `SendOnly` mid.
fn media_added_send_only(mid: Mid, kind: MediaKind) -> Event {
    use str0m::media::MediaAdded;
    Event::MediaAdded(MediaAdded {
        mid,
        kind,
        direction: Direction::SendOnly,
        simulcast: None,
    })
}

/// Build a synthetic `Event::MediaAdded` for a `RecvOnly` mid.
fn media_added_recv_only(mid: Mid, kind: MediaKind) -> Event {
    use str0m::media::MediaAdded;
    Event::MediaAdded(MediaAdded {
        mid,
        kind,
        direction: Direction::RecvOnly,
        simulcast: None,
    })
}

/// Core M2 fix: dispatch.rs must flip `Negotiating(mid)` → `Open(mid)` when
/// `Event::MediaAdded { direction: SendOnly, mid }` fires.
#[test]
fn media_added_send_only_transitions_negotiating_to_open() {
    let mut client = new_client(ClientId(1001));
    let metrics = client.metrics_for_tests().clone();

    let mid: Mid = Mid::from(&*"m42");
    let origin = ClientId(999);
    let track_in = Arc::new(TrackIn {
        origin,
        mid,
        kind: MediaKind::Video,
    });

    // Pre-seed a Negotiating track.
    client.tracks_out.push(TrackOut {
        track_in: Arc::downgrade(&track_in),
        state: TrackOutState::Negotiating(mid),
    });

    client.handle_event(media_added_send_only(mid, MediaKind::Video));

    let out = client.tracks_out.iter().find(|o| o.mid() == Some(mid));
    assert!(out.is_some(), "track_out with mid must exist");
    assert_eq!(
        out.unwrap().state,
        TrackOutState::Open(mid),
        "state must be Open(mid) after SendOnly MediaAdded"
    );

    assert_eq!(
        metrics
            .sfu_track_out_state_transitions_total
            .with_label_values(&["negotiating", "open"])
            .get(),
        1,
        "sfu_track_out_state_transitions_total{{negotiating,open}} must be 1"
    );
}

/// RecvOnly MediaAdded must create a TrackIn (publisher-side) and NOT touch tracks_out.
#[test]
fn media_added_recv_only_creates_track_in_not_track_out() {
    let mut client = new_client(ClientId(1002));
    let metrics = client.metrics_for_tests().clone();

    let mid: Mid = Mid::from(&*"m7");
    let origin = ClientId(888);
    let track_in = Arc::new(TrackIn {
        origin,
        mid,
        kind: MediaKind::Audio,
    });

    // Pre-seed a Negotiating entry for a different purpose.
    client.tracks_out.push(TrackOut {
        track_in: Arc::downgrade(&track_in),
        state: TrackOutState::Negotiating(mid),
    });

    // RecvOnly event — should add a TrackIn entry, not flip tracks_out.
    client.handle_event(media_added_recv_only(mid, MediaKind::Audio));

    // tracks_out state must be unchanged.
    let out = client.tracks_out.iter().find(|o| o.mid() == Some(mid));
    assert!(out.is_some(), "tracks_out entry must still exist");
    assert_eq!(
        out.unwrap().state,
        TrackOutState::Negotiating(mid),
        "RecvOnly MediaAdded must not flip Negotiating to Open"
    );

    // negotiating→open counter must not fire.
    assert_eq!(
        metrics
            .sfu_track_out_state_transitions_total
            .with_label_values(&["negotiating", "open"])
            .get(),
        0
    );
}

/// SendOnly event for unknown mid must not panic (defensive).
#[test]
fn media_added_send_only_unknown_mid_is_noop() {
    let mut client = new_client(ClientId(1003));
    let unknown_mid: Mid = Mid::from(&*"m99");

    // No entries — must not panic.
    client.handle_event(media_added_send_only(unknown_mid, MediaKind::Video));
    assert!(client.tracks_out.is_empty());
}

/// handle_track_open legacy path: ws_msg_tx absent → push ToOpen and stop.
#[test]
fn handle_track_open_legacy_path_when_no_ws_channel() {
    let mut publisher = new_client(ClientId(2001));
    let track_arc = seed_track_in(&mut publisher, 3, MediaKind::Audio);

    let mut subscriber = new_client(ClientId(2002));
    // new_client sets ws_msg_tx = None by design.
    assert!(subscriber.ws_msg_tx.is_none(), "new_client must have no ws_msg_tx");

    subscriber.handle_track_open(Arc::downgrade(&track_arc));

    assert_eq!(subscriber.tracks_out.len(), 1);
    assert_eq!(
        subscriber.tracks_out[0].state,
        TrackOutState::ToOpen,
        "legacy path must push ToOpen when ws_msg_tx is None"
    );
}
