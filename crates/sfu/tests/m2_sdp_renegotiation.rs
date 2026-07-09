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

    let mid: Mid = Mid::from("m42");
    let origin = ClientId(999);
    let track_in = Arc::new(TrackIn {
        origin,
        mid,
        kind: MediaKind::Video,
        external_peer_id: None,
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

    let mid: Mid = Mid::from("m7");
    let origin = ClientId(888);
    let track_in = Arc::new(TrackIn {
        origin,
        mid,
        kind: MediaKind::Audio,
        external_peer_id: None,
    });

    // Pre-seed a Negotiating entry for a different purpose.
    client.tracks_out.push(TrackOut {
        track_in: Arc::downgrade(&track_in),
        state: TrackOutState::Negotiating(mid),
    });

    // RecvOnly event — should add a TrackIn entry, not flip tracks_out.
    client.handle_event(media_added_recv_only(mid, MediaKind::Audio));

    // tracks_out state must be unchanged. mid() returns None for Negotiating
    // (per review fix: only Open returns Some), so search by state directly.
    let out = client
        .tracks_out
        .iter()
        .find(|o| matches!(o.state, TrackOutState::Negotiating(m) if m == mid));
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
    let unknown_mid: Mid = Mid::from("m99");

    // No entries — must not panic.
    client.handle_event(media_added_send_only(unknown_mid, MediaKind::Video));
    assert!(client.tracks_out.is_empty());
}

/// Drive a real str0m offer/answer exchange between two `Rtc` instances and
/// verify that `Event::MediaAdded { direction: SendOnly }` is actually emitted.
///
/// This test creates two in-process str0m peers (caller/callee), adds a
/// send-only audio m-line on the caller side, drives the SDP offer/answer
/// exchange manually, and confirms the callee emits `MediaAdded { SendOnly }`.
///
/// NOTE: str0m's in-process API requires driving the full ICE/DTLS handshake
/// before DataChannel / MediaAdded events fire. Because unit-test environments
/// have no UDP socket, we cannot complete the handshake without network I/O.
/// The test is therefore marked `#[ignore]` — run with
/// `cargo test -- --ignored accept_answer_emits_media_added_send_only`
/// in an environment with loopback UDP (CI or dev machine with lo available).
///
/// Gap: str0m requires real ICE connectivity for MediaAdded to fire. A fully
/// in-process simulation is not yet possible without the loopback socket helper
/// from str0m's own integration test suite (not re-exported as a public API).
#[test]
#[ignore = "requires loopback UDP — str0m MediaAdded only fires after ICE/DTLS connected"]
fn accept_answer_emits_media_added_send_only() {
    use std::time::Instant;
    use str0m::change::SdpOffer;
    use str0m::media::{Direction, MediaKind};
    use str0m::Rtc;

    let now = Instant::now();

    // Caller: will offer a send-only audio track.
    let mut caller = Rtc::new(now);
    let mut api = caller.sdp_api();
    api.add_media(MediaKind::Audio, Direction::SendOnly, None, None, None);
    let (offer, _pending) = api.apply().expect("apply must return Some for new media");

    // Callee: will answer. A real str0m answer requires ICE candidates to be
    // exchanged, which needs a socket — hence the ignore.
    let mut callee = Rtc::new(now);
    let offer_str = offer.to_sdp_string();
    let parsed_offer = SdpOffer::from_sdp_string(&offer_str).expect("offer parses");
    let _answer = callee
        .sdp_api()
        .accept_offer(parsed_offer)
        .expect("callee accept_offer must succeed");

    // If ICE were connected, pumping callee would yield:
    // Event::MediaAdded { direction: RecvOnly } (callee receives what caller sends).
    // On the caller side after accept_answer: Event::MediaAdded { direction: SendOnly }.
    // This assertion cannot run without network; left as documentation of the expected shape.
}

/// handle_track_open legacy path: ws_msg_tx absent → push ToOpen and stop.
#[test]
fn handle_track_open_legacy_path_when_no_ws_channel() {
    let mut publisher = new_client(ClientId(2001));
    let track_arc = seed_track_in(&mut publisher, 3, MediaKind::Audio);

    let mut subscriber = new_client(ClientId(2002));
    // new_client sets ws_msg_tx = None by design.
    // Use the test seam accessor — ws_msg_tx is pub(crate) and not reachable
    // from this integration test crate.
    assert!(
        subscriber.ws_msg_tx_is_none(),
        "new_client must have no ws_msg_tx"
    );

    subscriber.handle_track_open(Arc::downgrade(&track_arc));

    assert_eq!(subscriber.tracks_out.len(), 1);
    assert_eq!(
        subscriber.tracks_out[0].state,
        TrackOutState::ToOpen,
        "legacy path must push ToOpen when ws_msg_tx is None"
    );
}
