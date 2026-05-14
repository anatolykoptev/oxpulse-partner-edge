//! Registry methods that own the BWE / pacer / peer-reap concern.
//!
//! Split from [`super`] because it's a distinct concern from routing
//! UDP-to-client and fanning out events — and the M5.3 additions
//! pushed the parent over the line-count budget. Contains the public
//! accessors the forwarder uses, [`Registry::reap_dead`], and the
//! per-fanout pacer-layer refresh (fires once per `MediaData`).

use str0m::media::Rid;

use crate::client::layer;
use crate::propagate::ClientId;
use oxpulse_sfu_kit::bwe::estimator::BandwidthEstimator;

use super::Registry;

/// Fallback simulcast ladder used when a publisher hasn't been observed
/// emitting any RID yet (bootstrap window before the first MediaData
/// arrives, or re-init after a track reset). Keeps the existing
/// full ladder available pacer contract until per-publisher
/// `active_rids` has real data.
const DEFAULT_SIMULCAST_LADDER: [Rid; 3] = [layer::LOW, layer::MEDIUM, layer::HIGH];

impl Registry {
    /// Mutable access to the [`BandwidthEstimator`]. Exposed so the
    /// UDP loop / str0m-event plumbing can feed TWCC samples in
    /// without a circular dependency through [`super::Client`].
    pub fn bandwidth_mut(&mut self) -> &mut BandwidthEstimator {
        &mut self.bandwidth
    }

    /// Shared read of the current estimator — used by fanout and the
    /// metrics gauge publisher.
    pub fn bandwidth(&self) -> &BandwidthEstimator {
        &self.bandwidth
    }

    /// Per-client pacer iterator (Phase B migration).
    ///
    /// Previously returned a registry-level Pacer. After Phase B the pacer
    /// is per-client (Client::pacer: SubscriberPacer). Preserved for the
    /// Phase 2 ProbeController seam (docs/ROADMAP.md). Do NOT remove.
    #[allow(dead_code)]
    pub fn pacers_mut(&mut self) -> impl Iterator<Item = &mut oxpulse_sfu_kit::SubscriberPacer> {
        self.clients.iter_mut().map(|c| &mut c.pacer)
    }

    /// Drop dead clients and update metrics + BWE + pacer state.
    /// Moved from [`super`] so the single code path touches every
    /// per-peer pool that needs eviction on disconnect.
    ///
    /// Also clears the per-peer Prometheus label series on
    /// `sfu_bandwidth_estimate_bps{peer_id}` and
    /// `sfu_pacer_layer_total{peer_id, rid}` — otherwise reconnect
    /// churn would grow `peer_id` cardinality without bound
    /// (every new connection allocates a fresh [`ClientId`]).
    pub fn reap_dead(&mut self) {
        let detector = &mut self.detector;
        let metrics = &self.metrics;
        let bandwidth = &mut self.bandwidth;
        self.clients.retain(|c| {
            let alive = c.is_alive();
            if !alive {
                detector.remove_peer(&c.id.0);
                // CAST INVARIANT (cross-crate newtype): kit `ClientId` and
                // crate `ClientId` both wrap a `u64`. Numeric round-trip is
                // valid while both sides stay u64-backed; revisit on kit
                // representation change. (Not `// SAFETY:` — no `unsafe`.)
                bandwidth.reap_dead(oxpulse_sfu_kit::propagate::ClientId(*c.id));
                // Per-client SubscriberPacer drops automatically with c.
                metrics.client_disconnect_total.inc();
                metrics.active_participants.dec();

                // Scrub label series so peer_id cardinality doesn't
                // grow forever across reconnects. `remove_label_values`
                // returns `Err` when the series was never observed
                // (e.g. client disconnected before a BWE sample landed
                // or before the pacer picked a tier) — non-fatal.
                let peer_label = (*c.id).to_string();
                let _ = metrics
                    .bandwidth_estimate_bps
                    .remove_label_values(&[&peer_label]);
                let _ = metrics
                    .client_delivered_media_count
                    .remove_label_values(&[&peer_label]);
                for rid_label in PACER_RID_LABELS {
                    let _ = metrics
                        .pacer_layer_total
                        .remove_label_values(&[&peer_label, rid_label]);
                    // M6.1: scrub layer_transitions_total{from,to,peer} series
                    // for this peer to prevent cardinality growth on reconnects.
                    for to_label in PACER_RID_LABELS {
                        let _ = metrics.layer_transitions_total.remove_label_values(&[
                            rid_label,
                            to_label,
                            &peer_label,
                        ]);
                    }
                }
                // F2b-2: drop chat_relay_{tx,rx}_bytes_total{dc, client_id}
                // series for both dc values. `client_id` label equals the
                // ClientId u64 stringified — same format as `peer_label`.
                // `chat_relay_dropped_total` uses (dc, reason) only — no
                // client_id — so it is not in scope.
                for dc in ["data", "ctrl"] {
                    let _ = metrics
                        .chat_relay_tx_bytes_total
                        .remove_label_values(&[dc, &peer_label]);
                    let _ = metrics
                        .chat_relay_rx_bytes_total
                        .remove_label_values(&[dc, &peer_label]);
                }
                // Phase 8 T10: drop voice_relay_{tx,rx}_bytes_total{client_id}
                // series. Label schema: single `client_id` label (no `dc`).
                // `voice_relay_dropped` uses (reason) only — no client_id —
                // so it does not need scrubbing here.
                let _ = metrics
                    .voice_relay_tx_bytes_total
                    .remove_label_values(&[&peer_label]);
                let _ = metrics
                    .voice_relay_rx_bytes_total
                    .remove_label_values(&[&peer_label]);
                // Phase 2c review fix (MAJOR 1): drop bwe-hint counter series
                // on disconnect so reconnect churn doesn't grow cardinality.
                let _ = metrics
                    .sfu_bwe_hint_received_total
                    .remove_label_values(&[&peer_label]);
                let _ = metrics
                    .sfu_bwe_hint_throttled_total
                    .remove_label_values(&[&peer_label]);
                // MAJOR-2: decrement voice_relay_active_channels gauge.
                // with_voice_dc increments on open; we mirror it here on
                // reap so reconnect storms don't monotonically inflate the
                // gauge. Only decrement when the client actually had a voice
                // DC — relay clients (voice_data_cid == None) never inc'd.
                if c.voice_data_cid.is_some() {
                    metrics
                        .voice_relay_active_channels
                        .with_label_values(&["voice"])
                        .dec();
                }
                // chat gauge dec — mirror voice path (followup to T10 MAJOR-2).
                // with_chat_dcs increments both {data} and {ctrl} on open;
                // decrement both here on reap. Only decrement when the client
                // called with_chat_dcs — relay-origin clients that skipped it
                // have chat_data_cid == None and never inc'd the gauge.
                if c.chat_data_cid.is_some() {
                    metrics
                        .chat_relay_active_channels
                        .with_label_values(&["data"])
                        .dec();
                }
                if c.chat_ctrl_cid.is_some() {
                    metrics
                        .chat_relay_active_channels
                        .with_label_values(&["ctrl"])
                        .dec();
                }
                // reactions gauge dec — only when the gauge was actually
                // incremented (Event::ChannelOpen fired). Using the
                // `reactions_dc_opened` flag (not `reactions_dc_cid.is_some()`)
                // prevents double-dec and guards against v0.12.22 clients that
                // called `with_reactions_dc` but never completed SCTP DCEP.
                if c.reactions_dc_opened {
                    metrics
                        .chat_relay_active_channels
                        .with_label_values(&["reactions"])
                        .dec();
                }
            }
            alive
        });
        // 2026-05-06 post-mortem: keep `active_rooms` in lockstep with
        // population. Single-room SFU → 0 if empty, else 1. Idempotent.
        if self.clients.is_empty() {
            self.metrics.active_rooms.set(0);
        }
        // Update solo_since after reap:
        // * 0 clients → room empty, clear.
        // * 1 client  → start solo clock if not already running.
        // * ≥2 clients → multiple peers, clear.
        match self.clients.len() {
            0 => {
                self.solo_since = None;
            }
            1 => {
                if self.solo_since.is_none() {
                    self.solo_since = Some(std::time::Instant::now());
                }
            }
            _ => {
                self.solo_since = None;
            }
        }
    }

    /// Consult the pacer for each subscriber's current tier and
    /// publish the bandwidth-estimate / layer-selection metrics.
    /// Invoked once per `MediaData` fanout pass; cheap (O(clients)).
    ///
    /// `origin` identifies the *publisher* whose RIDs drive the
    /// `available_rids` pacer input. Subscribers other than the origin
    /// pick their layer from whatever the publisher has been seen
    /// emitting (see [`crate::client::Client::active_rids`]); the
    /// origin themselves still runs so the pacer state and metrics
    /// stay in sync across self-fanout passes.
    pub(super) fn update_pacer_layers(&mut self, origin: ClientId) {
        // Snapshot the publisher's currently-emitted RIDs before the
        // mut-loop so the borrow checker lets us index other clients.
        // Empty ⇒ bootstrap / non-simulcast; substitute the full ladder
        // so we don't silently wedge subscribers at audio-only before
        // the first packet.
        let publisher_rids: Vec<Rid> = self
            .clients
            .iter()
            .find(|c| c.id == origin)
            .map(|c| c.active_rids())
            .unwrap_or_default();
        let available: &[Rid] = if publisher_rids.is_empty() {
            &DEFAULT_SIMULCAST_LADDER
        } else {
            &publisher_rids
        };

        for client in self.clients.iter_mut() {
            // CAST INVARIANT: same u64-backed `ClientId` rule as in
            // `reap_dead` above. Update both sides if kit changes the
            // representation.
            let budget = self.bandwidth.estimate_bps(
                oxpulse_sfu_kit::propagate::ClientId(*client.id),
                std::time::Instant::now(),
            );
            let prev_layer = client.desired_layer;
            // GoogCC is now embedded in BandwidthEstimator::PerSubscriber and
            // applied as a ceiling inside combined_bps() → estimate_bps().
            // A separate merge gate here would double-count GoogCC. Trust
            // the kit (anatolykoptev/oxpulse-sfu-kit issue #17 resolved in
            // v0.11.4). The `budget` value from estimate_bps() already
            // incorporates the GoogCC ceiling alongside Kalman + native + hint.
            let chosen = client.pacer_select_layer(budget, available);
            let peer_label = (*client.id).to_string();
            if let Some(bps) = budget {
                self.metrics
                    .bandwidth_estimate_bps
                    .with_label_values(&[&peer_label])
                    .set(bps as i64);
            }
            // Per-peer media-throughput snapshot — diagnoses
            // 'connected but no media' cases. Cheap (atomic load
            // + gauge set).
            self.metrics
                .client_delivered_media_count
                .with_label_values(&[&peer_label])
                .set(client.delivered_media_count() as i64);
            if let Some(rid) = chosen {
                self.metrics
                    .pacer_layer_total
                    .with_label_values(&[&peer_label, rid_label_for(rid)])
                    .inc();
                // M6.1: record a transition only when the layer actually changed.
                if rid != prev_layer {
                    self.metrics
                        .layer_transitions_total
                        .with_label_values(&[
                            rid_label_for(prev_layer),
                            rid_label_for(rid),
                            &peer_label,
                        ])
                        .inc();
                }
            }
        }
    }
}

/// Every RID label `update_pacer_layers` could ever emit onto
/// `sfu_pacer_layer_total`. Kept in lockstep with [`rid_label_for`] —
/// if you add a variant there, mirror it here so `reap_dead` scrubs
/// the matching label series on disconnect.
///
/// Visible to sibling registry modules so [`super::Registry::insert`]'s
/// session-steal eviction path can run the same scrub without
/// duplicating the list.
pub(super) const PACER_RID_LABELS: &[&str] = &["q", "h", "f", "other"];

/// Map a simulcast `Rid` to its Prometheus label (`q` / `h` / `f`).
fn rid_label_for(rid: Rid) -> &'static str {
    if rid == layer::LOW {
        "q"
    } else if rid == layer::MEDIUM {
        "h"
    } else if rid == layer::HIGH {
        "f"
    } else {
        "other"
    }
}
