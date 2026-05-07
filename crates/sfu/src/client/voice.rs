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
//! * `frame_malformed` — frame larger than `VOICE_FRAME_MAX_BYTES`
//!   (outbound oversize guard). Also emitted by the inbound gate in
//!   `client::dispatch` when an inbound voice frame exceeds the cap.
//! * `subscriber_dc_not_open` — `voice_data_cid` is `None`: this relay
//!   client never opened a voice DC (`with_voice_dc` not called). Soft miss.
//! * `dc_closed` — `Rtc::channel(cid)` returned `None`: DC was opened but
//!   DTLS has since closed it (race between DTLS teardown and fanout).
//! * `dc_send_failed` — `channel.write()` returned an error. Indicates the
//!   SCTP layer rejected the write (buffer full, reset, etc.) — not a
//!   malformed payload. Not in the original spec; added for operational
//!   visibility.
//! * `buffered_amount_too_high` — DC outbound buffer exceeds
//!   `VOICE_BUFFERED_AMOUNT_MAX` bytes. Drops the frame as backpressure
//!   rather than enqueuing into an already-full buffer.

use crate::propagate::ClientId;

use super::Client;

/// Maximum accepted voice payload size in bytes. 64 KB gives generous
/// headroom for any codec (Opus max packet is ~1276 bytes at 48kHz;
/// even future batch-packed frames won't approach 64 KB).
pub const VOICE_FRAME_MAX_BYTES: usize = 64 * 1024;

/// Maximum allowed DC outbound buffer before the frame is dropped as
/// backpressure. Matches `VOICE_FRAME_MAX_BYTES` so a single queued
/// frame worth of data is the ceiling before we start shedding.
const VOICE_BUFFERED_AMOUNT_MAX: usize = VOICE_FRAME_MAX_BYTES;

/// Drop-reason labels. Kept aligned with the pre-touched series in
/// `metrics::SfuMetrics::new` so every label has a visible 0 baseline.
/// These are the spec-mandated label values for `voice_relay_dropped_total`.
const REASON_FRAME_MALFORMED: &str = "frame_malformed";
const REASON_SUBSCRIBER_DC_NOT_OPEN: &str = "subscriber_dc_not_open";
const REASON_DC_CLOSED: &str = "dc_closed";
const REASON_DC_SEND_FAILED: &str = "dc_send_failed";
const REASON_BUFFERED_AMOUNT_TOO_HIGH: &str = "buffered_amount_too_high";

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
                .with_label_values(&[REASON_FRAME_MALFORMED])
                .inc();
            return;
        }

        let Some(cid) = self.voice_data_cid else {
            // voice_data_cid is None — this relay client never opened a voice
            // DC (with_voice_dc was not called). Soft miss, expected for relay
            // clients that have no UI voice path.
            self.metrics
                .voice_relay_dropped
                .with_label_values(&[REASON_SUBSCRIBER_DC_NOT_OPEN])
                .inc();
            return;
        };

        let client_id_label = self.id.0.to_string();

        let Some(mut ch) = self.rtc.channel(cid) else {
            // DC was opened (voice_data_cid is Some) but Rtc::channel returned
            // None — DTLS has closed or reset the channel since with_voice_dc.
            self.metrics
                .voice_relay_dropped
                .with_label_values(&[REASON_DC_CLOSED])
                .inc();
            return;
        };

        // Backpressure guard: if the DC outbound buffer is already full,
        // drop this frame rather than enqueue into an overflowed buffer.
        // Fires `buffered_amount_too_high`; the sender is expected to reduce
        // bitrate when this counter rises (application-layer feedback is out
        // of scope for the SFU relay).
        let buffered = ch.buffered_amount();
        if buffered > VOICE_BUFFERED_AMOUNT_MAX {
            tracing::warn!(
                client = *self.id,
                buffered,
                "voice-relay: DC buffer full, dropping frame"
            );
            self.metrics
                .voice_relay_dropped
                .with_label_values(&[REASON_BUFFERED_AMOUNT_TOO_HIGH])
                .inc();
            return;
        }

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
                    .with_label_values(&[REASON_DC_SEND_FAILED])
                    .inc();
            }
        }
    }
}
