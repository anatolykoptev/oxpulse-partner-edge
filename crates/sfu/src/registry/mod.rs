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

use crate::active_speaker::ActiveSpeakerDetector;
use crate::bandwidth::BandwidthEstimator;
use crate::client::{Client, Transmit};
use crate::metrics::SfuMetrics;
use crate::pacer::Pacer;
use crate::propagate::Propagated;

mod bwe;
mod poll;
#[cfg(any(test, feature = "test-utils"))]
mod test_seams;

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
    pub(super) metrics: Arc<SfuMetrics>,
    pub(super) bandwidth: BandwidthEstimator,
    pub(super) pacer: Pacer,
}

impl Registry {
    pub fn new(metrics: Arc<SfuMetrics>) -> Self {
        let mut detector = ActiveSpeakerDetector::new();
        // M6.1: wire the hysteresis histogram so tick_active_speaker can observe
        // inter-change intervals without an extra metrics lookup in the hot path.
        detector.set_hysteresis_histogram(metrics.dominant_speaker_hysteresis_ms.clone());
        Self {
            clients: Vec::new(),
            to_propagate: VecDeque::new(),
            detector,
            metrics,
            bandwidth: BandwidthEstimator::new(),
            pacer: Pacer::new(),
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
    pub fn insert(&mut self, mut client: Client) {
        // Adopt the registry's metrics so forwarded_packets / layer_selection
        // increments land on the same Prometheus registry as connect / disconnect.
        client.metrics = self.metrics.clone();
        for entry in self.clients.iter().flat_map(|c| c.tracks_in.iter()) {
            client.handle_track_open(std::sync::Arc::downgrade(&entry.id));
        }
        self.detector.add_peer(*client.id, Instant::now());
        self.metrics.client_connect_total.inc();
        self.metrics.active_participants.inc();
        self.clients.push(client);
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
