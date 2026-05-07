//! Phase 8 T10 — voice DC relay outbound writer.
//!
//! Per-peer fanout sink for `Propagated::VoiceData`.
//! `crate::fanout::fanout` calls this on every non-origin client to push
//! the voice frame down the pre-negotiated voice DC opened in
//! [`super::construct`]:
//!
//!   * `voice` — id:6, unordered, `Reliability::MaxPacketLifetime{200ms}`
//!
//! Drop conditions emit `voice_relay_dropped_total{reason}`:
//! * `oversize` — frame larger than `VOICE_FRAME_MAX_BYTES`.
//! * `no_channel` — `Rtc::channel(cid)` returned `None` (DTLS still
//!   negotiating, channel closed, or `with_voice_dc` not called on this
//!   client). Treated as a soft miss.
//! * `write_err` — `channel.write()` returned an error.

use crate::propagate::ClientId;

use super::Client;

/// Maximum accepted voice payload size in bytes. 64 KB gives generous
/// headroom for any codec (Opus max packet is ~1276 bytes at 48kHz;
/// even future batch-packed frames won't approach 64 KB).
pub const VOICE_FRAME_MAX_BYTES: usize = 64 * 1024;

/// Drop-reason labels. Kept aligned with the pre-touched series in
/// `metrics::SfuMetrics::new` so every label has a visible 0 baseline.
const REASON_OVERSIZE: &str = "oversize";
const REASON_NO_CHANNEL: &str = "no_channel";
const REASON_WRITE_ERR: &str = "write_err";

impl Client {
    /// Forward a `Propagated::VoiceData` payload to *this* peer over the
    /// pre-negotiated `voice` DC. No-op when `origin == self.id` (skip-self
    /// echo guard) or when the voice DC was never opened (relay clients — see
    /// [`Client::with_voice_dc`]). Errors and oversize frames are dropped with
    /// a metric emit; we never disconnect the peer on a voice-relay failure.
    pub fn handle_voice_data_out(&mut self, origin: ClientId, payload: &[u8]) {
        if self.id == origin {
            return;
        }
        if payload.len() > VOICE_FRAME_MAX_BYTES {
            tracing::warn!(
                client = *self.id,
                len = payload.len(),
                "voice-relay: payload exceeds size cap, dropping"
            );
            self.metrics
                .voice_relay_dropped
                .with_label_values(&[REASON_OVERSIZE])
                .inc();
            return;
        }

        let Some(cid) = self.voice_data_cid else {
            // No voice DC opened (relay client or with_voice_dc not called).
            self.metrics
                .voice_relay_dropped
                .with_label_values(&[REASON_NO_CHANNEL])
                .inc();
            return;
        };

        let client_id_label = self.id.0.to_string();

        let Some(mut ch) = self.rtc.channel(cid) else {
            self.metrics
                .voice_relay_dropped
                .with_label_values(&[REASON_NO_CHANNEL])
                .inc();
            return;
        };

        match ch.write(false, payload) {
            Ok(_) => {
                self.metrics
                    .voice_relay_tx_bytes_total
                    .with_label_values(&[&client_id_label])
                    .inc_by(payload.len() as u64);
            }
            Err(e) => {
                tracing::warn!(
                    client = *self.id,
                    error = ?e,
                    "voice-relay: DC write failed"
                );
                self.metrics
                    .voice_relay_dropped
                    .with_label_values(&[REASON_WRITE_ERR])
                    .inc();
            }
        }
    }
}
