//! Downstream fanout: apply a forwarded `MediaData` to *this* peer.
//!
//! Split out of [`client/mod.rs`][super] because it owns a distinct
//! concern from the `Rtc` lifecycle / event dispatch: per-subscriber
//! simulcast layer filtering (M1.3 / M5.3), active-speaker
//! notification fanout (M1.4), and the writer-stage early returns
//! that tolerate unnegotiated sessions in tests.
//!
//! Phase B: [`Client::pacer_select_layer`] now drives the per-client
//! [`oxpulse_sfu_kit::SubscriberPacer`] (kit v0.11) rather than the
//! legacy registry-level `crate::pacer::Pacer` map. Each `Client` owns
//! its pacer; the registry passes only the BWE estimate and available RIDs.

use std::sync::atomic::Ordering;

use str0m::media::{MediaData, MediaKind, Rid};
use str0m::RtcError;

use super::{layer, Client};
use crate::propagate::ClientId;

impl Client {
    /// Consult the per-client [`oxpulse_sfu_kit::SubscriberPacer`] for the
    /// simulcast tier this subscriber should receive, given the latest BWE
    /// estimate. Updates `self.desired_layer` in place (no SDP renegotiation).
    /// Returns the chosen layer for Prometheus recording, or `None` when the
    /// pacer enters audio-only or video-suspended state.
    ///
    /// **Phase B behaviour change vs. F6-9/F7-5**: kit uses dual-threshold
    /// audio-only hysteresis (enter at `audio_only_bps=100k`, exit only above
    /// `low_min_bps=150k`) instead of the single-threshold 2-tick symmetric
    /// debounce. This is the standard LiveKit/mediasoup pattern. Tests that
    /// relied on the old F6-9/F7-5 model have been rewritten for the new
    /// dual-threshold semantics.
    ///
    /// `available_rids` drives the layer clamping after a `ChangeLayer` action;
    /// the pacer ignores which RIDs are available — it emits a target tier and
    /// this method clamps to the nearest available layer. Must not be empty —
    /// caller substitutes the full `[LOW, MEDIUM, HIGH]` ladder during bootstrap.
    pub fn pacer_select_layer(
        &mut self,
        budget_bps: Option<u64>,
        available_rids: &[Rid],
    ) -> Option<Rid> {
        use oxpulse_sfu_kit::PacerAction;

        let Some(budget) = budget_bps else {
            return Some(self.desired_layer);
        };

        match self.pacer.update(budget) {
            PacerAction::NoChange => Some(self.desired_layer),
            PacerAction::ChangeLayer(sfu_rid) => {
                // Convert kit SfuRid -> str0m Rid via the kit's public
                // `impl From<SfuRid> for str0m::media::Rid` (ADR-S11). The
                // conversion is lossless/zero-cost — it hands back the exact
                // inner `Rid` the kit holds — replacing the former hand-rolled
                // 3-arm `sfu_rid_to_rid` shadow-duplicate.
                // Clamp to available_rids: if the target isn't available,
                // fall back to the highest available layer below it.
                let target: Rid = sfu_rid.into();
                let rid = clamp_to_available(target, available_rids);
                if rid != self.desired_layer {
                    self.set_desired_layer(rid);
                }
                // ChangeLayer means video is running -- emit VideoMax capability.
                self.pending_tier_emit = Some(crate::propagate::SuspendTier::VideoMax);
                Some(rid)
            }
            PacerAction::SuspendVideo => {
                // BWE: video suspended, audio still normal bandwidth.
                self.pending_tier_emit = Some(crate::propagate::SuspendTier::AudioNormal);
                None
            }
            PacerAction::GoAudioOnly => {
                // BWE: entered full audio-only (low bandwidth) mode.
                self.pending_tier_emit = Some(crate::propagate::SuspendTier::AudioLow);
                None
            }
            PacerAction::RestoreAudio => {
                // Resumed audio-only; remain on current layer until RestoreVideo.
                Some(self.desired_layer)
            }
            PacerAction::RestoreVideo => {
                // BWE recovered; reset to LOW and let upgrade streak build.
                // Emit VideoMax to signal peer is back to full capability.
                self.pending_tier_emit = Some(crate::propagate::SuspendTier::VideoMax);
                let rid = layer::LOW;
                self.set_desired_layer(rid);
                Some(rid)
            }
            // PacerAction is #[non_exhaustive] — catch future variants.
            _ => Some(self.desired_layer),
        }
    }

    /// Forward a `MediaData` from `origin` out to this peer. Applies
    /// the simulcast layer filter; increments Prometheus counters for
    /// matched packets and layer selections.
    #[tracing::instrument(level = "trace", skip(self, data), fields(dst_peer = *self.id, src_peer = *origin))]
    pub fn handle_media_data_out(&mut self, origin: ClientId, data: &MediaData) {
        // G3 P0: Dependency Descriptor presence observability. Read the DD
        // marker placed by `svc::DdSerializer` on ingress and increment a
        // bounded-label counter. Pure observability — NO drop, NO forwarding
        // change. Inspected before the layer filter so every packet the
        // fanout sees for this subscriber is counted, regardless of layer.
        let dd_present = data
            .ext_vals
            .user_values
            .get::<crate::svc::DdPresent>()
            .is_some();
        self.metrics
            .sfu_dd_frames_total
            .with_label_values(&[if dd_present { "true" } else { "false" }])
            .inc();

        // M1.3 / M5.3: drop packets that don't match desired layer.
        // The desired layer itself may have been updated by the pacer
        // via [`pacer_select_layer`] earlier in the fanout cycle.
        if !layer::matches(self.desired_layer, data) {
            return;
        }

        let src_peer = origin.to_string();
        let dst_peer = self.id.to_string();

        // Find the matching outbound track entry. Media kind lives on TrackIn.
        let matched = self.tracks_out.iter().find(|o| {
            o.track_in
                .upgrade()
                .filter(|i| i.origin == origin && i.mid == data.mid)
                .is_some()
        });

        // Derive kind_label from TrackIn for metric labels.
        let kind_label = matched
            .and_then(|o| o.track_in.upgrade())
            .map(|t| match t.kind {
                MediaKind::Audio => "audio",
                MediaKind::Video => "video",
            })
            .unwrap_or("other");

        // Prometheus: layer_selection_total{layer} — simulcast packets only.
        if let Some(rid) = data.rid {
            let layer_label = if rid == layer::LOW {
                "q"
            } else if rid == layer::MEDIUM {
                "h"
            } else if rid == layer::HIGH {
                "f"
            } else {
                "other"
            };
            self.metrics
                .layer_selection_total
                .with_label_values(&[layer_label])
                .inc();
        }

        // Test-only: track packets that passed the layer filter and reached
        // the mid-gate check. Fires BEFORE writer.write — used by integration
        // tests on unnegotiated Rtc where writer.write never fires.
        // Production telemetry uses sfu_wire_written_total and
        // forwarded_packets_total (both below, after writer.write).
        #[cfg(any(test, feature = "test-utils"))]
        self.layer_passed.fetch_add(1, Ordering::Relaxed);

        let Some(mid) = self
            .tracks_out
            .iter()
            .find(|o| {
                o.track_in
                    .upgrade()
                    .filter(|i| i.origin == origin && i.mid == data.mid)
                    .is_some()
            })
            .and_then(|o| o.mid())
        else {
            // No matching outbound mid — track not yet wired (e.g. late-join
            // subscription is pending). Diagnose with:
            //   sfu_sfu_forward_decisions_total{action="skipped_no_track"} > 0
            // while sfu_sfu_subscription_setup_total shows no wired events for
            // this (publisher, subscriber) pair → cross-advertisement loop broke.
            self.metrics
                .sfu_forward_decisions_total
                .with_label_values(&[&src_peer, &dst_peer, kind_label, "skipped_no_track"])
                .inc();
            return;
        };

        // Track the last rid we actually forwarded, so keyframe
        // requests we relay upstream target the same layer. Only
        // updates on Some(rid) — single-layer publishers leave this
        // None, preserving the pre-M1.3 behaviour of `req.rid = None`
        // for non-simulcast writers. See `keyframe::incoming_keyframe_req`.
        // Single-track deferral: see `Client::chosen_rid` doc comment.
        if data.rid.is_some() && self.chosen_rid != data.rid {
            self.chosen_rid = data.rid;
        }

        let Some(writer) = self.rtc.writer(mid) else {
            self.metrics
                .sfu_forward_decisions_total
                .with_label_values(&[&src_peer, &dst_peer, kind_label, "skipped_no_track"])
                .inc();
            return;
        };
        let Some(pt) = writer.match_params(data.params) else {
            self.metrics
                .sfu_forward_decisions_total
                .with_label_values(&[&src_peer, &dst_peer, kind_label, "skipped_no_track"])
                .inc();
            return;
        };
        if let Err(e) = writer.write(pt, data.network_time, data.time, data.data.clone()) {
            tracing::warn!(client = *self.id, error = ?e, "writer.write failed");
            // Discriminate by RtcError variant for alertable observability.
            // WriteWithoutPoll is the known cause of frozen video at ≥10 peers
            // (str0m issue #952, 2026-05-05). All other variants collapse to "other"
            // to keep label cardinality bounded.
            let error_kind = match &e {
                RtcError::WriteWithoutPoll => "write_without_poll",
                _ => "other",
            };
            self.metrics
                .sfu_writer_write_errors_total
                .with_label_values(&[error_kind])
                .inc();
            self.metrics
                .sfu_forward_decisions_total
                .with_label_values(&[&src_peer, &dst_peer, kind_label, "write_err"])
                .inc();
            self.rtc.disconnect();
        } else {
            self.metrics
                .sfu_forward_decisions_total
                .with_label_values(&[&src_peer, &dst_peer, kind_label, "forwarded"])
                .inc();
            // forwarded_packets_total: only increments on successful SRTP write.
            // Previously fired before the mid() gate (inflated counts during
            // Negotiating window); now moved here so it reflects actual delivery.
            self.metrics
                .forwarded_packets_total
                .with_label_values(&[kind_label])
                .inc();
            // delivered_media: post-write counter for per-client delivery tracking.
            // Downstream: bwe.rs reads via delivered_media_count() for GCC convergence.
            self.delivered_media.fetch_add(1, Ordering::Relaxed);
            // sfu_wire_written_total: M2 SRTP delivery confirmation counter.
            self.metrics
                .sfu_wire_written_total
                .with_label_values(&[kind_label])
                .inc();
        }
    }

    /// Handle a dominant-speaker election change. The registry skips
    /// the speaker themselves (see [`crate::fanout::fanout`]) — this
    /// method is only invoked on *other* clients. Pushes a one-shot
    /// `{"type":"active_speaker","peerId":<u64>,"confidence":<f64>}` JSON payload onto the
    /// pre-negotiated `sfu-active-speaker` DC (id:3) so the UI can
    /// update spotlight/pin state without polling receiver audioLevel.
    pub fn handle_active_speaker_changed(&mut self, peer_id: u64, confidence: f64) {
        #[cfg(any(test, feature = "test-utils"))]
        {
            self.delivered_active_speaker
                .fetch_add(1, Ordering::Relaxed);
        }
        let payload = format_active_speaker_payload(peer_id, confidence);
        // Test-only seam: capture the formatted payload BEFORE the
        // `rtc.channel()` lookup so integration tests can assert wire
        // format on unnegotiated `Rtc` instances (no DTLS pipeline).
        // Production fanout still proceeds to the real DC write below.
        #[cfg(any(test, feature = "test-utils"))]
        {
            if let Ok(mut guard) = self.last_active_speaker_payload.lock() {
                *guard = Some((payload.clone(), std::time::Instant::now()));
            }
        }
        let Some(mut ch) = self.rtc.channel(self.active_speaker_cid) else {
            // DC not yet open (DTLS still negotiating, or peer dropped).
            // The detector will fire again within ~300 ms so we don't
            // bother queueing — a miss at handshake is harmless.
            return;
        };
        if let Err(e) = ch.write(false, payload.as_bytes()) {
            tracing::warn!(client = *self.id, error = ?e, "active_speaker DC write failed");
        }
    }
}

/// Clamp `target` to the highest available RID at or below its rank.
/// Falls back to the lowest available if nothing fits.
fn clamp_to_available(target: Rid, available: &[Rid]) -> Rid {
    use super::layer::{HIGH, LOW, MEDIUM};
    fn rank(r: Rid) -> u8 {
        if r == HIGH {
            2
        } else if r == MEDIUM {
            1
        } else {
            0
        }
    }
    let target_rank = rank(target);
    // Walk downward from target rank.
    for &candidate in &[HIGH, MEDIUM, LOW] {
        if rank(candidate) <= target_rank && available.contains(&candidate) {
            return candidate;
        }
    }
    // Nothing below target available — take whatever's lowest.
    available.first().copied().unwrap_or(LOW)
}

/// Format the `sfu-active-speaker` DC payload. Extracted from
/// [`Client::handle_active_speaker_changed`] so test capture and the
/// real DC write see byte-identical output. Wire contract (M4.B1):
/// `{"type":"active_speaker","peerId":<u64>,"confidence":<f64 with 3 fractional digits>}`.
#[inline]
fn format_active_speaker_payload(peer_id: u64, confidence: f64) -> String {
    format!(r#"{{"type":"active_speaker","peerId":{peer_id},"confidence":{confidence:.3}}}"#)
}
