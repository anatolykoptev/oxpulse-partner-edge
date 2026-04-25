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
use str0m::media::{KeyframeRequestKind, MediaData, MediaKind, Mid};
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
                tracing::warn!(client = *self.id, error = ?e, "poll_output failed");
                self.rtc.disconnect();
                Propagated::Noop
            }
        }
    }

    fn handle_output(&mut self, output: Output) -> Propagated {
        match output {
            Output::Transmit(t) => {
                self.pending_out.push_back(t);
                Propagated::Noop
            }
            Output::Timeout(t) => Propagated::Timeout(t),
            Output::Event(e) => self.handle_event(e),
        }
    }

    fn handle_event(&mut self, event: Event) -> Propagated {
        match event {
            Event::IceConnectionStateChange(IceConnectionState::Disconnected) => {
                self.rtc.disconnect();
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
            Event::MediaAdded(m) => self.track_in_added(m.mid, m.kind),
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
                dc::handle_channel_data(
                    self.id,
                    &label,
                    &data,
                    self.relay_auth_secret.as_deref(),
                    self.relay_signing_pubkey.as_deref().map(|s| s.as_str()),
                )
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
}
