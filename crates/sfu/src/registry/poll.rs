//! Registry poll loop, tick, and fanout — the "drive forward" concern.
//!
//! Split from [`super`] when M5.4.1 additions pushed `mod.rs` past 200
//! lines. Owns: [`Registry::poll_all`], [`Registry::tick`],
//! [`Registry::tick_active_speaker`], [`Registry::fanout_pending`].

use std::time::Instant;

use str0m::media::Rid;
use str0m::Input;

use crate::client::layer;
use crate::fanout::fanout;
use crate::propagate::Propagated;

use super::Registry;

impl Registry {
    /// Poll every client until each returns a `Timeout`, queuing
    /// propagated events. Returns the earliest wake-up deadline.
    pub fn poll_all(&mut self, now: Instant) -> Instant {
        let mut deadline = now + std::time::Duration::from_millis(100);
        for client in self.clients.iter_mut() {
            loop {
                if !client.is_alive() {
                    break;
                }
                match client.poll_output() {
                    Propagated::Timeout(t) => {
                        deadline = deadline.min(t);
                        break;
                    }
                    Propagated::Noop => continue,
                    other => {
                        // Feed RFC 6464 audio-level into the detector. str0m
                        // stores the level as a negated i8 in [-127, 0] — 0
                        // silent, -127 loudest. `ActiveSpeakerDetector` wants
                        // 0..127 where 0 is loudest (mediasoup convention),
                        // so we flip the sign. audio_level is only present on
                        // audio packets, so we don't need a MediaKind check.
                        if let Propagated::MediaData(origin, ref data) = other {
                            if let Some(raw) = data.ext_vals.audio_level {
                                // Skip speaker detection for relay clients — they
                                // re-stream audio from another SFU and must not
                                // participate in this instance's speaker election.
                                // The emitting client is always `client` (poll_output
                                // emits from self), so checking `client.is_relay()` is
                                // equivalent to checking if origin is a relay — and
                                // avoids a second borrow of `self.clients`.
                                if !client.is_relay() {
                                    let level = (-raw).clamp(0, 127) as u8;
                                    let now_ms =
                                        now.saturating_duration_since(self.detector_epoch)
                                            .as_millis() as u64;
                                    self.detector.record_level(origin.0, level, now_ms);
                                }
                            }
                        }
                        self.to_propagate.push_back(other);
                    }
                }
            }
        }
        deadline
    }

    /// Advance the dominant-speaker detector one tick. Queues a
    /// `Propagated::ActiveSpeakerChanged` when dominance changes.
    /// Called from `udp_loop::serve`'s 300ms interval branch.
    pub fn tick_active_speaker(&mut self, now: Instant) {
        let now_ms = now
            .saturating_duration_since(self.detector_epoch)
            .as_millis() as u64;
        if let Some(change) = self.detector.tick(now_ms) {
            self.metrics.dominant_speaker_changes_total.inc();
            // M6.1: record inter-change interval into the hysteresis histogram.
            // Replaces the inlined `record_hysteresis_observation` method that
            // lived on the old monomorphic detector — v0.3 has no such method.
            if let Some(prev) = self.last_speaker_change {
                let ms = now.duration_since(prev).as_secs_f64() * 1_000.0;
                self.metrics.dominant_speaker_hysteresis_ms.observe(ms);
            }
            self.last_speaker_change = Some(now);
            self.to_propagate
                .push_back(Propagated::ActiveSpeakerChanged {
                    peer_id: change.peer_id,
                    confidence: change.c2_margin,
                });
        }
    }

    /// Update Prometheus gauges with current per-peer audio activity scores.
    ///
    /// Also queues a `TopSpeakers` event with the top-3 speakers by
    /// medium-window score for broadcast via DC id:3. Called from
    /// `udp_loop::serve` on the same 300ms ASO tick branch as
    /// `tick_active_speaker`.
    pub fn tick_speaker_scores(&mut self) {
        for (peer_id, imm, med, lng) in self.detector.peer_scores() {
            let label = peer_id.to_string();
            self.metrics
                .speaker_immediate
                .with_label_values(&[&label])
                .set(imm);
            self.metrics
                .speaker_medium
                .with_label_values(&[&label])
                .set(med);
            self.metrics
                .speaker_long
                .with_label_values(&[&label])
                .set(lng);
        }

        let top3: Vec<u64> = self.detector.current_top_k(3);
        if !top3.is_empty() {
            self.to_propagate.push_back(Propagated::TopSpeakers(top3));
        }
    }

    /// Drive the session clock forward on every client.
    pub fn tick(&mut self, now: Instant) {
        for client in self.clients.iter_mut() {
            client.handle_input(Input::Timeout(now));
        }
    }

    /// Dynacast: scan subscriber desired layers per publisher and enqueue
    /// `Propagated::PublisherLayerHint` for each publisher whose maximum
    /// desired layer changed. Called once per 300 ms speaker tick.
    ///
    /// Applications may act on these hints to signal publishers to stop
    /// encoding simulcast layers that no subscriber is currently requesting.
    pub fn emit_publisher_layer_hints(&mut self) {
        use std::collections::HashMap;

        let rank = |r: Rid| -> u8 {
            if r == layer::LOW {
                0
            } else if r == layer::MEDIUM {
                1
            } else {
                2
            }
        };

        let mut max_per_publisher: HashMap<crate::propagate::ClientId, Rid> = HashMap::new();
        for subscriber in &self.clients {
            let sub_desired = subscriber.desired_layer();
            for track_out in &subscriber.tracks_out {
                if let Some(track_in) = track_out.track_in.upgrade() {
                    let publisher_id = track_in.origin;
                    let entry = max_per_publisher.entry(publisher_id).or_insert(layer::LOW);
                    if rank(sub_desired) > rank(*entry) {
                        *entry = sub_desired;
                    }
                }
            }
        }
        for (publisher_id, max_rid) in max_per_publisher {
            self.to_propagate.push_back(Propagated::PublisherLayerHint {
                publisher_id,
                max_rid,
            });
        }
    }

    /// Fan out every queued event. Before each `MediaData` pass the
    /// [`bwe`][super::bwe] submodule pokes the pacer so `desired_layer`
    /// reflects the latest GCC estimate.
    ///
    /// `BandwidthEstimate` and `ClientBudgetHint` are consumed here and
    /// never fan out to other clients.
    pub fn fanout_pending(&mut self) {
        while let Some(p) = self.to_propagate.pop_front() {
            match &p {
                Propagated::BandwidthEstimate(cid, bps) => {
                    self.bandwidth.record_native_estimate(
                        oxpulse_sfu_kit::propagate::ClientId(**cid),
                        *bps as f64,
                    );
                    continue;
                }
                Propagated::ClientBudgetHint(cid, bps) => {
                    // M5.4.1: client-reported budget ceiling. Record into the
                    // shared BandwidthEstimator so the pacer sees it on the
                    // next update_pacer_layers pass.
                    self.bandwidth.record_client_hint(
                        oxpulse_sfu_kit::propagate::ClientId(**cid),
                        *bps,
                        Instant::now(),
                    );
                    continue;
                }
                #[cfg(feature = "vfm")]
                Propagated::VfmLayerCap(sub_id, max_tid) => {
                    if let Some(client) = self.clients.iter_mut().find(|c| c.id == *sub_id) {
                        client.set_max_vfm_temporal_layer(*max_tid);
                    }
                    continue;
                }
                Propagated::MarkRelaySource(client_id, upstream_url) => {
                    if let Some(client) = self.clients.iter_mut().find(|c| c.id == *client_id) {
                        client.set_origin(oxpulse_sfu_kit::ClientOrigin::RelayFromSfu(
                            upstream_url.clone(),
                        ));
                        // Remove from detector retroactively — relay clients must not
                        // participate in speaker election. Normally insert() guards against
                        // this, but this client was inserted as Local before the DC
                        // relay_source handshake completed.
                        self.detector.remove_peer(&client_id.0);
                        tracing::info!(
                            client = **client_id,
                            upstream_url = %upstream_url,
                            "marked client as cascade relay source"
                        );
                    }
                    continue;
                }
                Propagated::UpstreamKeyframeRequest { source_relay_id, .. } => {
                    // TODO: forward to upstream SFU via signalling WebSocket.
                    tracing::debug!(
                        relay = **source_relay_id,
                        "upstream keyframe request — relay to signalling (not yet wired)"
                    );
                    continue;
                }
                Propagated::PublisherLayerHintForUpstream { publisher_relay_id, max_rid } => {
                    // TODO: forward to upstream SFU via signalling WebSocket.
                    tracing::debug!(
                        relay = **publisher_relay_id,
                        ?max_rid,
                        "upstream dynacast hint — relay to signalling (not yet wired)"
                    );
                    continue;
                }
                Propagated::PublisherLayerHint { publisher_id, max_rid } => {
                    tracing::debug!(
                        publisher = **publisher_id,
                        max_rid = ?max_rid,
                        "dynacast: publisher layer hint"
                    );
                    // TODO: relay to publisher via signalling channel (future work).
                    // For now, log it so operators can see it in traces.
                    continue;
                }
                // M5.3 fix-round: the publisher's active RIDs drive the
                // pacer's `available_rids` input — pass the origin through
                // so update_pacer_layers can look them up.
                Propagated::MediaData(origin, _) => self.update_pacer_layers(*origin),
                _ => {}
            }
            fanout(&p, &mut self.clients);
        }
    }
}
