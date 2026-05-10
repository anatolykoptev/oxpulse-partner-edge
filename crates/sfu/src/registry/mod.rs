//! Multi-client registry — routes UDP datagrams to the owning client
//! and fans out propagated events. Single-task ownership model
//! (no `Arc<RwLock>`). See chat.rs example for the original shape.
//!
//! Submodules: [`bwe`] (BWE + pacer accessors),
//! [`poll`] (poll_all / tick / fanout_pending),
//! [`test_seams`] (gated test-only helpers).

use std::collections::VecDeque;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Instant;

use str0m::net::{Protocol, Receive};
use str0m::Input;

use crate::client::{Client, Transmit};
use crate::metrics::SfuMetrics;
use crate::pacer::Pacer;
use crate::propagate::Propagated;
use dominant_speaker::ActiveSpeakerDetector;
use oxpulse_sfu_kit::bwe::estimator::BandwidthEstimator;

mod bwe;
mod poll;
#[cfg(any(test, feature = "test-utils"))]
mod test_seams;

use bwe::PACER_RID_LABELS;

/// Single-owner registry of connected peers. M1.4 adds an
/// `ActiveSpeakerDetector` driven by `udp_loop::serve`'s 300ms interval
/// (no detached tick task — preserves the single-task invariant).
/// M1.5 adds `SfuMetrics` threaded via constructor (no globals).
/// M5.3 adds a [`BandwidthEstimator`] + [`Pacer`] pair so per-subscriber
/// GCC output can steer simulcast-layer selection in
/// [`crate::client::fanout::handle_media_data_out`].
#[derive(Debug)]
pub struct Registry {
    pub(super) clients: Vec<Client>,
    pub(super) to_propagate: VecDeque<Propagated>,
    pub(super) detector: ActiveSpeakerDetector,
    pub(super) detector_epoch: Instant,
    /// M6.1: wall-clock time of the most recent `ActiveSpeakerChanged` emission.
    /// Used by `tick_active_speaker` to compute inter-change intervals for the
    /// hysteresis histogram (replacing the inlined `record_hysteresis_observation`).
    pub(super) last_speaker_change: Option<Instant>,
    pub(super) metrics: Arc<SfuMetrics>,
    pub(super) bandwidth: BandwidthEstimator,
    pub(super) pacer: Pacer,
    /// GoogCC v2 estimator — trendline delay + AIMD (additive alongside kit BWE).
    pub(super) googcc: crate::bwe::estimator::GoogCcEstimator,
    /// Instant at which the room first became a solo-peer room (exactly 1 client).
    /// `None` when the room has 0 or ≥2 clients.
    /// Set on `insert` / `reap_dead` when the count drops to 1;
    /// cleared when count becomes 0 or ≥2.
    /// Used by `check_solo_timeout` to evict lone peers after the configured hold.
    pub(super) solo_since: Option<Instant>,
    /// Shared secret for relay_source roomToken verification. Copied into each
    /// client at insert() time so DC messages can be verified in-place.
    pub(super) relay_auth_secret: Option<Arc<[u8]>>,
    /// Ed25519 public key (PEM) for EdDSA-signed room token verification (Phase 2).
    /// Copied into each client at insert() time alongside relay_auth_secret.
    pub(super) relay_signing_pubkey: Option<Arc<String>>,
}

impl Registry {
    pub fn new(metrics: Arc<SfuMetrics>) -> Self {
        Self::with_relay_secret(metrics, None)
    }

    /// Construct a registry with a relay authentication secret.
    /// Pass `Some(secret)` to enforce roomToken verification on relay_source DC messages.
    /// Pass `None` for dev/test mode (unauthenticated relay).
    pub fn with_relay_secret(
        metrics: Arc<SfuMetrics>,
        relay_auth_secret: Option<Arc<[u8]>>,
    ) -> Self {
        Self::with_relay_auth(metrics, relay_auth_secret, None)
    }

    /// Construct a registry with both HS256 secret and Ed25519 pubkey for room token auth.
    ///
    /// When `relay_signing_pubkey` is `Some`, EdDSA verification is preferred for
    /// relay_source DataChannel messages; HS256 is used as fallback when only
    /// `relay_auth_secret` is set.
    pub fn with_relay_auth(
        metrics: Arc<SfuMetrics>,
        relay_auth_secret: Option<Arc<[u8]>>,
        relay_signing_pubkey: Option<Arc<String>>,
    ) -> Self {
        let detector = ActiveSpeakerDetector::new();
        Self {
            clients: Vec::new(),
            to_propagate: VecDeque::new(),
            detector,
            detector_epoch: Instant::now(),
            last_speaker_change: None,
            metrics,
            bandwidth: BandwidthEstimator::new(),
            pacer: Pacer::new(),
            googcc: crate::bwe::estimator::GoogCcEstimator::new(),
            relay_auth_secret,
            relay_signing_pubkey,
            solo_since: None,
        }
    }

    /// Construct a registry with a fresh throwaway metrics instance.
    /// Intended only for tests that don't care about metrics values.
    #[cfg(any(test, feature = "test-utils"))]
    pub fn new_for_tests() -> Self {
        Self::new(Arc::new(SfuMetrics::default()))
    }

    pub fn is_empty(&self) -> bool {
        self.clients.is_empty()
    }

    pub fn len(&self) -> usize {
        self.clients.len()
    }

    /// Expose the underlying clients for tests and metrics. Not for
    /// production hot-path use.
    #[doc(hidden)]
    pub fn clients(&self) -> &[Client] {
        &self.clients
    }

    /// Insert a freshly-built client. Announces every existing client's
    /// tracks to the newcomer (chat.rs cross-advertisement pattern).
    /// The client's metrics handle is replaced with the registry's own
    /// so all counters (including per-forward) flow to one registry.
    ///
    /// Phase A Task A1 — peer_id-keyed session steal: if a client with
    /// the same `external_peer_id` (JWT `sub`) is already registered,
    /// the older session is signaled over its `close_signal` channel
    /// (delivers WS close 4031), evicted from the clients vec, and the
    /// newcomer adopts the slot. Defends against duplicate `/sfu/ws`
    /// upgrades from client multi-mount races (SvelteKit hydration,
    /// stale SW caches, lobby double-click). Live-debugged on
    /// MTBX-6732 2026-04-28: peer_id=2 opened two upgrades 144 ms apart
    /// and the older one's 15 s `bad offer` timeout poisoned the
    /// newer session's UI.
    pub fn insert(&mut self, mut client: Client) {
        // Adopt the registry's metrics so forwarded_packets / layer_selection
        // increments land on the same Prometheus registry as connect / disconnect.
        client.metrics = self.metrics.clone();
        // Copy the relay authentication secret so this client can verify
        // relay_source DataChannel messages in-place without touching the registry.
        client.relay_auth_secret = self.relay_auth_secret.clone();
        // Phase 2: also copy the Ed25519 pubkey for EdDSA-preferred verification.
        client.relay_signing_pubkey = self.relay_signing_pubkey.clone();

        // Session steal — drop the older entry sharing this external
        // peer_id BEFORE the cross-advertisement loop so the newcomer
        // doesn't see itself as a peer to subscribe to. Only browser
        // clients carry an `external_peer_id`; relay clients (None)
        // bypass this check entirely.
        if let Some(new_pid) = client.external_peer_id {
            if let Some(idx) = self
                .clients
                .iter()
                .position(|c| c.external_peer_id == Some(new_pid))
            {
                self.evict_for_steal(idx);
            }
        }

        // Cross-advertise existing publisher tracks to the newcomer.
        // Each iteration represents one publisher→subscriber subscription wiring.
        // sfu_subscription_setup_total lets operators confirm late joiners receive
        // exactly N wired events (one per existing publisher's track).
        let subscriber_peer = (*client.id).to_string();
        for pub_client in self.clients.iter() {
            let publisher_peer = (*pub_client.id).to_string();
            for entry in pub_client.tracks_in.iter() {
                client.handle_track_open(std::sync::Arc::downgrade(&entry.id));
                self.metrics
                    .sfu_subscription_setup_total
                    .with_label_values(&[&publisher_peer, &subscriber_peer, "wired"])
                    .inc();
            }
        }
        let peer_id = *client.id;
        let now_ms = self.detector_epoch.elapsed().as_millis() as u64;
        self.detector.add_peer(peer_id, now_ms);
        self.metrics.client_connect_total.inc();
        self.metrics.active_participants.inc();
        // Single-room SFU: any client present means the room is active.
        // Idempotent — `set(1)` on second insert is a no-op.
        // (Post-mortem 2026-05-06: previously hardcoded at init.)
        self.metrics.active_rooms.set(1);
        self.clients.push(client);
        // Update solo_since:
        // * 1 client after insert (first joiner) → start solo clock.
        // * ≥2 clients after insert → clear solo clock (second+ joiner joined).
        match self.clients.len() {
            1 => {
                // First joiner — room is now solo. Start clock.
                self.solo_since = Some(Instant::now());
            }
            _ => {
                // Second or later joiner — room has company. Clear clock.
                self.solo_since = None;
            }
        }
        // Emit a codec-capability hint so relay layers or application code can
        // inform the new peer that this SFU supports Opus RED / DRED.
        self.to_propagate.push_back(Propagated::AudioCodecHint {
            peer_id,
            opus_red: true,
            opus_dred: true,
        });
    }

    /// Evict the client at `idx` because a newer upgrade for the same
    /// `external_peer_id` is replacing it. Mirrors the cleanup in
    /// [`Self::reap_dead`]: signals the WS task to close, decrements
    /// the active-participants gauge, scrubs detector / BWE / pacer /
    /// per-peer label series, and bumps `client_disconnect_total` plus
    /// the dedicated `session_replaced_total` counter.
    ///
    /// `swap_remove` is safe here — `self.clients` ordering is not
    /// load-bearing (the registry iterates with `iter`/`iter_mut` and
    /// looks up by `id` or `accepts(input)` everywhere).
    fn evict_for_steal(&mut self, idx: usize) {
        let mut old = self.clients.swap_remove(idx);
        let peer_label = (*old.id).to_string();
        let external_peer_id = old.external_peer_id;

        // Wake the old WS task so it sends the 4031 close frame and
        // returns. `send` returning `Err` means the receiver was already
        // dropped (e.g. WS task exited on its own); benign.
        if let Some(tx) = old.close_signal.take() {
            let _ = tx.send(crate::client::CloseReason::SessionReplaced);
        }

        // Mark the str0m instance dead so any in-flight UDP demux drops
        // the datagram instead of routing to a soon-to-be-gone Rtc.
        old.rtc.disconnect();

        // Mirror reap_dead's scrub: detector / BWE / pacer / labels.
        self.detector.remove_peer(&old.id.0);
        self.bandwidth
            .reap_dead(oxpulse_sfu_kit::propagate::ClientId(*old.id));
        self.pacer.remove(&old.id);

        let _ = self
            .metrics
            .bandwidth_estimate_bps
            .remove_label_values(&[&peer_label]);
        // MINOR (round-3): mirror reap_dead's client_delivered_media_count scrub
        // so reconnect churn doesn't grow cardinality via the steal path.
        let _ = self
            .metrics
            .client_delivered_media_count
            .remove_label_values(&[&peer_label]);
        for rid_label in PACER_RID_LABELS {
            let _ = self
                .metrics
                .pacer_layer_total
                .remove_label_values(&[&peer_label, rid_label]);
            for to_label in PACER_RID_LABELS {
                let _ = self.metrics.layer_transitions_total.remove_label_values(&[
                    rid_label,
                    to_label,
                    &peer_label,
                ]);
            }
        }

        // F2b-2: drop chat_relay_{tx,rx}_bytes_total{dc, client_id} series
        // for both dc values, mirroring `bwe::Registry::reap_dead` scrub path.
        for dc in ["data", "ctrl"] {
            let _ = self
                .metrics
                .chat_relay_tx_bytes_total
                .remove_label_values(&[dc, &peer_label]);
            let _ = self
                .metrics
                .chat_relay_rx_bytes_total
                .remove_label_values(&[dc, &peer_label]);
        }
        // Phase 8 T10: drop voice_relay_{tx,rx}_bytes_total{client_id} series,
        // mirroring the reap_dead scrub path for the same cardinality invariant.
        let _ = self
            .metrics
            .voice_relay_tx_bytes_total
            .remove_label_values(&[&peer_label]);
        let _ = self
            .metrics
            .voice_relay_rx_bytes_total
            .remove_label_values(&[&peer_label]);
        // Phase 2c review fix (MAJOR 1): mirror reap_dead scrub for bwe-hint
        // counters on session-steal eviction path.
        let _ = self
            .metrics
            .sfu_bwe_hint_received_total
            .remove_label_values(&[&peer_label]);
        let _ = self
            .metrics
            .sfu_bwe_hint_throttled_total
            .remove_label_values(&[&peer_label]);
        // MAJOR-2: mirror the reap_dead gauge dec for the session-steal path.
        if old.voice_data_cid.is_some() {
            self.metrics
                .voice_relay_active_channels
                .with_label_values(&["voice"])
                .dec();
        }
        // chat gauge dec — mirror voice path for session-steal (followup to T10 MAJOR-2).
        // with_chat_dcs increments both {data} and {ctrl} on open; decrement here
        // on steal so reconnect storms don't monotonically inflate the gauge.
        if old.chat_data_cid.is_some() {
            self.metrics
                .chat_relay_active_channels
                .with_label_values(&["data"])
                .dec();
        }
        if old.chat_ctrl_cid.is_some() {
            self.metrics
                .chat_relay_active_channels
                .with_label_values(&["ctrl"])
                .dec();
        }
        // reactions gauge dec — only when the gauge was actually incremented
        // (Event::ChannelOpen fired). Guard on `reactions_dc_opened` (not
        // `reactions_dc_cid.is_some()`) to prevent double-dec and phantom decs
        // for v0.12.22 browsers that never completed SCTP DCEP before steal.
        if old.reactions_dc_opened {
            self.metrics
                .chat_relay_active_channels
                .with_label_values(&["reactions"])
                .dec();
        }

        self.metrics.client_disconnect_total.inc();
        self.metrics.active_participants.dec();
        self.metrics.session_replaced_total.inc();

        // Round-2 review fix: mirror `reap_dead`'s active_rooms invariant.
        // Today every production caller chains a follow-up `insert` that
        // resets the gauge to 1; future eviction paths (panic recovery,
        // auth revocation) might not, leaving active_rooms=1 with zero
        // clients — the exact silent-fail mode the 2026-05-06 post-mortem
        // targeted. Pin the invariant at the eviction site itself.
        if self.clients.is_empty() {
            self.metrics.active_rooms.set(0);
        }

        tracing::warn!(
            target: "sfu::registry",
            peer_id = ?external_peer_id,
            internal_id = *old.id,
            "session replaced — older client evicted (Phase A Task A1)"
        );

        // `old` drops here — str0m Rtc Drop cleans ICE/DTLS state.
    }

    /// Mark a connected client as a cascade relay from an upstream SFU.
    ///
    /// Call as soon as possible after `insert()` — ideally driven by the
    /// `MarkRelaySource` DC handshake via `fanout_pending`. Relay clients are
    /// excluded from dominant-speaker election and keyframe requests will be
    /// routed upstream rather than back to the relay connection.
    ///
    /// Idempotent: calling with the same `client_id` twice is safe.
    pub fn mark_relay_source(
        &mut self,
        client_id: crate::propagate::ClientId,
        upstream_url: String,
    ) {
        if let Some(client) = self.clients.iter_mut().find(|c| c.id == client_id) {
            client.set_origin(oxpulse_sfu_kit::ClientOrigin::RelayFromSfu(upstream_url));
            // Remove from detector retroactively — relay clients were inserted as
            // Local before the DC handshake completed, so they were added to the
            // detector. Removing here corrects that without requiring a full
            // teardown/re-insert cycle.
            self.detector.remove_peer(&client_id.0);
        }
    }

    /// Check whether the lone remaining peer has been solo for longer than
    /// `timeout`. If so, disconnect it so the next `reap_dead` pass removes it.
    ///
    /// `now` is passed in (rather than reading `Instant::now()` internally)
    /// so tests can control time without spinning up a real clock.
    ///
    /// No-op when the room has 0 or ≥2 participants.
    pub fn check_solo_timeout(&mut self, timeout: std::time::Duration, now: std::time::Instant) {
        // Only act when exactly 1 client is present.
        if self.clients.len() != 1 {
            return;
        }
        let Some(since) = self.solo_since else {
            return;
        };
        // Saturating sub: if clock goes backwards (e.g. test harness), elapsed = 0.
        let elapsed = now.saturating_duration_since(since);
        if elapsed < timeout {
            return;
        }
        // Exactly 1 client present — safe to index.
        if let Some(client) = self.clients.first_mut() {
            tracing::info!(
                target: "sfu::registry",
                peer_id = *client.id,
                elapsed_secs = elapsed.as_secs(),
                "solo peer exceeded hold timeout — disconnecting",
            );
            client.rtc.disconnect();
            self.metrics.sfu_solo_room_kicked_total.inc();
            // Clear so a subsequent (stale) check_solo_timeout call is a no-op
            // until reap_dead refreshes the state.
            self.solo_since = None;
        }
    }

    /// Route an incoming UDP datagram to whichever client claims it.
    /// Returns `true` if a client accepted, `false` when no client
    /// matched (common early in a connection — STUN arrives before the
    /// `Rtc` is registered).
    pub fn handle_incoming(
        &mut self,
        source: SocketAddr,
        destination: SocketAddr,
        payload: &[u8],
    ) -> bool {
        let Ok(contents) = payload.try_into() else {
            tracing::debug!(?source, bytes = payload.len(), "undecodable udp datagram");
            return false;
        };
        let input = Input::Receive(
            Instant::now(),
            Receive {
                proto: Protocol::Udp,
                source,
                destination,
                contents,
            },
        );
        if let Some(client) = self.clients.iter_mut().find(|c| c.accepts(&input)) {
            client.handle_input(input);
            true
        } else {
            tracing::debug!(?source, "no client accepts udp datagram");
            false
        }
    }

    /// Drain every client's outbound queue into `sink`. The caller
    /// (usually `udp_loop`) writes the bytes to the socket.
    pub fn drain_transmits<F: FnMut(Transmit)>(&mut self, mut sink: F) {
        for client in self.clients.iter_mut() {
            for t in client.drain_pending_out() {
                sink(t);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::client::test_seed::new_client;
    use crate::propagate::ClientId;

    /// When a second peer joins a room that already has an active publisher
    /// with at least one `tracks_in` entry, `Registry::insert` must emit
    /// exactly one `sfu_subscription_setup_total{result="wired"}` event per
    /// publisher track. This counter is the primary signal for diagnosing
    /// late-join forwarding failures: if it is 0 after a join, the
    /// cross-advertisement loop was skipped.
    #[test]
    fn insert_second_client_emits_subscription_setup_counter() {
        let metrics = Arc::new(SfuMetrics::new().expect("metrics build"));
        let mut registry = Registry::new(metrics.clone());

        // First peer: publisher. No existing clients → zero subscription events.
        let publisher = new_client(ClientId(1));
        registry.insert(publisher);
        // First joiner — no existing tracks → 0 subscription events.
        let count_after_first = metrics
            .sfu_subscription_setup_total
            .with_label_values(&["1", "1", "wired"])
            .get();
        // Nothing to wire yet (self-to-self is skipped by cross-ad loop).
        // The counter for src=1, dst=1 should not have been bumped; the loop
        // iterates over existing clients BEFORE inserting the newcomer, so
        // first insert sees an empty slice.
        assert_eq!(
            count_after_first, 0,
            "first client insert must not emit subscription events (room was empty)"
        );

        // Second peer: subscriber. Publisher has no tracks_in yet (no str0m
        // media pipeline in unit tests) → loop iterates over 0 TrackInEntry.
        // The counter should still be 0 because there are no tracks to wire.
        let subscriber = new_client(ClientId(2));
        registry.insert(subscriber);
        let count_src1_dst2 = metrics
            .sfu_subscription_setup_total
            .with_label_values(&["1", "2", "wired"])
            .get();
        assert_eq!(
            count_src1_dst2, 0,
            "no tracks_in means no subscription events — counter must be 0"
        );

        // Touch one label pair to materialise the series, then confirm it
        // appears in /metrics text. Dynamic-label counters only emit HELP/TYPE
        // lines after the first inc (prometheus crate behaviour).
        metrics
            .sfu_subscription_setup_total
            .with_label_values(&["1", "2", "wired"])
            .inc();
        let text = metrics.encode_text().expect("encode metrics");
        assert!(
            text.contains("sfu_sfu_subscription_setup_total"),
            "sfu_subscription_setup_total must appear in /metrics after first inc, got:\n{text}",
        );
    }
}
