//! Test-only seam that builds a `Client` without real str0m SDP
//! negotiation. Used by `tests/multi_client.rs` to verify fanout
//! semantics in isolation.

use std::sync::Arc;
use std::time::Instant;

use str0m::format::{
    Codec, CodecExtra, CodecSpec, FormatParams, PayloadParams, Vp8CodecExtra, Vp9CodecExtra,
};
use str0m::media::{Frequency, MediaData, MediaKind, MediaTime, Mid, Pt, Rid};
use str0m::rtp::{ExtensionValues, SeqNo};
use str0m::Rtc;

use super::tracks::{TrackIn, TrackInEntry};
use super::Client;
use crate::metrics::SfuMetrics;
use crate::propagate::ClientId;

impl Client {
    /// Test-only: whether `ws_msg_tx` is `None`.
    ///
    /// The field is `pub(crate)` so integration tests in `tests/` (a separate
    /// crate) cannot access it directly. This accessor is the minimum-invasive
    /// alternative to making the field `pub` — tests only need to assert absence
    /// of the channel in the legacy path, not inspect its value.
    pub fn ws_msg_tx_is_none(&self) -> bool {
        self.ws_msg_tx.is_none()
    }

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
///
/// Opens chat and voice DCs (mirrors the production browser path) but
/// does NOT open the reactions DC. Tests that exercise reactions fan-out
/// or the reactions gauge must use [`new_client_with_reactions`] instead.
/// This separation matches the relay/relay-tests path which skips
/// reactions fan-out on cascade edges.
pub fn new_client(id: ClientId) -> Client {
    let rtc = Rtc::builder().build(Instant::now());
    let metrics = Arc::new(SfuMetrics::default());
    // Phase 2b: test seam mirrors the production browser path
    // (`udp_loop::serve` browser-inject arm) which chains
    // `Client::new(...).with_chat_dcs()`. Tests covering relay-only
    // scenarios still go through `Client::new_outbound_relay` and never
    // hit this seam, so the conflicting SCTP id 5 case is preserved.
    let mut c = Client::new(rtc, metrics)
        .with_keys_dc()
        .with_chat_dcs()
        .with_voice_dc(200)
        .with_sfu_events_dc();
    c.id = id;
    c
}

/// Build a fresh `Client` that also opens the pre-negotiated reactions DC
/// (id:7, `reactions-group`). Use for tests that exercise reactions fan-out,
/// reactions gauge scrub on reap/steal, or the `Event::ChannelOpen` path for
/// DC id:7. All other tests should use [`new_client`] to keep the common test
/// path relay-compatible (relay clients skip the reactions DC).
pub fn new_client_with_reactions(id: ClientId) -> Client {
    let rtc = Rtc::builder().build(Instant::now());
    let metrics = Arc::new(SfuMetrics::default());
    let mut c = Client::new(rtc, metrics)
        .with_keys_dc()
        .with_chat_dcs()
        .with_voice_dc(200)
        .with_reactions_dc()
        .with_sfu_events_dc();
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
        // str0m 0.21: MediaData.data is now Arc<[u8]> (was Vec<u8>).
        data: vec![0xde, 0xad, 0xbe, 0xef].into(),
        ext_vals: ExtensionValues::default(),
        codec_extra: CodecExtra::None,
        contiguous: true,
        last_sender_info: None,
        audio_start_of_talk_spurt: false,
    }
}

/// Build a synthetic `MediaData` whose `is_keyframe()` returns `true`.
/// Uses `CodecExtra::Vp8` with `is_keyframe: true` — the codec-agnostic
/// `MediaData::is_keyframe()` checks this field. Used by the issue #618
/// keyframe-wait tests to simulate a publisher sending a keyframe after
/// a PLI request.
pub fn make_media_data_keyframe(mid_tag: u8, rid: Option<Rid>) -> MediaData {
    let mut data = make_media_data(mid_tag, rid);
    data.codec_extra = CodecExtra::Vp8(Vp8CodecExtra {
        discardable: false,
        sync: false,
        layer_index: 0,
        picture_id: Some(0),
        tl0_picture_id: Some(0),
        is_keyframe: true,
    });
    data
}

/// Build a synthetic `MediaData` with a VP9 codec where `is_keyframe()`
/// returns `false` — simulates an SFrame-encrypted VP9 stream where
/// str0m cannot detect keyframes from the ciphertext payload. The
/// `params.spec().codec` is `Codec::Vp9` so the keyframe-wait loop can
/// identify the codec and short-circuit with `codec_unobservable`.
pub fn make_media_data_vp9(mid_tag: u8, rid: Option<Rid>) -> MediaData {
    let mid: Mid = Mid::from(&*format!("m{mid_tag}"));
    let pt = Pt::from(96u8);
    let seq: SeqNo = 0u64.into();
    let params = PayloadParams::new(
        pt,
        None,
        CodecSpec {
            codec: Codec::Vp9,
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
        data: vec![0xde, 0xad, 0xbe, 0xef].into(),
        ext_vals: ExtensionValues::default(),
        // Vp9CodecExtra::default() has is_keyframe: false — str0m cannot
        // detect the keyframe bit under SFrame (ciphertext payload).
        codec_extra: CodecExtra::Vp9(Vp9CodecExtra::default()),
        contiguous: true,
        last_sender_info: None,
        audio_start_of_talk_spurt: false,
    }
}
