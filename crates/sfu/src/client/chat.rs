//! Phase 2b chat-relay outbound writers.
//!
//! Per-peer fanout sinks for `Propagated::ChatData` / `Propagated::ChatCtrl`.
//! `crate::fanout::fanout` calls these on every non-origin client to push
//! the AEAD-sealed (chat-data) or unsealed-by-design (chat-ctrl) payload
//! down the pre-negotiated DC opened in [`super::construct`]:
//!
//!   * `chat-data` — id:4, ordered, `Reliability::Reliable`
//!   * `chat-ctrl` — id:5, !ordered, `Reliability::MaxRetransmits{0}`
//!
//! Drop conditions emit `chat_relay_dropped_total{dc, reason}`:
//! * `oversize` — frame larger than 256 KB (matches client wire codec).
//! * `no_channel` — `Rtc::channel(cid)` returned `None` (DTLS still
//!   negotiating, or channel closed). Treated as a soft miss; a
//!   reactive 300ms re-tick path is not added — the next chat frame
//!   from the origin will retry naturally.
//! * `write_err` — `channel.write()` returned an error.
//! * `channel_closed` — reserved label, pre-touched on the registry,
//!   no emit-site yet (str0m surfaces close as a soft
//!   `channel(cid) == None` today).

use crate::propagate::ClientId;

use super::Client;

/// Maximum accepted chat-data / chat-ctrl payload size in bytes.
/// Mirrors [`super::dc::CHAT_FRAME_MAX_BYTES`] — replicated as a private
/// constant rather than re-exported because the producer-side guard in
/// `dc.rs` already prevents oversize frames from ever reaching this
/// fanout method. The check here is defence-in-depth against a future
/// caller (e.g. a server-originated chat-ctrl heartbeat) that bypasses
/// the inbound DC handler.
const CHAT_FRAME_MAX_BYTES: usize = 256 * 1024;

/// Channel-kind label used in chat-relay metric series.
const DC_LABEL_DATA: &str = "data";
const DC_LABEL_CTRL: &str = "ctrl";

/// Drop-reason labels. Kept aligned with the pre-touched series in
/// `metrics::SfuMetrics::new` so every label combination has a visible 0
/// baseline at scrape time.
const REASON_OVERSIZE: &str = "oversize";
const REASON_NO_CHANNEL: &str = "no_channel";
const REASON_WRITE_ERR: &str = "write_err";

impl Client {
    /// Forward a `Propagated::ChatData` payload to *this* peer over the
    /// pre-negotiated `chat-data` DC. No-op when `origin == self.id`
    /// (skip-self echo guard). Errors and oversize frames are dropped
    /// with a metric emit; we never disconnect the peer on a chat-relay
    /// failure (a flaky chat-data DC must not tear down the media path).
    pub fn handle_chat_data_out(&mut self, origin: ClientId, payload: &[u8]) {
        if self.id == origin {
            return;
        }
        self.write_chat_frame(DC_LABEL_DATA, self.chat_data_cid, payload);
    }

    /// Forward a `Propagated::ChatCtrl` payload to *this* peer over the
    /// pre-negotiated `chat-ctrl` DC (`MaxRetransmits{0}` — best-effort).
    pub fn handle_chat_ctrl_out(&mut self, origin: ClientId, payload: &[u8]) {
        if self.id == origin {
            return;
        }
        self.write_chat_frame(DC_LABEL_CTRL, self.chat_ctrl_cid, payload);
    }

    fn write_chat_frame(
        &mut self,
        dc_label: &'static str,
        cid: str0m::channel::ChannelId,
        payload: &[u8],
    ) {
        if payload.len() > CHAT_FRAME_MAX_BYTES {
            tracing::warn!(
                client = *self.id,
                dc = dc_label,
                len = payload.len(),
                "chat-relay: payload exceeds size cap, dropping"
            );
            self.metrics
                .chat_relay_dropped_total
                .with_label_values(&[dc_label, REASON_OVERSIZE])
                .inc();
            return;
        }

        // Pre-format the client_id label once. Allocates per send — cheap
        // at the expected steady-state of <100 evt/s and avoids cardinality
        // surprises (single number per client). Cleanup on disconnect is a
        // follow-up wired through reap_dead.
        let client_id_label = self.id.0.to_string();

        let Some(mut ch) = self.rtc.channel(cid) else {
            self.metrics
                .chat_relay_dropped_total
                .with_label_values(&[dc_label, REASON_NO_CHANNEL])
                .inc();
            return;
        };

        match ch.write(false, payload) {
            Ok(_) => {
                self.metrics
                    .chat_relay_tx_bytes_total
                    .with_label_values(&[dc_label, &client_id_label])
                    .inc_by(payload.len() as u64);
            }
            Err(e) => {
                tracing::warn!(
                    client = *self.id,
                    dc = dc_label,
                    error = ?e,
                    "chat-relay: DC write failed"
                );
                self.metrics
                    .chat_relay_dropped_total
                    .with_label_values(&[dc_label, REASON_WRITE_ERR])
                    .inc();
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::client::test_seed::new_client;
    use crate::propagate::ClientId;

    #[test]
    fn chat_data_skip_self_does_not_emit_metric() {
        let mut c = new_client(ClientId(1));
        let before = c
            .metrics
            .chat_relay_tx_bytes_total
            .with_label_values(&["data", "1"])
            .get();
        c.handle_chat_data_out(ClientId(1), b"hi");
        let after = c
            .metrics
            .chat_relay_tx_bytes_total
            .with_label_values(&["data", "1"])
            .get();
        assert_eq!(before, after, "self-echo must not increment tx bytes");
    }

    #[test]
    fn chat_ctrl_skip_self_does_not_emit_metric() {
        let mut c = new_client(ClientId(2));
        let before = c
            .metrics
            .chat_relay_tx_bytes_total
            .with_label_values(&["ctrl", "2"])
            .get();
        c.handle_chat_ctrl_out(ClientId(2), b"typing");
        let after = c
            .metrics
            .chat_relay_tx_bytes_total
            .with_label_values(&["ctrl", "2"])
            .get();
        assert_eq!(before, after);
    }

    #[test]
    fn oversize_chat_data_increments_drop() {
        let mut c = new_client(ClientId(3));
        let before = c
            .metrics
            .chat_relay_dropped_total
            .with_label_values(&["data", "oversize"])
            .get();
        let big = vec![0u8; CHAT_FRAME_MAX_BYTES + 1];
        c.handle_chat_data_out(ClientId(99), &big);
        let after = c
            .metrics
            .chat_relay_dropped_total
            .with_label_values(&["data", "oversize"])
            .get();
        assert_eq!(after, before + 1, "oversize chat-data must bump drop counter");
    }

    #[test]
    fn unnegotiated_dc_increments_no_channel_drop() {
        // test_seed::new_client builds an Rtc that has not gone through DTLS,
        // so `rtc.channel(cid)` returns None — we exercise the no_channel arm.
        let mut c = new_client(ClientId(4));
        let before = c
            .metrics
            .chat_relay_dropped_total
            .with_label_values(&["data", "no_channel"])
            .get();
        c.handle_chat_data_out(ClientId(99), b"payload");
        let after = c
            .metrics
            .chat_relay_dropped_total
            .with_label_values(&["data", "no_channel"])
            .get();
        assert_eq!(after, before + 1);
    }
}
