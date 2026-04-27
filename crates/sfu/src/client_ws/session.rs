//! Per-WebSocket session — Phase 7 M4.A2.
//!
//! Drives the SDP offer/answer exchange with a single browser peer, then
//! hands the resulting `Rtc` (acting as **answerer**) to the main UDP
//! loop via the [`PendingClient`] channel. From that point on, ICE/DTLS
//! and media forwarding flow identically to relay clients — see
//! [`crate::relay::client::PendingRelay`] for the analogous offerer path.
//!
//! ## Wire format
//!
//! Frames are JSON text frames; binary frames are ignored. Messages are
//! tagged with a `kind` discriminator so this stays mappable to the
//! browser's `useGroupCall-rtc.ts` shape (M4.B1):
//!
//! ```json
//! { "kind": "offer", "sdp": "..." }
//! { "kind": "answer", "sdp": "..." }
//! { "kind": "ice", "candidate": "..." }
//! ```
//!
//! The current implementation is **non-trickle**: the browser must
//! complete `iceGatheringState=complete` before sending the offer (the
//! same pattern the spike at
//! `oxpulse-partner-edge/crates/sfu/examples/client_answerer.rs` proved
//! with str0m). `ice` frames received post-answer are accepted but
//! logged-and-ignored — server→client trickle requires a registry
//! backchannel that doesn't exist yet (it lands with M4.A4's
//! active-speaker DC plumbing).
//!
//! ## Lifetime
//!
//! 1. Wait for the first JSON frame; require `kind == "offer"`.
//! 2. Build a fresh str0m `Rtc`, install the SFU's UDP host candidate
//!    *before* `accept_offer` (so the candidate appears in the answer
//!    SDP — see spike line 173 for the rationale).
//! 3. `accept_offer(SdpOffer::from_sdp_string(...))` → `SdpAnswer`.
//! 4. Send `{kind:"answer", sdp:...}` over WS.
//! 5. Send the `PendingClient` over the inject channel — the main UDP
//!    loop calls `Client::new(rtc, metrics)` (which defaults
//!    `origin = ClientOrigin::Local`) and `Registry::insert`.
//! 6. Park, ignoring further frames, until WS closes. Unlike the relay
//!    drop-and-go path, we keep the WS open so future M4.A4 server→
//!    client DC events can reuse the same socket.

use std::net::SocketAddr;
use std::time::Instant;

use axum::extract::ws::{Message, WebSocket};
use serde_json::Value;
use str0m::change::SdpOffer;
use str0m::{Candidate, Rtc};
use tokio::sync::mpsc::Sender;

use super::handler::{close_with_code, CLOSE_DRAIN_TIMEOUT};

/// Maximum time to wait for the browser's `offer` frame after the WS
/// upgrade completes. Slightly longer than typical browser ICE-gathering
/// time (~1–3s on a healthy network).
const OFFER_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(15);

/// WS application close codes used by this module. 4xxx is the
/// RFC 6455 §7.4.2 "private use" range.
mod close_code {
    use axum::extract::ws::CloseCode;
    /// Browser sent a malformed first frame (not JSON, missing `kind`,
    /// wrong `kind`, or unparseable SDP).
    pub const BAD_OFFER: CloseCode = 4002;
    /// Server failed to build a str0m answerer (str0m rejected the
    /// offered SDP, e.g. unsupported codec mix).
    pub const SDP_INTERNAL: CloseCode = 4003;
    /// Server's inject channel into the registry is closed — the SFU is
    /// shutting down or the UDP loop has exited.
    pub const SERVER_GOING_AWAY: CloseCode = 1001;
}

/// Pre-ICE str0m instance ready for registry adoption.
///
/// Mirrors [`crate::relay::client::PendingRelay`] but for browser peers:
/// no upstream URL, no pre-allocated relay-source DC. The registry calls
/// `Client::new(rtc, metrics)` which leaves `origin = ClientOrigin::Local`
/// and creates the negotiated `sfu-active-speaker` DC at SCTP id 3.
#[derive(Debug)]
pub struct PendingClient {
    /// str0m instance with the SDP exchange completed and the host
    /// candidate installed. Caller hands this to `Client::new` and
    /// `Registry::insert`.
    pub rtc: Rtc,
    /// Room ID from the path/JWT — for logging only; the registry is
    /// already room-scoped at the process level (one SFU instance per
    /// room set).
    pub room_id: String,
    /// `sub` claim from the room JWT (signaling-assigned peer id). Not
    /// used by `Client::new` today (the registry assigns its own
    /// `ClientId`); carried so M4.A4 can correlate active-speaker
    /// broadcasts with signaling peers.
    pub external_peer_id: u64,
}

/// Run a single WS session. Returns `Ok` on clean shutdown; `Err` on
/// internal failure that should be logged by the caller.
pub async fn run(
    mut socket: WebSocket,
    room_id: String,
    peer_id: u64,
    local_udp_addr: SocketAddr,
    inject_tx: Sender<PendingClient>,
) -> anyhow::Result<()> {
    // 1. Read the first text frame, expect a JSON offer.
    let offer_sdp = match read_offer(&mut socket).await {
        Ok(s) => s,
        Err(e) => {
            tracing::warn!(target: "sfu::client_ws", peer_id, %room_id, error = %e, "client_ws: bad offer frame");
            close_with_code(socket, close_code::BAD_OFFER, "bad offer").await;
            return Ok(());
        }
    };

    // 2. Build str0m as answerer. Add the host candidate BEFORE
    //    `accept_offer` so the answer SDP advertises the SFU's UDP
    //    socket — see spike line 173.
    let mut rtc = Rtc::builder().build(Instant::now());
    match Candidate::host(local_udp_addr, "udp") {
        Ok(cand) => {
            rtc.add_local_candidate(cand);
        }
        Err(e) => {
            tracing::error!(target: "sfu::client_ws", peer_id, %room_id, error = %e,
                "client_ws: failed to build host candidate from local_udp_addr");
            close_with_code(socket, close_code::SDP_INTERNAL, "internal").await;
            return Ok(());
        }
    }

    // 3. `accept_offer` — the str0m answerer entry point.
    let offer = match SdpOffer::from_sdp_string(&offer_sdp) {
        Ok(o) => o,
        Err(e) => {
            tracing::warn!(target: "sfu::client_ws", peer_id, %room_id, error = %e,
                "client_ws: SDP offer did not parse");
            close_with_code(socket, close_code::BAD_OFFER, "bad sdp").await;
            return Ok(());
        }
    };
    let answer = match rtc.sdp_api().accept_offer(offer) {
        Ok(a) => a,
        Err(e) => {
            tracing::warn!(target: "sfu::client_ws", peer_id, %room_id, error = %e,
                "client_ws: str0m rejected offer");
            close_with_code(socket, close_code::SDP_INTERNAL, "sdp rejected").await;
            return Ok(());
        }
    };

    // 4. Send the answer back over WS.
    let answer_sdp = answer.to_sdp_string();
    let answer_frame = serde_json::json!({ "kind": "answer", "sdp": answer_sdp }).to_string();
    if socket
        .send(Message::Text(answer_frame.into()))
        .await
        .is_err()
    {
        tracing::warn!(target: "sfu::client_ws", peer_id, %room_id, "client_ws: send(answer) failed; peer gone");
        return Ok(());
    }
    tracing::info!(target: "sfu::client_ws", peer_id, %room_id, bytes = answer_sdp.len(),
        "client_ws: answer sent; injecting into registry");

    // 5. Hand the pre-ICE Rtc to the main UDP loop. From here on,
    //    ICE/DTLS/SRTP run via udp_loop::serve identically to relay
    //    clients (see `udp_loop::serve` `relay_rx` arm).
    if inject_tx
        .send(PendingClient {
            rtc,
            room_id: room_id.clone(),
            external_peer_id: peer_id,
        })
        .await
        .is_err()
    {
        tracing::error!(target: "sfu::client_ws", peer_id, %room_id,
            "client_ws: inject channel closed — UDP loop is shutting down");
        close_with_code(socket, close_code::SERVER_GOING_AWAY, "shutting down").await;
        return Ok(());
    }

    // 6. Park: keep the WS open and consume frames so future M4.A4 DC
    //    events can be sent in parallel. Trickle ICE candidates from the
    //    browser are accepted but logged-and-ignored today (non-trickle
    //    is the M4.A2 contract; M4.A4 introduces the registry→session
    //    backchannel needed to round-trip).
    park_until_close(&mut socket, &room_id, peer_id).await;

    // Bound the close handshake — a misbehaving peer can otherwise pin
    // this task open via TCP keepalive.
    let _ = tokio::time::timeout(CLOSE_DRAIN_TIMEOUT, async {
        // If the peer hasn't already closed, send a clean close ourselves.
        let _ = socket
            .send(Message::Close(Some(axum::extract::ws::CloseFrame {
                code: 1000,
                reason: "session ended".into(),
            })))
            .await;
        // Drain any in-flight frames the peer may still send.
        while let Some(msg) = socket.recv().await {
            if matches!(msg, Ok(Message::Close(_)) | Err(_)) {
                break;
            }
        }
    })
    .await;

    tracing::info!(target: "sfu::client_ws", peer_id, %room_id, "client_ws: session ended");
    Ok(())
}

/// Read the first text frame and decode `{kind:"offer", sdp:"..."}`.
/// Pings, pongs, and binary frames are skipped. Times out if no offer
/// arrives within [`OFFER_TIMEOUT`].
async fn read_offer(socket: &mut WebSocket) -> anyhow::Result<String> {
    let frame = tokio::time::timeout(OFFER_TIMEOUT, async {
        loop {
            match socket.recv().await {
                Some(Ok(Message::Text(t))) => break Some(t),
                Some(Ok(Message::Ping(p))) => {
                    if socket.send(Message::Pong(p)).await.is_err() {
                        break None;
                    }
                }
                Some(Ok(Message::Pong(_))) | Some(Ok(Message::Binary(_))) => continue,
                Some(Ok(Message::Close(_))) | None | Some(Err(_)) => break None,
            }
        }
    })
    .await
    .map_err(|_| anyhow::anyhow!("offer not received within {:?}", OFFER_TIMEOUT))?;

    let Some(text) = frame else {
        anyhow::bail!("WS closed before offer");
    };

    let v: Value = serde_json::from_str(text.as_str())?;
    if v.get("kind").and_then(|k| k.as_str()) != Some("offer") {
        anyhow::bail!(
            "expected first frame kind=\"offer\", got {}",
            v.get("kind")
                .and_then(|k| k.as_str())
                .unwrap_or("<missing>")
        );
    }
    let sdp = v
        .get("sdp")
        .and_then(|s| s.as_str())
        .ok_or_else(|| anyhow::anyhow!("offer frame missing sdp field"))?
        .to_string();
    if sdp.is_empty() {
        anyhow::bail!("offer.sdp is empty");
    }
    Ok(sdp)
}

/// Consume frames until the peer closes. ICE-trickle frames from the
/// browser are accepted but ignored — see module doc.
async fn park_until_close(socket: &mut WebSocket, room_id: &str, peer_id: u64) {
    while let Some(msg) = socket.recv().await {
        match msg {
            Ok(Message::Text(t)) => {
                if let Ok(v) = serde_json::from_str::<Value>(t.as_str()) {
                    if v.get("kind").and_then(|k| k.as_str()) == Some("ice") {
                        tracing::debug!(target: "sfu::client_ws", peer_id, %room_id,
                            "client_ws: ignoring trickle-ice frame (M4.A2 is non-trickle)");
                        continue;
                    }
                }
                tracing::debug!(target: "sfu::client_ws", peer_id, %room_id,
                    bytes = t.len(), "client_ws: ignoring post-handshake text frame");
            }
            Ok(Message::Binary(_)) => { /* ignore */ }
            Ok(Message::Ping(p)) => {
                if socket.send(Message::Pong(p)).await.is_err() {
                    break;
                }
            }
            Ok(Message::Pong(_)) => { /* ignore */ }
            Ok(Message::Close(_)) => break,
            Err(e) => {
                tracing::debug!(target: "sfu::client_ws", peer_id, %room_id,
                    error = %e, "client_ws: recv error");
                break;
            }
        }
    }
}
