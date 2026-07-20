//! G3 Phase 0 — load-bearing de-risk integration test.
//!
//! Proves the single biggest P0 unknown: that str0m's URI-reconcile
//! (`rtp::ext::remap` / `session::remote_extmap`) rebinds our
//! `DdSerializer` — registered on the subscriber-facing `RtcConfig` at a
//! LOCAL extmap id — to whatever ARBITRARY extmap id a peer negotiates for
//! the Dependency Descriptor URI, AND that a packet carrying a DD then
//! yields `Some(DdPresent)` on `MediaData.ext_vals.user_values`.
//!
//! This is the exact seam P1 SVC layer-selection will depend on. If str0m
//! ever stops rebinding by URI, P1 would silently receive zero DD-bearing
//! packets and the layer selector would never fire — this test catches that
//! regression at P0, before the parser investment.
//!
//! The test runs a real two-`Rtc` SDP handshake + DTLS/SRTP media flow
//! (minimal self-contained poll harness, no netem dep): the peer (offerer,
//! browser sim) registers DD at extmap id 14, the SFU (answerer) uses the
//! production `subscriber_rtc_config` which registers DD at local id 9.
//! After negotiation the SFU's remote extmap must have DD at id 14 (rebind
//! proved), and a VP8 frame written by the peer with a DD must arrive on
//! the SFU side with `DdPresent` populated.

use std::collections::VecDeque;
use std::net::Ipv4Addr;
use std::time::{Duration, Instant};

use oxpulse_sfu::config::{subscriber_rtc_config, DD_LOCAL_EXTMAP_ID};
use oxpulse_sfu::svc::{DdPresent, DdSerializer, DD_URI};
use str0m::change::SdpOffer;
use str0m::format::Codec;
use str0m::media::{Direction, MediaKind};
use str0m::net::Receive;
use str0m::rtp::Extension;
use str0m::{Candidate, Event, Input, Output, Rtc, RtcError};

/// Extmap id the peer (browser sim) registers DD under — deliberately
/// DIFFERENT from the SFU's local [`DD_LOCAL_EXTMAP_ID`] (9) so the test
/// proves the URI-rebind, not a coincidental id match.
const PEER_DD_EXTMAP_ID: u8 = 14;

/// Minimal test peer: a str0m `Rtc` + a transmit queue + collected events.
struct Peer {
    rtc: Rtc,
    last: Instant,
    start: Instant,
    events: Vec<Event>,
    tx: VecDeque<str0m::net::Transmit>,
}

impl Peer {
    fn new(rtc: Rtc) -> Self {
        let now = Instant::now();
        Peer {
            rtc,
            last: now,
            start: now,
            events: Vec::new(),
            tx: VecDeque::new(),
        }
    }

    fn duration(&self) -> Duration {
        self.last - self.start
    }

    /// Drain pending outputs until the next timeout, queueing transmits and
    /// collecting events. Returns the next timeout instant.
    fn poll_until_timeout(&mut self) -> Instant {
        loop {
            match self.rtc.poll_output() {
                Ok(Output::Timeout(t)) => return t,
                Ok(Output::Transmit(t)) => self.tx.push_back(t),
                Ok(Output::Event(e)) => self.events.push(e),
                Err(e) => panic!("poll_output error: {e:?}"),
            }
        }
    }

    fn is_connected(&self) -> bool {
        self.rtc.is_connected()
    }
}

/// Advance both peers: fire the earliest scheduled timeout on BOTH sides
/// (advancing their clocks together), then cross-deliver any queued
/// transmits. Loosely mirrors str0m's `tests/common::progress` but routes
/// transmits directly (no netem) and fires both sides per step so neither
/// clock stalls waiting for the other.
fn progress(l: &mut Peer, r: &mut Peer) -> Result<(), RtcError> {
    let l_timeout = l.poll_until_timeout();
    let r_timeout = r.poll_until_timeout();
    let mut next = l_timeout.min(r_timeout);

    // Forced time advance: when both rtcs report a timeout AT their current
    // `last` (i.e. "nothing scheduled, ask again later"), `next` would not
    // advance and the driver would spin forever. Bump by 10ms to guarantee
    // forward progress — mirrors str0m's `tests/common::forced_time_advance`.
    let min_last = l.last.min(r.last);
    if next <= min_last {
        next = min_last + Duration::from_millis(10);
    }

    // Fire the timeout on both peers at the shared instant. str0m's
    // `handle_input(Timeout(t))` is a no-op if t is before the rtc's next
    // scheduled work, so calling it on the side whose timeout is later is
    // safe and keeps the two clocks roughly in sync.
    l.rtc.handle_input(Input::Timeout(next))?;
    l.last = next;
    r.rtc.handle_input(Input::Timeout(next))?;
    r.last = next;

    l.poll_until_timeout_drain();
    r.poll_until_timeout_drain();

    // Cross-deliver any transmits each side has queued for the other.
    deliver(l, r)?;
    deliver(r, l)?;

    Ok(())
}

impl Peer {
    /// Drain outputs after a timeout fire, stopping at the NEXT timeout.
    fn poll_until_timeout_drain(&mut self) {
        loop {
            match self.rtc.poll_output() {
                Ok(Output::Timeout(_)) => break,
                Ok(Output::Transmit(t)) => self.tx.push_back(t),
                Ok(Output::Event(e)) => self.events.push(e),
                Err(e) => panic!("poll_output error: {e:?}"),
            }
        }
    }
}

/// Deliver all transmits queued in `from` to `to` as `Input::Receive`.
fn deliver(from: &mut Peer, to: &mut Peer) -> Result<(), RtcError> {
    let now = to.last.max(from.last);
    while let Some(t) = from.tx.pop_front() {
        let input = Input::Receive(
            now,
            Receive::new(t.proto, t.source, t.destination, &t.contents)?,
        );
        to.rtc.handle_input(input)?;
        to.poll_until_timeout_drain();
    }
    Ok(())
}

#[test]
fn dd_extension_uri_rebinds_to_peer_extmap_id() -> Result<(), RtcError> {
    // Install the default crypto provider (DTLS/SRTP needs it).
    str0m::crypto::from_feature_flags().install_process_default();

    // SFU side (answerer): production subscriber config — DD registered at
    // local id DD_LOCAL_EXTMAP_ID (9).
    let sfu_rtc = subscriber_rtc_config(None).build(Instant::now());
    let mut sfu = Peer::new(sfu_rtc);

    // Peer side (offerer / browser sim): register the SAME serializer under
    // a DIFFERENT extmap id. str0m must rebind by URI on answer.
    let peer_dd_ext = Extension::with_serializer(DD_URI, DdSerializer);
    let peer_rtc = Rtc::builder()
        .set_extension(PEER_DD_EXTMAP_ID, peer_dd_ext)
        .build(Instant::now());
    let mut peer = Peer::new(peer_rtc);

    // Host candidates on both sides.
    sfu.rtc
        .add_local_candidate(
            Candidate::host((Ipv4Addr::new(1, 1, 1, 1), 1000).into(), "udp").unwrap(),
        )
        .unwrap();
    peer.rtc
        .add_local_candidate(
            Candidate::host((Ipv4Addr::new(2, 2, 2, 2), 2000).into(), "udp").unwrap(),
        )
        .unwrap();

    // Peer offers a video m-line (SendRecv). DD is video-only, so a video
    // media line is required for the DD extmap to be negotiated.
    let mut change = peer.rtc.sdp_api();
    let mid = change.add_media(MediaKind::Video, Direction::SendRecv, None, None, None);
    let (offer, pending) = change.apply().unwrap();

    // SFU accepts the offer; peer accepts the answer.
    let offer_str = offer.to_sdp_string();
    let offer_parsed = SdpOffer::from_sdp_string(&offer_str).expect("parse offer");
    let answer = sfu.rtc.sdp_api().accept_offer(offer_parsed)?;
    peer.rtc.sdp_api().accept_answer(pending, answer)?;

    // ── DE-RISK ASSERTION 1: URI-rebind ───────────────────────────────────
    // The SFU registered DD at local id 9, the peer offered it at id 14.
    // After answer, the SFU's REMOTE extmap (what the peer will send) must
    // have DD at id 14 — i.e. str0m rebinding our serializer by URI to the
    // peer's extmap id. This is the load-bearing P0 behaviour.
    let sfu_remote_exts = sfu.rtc.media(mid).unwrap().remote_extmap();
    assert_eq!(
        sfu_remote_exts
            .lookup(PEER_DD_EXTMAP_ID)
            .map(|e| e.as_uri()),
        Some(DD_URI),
        "SFU's remote extmap must have DD at the PEER's id {} (URI-rebind from local id {})",
        PEER_DD_EXTMAP_ID,
        DD_LOCAL_EXTMAP_ID,
    );
    // And the SFU's remote extmap must NOT have DD at the SFU's original
    // local id 9 — the rebind moved it to the peer's id 14.
    assert_ne!(
        sfu_remote_exts
            .lookup(DD_LOCAL_EXTMAP_ID)
            .map(|e| e.as_uri()),
        Some(DD_URI),
        "DD must have rebinding away from local id {}",
        DD_LOCAL_EXTMAP_ID,
    );

    // Convergence check: str0m's rebind makes the answerer (SFU) adopt the
    // offerer's extmap id, so the peer's remote extmap (the SFU's answer)
    // must ALSO have DD at 14 — both sides agree on the offerer's id.
    let peer_remote_exts = peer.rtc.media(mid).unwrap().remote_extmap();
    assert_eq!(
        peer_remote_exts
            .lookup(PEER_DD_EXTMAP_ID)
            .map(|e| e.as_uri()),
        Some(DD_URI),
        "peer's remote extmap must have DD at the converged id {} (SFU adopted the offerer's id)",
        PEER_DD_EXTMAP_ID,
    );

    // Drive the ICE/DTLS handshake to connected.
    let mut steps = 0;
    while !sfu.is_connected() && !peer.is_connected() {
        progress(&mut peer, &mut sfu)?;
        steps += 1;
        if steps > 200_000 {
            panic!("ICE/DTLS did not connect within step budget");
        }
    }
    // Sync the two clocks to the later of the two for the media phase.
    let max = peer.last.max(sfu.last);
    peer.last = max;
    sfu.last = max;

    // Resolve VP8 payload params on the peer (sender) side.
    let params = peer
        .rtc
        .codec_config()
        .find(|p| p.spec().codec == Codec::Vp8)
        .cloned()
        .expect("VP8 in default codec config");
    let pt = params.pt();

    // A synthetic DD payload — P0 does not bit-parse, so any non-empty bytes
    // prove the round-trip. Use a realistic-ish 4-byte DD stub.
    let dd_bytes = vec![0x10, 0x20, 0x30, 0x40];
    let media_payload = vec![0u8; 80];

    // Write media from the peer with the DD user extension value set.
    // Drive progress so the packet reaches the SFU.
    let mut saw_dd = false;
    let mut steps = 0;
    while peer.duration() < Duration::from_secs(3) {
        let wallclock = peer.start + peer.duration();
        let time = peer.duration().into();

        peer.rtc
            .writer(mid)
            .unwrap()
            .user_extension_value(DdPresent(dd_bytes.clone()))
            .write(pt, wallclock, time, media_payload.clone())?;

        progress(&mut peer, &mut sfu)?;

        // Check the SFU side for MediaData events carrying DdPresent.
        while let Some((_, ev)) = pop_event(&mut sfu) {
            if let Event::MediaData(d) = ev {
                let v = d.ext_vals.user_values.get::<DdPresent>();
                if let Some(dd) = v {
                    assert_eq!(
                        dd.0, dd_bytes,
                        "DD bytes must round-trip verbatim through the serializer",
                    );
                    saw_dd = true;
                }
            }
        }

        steps += 1;
        if steps > 200_000 {
            panic!("media phase did not complete within step budget");
        }
    }

    // ── DE-RISK ASSERTION 2: packet-level DD delivery ────────────────────
    assert!(
        saw_dd,
        "SFU must have received at least one MediaData with DdPresent populated \
         — str0m URI-rebind + DdSerializer parse seam works end-to-end",
    );

    Ok(())
}

/// Pop the oldest event from a peer's event queue (FIFO).
fn pop_event(p: &mut Peer) -> Option<(Instant, Event)> {
    if p.events.is_empty() {
        None
    } else {
        Some((p.last, p.events.remove(0)))
    }
}
