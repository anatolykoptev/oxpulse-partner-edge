//! SFU-originated event broadcasts via `sfu-events` DC (id:8).
//!
//! Wire schema source-of-truth:
//!   (chat side, Task 2c.5) web/src/lib/quality/peer-suspended-schema.ts
//!   web/src/lib/sfu-events-transport.ts
//!
//! This module is the **only** place the DC id and label constants live on
//! the Rust side. The chat side must use the same id:8 and label "sfu-events"
//! when Task 2c.5 lands (see plan: plans/oxpulse-chat/2026-05-14-phase-2c-peer-suspended-bridge.md).
//!
//! Design choices:
//! - Unordered, MaxRetransmits{0} — same class as `sfu-active-speaker` (id:3).
//! - SFU-originated only — browsers MUST NOT write here.
//! - Plain JSON, no header/seq/dedup — frames are idempotent state updates.
//!   Receiver applies last-write-wins by `ts`; no dedup needed.
//! - Frame cap: 256 bytes (generous for ~80-byte peer-suspended frame).

use crate::propagate::{ClientId, SuspendTier};

/// SCTP stream id for the pre-negotiated `sfu-events` DC.
///
/// DC id inventory (as of 2026-05-15):
///   id:1  sframe-keys     (ordered, reliable)
///   id:2  sfu-budget      (negotiated, unordered)
///   id:3  sfu-active-speaker (ordered, reliable)
///   id:4  chat-data       (ordered, reliable)
///   id:5  chat-ctrl       (unordered, MaxRetransmits{0})
///   id:6  voice           (unordered, MaxPacketLifetime{200ms})
///   id:7  reactions-group (ordered, MaxPacketLifetime{1000ms})
///   id:8  sfu-events      (unordered, MaxRetransmits{0}) ← THIS MODULE
///
/// Plan originally cited id:6 as primary with id:7 as fallback; pre-flight
/// inventory showed both occupied. Bumped to id:8.
pub const SFU_EVENTS_DC_ID: u16 = 8;

/// Label of the pre-negotiated `sfu-events` DC.
/// Must match browser-side `{ negotiated: true, id: 8, label: "sfu-events" }`.
pub const SFU_EVENTS_DC_LABEL: &str = "sfu-events";

/// JSON `kind` field value for peer-suspended frames.
pub const PEER_SUSPENDED_KIND: &str = "peer-suspended";

/// Maximum allowed frame size in bytes. Frames larger than this are dropped
/// by `handle_sfu_event_out` before writing to the DC.
pub const MAX_FRAME_SIZE: usize = 256;

/// Internal wire struct for serializing peer-suspended frames.
#[derive(serde::Serialize)]
struct PeerSuspendedFrame<'a> {
    kind: &'a str,
    from: String,
    ts: u64,
    tier: &'a str,
}

/// Build the JSON bytes for a `peer-suspended` frame.
///
/// The result is always < `MAX_FRAME_SIZE` bytes for any valid `ClientId`
/// and `SuspendTier` (verified by inline test). Caller must check before
/// calling `handle_sfu_event_out` which enforces the cap independently.
pub fn build_peer_suspended(peer_id: ClientId, tier: &SuspendTier) -> Vec<u8> {
    let frame = PeerSuspendedFrame {
        kind: PEER_SUSPENDED_KIND,
        from: peer_id.0.to_string(),
        ts: now_ms(),
        tier: tier.as_wire_str(),
    };
    // serde_json::to_vec cannot fail for this struct (no maps with non-string
    // keys, no floats that serialize to inf/nan, no custom serializers).
    serde_json::to_vec(&frame).unwrap_or_default()
}

/// Current Unix time in milliseconds. Used as frame timestamp for
/// last-write-wins ordering on the receiver.
fn now_ms() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

// ── inline tests ─────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::propagate::{ClientId, SuspendTier};

    /// Parse a peer-suspended frame from JSON bytes (test helper).
    fn parse_frame(bytes: &[u8]) -> serde_json::Value {
        serde_json::from_slice(bytes).expect("must be valid JSON")
    }

    #[test]
    fn constants_anti_regression() {
        // If you change these, the chat side (Task 2c.5) must be updated too.
        assert_eq!(SFU_EVENTS_DC_ID, 8);
        assert_eq!(SFU_EVENTS_DC_LABEL, "sfu-events");
        assert_eq!(PEER_SUSPENDED_KIND, "peer-suspended");
    }

    #[test]
    fn build_peer_suspended_audio_normal_parses_correctly() {
        let payload = build_peer_suspended(ClientId(42), &SuspendTier::AudioNormal);
        let v = parse_frame(&payload);
        assert_eq!(v["kind"], "peer-suspended");
        assert_eq!(v["from"], "42");
        assert_eq!(v["tier"], "audio-normal");
        assert!(v["ts"].is_number());
    }

    #[test]
    fn build_peer_suspended_audio_low_parses_correctly() {
        let payload = build_peer_suspended(ClientId(7), &SuspendTier::AudioLow);
        let v = parse_frame(&payload);
        assert_eq!(v["kind"], "peer-suspended");
        assert_eq!(v["from"], "7");
        assert_eq!(v["tier"], "audio-low");
    }

    #[test]
    fn build_peer_suspended_video_max_parses_correctly() {
        let payload = build_peer_suspended(ClientId(1), &SuspendTier::VideoMax);
        let v = parse_frame(&payload);
        assert_eq!(v["tier"], "video-max");
    }

    #[test]
    fn build_peer_suspended_all_tiers_under_max_frame_size() {
        for tier in [
            SuspendTier::AudioNormal,
            SuspendTier::AudioLow,
            SuspendTier::VideoMax,
        ] {
            // Use u64::MAX as peer_id for the worst-case string length.
            let payload = build_peer_suspended(ClientId(u64::MAX), &tier);
            assert!(
                payload.len() < MAX_FRAME_SIZE,
                "tier {:?} payload {} bytes exceeds MAX_FRAME_SIZE={}",
                tier,
                payload.len(),
                MAX_FRAME_SIZE
            );
        }
    }
}
