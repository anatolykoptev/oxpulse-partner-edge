//! Dependency Descriptor (DD) RTP header-extension seam — G3 P0 + P1.
//!
//! The AV1 RTP spec defines a *cleartext* RTP header extension that carries
//! the per-frame Dependency Descriptor:
//! <https://aomediacodec.github.io/av1-rtp-spec/#dependency-descriptor-rtp-header-extension>.
//!
//! The DD is the load-bearing signal for per-subscriber SVC layer selection:
//! it describes the spatial/temporal layer structure of each frame so a
//! forwarder can decide which frames to drop for a subscriber that wants a
//! lower layer — WITHOUT decrypting the payload. This is safe under our
//! SFrame (RFC 9605) E2EE because we do NOT perform CryptEx / RFC 9335
//! header-extension encryption, so the DD stays cleartext end-to-end.
//!
//! str0m 0.21 does not expose the DD, but it provides a clean plug-in seam:
//! the [`ExtensionSerializer`] trait + [`ExtensionValues::user_values`] typed
//! AnyMap + automatic URI-reconcile (str0m rebinds a registered serializer to
//! whatever extmap id the browser negotiated, matched BY URI). P0 proved that
//! seam works end-to-end. P1 adds the bit-parser ([`super::dd_parse`]) and the
//! per-stream structure cache ([`DdStructureCache`]).
//!
//! ## P0 behaviour (unchanged)
//!
//! [`DdSerializer::parse_value`] stores the raw extension bytes wrapped in
//! [`DdPresent`] into `user_values`, marking that a DD travelled on the
//! packet. [`DdSerializer::write_to`] re-emits the raw bytes verbatim when a
//! [`DdPresent`] value is present, so the extension round-trips faithfully.
//! The SFU never sets `DdPresent` on an egress stream (it only reads it from
//! ingress `MediaData.ext_vals`), so egress `write_to` is a no-op.
//!
//! ## P1: per-stream structure cache — design note
//!
//! A template-only DD (non-keyframe) carries only `frame_dependency_template_id`;
//! resolving its `temporal_id` needs the `template_dependency_structure` from
//! the last keyframe. The cache MUST be per-stream (per publisher track).
//!
//! **Why the cache is NOT inside `DdSerializer::parse_value`:** str0m's
//! `ExtensionSerializer::parse_value(&self, buf, &mut ExtensionValues)`
//! receives **no stream identity** — only the raw extension bytes and the
//! per-packet `ExtensionValues`. There is no SSRC, no `Mid`, no publisher id.
//! Caching per-stream inside `parse_value` is therefore impossible. The
//! cache lives here as a standalone [`DdStructureCache`] struct, instantiated
//! per-subscriber on `Client` and mutated via `&mut self` in
//! `handle_media_data_out` (which has `(origin, data.mid)` stream context).
//! No interior mutability is needed because the fanout path holds exclusive
//! `&mut Client` access — documented here per the P1 requirement.

use std::collections::HashMap;

use str0m::media::Mid;
use str0m::rtp::{ExtensionSerializer, ExtensionValues};

use super::dd_parse::TemplateDependencyStructure;
use crate::propagate::ClientId;

/// RTP header-extension URI for the AV1 Dependency Descriptor.
///
/// <https://aomediacodec.github.io/av1-rtp-spec/#dependency-descriptor-rtp-header-extension>
pub const DD_URI: &str =
    "https://aomediacodec.github.io/av1-rtp-spec/#dependency-descriptor-rtp-header-extension";

/// Marker stored in [`ExtensionValues::user_values`] when a Dependency
/// Descriptor extension was parsed on an incoming RTP packet.
///
/// Carries the raw extension bytes so [`DdSerializer::write_to`] can re-emit
/// them verbatim (forward-compatible round-trip). P0 only inspects presence
/// via `user_values.get::<DdPresent>()` — the bytes are NOT bit-parsed here
/// (spatial/temporal ids, DTIs, chains are P1).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DdPresent(pub Vec<u8>);

/// `ExtensionSerializer` for the AV1 Dependency Descriptor header extension.
///
/// P0: stores the raw bytes as [`DdPresent`] on parse and re-emits them on
/// write. No DD bit-layout knowledge is required at this phase.
#[derive(Debug, Clone, Copy)]
pub struct DdSerializer;

impl ExtensionSerializer for DdSerializer {
    fn write_to(&self, buf: &mut [u8], ev: &ExtensionValues) -> usize {
        let Some(dd) = ev.user_values.get::<DdPresent>() else {
            return 0;
        };
        let n = dd.0.len();
        if n == 0 || buf.len() < n {
            return 0;
        }
        buf[..n].copy_from_slice(&dd.0);
        n
    }

    fn parse_value(&self, buf: &[u8], ev: &mut ExtensionValues) -> bool {
        // Empty DD is not a valid extension element (RFC 8285 §4.2 one-byte
        // form has len 1..=16; two-byte len 0 is technically allowed but
        // carries no DD information). Treat it as absent so the presence
        // counter reflects real DD-bearing packets.
        if buf.is_empty() {
            return false;
        }
        ev.user_values.set(DdPresent(buf.to_vec()));
        true
    }

    fn is_video(&self) -> bool {
        true
    }

    fn is_audio(&self) -> bool {
        false
    }
}

// ─── P1: per-stream structure cache ─────────────────────────────────────────

/// Per-stream cache of the most-recent `template_dependency_structure` seen
/// on a keyframe DD. Used to resolve template-only DDs (non-keyframe frames
/// that carry only `frame_dependency_template_id`).
///
/// **Keying:** `(ClientId, Mid)` — the publisher's client id + the media id.
/// DD is an SVC signal (single SSRC with spatial/temporal layers), not
/// simulcast, so `(origin, mid)` uniquely identifies the publisher track.
/// `rid` is NOT part of the key (RID-simulcast selection lives in
/// `client/layer.rs`, out of scope for P1).
///
/// **Interior mutability:** none. The cache is mutated via `&mut self` in
/// `Client::handle_media_data_out`, which holds exclusive access to the
/// subscriber's `Client`. See the module-level design note for why the cache
/// cannot live inside `DdSerializer::parse_value` (no stream context there).
///
/// **Bounding:** entries are bounded by the number of active publisher tracks
/// the subscriber receives. The cache is capped at `MAX_STREAMS` (32); the
/// oldest entry is evicted on insert when full — a defensive guard against
/// adversarial mid churn. The cache lives on the subscriber's `Client` and
/// drops with it on disconnect, so departed-subscriber cleanup is automatic.
/// Stale entries for a departed *publisher* are not scrubbed cross-client
/// (that would require an O(N²) fan-out across survivors on every reap);
/// they are bounded by `MAX_STREAMS` and age out via the cap.
pub struct DdStructureCache {
    map: HashMap<(ClientId, Mid), TemplateDependencyStructure>,
    /// Simple LRU-ish ordering: keys in insertion order, oldest at front.
    /// Not a true LRU (no reordering on access) — sufficient for the cap guard.
    order: std::collections::VecDeque<(ClientId, Mid)>,
}

/// Maximum number of per-stream structures cached per subscriber. 32 is well
/// above the expected publisher count in a single SFU room (typically ≤ 12)
/// while bounding memory against adversarial mid churn.
const MAX_STREAMS: usize = 32;

impl DdStructureCache {
    pub fn new() -> Self {
        Self {
            map: HashMap::new(),
            order: std::collections::VecDeque::new(),
        }
    }

    /// Look up the cached structure for a stream.
    pub fn get(&self, key: &(ClientId, Mid)) -> Option<&TemplateDependencyStructure> {
        self.map.get(key)
    }

    /// Insert / replace the structure for a stream. Evicts the oldest entry
    /// if the cache is at capacity.
    pub fn insert(&mut self, key: (ClientId, Mid), structure: TemplateDependencyStructure) {
        if !self.map.contains_key(&key) {
            if self.order.len() >= MAX_STREAMS {
                if let Some(evicted) = self.order.pop_front() {
                    self.map.remove(&evicted);
                }
            }
            self.order.push_back(key);
        }
        self.map.insert(key, structure);
    }

    /// Number of cached structures.
    pub fn len(&self) -> usize {
        self.map.len()
    }

    /// Whether the cache is empty.
    pub fn is_empty(&self) -> bool {
        self.map.is_empty()
    }
}

impl Default for DdStructureCache {
    fn default() -> Self {
        Self::new()
    }
}

impl std::fmt::Debug for DdStructureCache {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DdStructureCache")
            .field("streams", &self.map.len())
            .finish()
    }
}
