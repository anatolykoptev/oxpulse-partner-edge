//! Registry poll loop, tick, and fanout — the "drive forward" concern.
//!
//! Split from [`super`] when M5.4.1 additions pushed `mod.rs` past 200
//! lines. Owns: [`Registry::poll_all`], [`Registry::tick`],
//! [`Registry::tick_active_speaker`], [`Registry::fanout_pending`].

use std::time::Instant;

use str0m::Input;

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
                    // TODO(M2): parse RFC 6464 audio-level ext and feed
                    // detector.record_level(...) for MediaData events.
                    other => self.to_propagate.push_back(other),
                }
            }
        }
        deadline
    }

    /// Advance the dominant-speaker detector one tick. Queues a
    /// `Propagated::ActiveSpeakerChanged` when dominance changes.
    /// Called from `udp_loop::serve`'s 300ms interval branch.
    pub fn tick_active_speaker(&mut self, now: Instant) {
        if let Some(peer_id) = self.detector.tick(now) {
            self.metrics.dominant_speaker_changes_total.inc();
            // M6.1: record inter-change interval into the hysteresis histogram.
            self.detector.record_hysteresis_observation(now);
            self.to_propagate
                .push_back(Propagated::ActiveSpeakerChanged { peer_id });
        }
    }

    /// Drive the session clock forward on every client.
    pub fn tick(&mut self, now: Instant) {
        for client in self.clients.iter_mut() {
            client.handle_input(Input::Timeout(now));
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
                    self.bandwidth.record_native_estimate(*cid, *bps);
                    continue;
                }
                Propagated::ClientBudgetHint(cid, bps) => {
                    // M5.4.1: client-reported budget ceiling. Record into the
                    // shared BandwidthEstimator so the pacer sees it on the
                    // next update_pacer_layers pass.
                    self.bandwidth
                        .record_client_hint(*cid, *bps, Instant::now());
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
