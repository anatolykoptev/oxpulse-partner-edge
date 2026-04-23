//! `Client` construction — wraps a fresh `Rtc`, allocates a
//! process-unique `ClientId`, and initialises every field to its
//! zero-state default. Split from `client/mod.rs` so the main file
//! keeps its focus on the str0m poll/dispatch state machine.

use std::collections::{HashSet, VecDeque};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use str0m::channel::{ChannelConfig, Reliability};
use str0m::Rtc;

use super::{layer, Client};
use crate::metrics::SfuMetrics;
use crate::propagate::ClientId;

fn next_client_id() -> ClientId {
    static ID_COUNTER: AtomicU64 = AtomicU64::new(0);
    ClientId(ID_COUNTER.fetch_add(1, Ordering::SeqCst))
}

impl Client {
    /// Wrap a freshly-created [`Rtc`] instance.
    ///
    /// Opens the pre-negotiated `sfu-active-speaker` DC at SCTP stream id 3
    /// before any SDP offer/answer, which locks in the id before the client
    /// can race on the wire. Client side opens a symmetric DC with
    /// `{ negotiated: true, id: 3 }`; the DC becomes usable once DTLS is up.
    pub fn new(mut rtc: Rtc, metrics: Arc<SfuMetrics>) -> Self {
        let active_speaker_cid = rtc.direct_api().create_data_channel(ChannelConfig {
            label: "sfu-active-speaker".to_string(),
            ordered: true,
            reliability: Reliability::Reliable,
            negotiated: Some(3),
            protocol: String::new(),
        });
        Self {
            id: next_client_id(),
            rtc,
            tracks_in: Vec::new(),
            tracks_out: Vec::new(),
            chosen_rid: None,
            desired_layer: layer::LOW,
            active_rids: HashSet::new(),
            pending_out: VecDeque::new(),
            metrics,
            delivered_media: AtomicU64::new(0),
            #[cfg(any(test, feature = "test-utils"))]
            delivered_active_speaker: AtomicU64::new(0),
            active_speaker_cid,
            origin: oxpulse_sfu_kit::ClientOrigin::Local,
            #[cfg(feature = "vfm")]
            max_vfm_temporal_layer: u8::MAX,
        }
    }
}
