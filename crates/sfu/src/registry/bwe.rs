//! Registry methods that own the BWE / pacer / peer-reap concern.
//!
//! Split from [`super`] because it's a distinct concern from routing
//! UDP-to-client and fanning out events — and the M5.3 additions
//! pushed the parent over the line-count budget. Contains the public
//! accessors the forwarder uses, [`Registry::reap_dead`], and the
//! per-fanout pacer-layer refresh (fires once per `MediaData`).

use str0m::media::Rid;

use crate::bandwidth::BandwidthEstimator;
use crate::client::layer;
use crate::pacer::Pacer;
use crate::propagate::ClientId;

use super::Registry;

/// Fallback simulcast ladder used when a publisher hasn't been observed
/// emitting any RID yet (bootstrap window before the first MediaData
/// arrives, or re-init after a track reset). Keeps the existing
/// "full ladder available" pacer contract until per-publisher
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

    /// Mutable access to the [`Pacer`]. The per-client fanout path
    /// calls `preferred_rid` via this handle on every forwarded packet.
    pub fn pacer_mut(&mut self) -> &mut Pacer {
        &mut self.pacer
    }

    /// Shared read of the pacer — e.g. test helpers.
    pub fn pacer(&self) -> &Pacer {
        &self.pacer
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
        let pacer = &mut self.pacer;
        self.clients.retain(|c| {
            let alive = c.is_alive();
            if !alive {
                detector.remove_peer(&c.id.0);
                bandwidth.remove(&c.id);
                pacer.remove(&c.id);
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
            }
            alive
        });
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
            let budget = self
                .bandwidth
                .estimate_bps(&client.id, std::time::Instant::now());
            let prev_layer = client.desired_layer;
            let chosen = client.pacer_select_layer(&mut self.pacer, budget, available);
            let peer_label = (*client.id).to_string();
            if let Some(bps) = budget {
                self.metrics
                    .bandwidth_estimate_bps
                    .with_label_values(&[&peer_label])
                    .set(bps as i64);
            }
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
const PACER_RID_LABELS: &[&str] = &["q", "h", "f", "other"];

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
