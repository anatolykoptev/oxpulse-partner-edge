//! str0m event dispatch for [`Client`].
//!
//! Owns `poll_output` → `handle_output` → `handle_event` and the two
//! private helpers `track_in_added` / `track_in_media`. Split from
//! [`super`] when M5.4.1 DC-ingestion additions pushed `mod.rs` past
//! the 200-line target. The concern here is: "what does the client do
//! with each str0m Output/Event?" — a distinct concern from the struct
//! definition and accessor surface in `mod.rs`.

use std::sync::Arc;

use str0m::bwe::BweKind;
use str0m::channel::ChannelData;
use str0m::media::{Direction, KeyframeRequestKind, MediaData, MediaKind, Mid};
use str0m::{Event, IceConnectionState, Output};

use super::dc;
use super::tracks::{TrackIn, TrackInEntry};
use super::Client;
use crate::propagate::Propagated;

impl Client {
    /// Drive str0m forward one step. Outbound UDP is appended to
    /// `pending_out`; the registry drains it between polls.
    pub fn poll_output(&mut self) -> Propagated {
        if !self.rtc.is_alive() {
            return Propagated::Noop;
        }
        match self.rtc.poll_output() {
            Ok(output) => self.handle_output(output),
            Err(e) => {
                // Error from str0m poll_output — bump the str0m output error
                // counter so rate(sfu_str0m_output_total{kind="error"}[1m]) > 0
                // alerts fire without requiring log monitoring.
                let peer_label = (*self.id).to_string();
                self.metrics
                    .sfu_str0m_output_total
                    .with_label_values(&[&peer_label, "error"])
                    .inc();
                tracing::warn!(client = *self.id, error = ?e, "poll_output failed");
                self.rtc.disconnect();
                Propagated::Noop
            }
        }
    }

    fn handle_output(&mut self, output: Output) -> Propagated {
        // str0m output distribution tap. Labelled by peer_id and kind so
        // operators can see per-peer transmit rates, event frequencies, and
        // error counts without log mining.
        //
        // kind ∈ {transmit, timeout, event_ice, event_media_added,
        //         event_media_data, event_keyframe_req, event_bwe,
        //         event_channel, event_other}
        //
        // Note: we label Output::Event sub-variants individually so the
        // "transmit rate drop" alert (kind=transmit → 0) is distinct from
        // "media stream stopped" (kind=event_media_data → 0).
        let peer_label = (*self.id).to_string();
        let kind_label = match &output {
            Output::Transmit(_) => "transmit",
            Output::Timeout(_) => "timeout",
            Output::Event(Event::IceConnectionStateChange(_)) => "event_ice",
            Output::Event(Event::MediaAdded(_)) => "event_media_added",
            Output::Event(Event::MediaData(_)) => "event_media_data",
            Output::Event(Event::KeyframeRequest(_)) => "event_keyframe_req",
            Output::Event(Event::EgressBitrateEstimate(_)) => "event_bwe",
            Output::Event(Event::ChannelData(_)) => "event_channel",
            Output::Event(Event::Connected) => "event_connected",
            Output::Event(_) => "event_other",
        };
        self.metrics
            .sfu_str0m_output_total
            .with_label_values(&[&peer_label, kind_label])
            .inc();

        match output {
            Output::Transmit(t) => {
                self.pending_out.push_back(t);
                Propagated::Noop
            }
            Output::Timeout(t) => Propagated::Timeout(t),
            Output::Event(e) => self.handle_event(e),
        }
    }

    pub fn handle_event(&mut self, event: Event) -> Propagated {
        match event {
            // 2026-05-07 metric coverage audit: track ALL ICE state transitions,
            // not only Disconnected.  The counter lets operators distinguish a
            // peer that never reached Connected (checking → disconnect = NAT hole
            // failure) from one that connected and then dropped (connected →
            // disconnected = mid-call network loss).
            //
            // SAFETY: keep this as a full match on `s` rather than a wildcard
            // arm on the original Disconnected-only pattern.  The IceConnectionState
            // enum has no `Failed` / `Closed` variants in str0m 0.18; `other` here
            // is a deliberate catch-all for future enum expansion — collapsing
            // novel states into a single label preserves bounded cardinality.
            Event::IceConnectionStateChange(s) => {
                // `#[allow(unreachable_patterns)]`: str0m 0.18 exposes exactly
                // New/Checking/Connected/Completed/Disconnected so the wildcard
                // is unreachable today.  It is intentionally kept for forward
                // compatibility — if a future str0m bump adds a new variant the
                // counter continues to work with bounded cardinality rather than
                // causing a compile error or an unhandled match.
                #[allow(unreachable_patterns)]
                let label = match s {
                    IceConnectionState::New => "new",
                    IceConnectionState::Checking => "checking",
                    IceConnectionState::Connected => "connected",
                    IceConnectionState::Completed => "completed",
                    IceConnectionState::Disconnected => "disconnected",
                    _ => "other",
                };
                self.metrics
                    .ice_state_total
                    .with_label_values(&[label])
                    .inc();
                if matches!(s, IceConnectionState::Disconnected) {
                    self.rtc.disconnect();
                }
                Propagated::Noop
            }
            Event::Connected => {
                tracing::info!(peer_id = *self.id, "WebRTC connected");
                // For outbound relay clients: announce ourselves to the upstream SFU
                // so it marks our connection as RelayFromSfu and excludes us from
                // its speaker election. relay_source_pending is None for browser clients.
                if let Some((dc_id, upstream_url, room_token)) = self.relay_source_pending.take() {
                    use crate::relay::client::relay_source_message;
                    match self.rtc.channel(dc_id) {
                        Some(mut ch) => {
                            let msg = relay_source_message(&upstream_url, &room_token);
                            if let Err(e) = ch.write(false, msg.as_bytes()) {
                                tracing::warn!(error = %e, upstream = %upstream_url,
                                    "relay: failed to write relay_source DC message");
                            } else {
                                tracing::info!(upstream = %upstream_url,
                                    "relay: sent relay_source DC message to upstream");
                            }
                        }
                        None => {
                            // DC not open yet — SCTP negotiation can lag behind DTLS.
                            // The upstream will still receive relay_source once the DC opens.
                            tracing::warn!(upstream = %upstream_url,
                                "relay: DC not open at Event::Connected — relay_source deferred");
                        }
                    }
                }
                Propagated::Noop
            }
            Event::MediaAdded(m) => {
                // B2: explicit match on direction instead of is_sending().
                // is_sending() returns true for BOTH SendOnly AND SendRecv,
                // which would silently swallow a SendRecv event that should
                // also create a TrackIn. Explicit match eliminates the ambiguity.
                match m.direction {
                    Direction::SendOnly => {
                        // This is one of OUR send-only m-lines that just completed
                        // negotiation (renegotiation answer accepted by str0m).
                        // Walk tracks_out, find the Negotiating(mid) entry, flip to Open.
                        let mut transitioned = false;
                        for track_out in &mut self.tracks_out {
                            if let crate::client::tracks::TrackOutState::Negotiating(neg_mid) =
                                track_out.state
                            {
                                if neg_mid == m.mid {
                                    track_out.state =
                                        crate::client::tracks::TrackOutState::Open(neg_mid);
                                    self.metrics
                                        .sfu_track_out_state_transitions_total
                                        .with_label_values(&["negotiating", "open"])
                                        .inc();
                                    tracing::debug!(
                                        client = *self.id,
                                        mid = ?m.mid,
                                        "M2: TrackOut Negotiating → Open"
                                    );
                                    transitioned = true;
                                    break;
                                }
                            }
                        }
                        if !transitioned {
                            tracing::warn!(
                                client = *self.id,
                                mid = ?m.mid,
                                "M2: Event::MediaAdded SendOnly but no Negotiating(mid) track found"
                            );
                        }
                        Propagated::Noop
                    }
                    // RecvOnly / SendRecv / Inactive — a remote peer started sending;
                    // add TrackIn. SendRecv must also create a TrackIn so the
                    // subscriber side is wired even when str0m emits SendRecv
                    // for a newly added m-line.
                    Direction::RecvOnly | Direction::SendRecv | Direction::Inactive => {
                        self.track_in_added(m.mid, m.kind)
                    }
                }
            }
            Event::MediaData(data) => self.track_in_media(data),
            Event::KeyframeRequest(req) => self.incoming_keyframe_req(req),
            // M5.3: forward str0m's own GCC estimate to the registry so
            // the shared `BandwidthEstimator` can use it as a ceiling.
            Event::EgressBitrateEstimate(BweKind::Twcc(bitrate)) => {
                Propagated::BandwidthEstimate(self.id, bitrate.as_u64())
            }
            // M5.4.1: browser-reported bandwidth budget from DC id:2.
            // Resolve the label first (requires &mut Rtc) before calling
            // the pure dc handler, to avoid a simultaneous mut+shared borrow.
            Event::ChannelData(ChannelData { id, data, .. }) => {
                let label = self
                    .rtc
                    .channel(id)
                    .and_then(|ch| ch.config().map(|c| c.label.clone()))
                    .unwrap_or_default();
                let result = dc::handle_channel_data(
                    self.id,
                    &label,
                    &data,
                    self.relay_auth_secret.as_deref(),
                    self.relay_signing_pubkey.as_deref().map(|s| s.as_str()),
                );
                // MAJOR-1: inbound oversize voice frame — emit the
                // `frame_malformed` drop counter at the dispatch callsite.
                // `handle_channel_data` returns Noop for voice-channel
                // oversize (defence-in-depth gate in dc.rs:~180) without
                // touching metrics because that function is pure (no metrics
                // param). The label is already resolved here, so this is the
                // cheapest place to close the gap. Adversarial senders that
                // flood > 64 KB frames are now visible to alerting.
                if label == "voice" && matches!(result, Propagated::Noop) {
                    // Only emit when data actually exceeds the cap — if
                    // handle_channel_data returned Noop for a different reason
                    // (e.g. the VoiceData payload was fine but some other branch
                    // rejected it) we would over-count. Guard with the same
                    // constant used inside dc.rs.
                    if data.len() > super::voice::VOICE_FRAME_MAX_BYTES {
                        self.metrics
                            .voice_relay_dropped
                            .with_label_values(&["frame_malformed"])
                            .inc();
                    }
                }
                result
            }
            _ => Propagated::Noop,
        }
    }

    fn track_in_added(&mut self, mid: Mid, kind: MediaKind) -> Propagated {
        let entry = TrackInEntry {
            id: Arc::new(TrackIn {
                origin: self.id,
                mid,
                kind,
            }),
            last_keyframe_request: None,
        };
        let weak = Arc::downgrade(&entry.id);
        self.tracks_in.push(entry);
        Propagated::TrackOpen(self.id, weak)
    }

    fn track_in_media(&mut self, data: MediaData) -> Propagated {
        if !data.contiguous {
            self.request_keyframe_throttled(data.mid, data.rid, KeyframeRequestKind::Fir);
        }
        // M5.3 fix-round: accumulate the set of simulcast RIDs this peer
        // has produced. `Registry::update_pacer_layers` passes this down
        // to `pacer.preferred_rid` so screenshare publishers (typically
        // one low layer only) don't have subscribers selecting a tier
        // the publisher never emits. Non-simulcast senders leave `rid`
        // as `None` and fall through on the filter side anyway.
        if let Some(rid) = data.rid {
            self.active_rids.insert(rid);
        }
        Propagated::MediaData(self.id, data)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::relay::client::PendingRelay;
    use std::sync::Arc;

    // ── ICE state metrics (2026-05-07 observability gap) ─────────────────────

    /// Each known ICE state maps to the correct `sfu_ice_state_total` label
    /// and increments by exactly 1.  Previously only `Disconnected` was
    /// handled; `Checking` / `Connected` / `Completed` were silent.
    #[test]
    fn ice_state_counter_increments_for_each_variant() {
        use crate::client::test_seed::new_client;
        use crate::propagate::ClientId;

        let metrics = Arc::new(crate::metrics::SfuMetrics::new().expect("metrics build"));
        let mut client = new_client(ClientId(800));
        // Override client's metrics with our observable instance.
        client.metrics = metrics.clone();

        let cases = [
            (IceConnectionState::New, "new"),
            (IceConnectionState::Checking, "checking"),
            (IceConnectionState::Connected, "connected"),
            (IceConnectionState::Completed, "completed"),
            (IceConnectionState::Disconnected, "disconnected"),
        ];
        for (state, label) in cases {
            let before = metrics.ice_state_total.with_label_values(&[label]).get();
            client.handle_event(Event::IceConnectionStateChange(state));
            let after = metrics.ice_state_total.with_label_values(&[label]).get();
            assert_eq!(
                after,
                before + 1,
                "ice_state_total{{state=\"{label}\"}} must increment by 1 for {:?}",
                state,
            );
        }
    }

    /// Only `Disconnected` must call `rtc.disconnect()`; all other
    /// transitions must leave the `Rtc` alive.
    #[test]
    fn only_disconnected_calls_rtc_disconnect() {
        use crate::client::test_seed::new_client;
        use crate::propagate::ClientId;

        let metrics = Arc::new(crate::metrics::SfuMetrics::new().expect("metrics build"));

        for state in [
            IceConnectionState::New,
            IceConnectionState::Checking,
            IceConnectionState::Connected,
            IceConnectionState::Completed,
        ] {
            let mut client = new_client(ClientId(801));
            client.metrics = metrics.clone();
            assert!(client.rtc.is_alive(), "rtc must be alive before transition");
            client.handle_event(Event::IceConnectionStateChange(state));
            assert!(
                client.rtc.is_alive(),
                "rtc must stay alive after {:?} — only Disconnected disconnects",
                state,
            );
        }

        let mut client = new_client(ClientId(802));
        client.metrics = metrics.clone();
        assert!(client.rtc.is_alive());
        client.handle_event(Event::IceConnectionStateChange(
            IceConnectionState::Disconnected,
        ));
        assert!(
            !client.rtc.is_alive(),
            "rtc must be dead after Disconnected — rtc.disconnect() must have been called"
        );
    }

    // ── existing tests ────────────────────────────────────────────────────────

    #[test]
    fn relay_source_pending_cleared_on_connected() {
        // Build an outbound relay client with relay_source_pending set
        let mut rtc = str0m::Rtc::new(std::time::Instant::now());
        let dc_id = rtc
            .direct_api()
            .create_data_channel(str0m::channel::ChannelConfig {
                label: "test-relay-src".to_string(),
                ordered: true,
                reliability: str0m::channel::Reliability::Reliable,
                negotiated: Some(5),
                protocol: String::new(),
            });
        let pending = PendingRelay {
            rtc,
            room_id: "r".to_string(),
            upstream_url: "wss://eu.oxpulse.chat/ws/sfu/r".to_string(),
            upstream_room_token: "tok".to_string(),
            dc_id,
        };
        let mut client =
            Client::new_outbound_relay(pending, Arc::new(crate::metrics::SfuMetrics::default()));
        assert!(
            client.relay_source_pending.is_some(),
            "must be set before Connected"
        );

        // Fire Event::Connected
        client.handle_event(Event::Connected);

        // relay_source_pending must be cleared regardless of whether DC was open
        assert!(
            client.relay_source_pending.is_none(),
            "must be cleared after Connected"
        );
    }

    // ── M2 B2: MediaAdded direction dispatch ─────────────────────────────────

    /// B2 regression: `Event::MediaAdded { direction: SendRecv }` must create
    /// a `tracks_in` entry (not silently swallow the event as a state flip).
    /// Previously `is_sending()` returned true for SendRecv, causing the else
    /// branch (track_in_added) to be skipped.
    #[test]
    fn media_added_send_recv_creates_track_in() {
        use crate::client::test_seed::new_client;
        use crate::propagate::ClientId;
        use str0m::media::{Direction, MediaAdded, MediaKind, Mid};

        let mut client = new_client(ClientId(900));
        let mid = Mid::from("m1");

        // Simulate Event::MediaAdded { direction: SendRecv }
        let event = Event::MediaAdded(MediaAdded {
            mid,
            kind: MediaKind::Video,
            direction: Direction::SendRecv,
            simulcast: None,
        });
        client.handle_event(event);

        // Must have created a TrackIn entry — NOT treated as a state flip.
        assert_eq!(
            client.tracks_in.len(),
            1,
            "SendRecv MediaAdded must call track_in_added (creates a TrackIn)"
        );
    }

    /// B2 regression: `Event::MediaAdded { direction: RecvOnly }` must create
    /// a `tracks_in` entry (baseline: existing behaviour must stay correct).
    #[test]
    fn media_added_recv_only_creates_track_in() {
        use crate::client::test_seed::new_client;
        use crate::propagate::ClientId;
        use str0m::media::{Direction, MediaAdded, MediaKind, Mid};

        let mut client = new_client(ClientId(901));
        let mid = Mid::from("m2");

        let event = Event::MediaAdded(MediaAdded {
            mid,
            kind: MediaKind::Audio,
            direction: Direction::RecvOnly,
            simulcast: None,
        });
        client.handle_event(event);

        assert_eq!(
            client.tracks_in.len(),
            1,
            "RecvOnly MediaAdded must call track_in_added"
        );
    }

    /// B2 regression: `Event::MediaAdded { direction: SendOnly }` must NOT
    /// create a `tracks_in` entry — it's our outbound track completing negotiation.
    /// With an empty `tracks_out`, the transitioned flag stays false and a warn
    /// is logged (observable via tracing subscriber in integration), but no panic.
    #[test]
    fn media_added_send_only_does_not_create_track_in() {
        use crate::client::test_seed::new_client;
        use crate::propagate::ClientId;
        use str0m::media::{Direction, MediaAdded, MediaKind, Mid};

        let mut client = new_client(ClientId(902));
        let mid = Mid::from("m3");

        let event = Event::MediaAdded(MediaAdded {
            mid,
            kind: MediaKind::Video,
            direction: Direction::SendOnly,
            simulcast: None,
        });
        client.handle_event(event);

        assert_eq!(
            client.tracks_in.len(),
            0,
            "SendOnly MediaAdded must NOT call track_in_added (not a remote track)"
        );
    }
}
