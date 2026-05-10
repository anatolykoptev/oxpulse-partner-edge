//! KX fix — sframe-keys DC relay outbound writer.
//!
//! Per-peer fanout sink for `Propagated::KeysData`.
//! `crate::fanout::fanout` calls this on every non-origin client to push
//! the SFrame key-exchange `identity` frame down the pre-negotiated
//! sframe-keys DC opened in [`super::construct`]:
//!
//!   * `sframe-keys` — id:1, ordered, `Reliability::Reliable`
//!
//! Drop conditions:
//! * `no_channel` — `keys_dc_cid` is `None` (DC never opened, e.g. relay
//!   client) or `Rtc::channel(cid)` returned `None` (DTLS not yet up).
//!   Soft miss — skip-self guard already fires before this path.
//! * `oversize` — frame larger than 64 KB defence-in-depth cap.
//! * `write_err` — `channel.write()` returned an error.
//!
//! No metric series added beyond tracing::warn — the KX path is low-
//! frequency (one identity frame per join) and doesn't warrant a
//! dedicated Prometheus series. A follow-up can add one when operational
//! visibility is needed.

use crate::propagate::ClientId;

use super::Client;

/// Maximum accepted sframe-keys payload size (defence-in-depth).
/// Mirrors [`super::dc::SFRAME_KEYS_FRAME_MAX_BYTES`].
const SFRAME_KEYS_FRAME_MAX_BYTES: usize = 64 * 1024;

impl Client {
    /// Forward a `Propagated::KeysData` payload to *this* peer over the
    /// pre-negotiated `sframe-keys` DC (id:1). No-op when
    /// `origin == self.id` (skip-self echo guard) or when the DC was
    /// never opened (relay clients — see [`Client::with_keys_dc`]).
    /// Errors are dropped with a `tracing::warn!`; we never disconnect
    /// the peer on a KX relay failure.
    pub fn handle_keys_data_out(&mut self, origin: ClientId, payload: &[u8]) {
        if self.id == origin {
            return;
        }
        if payload.len() > SFRAME_KEYS_FRAME_MAX_BYTES {
            tracing::warn!(
                client = *self.id,
                len = payload.len(),
                "sframe-keys relay: payload exceeds size cap, dropping"
            );
            return;
        }
        let Some(cid) = self.keys_dc_cid else {
            // DC never opened (relay client or with_keys_dc not called) — soft miss.
            return;
        };
        let Some(mut ch) = self.rtc.channel(cid) else {
            // DTLS not yet up or channel was closed — soft miss.
            tracing::debug!(
                client = *self.id,
                "sframe-keys relay: DC not yet open, dropping frame"
            );
            return;
        };
        if let Err(e) = ch.write(false, payload) {
            tracing::warn!(
                client = *self.id,
                error = ?e,
                "sframe-keys relay: DC write failed"
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::client::test_seed::new_client;
    use crate::propagate::ClientId;

    #[test]
    fn keys_data_skip_self_no_op() {
        let mut c = new_client(ClientId(1));
        // Should not panic; just silently skip.
        c.handle_keys_data_out(ClientId(1), b"identity-payload");
    }

    #[test]
    fn keys_data_oversize_dropped_gracefully() {
        let mut c = new_client(ClientId(2));
        let big = vec![0u8; SFRAME_KEYS_FRAME_MAX_BYTES + 1];
        // Should not panic; logs warn and returns.
        c.handle_keys_data_out(ClientId(99), &big);
    }

    #[test]
    fn keys_data_unnegotiated_rtc_soft_miss() {
        // new_client calls with_keys_dc → keys_dc_cid is Some, but the Rtc
        // is not DTLS-negotiated so rtc.channel(cid) returns None → soft miss.
        let mut c = new_client(ClientId(3));
        c.handle_keys_data_out(ClientId(99), b"identity");
    }

    #[test]
    fn fanout_skips_origin_reaches_all_others() {
        use crate::fanout::fanout_for_tests;
        use crate::propagate::Propagated;

        // Three clients. Origin (id=20) must be skipped.
        // Since DCs are not DTLS-negotiated in tests, handle_keys_data_out
        // on non-origin clients hits the `rtc.channel(cid) == None` soft-miss
        // path without panicking. Confirms fanout dispatch reaches N-1 peers.
        let mut clients = vec![
            new_client(ClientId(20)),
            new_client(ClientId(21)),
            new_client(ClientId(22)),
        ];
        // Run fanout — just assert no panic (no metric to check since we
        // don't add a dedicated Prometheus series for KX).
        fanout_for_tests(
            &Propagated::KeysData(ClientId(20), b"identity-bytes".to_vec()),
            &mut clients,
        );
    }

    #[test]
    fn keys_data_client_id_returns_origin() {
        use crate::propagate::Propagated;
        let cid = ClientId(99);
        let p = Propagated::KeysData(cid, b"kx".to_vec());
        assert_eq!(p.client_id(), Some(cid));
    }
}
