//! Test-only seam that builds a `Client` without real str0m SDP
//! negotiation. Used by `tests/multi_client.rs` to verify fanout
//! semantics in isolation.

use std::sync::Arc;
use std::time::Instant;

use str0m::format::{Codec, CodecExtra, CodecSpec, FormatParams, PayloadParams};
use str0m::media::{Frequency, MediaData, MediaKind, MediaTime, Mid, Pt, Rid};
use str0m::rtp::{ExtensionValues, SeqNo};
use str0m::Rtc;

use super::tracks::{TrackIn, TrackInEntry};
use super::Client;
use crate::metrics::SfuMetrics;
use crate::propagate::ClientId;

impl Client {
    /// Test-only: inject an observed "publisher-produced" RID without
    /// running the `track_in_media` path. Used by screenshare-like
    /// tests that want to pin `active_rids` to a subset of the full
    /// simulcast ladder before the pacer refreshes. Production code
    /// should never touch this field directly — `track_in_media`
    /// owns the canonical write.
    pub fn seed_active_rid_for_tests(&mut self, rid: Rid) {
        self.active_rids.insert(rid);
    }

    /// Test-only: mark the underlying str0m `Rtc` as disconnected so
    /// `Client::is_alive` returns false on the next poll. Needed for
    /// the `reap_dead` label-cleanup test — the real disconnect path
    /// requires an ICE/DTLS pipeline we don't set up in unit tests.
    pub fn disconnect_for_tests(&mut self) {
        self.rtc.disconnect();
    }

    /// Test-only: override the value that `handle_voice_data_out` reads from
    /// `ch.buffered_amount()`. Necessary because str0m's SCTP association is
    /// not live in unit tests — `buffered_amount()` always returns 0 without a
    /// real DTLS handshake, making the `buffered_amount_too_high` backpressure
    /// branch unreachable via the real path. Setting this above
    /// `VOICE_BUFFERED_AMOUNT_MAX` (64 KiB) lets tests exercise the drop path.
    pub fn set_buffered_amount_for_tests(&mut self, amount: usize) {
        self.buffered_amount_override = Some(amount);
    }
}

/// Build a fresh `Client` wrapping a default `Rtc`. The `Rtc` is
/// unnegotiated — writer calls inside `handle_media_data_out` will
/// no-op, but the `delivered_media` counter still ticks so fanout is
/// observable.
pub fn new_client(id: ClientId) -> Client {
    let rtc = Rtc::builder().build(Instant::now());
    let metrics = Arc::new(SfuMetrics::default());
    // Phase 2b: test seam mirrors the production browser path
    // (`udp_loop::serve` browser-inject arm) which chains
    // `Client::new(...).with_chat_dcs()`. Tests covering relay-only
    // scenarios still go through `Client::new_outbound_relay` and never
    // hit this seam, so the conflicting SCTP id 5 case is preserved.
    let mut c = Client::new(rtc, metrics).with_chat_dcs().with_voice_dc(200);
    c.id = id;
    c
}

/// Seed an incoming track on `client`, returning the `Arc<TrackIn>`
/// so the caller can `Arc::downgrade` it into every other client's
/// `tracks_out`.
pub fn seed_track_in(client: &mut Client, mid_tag: u8, kind: MediaKind) -> Arc<TrackIn> {
    let mid: Mid = Mid::from(&*format!("m{mid_tag}"));
    let entry = TrackInEntry {
        id: Arc::new(TrackIn {
            origin: client.id,
            mid,
            kind,
            external_peer_id: client.external_peer_id,
        }),
        last_keyframe_request: None,
    };
    let arc = entry.id.clone();
    client.tracks_in.push(entry);
    arc
}

/// Build a synthetic `MediaData` with the given mid tag and optional
/// rid — used by fanout / simulcast filter tests to inject packets
/// without running RTP packetization. The writer path early-returns
/// on unnegotiated `Rtc`, but the M1.3 layer filter in
/// [`super::fanout`] runs before any writer call, so tests observe
/// filter semantics purely via the `delivered_media` counter.
pub fn make_media_data(mid_tag: u8, rid: Option<Rid>) -> MediaData {
    let mid: Mid = Mid::from(&*format!("m{mid_tag}"));
    let pt = Pt::from(96u8);
    let seq: SeqNo = 0u64.into();
    let params = PayloadParams::new(
        pt,
        None,
        CodecSpec {
            codec: Codec::Vp8,
            clock_rate: Frequency::NINETY_KHZ,
            channels: None,
            format: FormatParams::default(),
        },
    );
    MediaData {
        mid,
        pt,
        rid,
        params,
        time: MediaTime::from_90khz(0),
        network_time: Instant::now(),
        seq_range: seq..=seq,
        data: vec![0xde, 0xad, 0xbe, 0xef],
        ext_vals: ExtensionValues::default(),
        codec_extra: CodecExtra::None,
        contiguous: true,
        last_sender_info: None,
        audio_start_of_talk_spurt: false,
    }
}
