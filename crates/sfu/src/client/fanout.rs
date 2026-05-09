//! Downstream fanout: apply a forwarded `MediaData` to *this* peer.
//!
//! Split out of [`client/mod.rs`][super] because it owns a distinct
//! concern from the `Rtc` lifecycle / event dispatch: per-subscriber
//! simulcast layer filtering (M1.3 / M5.3), active-speaker
//! notification fanout (M1.4), and the writer-stage early returns
//! that tolerate unnegotiated sessions in tests.
//!
//! M5.3: the per-subscriber simulcast layer is no longer static —
//! [`Client::pacer_select_layer`] runs before the filter and updates
//! `desired_layer` from the GCC bandwidth estimate produced by the
//! registry-owned [`oxpulse_sfu_kit::bwe::estimator::BandwidthEstimator`] paired
//! with the [`crate::pacer::Pacer`]. See those modules for the
//! algorithm + hysteresis.

use std::sync::atomic::Ordering;

use str0m::media::{MediaData, MediaKind, Rid};

use super::{layer, Client};
use crate::pacer::Pacer;
use crate::propagate::ClientId;

impl Client {
    /// Consult the [`Pacer`] for the simulcast tier this subscriber
    /// should currently receive, given the latest GCC estimate from
    /// [`oxpulse_sfu_kit::bwe::estimator::BandwidthEstimator::estimate_bps`]. Updates
    /// `self.desired_layer` in place (cheap — no SDP renegotiation).
    /// Returns the chosen layer so the caller can record a metric.
    ///
    /// `budget_bps = None` means no estimate yet — hold the default
    /// `LOW` tier. Below [`AUDIO_ONLY_THRESHOLD_BPS`] the return is
    /// `None`, signalling the caller to drop video frames entirely.
    ///
    /// `available_rids` is the set of simulcast RIDs the *publisher*
    /// is currently emitting (see [`Client::active_rids`]). Must not
    /// be empty — caller substitutes the full `[LOW, MEDIUM, HIGH]`
    /// ladder during the bootstrap window. Without this plumbing a
    /// screenshare publisher sending only `q` with a 2Mbps subscriber
    /// would still have the pacer pick `f`, and every incoming `q`
    /// packet would be dropped by the layer filter (silent
    /// zero-forwarding).
    pub fn pacer_select_layer(
        &mut self,
        pacer: &mut Pacer,
        budget_bps: Option<u64>,
        available_rids: &[Rid],
    ) -> Option<Rid> {
        let Some(budget) = budget_bps else {
            return Some(self.desired_layer);
        };
        if pacer.check_audio_only_stateful(self.id, budget) {
            return None;
        }
        let chosen = pacer.preferred_rid(self.id, budget, available_rids)?;
        if chosen != self.desired_layer {
            self.set_desired_layer(chosen);
        }
        Some(chosen)
    }

    /// Forward a `MediaData` from `origin` out to this peer. Applies
    /// the simulcast layer filter; increments Prometheus counters for
    /// matched packets and layer selections.
    #[tracing::instrument(level = "trace", skip(self, data), fields(dst_peer = *self.id, src_peer = *origin))]
    pub fn handle_media_data_out(&mut self, origin: ClientId, data: &MediaData) {
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

/// Format the `sfu-active-speaker` DC payload. Extracted from
/// [`Client::handle_active_speaker_changed`] so test capture and the
/// real DC write see byte-identical output. Wire contract (M4.B1):
/// `{"type":"active_speaker","peerId":<u64>,"confidence":<f64 with 3 fractional digits>}`.
#[inline]
fn format_active_speaker_payload(peer_id: u64, confidence: f64) -> String {
    format!(r#"{{"type":"active_speaker","peerId":{peer_id},"confidence":{confidence:.3}}}"#)
}
