//! Cross-client event fanout.
//!
//! Separate from [`registry`][crate::registry] — that module owns
//! routing UDP-to-client and polling; this module owns the "deliver
//! one `Propagated` event to every non-origin client" logic, which in
//! chat.rs is the free `propagate` function.
//!
//! The M1.3 simulcast filter lives deeper — in
//! [`client::fanout::handle_media_data_out`][crate::client::fanout] —
//! so this module just dispatches the right method per variant.

use crate::client::Client;
use crate::propagate::Propagated;

/// Apply a single propagated event to every client except the
/// originator. `pub(crate)` so the registry's own methods and the
/// `#[cfg(test)]` test seam can call it.
pub(crate) fn fanout(p: &Propagated, clients: &mut [Client]) {
    // `ActiveSpeakerChanged` carries a bare `peer_id: u64` (mediasoup's
    // observer shape) rather than a `ClientId` origin — handle it
    // separately so `client_id()`-based skip doesn't short-circuit.
    if let Propagated::ActiveSpeakerChanged {
        peer_id,
        confidence,
    } = p
    {
        for client in clients.iter_mut() {
            if *client.id == *peer_id {
                // Skip-self: the speaker themselves doesn't receive
                // their own dominance notification.
                continue;
            }
            client.handle_active_speaker_changed(*peer_id, *confidence);
        }
        return;
    }

    let Some(origin) = p.client_id() else {
        return;
    };
    for client in clients.iter_mut() {
        if client.id == origin {
            continue;
        }
        match p {
            Propagated::TrackOpen(_, track_in) => client.handle_track_open(track_in.clone()),
            Propagated::MediaData(_, data) => client.handle_media_data_out(origin, data),
            Propagated::KeyframeRequest(_, req, source, mid_in) => {
                if *source == client.id {
                    client.handle_keyframe_request(*req, *mid_in);
                }
            }
            Propagated::Noop
            | Propagated::Timeout(_)
            | Propagated::ActiveSpeakerChanged { .. }
            | Propagated::BandwidthEstimate(..)
            | Propagated::ClientBudgetHint(..) => {
                // BandwidthEstimate and ClientBudgetHint are consumed inside
                // `Registry::fanout_pending` before this function is called —
                // safe no-op if either appears here.
            }
        }
    }
}

/// Test-only seam: drive `fanout` against a caller-owned
/// `&mut [Client]`. `tests/multi_client.rs` uses this to exercise
/// fanout semantics without running the full async loop.
#[cfg(any(test, feature = "test-utils"))]
#[doc(hidden)]
pub fn fanout_for_tests(p: &Propagated, clients: &mut [Client]) {
    fanout(p, clients);
}
