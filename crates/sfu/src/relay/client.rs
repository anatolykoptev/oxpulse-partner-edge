//! Outbound WebRTC relay client — str0m as SDP offerer.
//!
//! Connects to an upstream edge SFU via WebSocket, performs the SDP offer/answer
//! exchange, then hands the pre-ICE `Rtc` back to the caller as a `PendingRelay`.
//! The main UDP loop (serve() in udp_loop.rs) drives ICE/DTLS/SRTP from that point,
//! identically to browser WebRTC peers.

use std::net::SocketAddr;
use std::time::{Duration, Instant};

use anyhow::Context;
use futures_util::{SinkExt, StreamExt};
use str0m::change::SdpAnswer;
use str0m::media::{Direction, MediaKind};
use str0m::{Candidate, Rtc};
use tokio_tungstenite::{connect_async, tungstenite::protocol::Message};

/// A relay connection that completed SDP exchange but has not yet completed ICE.
/// Pass to the Registry via the relay injection channel — the main UDP loop drives
/// ICE/DTLS/SRTP alongside browser clients from that point on.
#[derive(Debug)]
pub struct PendingRelay {
    pub rtc: str0m::Rtc,
    pub room_id: String,
    pub upstream_url: String,
    pub upstream_room_token: String,
    /// Pre-negotiated DC id for the relay_source announcement.
    /// Written to upstream once Event::Connected fires in dispatch.rs.
    pub dc_id: str0m::channel::ChannelId,
}

/// Serialise the relay-source DataChannel announcement message.
///
/// `room_token` is the room JWT issued by oxpulse-chat signaling for this room.
/// The upstream SFU verifies this token to prevent unauthenticated relay promotion.
/// Pass an empty string only for dev/test when SIGNALING_SFU_SECRET is unset.
pub fn relay_source_message(upstream_url: &str, room_token: &str) -> String {
    serde_json::json!({
        "type": "relay_source",
        "upstreamUrl": upstream_url,
        "roomToken": room_token,
    })
    .to_string()
}

/// JSON join message — same format a browser peer sends at WebSocket handshake.
pub fn join_message() -> String {
    r#"{"type":"join"}"#.to_string()
}

/// Establish a relay WebRTC connection to `upstream_ws_url`.
///
/// Protocol:
/// 1. Open WebSocket to upstream WS endpoint.
/// 2. Send `{"type":"join"}`.
/// 3. Create str0m Rtc as offerer; produce SDP offer.
/// 4. Send `{"type":"signal","payload":{"type":"offer","sdp":"..."}}` over WS.
/// 5. Receive `{"type":"signal","payload":{"type":"answer","sdp":"..."}}`.
/// 6. Apply answer; add local ICE candidate.
/// 7. Return `PendingRelay` — the caller hands this to the main UDP loop
///    which drives ICE/DTLS/SRTP from that point on.
///
/// Returns true if the upstream URL is from an allowed host.
/// Defense-in-depth against SSRF even if a signed JWT somehow contains a bad URL.
fn is_allowed_upstream_host(url: &str) -> bool {
    // Must be wss://
    let Some(rest) = url.strip_prefix("wss://") else {
        return false;
    };
    // Extract hostname (before first / or :)
    let host = rest.split(['/', ':']).next().unwrap_or("");

    // Allow-list: our own infrastructure + localhost for dev/test
    let allowed = [".oxpulse.chat", "localhost", "127.0.0.1", "::1"];
    allowed.iter().any(|&pattern| {
        if pattern.starts_with('.') {
            host.ends_with(pattern) || host == &pattern[1..]
        } else {
            host == pattern
        }
    })
}

#[tracing::instrument(skip(upstream_room_token, stats_interval_secs), fields(otel.kind = "client"))]
pub async fn connect_relay(
    upstream_ws_url: &str,
    upstream_room_token: &str,
    local_udp_addr: SocketAddr,
    room_id: String,
    stats_interval_secs: u64,
) -> anyhow::Result<PendingRelay> {
    // Defense-in-depth: validate upstream host even though JWT is signed.
    if !is_allowed_upstream_host(upstream_ws_url) {
        anyhow::bail!(
            "upstream URL host is not in the allow-list: {}",
            upstream_ws_url
        );
    }

    // 1. Open WebSocket.
    let (mut ws, _) = connect_async(upstream_ws_url)
        .await
        .with_context(|| format!("WS connect to {upstream_ws_url}"))?;
    tracing::info!(upstream = %upstream_ws_url, "relay WS connected");

    // 2. Send join.
    ws.send(Message::Text(join_message().into())).await?;

    // 3. Create str0m Rtc as offerer with stats enabled.
    //    stats_interval_secs == 0 disables stats (same as Rtc::new).
    let stats_interval =
        (stats_interval_secs > 0).then(|| Duration::from_secs(stats_interval_secs));
    let mut rtc = Rtc::builder()
        .set_stats_interval(stats_interval)
        .build(Instant::now());

    // Pre-negotiate relay-source DataChannel at SCTP stream id 5
    // (ids 2 and 3 are already used by the normal peer path).
    // NOTE: direct_api DC is not part of the SDP offer; it will be
    // established after DTLS via SCTP once both sides agree on id 5.
    let dc_id = rtc
        .direct_api()
        .create_data_channel(str0m::channel::ChannelConfig {
            label: "sfu-relay-source".to_string(),
            ordered: true,
            reliability: str0m::channel::Reliability::Reliable,
            negotiated: Some(5),
            protocol: String::new(),
        });

    // Build the SDP offer via sdp_api — we receive audio + video from upstream.
    let pending = {
        let mut changes = rtc.sdp_api();
        changes.add_media(MediaKind::Audio, Direction::RecvOnly, None, None, None);
        changes.add_media(MediaKind::Video, Direction::RecvOnly, None, None, None);
        let (offer, pending) = changes
            .apply()
            .ok_or_else(|| anyhow::anyhow!("sdp_api produced no offer (no changes)"))?;

        // 4. Send offer over WS.
        let offer_sdp = offer.to_sdp_string();
        let offer_payload = serde_json::json!({
            "type": "signal",
            "payload": { "type": "offer", "sdp": offer_sdp }
        })
        .to_string();
        ws.send(Message::Text(offer_payload.into())).await?;
        tracing::debug!("relay: sent SDP offer");

        pending
    };

    // 5. Receive SDP answer.
    let answer = loop {
        match ws.next().await {
            Some(Ok(Message::Text(text))) => {
                let v: serde_json::Value = serde_json::from_str(text.as_str())?;
                if v["type"] == "signal" {
                    if let Some(payload) = v["payload"].as_object() {
                        if payload.get("type").and_then(|t| t.as_str()) == Some("answer") {
                            let sdp_str = payload
                                .get("sdp")
                                .and_then(|s| s.as_str())
                                .unwrap_or_default();
                            break SdpAnswer::from_sdp_string(sdp_str)
                                .context("parse SDP answer")?;
                        }
                    }
                }
            }
            Some(Ok(_)) => continue,
            _ => anyhow::bail!("WS closed before receiving SDP answer"),
        }
    };

    // 6. Apply answer.
    rtc.sdp_api()
        .accept_answer(pending, answer)
        .context("apply SDP answer")?;
    tracing::debug!("relay: applied SDP answer");

    // Add the SFU's host candidate. Phase 7 M4.A6: `local_udp_addr` here
    // is the public-IP-overridden `host_candidate_addr` from main.rs (or the
    // raw bind address as fallback). Keeping the parameter name to avoid
    // touching the str0m-adjacent surface area; the upstream SFU treats this
    // candidate identically to the historical bind-address one.
    if let Ok(candidate) = Candidate::host(local_udp_addr, "udp") {
        rtc.add_local_candidate(candidate);
    }

    // Return the pre-ICE Rtc to the caller.
    // The main UDP loop (serve() in udp_loop.rs) drives ICE/DTLS/SRTP
    // for this relay client identically to browser WebRTC peers.
    tracing::info!(upstream = %upstream_ws_url, "relay: SDP exchange complete, handing Rtc to registry");
    Ok(PendingRelay {
        rtc,
        room_id,
        upstream_url: upstream_ws_url.to_string(),
        upstream_room_token: upstream_room_token.to_string(),
        dc_id,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn relay_source_message_contains_type_url_and_token() {
        let msg = relay_source_message("wss://eu.example/ws/sfu/room1", "test-room-token");
        let v: serde_json::Value = serde_json::from_str(&msg).unwrap();
        assert_eq!(v["type"], "relay_source");
        assert_eq!(v["upstreamUrl"], "wss://eu.example/ws/sfu/room1");
        assert_eq!(v["roomToken"], "test-room-token");
    }

    #[test]
    fn join_message_is_valid_json() {
        let msg = join_message();
        let v: serde_json::Value = serde_json::from_str(&msg).unwrap();
        assert_eq!(v["type"], "join");
    }

    #[test]
    fn upstream_allow_list_accepts_valid_hosts() {
        assert!(is_allowed_upstream_host(
            "wss://edge.oxpulse.chat/ws/sfu/room1"
        ));
        assert!(is_allowed_upstream_host(
            "wss://us-1.oxpulse.chat/ws/sfu/room1"
        ));
        assert!(is_allowed_upstream_host("wss://localhost/ws/sfu/room1"));
        assert!(is_allowed_upstream_host(
            "wss://127.0.0.1:8911/ws/sfu/room1"
        ));
        assert!(is_allowed_upstream_host("wss://oxpulse.chat/ws/sfu/room1"));
    }

    #[test]
    fn upstream_allow_list_rejects_external_hosts() {
        assert!(!is_allowed_upstream_host("wss://attacker.example.com/ssrf"));
        assert!(!is_allowed_upstream_host("wss://10.0.0.1/internal"));
        assert!(!is_allowed_upstream_host("http://localhost/not-wss"));
        assert!(!is_allowed_upstream_host("wss://evil-oxpulse.chat/bypass"));
        assert!(!is_allowed_upstream_host("wss://notoxpulse.chat/bypass"));
    }

    #[test]
    fn pending_relay_fields_are_accessible() {
        let mut rtc = str0m::Rtc::new(std::time::Instant::now());
        let dc_id = rtc
            .direct_api()
            .create_data_channel(str0m::channel::ChannelConfig {
                label: "test".to_string(),
                ordered: true,
                reliability: str0m::channel::Reliability::Reliable,
                negotiated: Some(5),
                protocol: String::new(),
            });
        let p = PendingRelay {
            rtc,
            room_id: "room-1".to_string(),
            upstream_url: "wss://eu.oxpulse.chat/ws/sfu/room-1".to_string(),
            upstream_room_token: "tok".to_string(),
            dc_id,
        };
        assert_eq!(p.room_id, "room-1");
        assert_eq!(p.upstream_url, "wss://eu.oxpulse.chat/ws/sfu/room-1");
    }

    #[test]
    fn is_allowed_upstream_host_still_works() {
        assert!(is_allowed_upstream_host("wss://edge.oxpulse.chat/ws/sfu/r"));
        assert!(is_allowed_upstream_host("wss://127.0.0.1:9999/ws/sfu/r"));
        assert!(!is_allowed_upstream_host("wss://attacker.com/ssrf"));
    }
}
