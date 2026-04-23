//! Test-only affordances for `Registry`. Gated with
//! `cfg(any(test, feature = test-utils))` so the release binary is
//! lean and the observer APIs can't be abused in production code.
//!
//! Split from `registry.rs` per CLAUDE.md — test seams are a distinct
//! concern from the production routing/fanout state machine.

use std::time::Instant;

use str0m::media::Rid;

use super::Registry;
use crate::fanout::fanout;
use crate::propagate::Propagated;

impl Registry {
    /// Test-only: run `fanout` against the registry's own clients.
    /// Useful when the caller has already gone through `insert()` (so
    /// cross-advertisement is in effect) and only wants to observe
    /// fanout from there.
    #[doc(hidden)]
    pub fn fanout_for_tests(&mut self, p: &Propagated) {
        fanout(p, &mut self.clients);
    }

    /// Test-only: read a client's delivered-media counter by index.
    #[doc(hidden)]
    pub fn delivered_media_count(&self, idx: usize) -> u64 {
        self.clients[idx].delivered_media_count()
    }

    /// Test-only: read a client's delivered-active-speaker counter
    /// by index. Used by `tests/multi_client.rs` to verify skip-self
    /// semantics on the ActiveSpeakerChanged fanout.
    #[doc(hidden)]
    pub fn delivered_active_speaker_count(&self, idx: usize) -> u64 {
        self.clients[idx].delivered_active_speaker_count()
    }

    /// Test-only: flip a client's desired simulcast layer by index.
    #[doc(hidden)]
    pub fn set_desired_layer_for_tests(&mut self, idx: usize, rid: Rid) {
        self.clients[idx].set_desired_layer(rid);
    }

    /// Test-only: inject an audio level into the dominant-speaker
    /// detector bypassing the (M2-deferred) wire-level RFC 6464
    /// parser. Uses `record_level` directly with ms conversion.
    #[doc(hidden)]
    pub fn inject_audio_level_for_tests(&mut self, peer_id: u64, level: u8, now: Instant) {
        let now_ms = now
            .saturating_duration_since(self.detector_epoch)
            .as_millis() as u64;
        self.detector.record_level(peer_id, level, now_ms);
    }

    /// Test-only: force an ASO tick and drain any fanout the detector
    /// may have queued. Returns the peer id if dominance changed on
    /// this tick, mirroring the detector's own return.
    #[doc(hidden)]
    pub fn force_active_speaker_tick_for_tests(&mut self, now: Instant) -> Option<u64> {
        let now_ms = now
            .saturating_duration_since(self.detector_epoch)
            .as_millis() as u64;
        let changed = self.detector.tick(now_ms);
        if let Some(ref change) = changed {
            self.metrics.dominant_speaker_changes_total.inc();
            self.to_propagate
                .push_back(Propagated::ActiveSpeakerChanged {
                    peer_id: change.peer_id,
                    confidence: change.c2_margin,
                });
        }
        self.fanout_pending();
        changed.map(|c| c.peer_id)
    }

    /// Test-only: read the detector's current dominant peer, if any.
    #[doc(hidden)]
    pub fn current_active_speaker(&self) -> Option<u64> {
        self.detector.current_dominant().copied()
    }

    /// Test-only: force both the Kalman delay and loss estimators for
    /// `subscriber` to report `target_bps`, bypassing TWCC simulation.
    /// Uses the kit's `force_high_estimate_for_tests` seam which zeroes
    /// both estimators to a fixed value without needing real network samples.
    /// `native_estimate_bps` is left untouched so ceiling semantics apply.
    /// Use [`Self::cap_subscriber_bandwidth_for_tests`] to apply a ceiling.
    #[doc(hidden)]
    pub fn drive_subscriber_bandwidth_for_tests(
        &mut self,
        subscriber: crate::propagate::ClientId,
        target_bps: u64,
    ) {
        self.bandwidth.force_high_estimate_for_tests(
            oxpulse_sfu_kit::propagate::ClientId(*subscriber),
            target_bps as f64,
        );
    }

    /// Test-only: pin a subscriber's GCC estimate ceiling so
    /// integration tests can simulate a capped downlink. Uses
    /// `record_native_estimate` which clamps our combined output to
    /// this ceiling via `min`.
    #[doc(hidden)]
    pub fn cap_subscriber_bandwidth_for_tests(
        &mut self,
        subscriber: crate::propagate::ClientId,
        bps: u64,
    ) {
        self.bandwidth.record_native_estimate(
            oxpulse_sfu_kit::propagate::ClientId(*subscriber),
            bps as f64,
        );
    }

    /// Test-only: force the pacer + metrics refresh out-of-band
    /// (normally invoked from the `MediaData` fanout path). Also
    /// drains any queued BandwidthEstimate events through
    /// `fanout_pending` so the wiring behaves as in production.
    ///
    /// `origin` identifies the publisher whose `active_rids` drive
    /// the `available_rids` pacer input (post M5.3-fix plumbing).
    /// Empty `active_rids` falls back to the default
    /// `[LOW, MEDIUM, HIGH]` ladder so tests that haven't seeded media
    /// still exercise the full-simulcast code path.
    #[doc(hidden)]
    pub fn force_pacer_refresh_for_tests(&mut self, origin: crate::propagate::ClientId) {
        self.update_pacer_layers(origin);
    }

    /// Test-only: seed an `active_rid` on a client by id, bypassing
    /// the `track_in_media` pipeline. Required for the screenshare
    /// regression test (publisher pretends to be emitting only `q` —
    /// without a real str0m media pipeline we have to inject directly).
    #[doc(hidden)]
    pub fn seed_active_rid_for_tests(&mut self, id: crate::propagate::ClientId, rid: Rid) {
        if let Some(client) = self.clients.iter_mut().find(|c| c.id == id) {
            client.seed_active_rid_for_tests(rid);
        }
    }

    /// Test-only: force-disconnect a client by id so the next
    /// `reap_dead` pass drops it. Used by the reap-round metrics
    /// cleanup test to exercise the label-scrub branch without
    /// spinning up a real STUN/DTLS pipeline.
    #[doc(hidden)]
    pub fn disconnect_client_for_tests(&mut self, id: crate::propagate::ClientId) {
        if let Some(client) = self.clients.iter_mut().find(|c| c.id == id) {
            client.disconnect_for_tests();
        }
    }

    /// Test-only: invoke `reap_dead` out-of-band.
    #[doc(hidden)]
    pub fn reap_dead_for_tests(&mut self) {
        self.reap_dead();
    }
}
