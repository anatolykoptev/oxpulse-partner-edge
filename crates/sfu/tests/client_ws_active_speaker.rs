//! M4.A4 — integration test for the `active_speaker` DataChannel
//! payload.
//!
//! Why this lives here, not as a true end-to-end DTLS test: there's no
//! precedent in this crate for driving a full WS+DTLS shuttle in a
//! unit/integration test. The previous M4.A4 attempt (stop-report
//! preceding `267e529`) refused to ship a half-fake test that would
//! never observe the format!() output because the writer-stage early
//! return in [`oxpulse_sfu::client::fanout::handle_active_speaker_changed`]
//! always trips on an unnegotiated `Rtc` — the DC `rtc.channel(...)`
//! lookup returns `None` before the JSON payload ever leaves the
//! function. Option A (the path taken here): a `cfg(any(test,
//! feature = "test-utils"))` capture seam parallel to the existing
//! `delivered_active_speaker: AtomicU64`. The seam stores
//! `(payload, Instant)` *before* the writer-stage early return, so
//! tests observe the byte-identical format!() output that DTLS-up
//! production code would write to the wire.
//!
//! Coverage scope:
//! 1. **Wire format** — the JSON payload matches the M4.B1 contract
//!    (`type` / `peerId` / `confidence` keys; `type:` not `kind:`).
//! 2. **Skip-self** — the dominant speaker's own
//!    [`oxpulse_sfu::Client::handle_active_speaker_changed`] is never
//!    invoked (no capture present).
//! 3. **Cross-client isolation** — every non-self client sees the
//!    *same* peer_id, captured at near-identical timestamps (the
//!    fanout loop is microseconds tight; we tolerate ~50 ms).
//!
//! NOT covered here: actual DTLS delivery / SCTP write through
//! str0m. That path is exercised by [`oxpulse_sfu_kit`] and the
//! dominant-speaker call chain through `Registry::tick_active_speaker`
//! is already covered by `tests/simulcast_speaker.rs` which uses the
//! same in-memory `Client::new` + Registry fixture.
//!
//! Cross-references:
//! - M4.A3 commit `267e529` (browser-to-browser media + simulcast
//!   selection integration tests).
//! - `tests/simulcast_speaker.rs::active_speaker_dominance_and_hysteresis_and_skip_self`
//!   for the audio-level injection pattern this file mirrors.

use std::time::Instant;

use oxpulse_sfu::client::test_seed::new_client;
use oxpulse_sfu::{ClientId, Propagated, Registry};
use serde_json::Value;

#[test]
fn active_speaker_change_format_and_isolation_three_local_clients() {
    let mut registry = Registry::new_for_tests();

    // Three Local-origin clients with deterministic ids matching
    // peer_id space. `Client::new` defaults to ClientOrigin::Local,
    // so no further setup is required.
    let mut a = new_client(ClientId(1));
    a.id = ClientId(1);
    let mut b = new_client(ClientId(2));
    b.id = ClientId(2);
    let mut c = new_client(ClientId(3));
    c.id = ClientId(3);
    registry.insert(a);
    registry.insert(b);
    registry.insert(c);

    // Drive a synthetic dominance event with a known confidence so we
    // can assert both the payload bytes and the skip-self semantics.
    // Using a deterministic 0.7 (rather than relying on the detector's
    // bootstrap election) lets the test pin the exact `confidence:.3`
    // formatting in the wire-format assertion below.
    let dominant_peer: u64 = 2;
    let confidence: f64 = 0.7;
    registry.fanout_for_tests(&Propagated::ActiveSpeakerChanged {
        peer_id: dominant_peer,
        confidence,
    });

    // Helper: read the captured payload+Instant for a client by index.
    let captured = |idx: usize| -> Option<(String, Instant)> {
        registry.clients()[idx].last_active_speaker_payload()
    };

    // --- Skip-self: the dominant speaker (idx=1) must NOT have a
    //     captured payload. The fanout loop in `crate::fanout::fanout`
    //     skips `*client.id == *peer_id` before
    //     `handle_active_speaker_changed` is reached.
    assert!(
        captured(1).is_none(),
        "dominant speaker (peer_id=2 / idx=1) must not receive its own notification"
    );

    // --- Other two clients see the change.
    let cap_a = captured(0).expect("client A receives ActiveSpeakerChanged");
    let cap_c = captured(2).expect("client C receives ActiveSpeakerChanged");

    // --- Wire format: parse and assert the M4.B1 contract.
    //     Keys MUST be exactly {type, peerId, confidence}, no extras,
    //     no missing. `type` (not `kind`) is the contract — the
    //     browser handler keys off `msg.type === 'active_speaker'`.
    for (label, payload) in [("A", &cap_a.0), ("C", &cap_c.0)] {
        let v: Value = serde_json::from_str(payload)
            .unwrap_or_else(|e| panic!("client {label}: payload not valid JSON: {payload:?}: {e}"));
        let obj = v
            .as_object()
            .unwrap_or_else(|| panic!("client {label}: payload not a JSON object: {payload:?}"));

        // Exact key set.
        let mut keys: Vec<&str> = obj.keys().map(String::as_str).collect();
        keys.sort();
        assert_eq!(
            keys,
            vec!["confidence", "peerId", "type"],
            "client {label}: unexpected key set in payload {payload:?}"
        );

        // type == "active_speaker" (NOT kind).
        assert_eq!(
            obj.get("type").and_then(Value::as_str),
            Some("active_speaker"),
            "client {label}: type field must be \"active_speaker\""
        );

        // peerId is u64, equals dominant_peer.
        let peer_id = obj
            .get("peerId")
            .and_then(Value::as_u64)
            .unwrap_or_else(|| panic!("client {label}: peerId not a u64 in {payload:?}"));
        assert_eq!(
            peer_id, dominant_peer,
            "client {label}: peerId must match dominant"
        );

        // confidence is a finite f64; this test injects 0.7 so
        // the formatted bytes are "0.700" — assert the exact value
        // round-trips. (We avoid 0.0..=1.0 range assertions because
        // detector::c2_margin can technically exceed 1.0; the
        // wire-format contract here is tighter than the detector
        // output range.)
        let conf = obj
            .get("confidence")
            .and_then(Value::as_f64)
            .unwrap_or_else(|| panic!("client {label}: confidence not f64 in {payload:?}"));
        assert!(
            conf.is_finite(),
            "client {label}: confidence must be finite, got {conf}"
        );
        assert!(
            (conf - confidence).abs() < 1e-9,
            "client {label}: confidence round-trip mismatch (expected {confidence}, got {conf})"
        );
    }

    // --- Cross-client isolation: both receivers see the SAME peer_id
    //     (we already checked above) and capture at near-simultaneous
    //     instants. The fanout loop is single-threaded and tight; the
    //     ~50 ms tolerance is generous and only guards against a
    //     pathological scheduler stall mid-loop.
    let delta = if cap_a.1 > cap_c.1 {
        cap_a.1.duration_since(cap_c.1)
    } else {
        cap_c.1.duration_since(cap_a.1)
    };
    assert!(
        delta.as_millis() <= 50,
        "cross-client capture instants drifted by {}ms (>50ms tolerance) — fanout loop is supposed to be tight",
        delta.as_millis()
    );

    // Print delta for the report; harmless in CI.
    eprintln!("cross-client capture delta: {} µs", delta.as_micros());
    eprintln!("payload sample (client A): {}", cap_a.0);
}
