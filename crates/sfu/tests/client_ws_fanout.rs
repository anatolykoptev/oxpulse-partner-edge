//! M4.A3: browser↔SFU↔browser fanout + simulcast layer selection.
//!
//! Sister file to [`client_ws_session.rs`][session]: that one covers the
//! signalling half (offer/answer over WS, `PendingClient` injection);
//! this one covers the *post-injection* half — once two
//! `ClientOrigin::Local` peers are sitting in the same `Registry`, do
//! their RTP forwards reach each other, and does the per-receiver
//! simulcast layer selection respect the budget hints that arrive over
//! DC id:2?
//!
//! The two contracts under test:
//!
//! 1. **Two `ClientOrigin::Local` peers in one Registry fan out media
//!    to each other.** The chain `Client::new → Registry::insert →
//!    Propagated::MediaData → fanout::fanout` already iterates all
//!    non-origin clients (see `crates/sfu/src/fanout.rs`), but no test
//!    asserted this for *Local-origin pairs*. Existing fanout tests
//!    use `new_client` from `test_seed`, which goes through
//!    `Client::new` and ends up Local — so the assertion was implicit.
//!    M4.A3 promotes it to explicit.
//!
//! 2. **DC id:2 (`sfu-budget`) budget hints from a Local-origin
//!    receiver flow through the same pacer pipeline that relay
//!    receivers use.** The `client::dc::handle_channel_data` function
//!    takes a `ClientId` only — `ClientOrigin` is never consulted —
//!    so origin-agnostic is a code-reading conclusion. The
//!    registry-level pacer integration deserves an end-to-end
//!    assertion alongside the existing
//!    `m53_capped_receiver_sees_q_uncapped_sees_f` in
//!    `tests/multi_client.rs`.
//!
//! Why no real two-peer ICE handshake here: the codebase does not
//! have that scaffold (see `tests/relay_media_e2e.rs`, the closest
//! analogue, which also avoids real ICE in favour of the
//! `Registry::insert + fanout_for_tests` pattern). Building one
//! would be its own multi-day effort and is explicitly out of scope
//! for this task ("don't add new fanout/routing code unless the test
//! reveals a real gap" — the gap doesn't exist).
//!
//! [session]: client_ws_session

use std::sync::Arc;
use std::time::Instant;

use oxpulse_sfu::client::layer;
use oxpulse_sfu::client::test_seed::{make_media_data, seed_track_in};
use oxpulse_sfu::metrics::SfuMetrics;
use oxpulse_sfu::{Client, ClientId, Propagated, Registry};
use str0m::media::MediaKind;

/// Build a "browser" `Client` — i.e. the exact construction path the
/// `client_ws::session` handler triggers when it sends a
/// `PendingClient` and `udp_loop::serve` calls `Client::new(rtc, m)`.
/// `origin` defaults to `ClientOrigin::Local`.
fn build_browser_client(id: ClientId) -> Client {
    let rtc = str0m::Rtc::new(Instant::now());
    let metrics = Arc::new(SfuMetrics::default());
    let mut client = Client::new(rtc, metrics);
    // Override the auto-allocated id so tests can map by stable id —
    // `construct.rs` uses an `AtomicU64` counter that's
    // non-deterministic across test ordering otherwise.
    client.id = id;
    client
}

#[test]
fn two_browsers_in_same_room_exchange_rtp() {
    // Construction parity with the production path: each peer goes
    // through `Client::new` → `Registry::insert`, exactly as the
    // `client_inject_rx` arm of `udp_loop::serve` does. The only
    // semantic difference vs the prod path is that we don't drive
    // ICE/DTLS — `make_media_data` synthesizes `MediaData` directly so
    // the writer path early-returns on the unnegotiated `Rtc` while
    // the M1.3 layer filter and the `delivered_media` counter still
    // tick. This is the same trade `tests/relay_media_e2e.rs` makes.
    let mut registry = Registry::new_for_tests();

    // Browser A: publisher with one video track.
    let a_id = ClientId(700);
    let mut a = build_browser_client(a_id);
    assert!(
        !a.is_relay(),
        "browser A constructed via Client::new must be Local-origin (M4.A3 contract)"
    );
    let _track_a = seed_track_in(&mut a, 1, MediaKind::Video);
    registry.insert(a);

    // Browser B: subscriber. Inserted second so `Registry::insert`
    // cross-advertises A's track into B's `tracks_out` (the `chat.rs`
    // late-joiner pattern).
    let b_id = ClientId(701);
    let b = build_browser_client(b_id);
    assert!(
        !b.is_relay(),
        "browser B constructed via Client::new must be Local-origin (M4.A3 contract)"
    );
    registry.insert(b);

    // Browser A "publishes" a packet — this is what `udp_loop::serve`
    // does when an RTP datagram from A's 4-tuple arrives, demuxes
    // through `Registry::handle_incoming` → str0m → emits `MediaData`
    // → `Propagated::MediaData(a_id, …)`.
    let packet = make_media_data(1, None);
    registry.fanout_for_tests(&Propagated::MediaData(a_id, packet));

    // A is the origin and must NOT self-receive (chat.rs invariant).
    assert_eq!(
        registry.delivered_media_count(0),
        0,
        "browser A is origin — must not self-receive its own RTP"
    );
    // B must receive — the headline M4.A3 contract: two
    // `Local`-origin clients in one room exchange media without any
    // relay-specific code paths.
    assert_eq!(
        registry.delivered_media_count(1),
        1,
        "browser B must receive browser A's RTP via the Local→Local fanout pool"
    );

    // Registry sanity: 2 clients, neither is a relay.
    assert_eq!(registry.len(), 2, "registry has both browser peers");
    for (i, c) in registry.clients().iter().enumerate() {
        assert!(
            !c.is_relay(),
            "client[{i}] must remain Local — no `mark_relay_source` was called"
        );
    }
}

#[test]
fn browser_low_budget_drops_to_q_layer() {
    // Publisher A emits the full simulcast ladder (q+h+f). Receiver B
    // is a Local-origin browser whose downlink is capped at 200 kbps
    // — below the `h` floor — so the pacer must hold B's
    // `desired_layer` at LOW. The M1.3 filter then drops `h`/`f`
    // packets at fanout time.
    //
    // This is the Local-origin counterpart to
    // `m53_capped_receiver_sees_q_uncapped_sees_f` in
    // `tests/multi_client.rs`, written here to make the M4.A3 claim
    // ("DC id:2 budget pipeline is origin-agnostic") explicit at the
    // registry level. The DC budget *parser* is exercised by the unit
    // tests in `client/dc.rs`; here we exercise the pacer wiring
    // downstream of it.
    let mut registry = Registry::new_for_tests();

    let publisher_id = ClientId(710);
    let mut publisher = build_browser_client(publisher_id);
    let _track = seed_track_in(&mut publisher, 1, MediaKind::Video);
    registry.insert(publisher);

    // Pre-seed the publisher's `active_rids` with the full simulcast
    // ladder — without this, the pacer falls back to the default
    // `[LOW, MEDIUM, HIGH]` ladder anyway, but seeding makes the test
    // exercise the post-M5.3 active-RID plumbing path explicitly.
    registry.seed_active_rid_for_tests(publisher_id, layer::LOW);
    registry.seed_active_rid_for_tests(publisher_id, layer::MEDIUM);
    registry.seed_active_rid_for_tests(publisher_id, layer::HIGH);

    // Receiver B: also Local-origin.
    let receiver_id = ClientId(711);
    let receiver = build_browser_client(receiver_id);
    registry.insert(receiver);

    // Apply a 200 kbps downlink cap. In production this would arrive
    // as `{"type":"budget","bps":200000}` over DC id:2 from the
    // browser, get parsed by `dc::handle_channel_data` into
    // `Propagated::ClientBudgetHint`, and feed
    // `BandwidthEstimator::record_native_estimate` via
    // `registry::poll::fanout_pending`. The test seam below skips the
    // wire format and calls `record_native_estimate` directly — same
    // post-condition.
    registry.cap_subscriber_bandwidth_for_tests(receiver_id, 200_000);

    // 6 hysteresis cycles to converge the pacer (matches
    // `m53_capped_receiver_sees_q_uncapped_sees_f`).
    for _ in 0..6 {
        registry.force_pacer_refresh_for_tests(publisher_id);
    }

    // The capped receiver must hold LOW.
    assert_eq!(
        registry.clients()[1].desired_layer(),
        layer::LOW,
        "Local-origin receiver with 200 kbps budget must pacer-pick LOW",
    );

    // Publisher emits q, h, f — only q gets through to B.
    for rid in [layer::LOW, layer::MEDIUM, layer::HIGH] {
        let prop = Propagated::MediaData(publisher_id, make_media_data(1, Some(rid)));
        registry.fanout_for_tests(&prop);
    }
    assert_eq!(
        registry.delivered_media_count(1),
        1,
        "receiver must receive exactly 1 packet (the q layer); h/f dropped by M1.3 filter",
    );
}

// DC id:2 origin-agnosticism is established by inspection: the
// `client::dc::handle_channel_data` function signature is
// `(ClientId, &str, &[u8], Option<&[u8]>, Option<&str>) -> Propagated`
// — no `ClientOrigin` parameter. Existing unit tests in
// `client/dc.rs::tests` cover the budget parser directly. The
// `browser_low_budget_drops_to_q_layer` test above exercises the
// downstream registry/pacer wiring with a Local-origin receiver,
// which is the wiring M4.A3 actually changes (vs M5.3, which
// validated the parser end-to-end with relay receivers).
