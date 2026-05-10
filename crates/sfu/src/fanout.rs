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

    // `TopSpeakers` is a broadcast — deliver to *all* clients (no skip-self).
    // Uses the same DC id:3 (`sfu-active-speaker`) as `ActiveSpeakerChanged`.
    if let Propagated::TopSpeakers(ref speakers) = p {
        // Build a compact JSON array of u64 peer IDs without serde_json.
        let ids: Vec<String> = speakers.iter().map(|id| id.to_string()).collect();
        let payload = format!(r#"{{"type":"top_speakers","peerIds":[{}]}}"#, ids.join(","));
        for client in clients.iter_mut() {
            let Some(mut ch) = client.rtc.channel(client.active_speaker_cid) else {
                // DC not yet open — skip silently; next tick will retry.
                continue;
            };
            if let Err(e) = ch.write(false, payload.as_bytes()) {
                tracing::warn!(client = *client.id, error = ?e, "top_speakers DC write failed");
            }
        }
        return;
    }

    // `AudioCodecHint` is application-level — no fanout to clients.
    if let Propagated::AudioCodecHint {
        peer_id,
        opus_red,
        opus_dred,
    } = p
    {
        tracing::debug!(%peer_id, opus_red, opus_dred, "audio codec hint");
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
            // Phase 2b: chat-data + chat-ctrl per-peer relay. Skip-self is
            // already handled by the `client.id == origin` guard above plus
            // a defensive check inside `handle_chat_{data,ctrl}_out`.
            Propagated::ChatData(_, payload) => client.handle_chat_data_out(origin, payload),
            Propagated::ChatCtrl(_, payload) => client.handle_chat_ctrl_out(origin, payload),
            // Phase 8 T10: voice DC relay. Same skip-self + dc-not-open
            // guard pattern as chat-data / chat-ctrl above.
            Propagated::VoiceData(_, payload) => client.handle_voice_data_out(origin, payload),
            // KX fix: sframe-keys relay. Skip-self guard mirrors chat-data.
            Propagated::KeysData(_, payload) => client.handle_keys_data_out(origin, payload),
            Propagated::Noop
            | Propagated::Timeout(_)
            | Propagated::ActiveSpeakerChanged { .. }
            | Propagated::BandwidthEstimate(..)
            | Propagated::ClientBudgetHint(..)
            | Propagated::PublisherLayerHint { .. }
            | Propagated::TopSpeakers(_)
            | Propagated::AudioCodecHint { .. }
            | Propagated::MarkRelaySource(..)
            | Propagated::UpstreamKeyframeRequest { .. }
            | Propagated::PublisherLayerHintForUpstream { .. } => {
                // BandwidthEstimate, ClientBudgetHint, PublisherLayerHint, and relay
                // variants are consumed inside `Registry::fanout_pending` before
                // this function is called — safe no-op if any appear here.
                // TopSpeakers and AudioCodecHint are handled above with early
                // returns and never reach this arm.
            }
            #[cfg(feature = "vfm")]
            Propagated::VfmLayerCap(..) => {
                // VfmLayerCap is consumed inside `Registry::fanout_pending`.
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
