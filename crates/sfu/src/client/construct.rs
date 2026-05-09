//! `Client` construction — wraps a fresh `Rtc`, allocates a
//! process-unique `ClientId`, and initialises every field to its
//! zero-state default. Split from `client/mod.rs` so the main file
//! keeps its focus on the str0m poll/dispatch state machine.

use std::collections::{HashSet, VecDeque};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use str0m::channel::{ChannelConfig, Reliability};
use str0m::Rtc;
use tokio::sync::oneshot;

use super::{layer, Client, CloseReason};
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
        // Phase 2b chat-data (id:4) + chat-ctrl (id:5) DCs are opened
        // separately via `with_chat_dcs()` — the relay code path
        // (`relay/client.rs`) pre-opens id=5 as `sfu-relay-source` on the
        // outbound rtc *before* `Self::new` runs, and calling
        // `direct_api().create_data_channel(... id=5)` here would panic
        // with "sctp_stream_id (5) exists already". Browser construction
        // sites chain `Client::new(rtc, metrics).with_chat_dcs()`; relay
        // construction sites do not — cascade SFU edges have no UI chat.
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
            layer_passed: AtomicU64::new(0),
            #[cfg(any(test, feature = "test-utils"))]
            delivered_active_speaker: AtomicU64::new(0),
            #[cfg(any(test, feature = "test-utils"))]
            last_active_speaker_payload: std::sync::Mutex::new(None),
            #[cfg(any(test, feature = "test-utils"))]
            buffered_amount_override: None,
            active_speaker_cid,
            chat_data_cid: None,
            chat_ctrl_cid: None,
            voice_data_cid: None,
            relay_source_pending: None,
            origin: oxpulse_sfu_kit::ClientOrigin::Local,
            relay_auth_secret: None,
            relay_signing_pubkey: None,
            #[cfg(feature = "vfm")]
            max_vfm_temporal_layer: u8::MAX,
            // Phase J M2 — all None/empty at construction; populated by
            // with_ws_msg_tx / with_ws_ctrl_rx in the browser inject arm.
            ws_msg_tx: None,
            ws_ctrl_rx: None,
            pending_offer: None,
            pending_offer_at: None,
            renegotiation_queue: std::collections::VecDeque::new(),
            // Phase A Task A1 — defaults are `None`. The browser
            // injection path (`udp_loop::serve` `client_inject_rx` arm)
            // calls `with_external_peer_id` and `with_close_signal`
            // before insertion; relay clients leave them `None` and are
            // not subject to peer-id steal.
            external_peer_id: None,
            close_signal: None,
        }
    }

    /// Phase 2b: open the pre-negotiated chat-data (id:4, reliable,
    /// ordered) + chat-ctrl (id:5, !ordered, `MaxRetransmits{0}`) DCs
    /// so this client participates in browser-side chat fanout. Browser
    /// construction sites in `udp_loop::serve` call this after
    /// [`Client::new`]; cascade relay clients skip it because
    /// `relay/client.rs` already owns SCTP stream id 5 for
    /// `sfu-relay-source` on the outbound rtc and a second create on
    /// id 5 would panic with `sctp_stream_id (5) exists already`.
    ///
    /// `MaxRetransmits{0}` semantics on str0m 0.18.1 are confirmed at
    /// `src/sctp/mod.rs:187-200` — partial reliability is wired through
    /// `set_reliability_params()` at `:214` without any fork.
    pub fn with_chat_dcs(mut self) -> Self {
        let chat_data_cid = self.rtc.direct_api().create_data_channel(ChannelConfig {
            label: "chat-data".to_string(),
            ordered: true,
            reliability: Reliability::Reliable,
            negotiated: Some(4),
            protocol: String::new(),
        });
        let chat_ctrl_cid = self.rtc.direct_api().create_data_channel(ChannelConfig {
            label: "chat-ctrl".to_string(),
            ordered: false,
            reliability: Reliability::MaxRetransmits { retransmits: 0 },
            negotiated: Some(5),
            protocol: String::new(),
        });
        self.chat_data_cid = Some(chat_data_cid);
        self.chat_ctrl_cid = Some(chat_ctrl_cid);
        self.metrics
            .chat_relay_active_channels
            .with_label_values(&["data"])
            .inc();
        self.metrics
            .chat_relay_active_channels
            .with_label_values(&["ctrl"])
            .inc();
        self
    }

    /// Phase 8 T10: open the pre-negotiated voice DC (id:6, unordered,
    /// `MaxPacketLifetime{max_pkt_lifetime_ms}`). Browser construction
    /// sites in `udp_loop::serve` call this after [`Client::with_chat_dcs`];
    /// cascade relay clients skip it because they have no UI voice path.
    ///
    /// `max_pkt_lifetime_ms` — recommended value 200 ms (voice frames
    /// older than that are useless and should be discarded).
    pub fn with_voice_dc(mut self, max_pkt_lifetime_ms: u16) -> Self {
        let voice_data_cid = self.rtc.direct_api().create_data_channel(ChannelConfig {
            label: "voice".to_string(),
            ordered: false,
            reliability: Reliability::MaxPacketLifetime {
                lifetime: max_pkt_lifetime_ms,
            },
            negotiated: Some(6),
            protocol: String::new(),
        });
        self.voice_data_cid = Some(voice_data_cid);
        self.metrics
            .voice_relay_active_channels
            .with_label_values(&["voice"])
            .inc();
        self
    }

    /// Phase A Task A1: tag this client with the JWT `sub` from the
    /// signaling token so [`crate::registry::Registry::insert`] can
    /// dedupe by `(room_id, peer_id)`.
    ///
    /// Browser path only — relay clients pass through their own identity
    /// scheme (`upstream_url`) and must NOT be tagged here.
    pub fn with_external_peer_id(mut self, peer_id: u64) -> Self {
        self.external_peer_id = Some(peer_id);
        self
    }

    /// Phase A Task A1: install the channel the registry will use to
    /// signal a session-steal eviction. The corresponding receiver is
    /// held by the WS task (`client_ws::session::run`), which selects
    /// on it and translates [`CloseReason`] into the wire-level close.
    ///
    /// Idempotent in the sense that Drop on the sender simply closes
    /// the receiver — the WS task observes that as `Err(_)` and falls
    /// back to its normal close path.
    pub fn with_close_signal(mut self, tx: oneshot::Sender<CloseReason>) -> Self {
        self.close_signal = Some(tx);
        self
    }

    /// Phase J M2: attach the WS sender for outbound messages to the browser
    /// (currently: offer-renegotiate JSON frames). `None` for relay clients
    /// and test `new_client` — they have no WS channel.
    pub fn with_ws_msg_tx(mut self, tx: tokio::sync::mpsc::Sender<String>) -> Self {
        self.ws_msg_tx = Some(tx);
        self
    }

    /// Phase J M2: attach the WS control receiver for inbound browser replies
    /// (currently: answer-renegotiate). Called by the UDP loop after inject.
    pub fn with_ws_ctrl_rx(
        mut self,
        rx: tokio::sync::mpsc::Receiver<crate::client_ws::WsClientCtrl>,
    ) -> Self {
        self.ws_ctrl_rx = Some(rx);
        self
    }

    /// Construct an outbound relay client from a [`crate::relay::client::PendingRelay`].
    ///
    /// Sets `origin` to `RelayFromSfu` immediately — we know we're a relay at
    /// construction time. Stores `relay_source_pending` so `dispatch.rs` sends
    /// the DC announcement to upstream once `Event::Connected` fires.
    pub fn new_outbound_relay(
        pending: crate::relay::client::PendingRelay,
        metrics: Arc<SfuMetrics>,
    ) -> Self {
        let upstream_url = pending.upstream_url.clone();
        let mut client = Self::new(pending.rtc, metrics);
        client.origin = oxpulse_sfu_kit::ClientOrigin::RelayFromSfu(upstream_url);
        client.relay_source_pending = Some((
            pending.dc_id,
            pending.upstream_url,
            pending.upstream_room_token,
        ));
        client
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::relay::client::PendingRelay;
    use std::sync::Arc;

    fn make_pending() -> PendingRelay {
        let mut rtc = str0m::Rtc::new(std::time::Instant::now());
        let dc_id = rtc
            .direct_api()
            .create_data_channel(str0m::channel::ChannelConfig {
                label: "test-relay".to_string(),
                ordered: true,
                reliability: str0m::channel::Reliability::Reliable,
                negotiated: Some(5),
                protocol: String::new(),
            });
        PendingRelay {
            rtc,
            room_id: "room-1".to_string(),
            upstream_url: "wss://eu.oxpulse.chat/ws/sfu/room-1".to_string(),
            upstream_room_token: "tok".to_string(),
            dc_id,
        }
    }

    #[test]
    fn new_outbound_relay_sets_relay_origin() {
        let client = Client::new_outbound_relay(
            make_pending(),
            Arc::new(crate::metrics::SfuMetrics::default()),
        );
        assert!(
            client.is_relay(),
            "outbound relay client must have RelayFromSfu origin"
        );
    }

    #[test]
    fn new_outbound_relay_has_pending_dc_message() {
        let client = Client::new_outbound_relay(
            make_pending(),
            Arc::new(crate::metrics::SfuMetrics::default()),
        );
        assert!(
            client.relay_source_pending.is_some(),
            "relay_source_pending must be set for outbound relay"
        );
        let (_, url, token) = client.relay_source_pending.as_ref().unwrap();
        assert_eq!(url, "wss://eu.oxpulse.chat/ws/sfu/room-1");
        assert_eq!(token, "tok");
    }

    #[test]
    fn new_browser_client_has_no_pending() {
        let rtc = str0m::Rtc::new(std::time::Instant::now());
        let client = Client::new(rtc, Arc::new(crate::metrics::SfuMetrics::default()));
        assert!(!client.is_relay());
        assert!(client.relay_source_pending.is_none());
    }
}
