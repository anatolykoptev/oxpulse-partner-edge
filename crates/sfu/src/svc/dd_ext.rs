//! Dependency Descriptor (DD) RTP header-extension seam — G3 Phase 0.
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
//! whatever extmap id the browser negotiated, matched BY URI). P0 proves that
//! seam works end-to-end and adds a Prometheus counter. **No bit-parsing, no
//! layer drop** — those are P1.
//!
//! P0 behaviour: [`DdSerializer::parse_value`] stores the raw extension bytes
//! wrapped in [`DdPresent`] into `user_values`, marking that a DD travelled on
//! the packet. [`DdSerializer::write_to`] re-emits the raw bytes verbatim when
//! a [`DdPresent`] value is present, so the extension round-trips faithfully.
//! The SFU never sets `DdPresent` on an egress stream (it only reads it from
//! ingress `MediaData.ext_vals`), so egress `write_to` is a no-op and P0
//! changes no forwarding behaviour — pure observability.

use str0m::rtp::{ExtensionSerializer, ExtensionValues};

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
