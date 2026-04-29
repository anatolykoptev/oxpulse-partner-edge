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
//! 4. Build the answer frame string (don't send yet).
//! 5. Send the `PendingClient` over the inject channel — the main UDP
//!    loop calls `Client::new(rtc, metrics)` (which defaults
//!    `origin = ClientOrigin::Local`) and `Registry::insert`. **Order
//!    matters:** this happens BEFORE step 6 to avoid a window where the
//!    browser has the answer (and is emitting STUN) but the registry
//!    hasn't adopted the peer yet — those packets would be logged as
//!    `no client accepts udp datagram` (registry::mod.rs).
//! 6. Send `{kind:"answer", sdp:...}` over WS.
//! 7. Park, ignoring further frames, until WS closes. Unlike the relay
//!    drop-and-go path, we keep the WS open so future M4.A4 server→
//!    client DC events can reuse the same socket.

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Instant;

use axum::extract::ws::{CloseFrame, Message, WebSocket};
use serde_json::Value;
use str0m::change::SdpOffer;
use str0m::{Candidate, Rtc};
use tokio::sync::mpsc::Sender;
use tokio::sync::oneshot;

use super::handler::{close_with_code, CLOSE_DRAIN_TIMEOUT};
use crate::client::CloseReason;
use crate::metrics::{close_code_label, SfuMetrics};

/// Maximum time to wait for the browser's `offer` frame after the WS
/// upgrade completes. Slightly longer than typical browser ICE-gathering
/// time (~1–3s on a healthy network).
const OFFER_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(15);

/// WS application close codes used by this module. 4xxx is the
/// RFC 6455 §7.4.2 "private use" range.
///
/// Code 4031 ("session replaced") is emitted via
/// [`crate::client::CloseReason::SessionReplaced::ws_close_code`] —
/// kept on the enum rather than duplicated here so the metric label and
/// wire code agree by construction.
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

/// RAII guard for the `client_ws_active_sessions` gauge and
/// `client_ws_session_duration_seconds` histogram.
///
/// Increments the active-sessions gauge on construction; on drop —
/// including panics — decrements the gauge, observes the elapsed time,
/// and increments `client_ws_session_ended_total{close_code=...}`. The
/// `close_code` slot is mutable so each terminal branch can pin the
/// right value before returning.
struct ActiveSessionGuard {
    metrics: Arc<SfuMetrics>,
    started_at: Instant,
    close_code: u16,
}

impl ActiveSessionGuard {
    fn new(metrics: Arc<SfuMetrics>) -> Self {
        metrics.client_ws_active_sessions.inc();
        Self {
            metrics,
            started_at: Instant::now(),
            close_code: 1000,
        }
    }

    fn set_close_code(&mut self, code: u16) {
        self.close_code = code;
    }
}

impl Drop for ActiveSessionGuard {
    fn drop(&mut self) {
        self.metrics.client_ws_active_sessions.dec();
        self.metrics
            .client_ws_session_duration_seconds
            .observe(self.started_at.elapsed().as_secs_f64());
        self.metrics
            .client_ws_session_ended_total
            .with_label_values(&[close_code_label(self.close_code)])
            .inc();
    }
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
    /// `sub` claim from the room JWT (signaling-assigned peer id).
    /// Threaded onto [`crate::client::Client::external_peer_id`] in the
    /// `udp_loop::serve` `client_inject_rx` arm so
    /// [`crate::registry::Registry::insert`] can dedupe by
    /// `(room_id, peer_id)` and trigger a session steal when a newer
    /// upgrade arrives (Phase A Task A1).
    pub external_peer_id: u64,
    /// Phase A Task A1: sender half of the steal-signal channel. The
    /// receiver half lives on the WS task; the registry holds this
    /// sender and fires it (delivers [`CloseReason::SessionReplaced`])
    /// when a duplicate upgrade evicts the older session.
    pub close_signal: oneshot::Sender<CloseReason>,
}

/// Run a single WS session. Returns `Ok` on clean shutdown; `Err` on
/// internal failure that should be logged by the caller.
pub async fn run(
    mut socket: WebSocket,
    room_id: String,
    peer_id: u64,
    local_udp_addr: SocketAddr,
    inject_tx: Sender<PendingClient>,
    metrics: Arc<SfuMetrics>,
) -> anyhow::Result<()> {
    let mut guard = ActiveSessionGuard::new(metrics.clone());
    // 1. Read the first text frame, expect a JSON offer.
    let offer_sdp = match read_offer(&mut socket).await {
        Ok(s) => s,
        Err(e) => {
            tracing::warn!(target: "sfu::client_ws", peer_id, %room_id, error = %e, "client_ws: bad offer frame");
            metrics
                .client_ws_offer_processed_total
                .with_label_values(&["parse_err"])
                .inc();
            guard.set_close_code(close_code::BAD_OFFER);
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
            metrics
                .client_ws_offer_processed_total
                .with_label_values(&["ice_err"])
                .inc();
            guard.set_close_code(close_code::SDP_INTERNAL);
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
            metrics
                .client_ws_offer_processed_total
                .with_label_values(&["sdp_err"])
                .inc();
            guard.set_close_code(close_code::BAD_OFFER);
            close_with_code(socket, close_code::BAD_OFFER, "bad sdp").await;
            return Ok(());
        }
    };
    let answer = match rtc.sdp_api().accept_offer(offer) {
        Ok(a) => a,
        Err(e) => {
            tracing::warn!(target: "sfu::client_ws", peer_id, %room_id, error = %e,
                "client_ws: str0m rejected offer");
            metrics
                .client_ws_offer_processed_total
                .with_label_values(&["sdp_err"])
                .inc();
            guard.set_close_code(close_code::SDP_INTERNAL);
            close_with_code(socket, close_code::SDP_INTERNAL, "sdp rejected").await;
            return Ok(());
        }
    };
    // Offer survived parse + str0m accept_offer → counts as a clean
    // outcome at the SDP layer. Inject + answer-send come next.
    metrics
        .client_ws_offer_processed_total
        .with_label_values(&["ok"])
        .inc();

    // 4. Build the answer frame eagerly — but DON'T send it yet. The
    //    browser starts emitting STUN binding requests against our UDP
    //    socket as soon as it sees the answer SDP. If we send the answer
    //    *before* the registry has adopted this peer, those STUN packets
    //    get logged as `no client accepts udp datagram` (registry::mod.rs)
    //    until `client_inject_rx` is drained on the next `serve()` tick.
    //    Reordering inject-then-answer closes that race window. (See
    //    M4.A2 follow-up.)
    let answer_sdp = answer.to_sdp_string();
    let answer_frame = serde_json::json!({ "kind": "answer", "sdp": answer_sdp }).to_string();

    // 5. Hand the pre-ICE Rtc to the main UDP loop FIRST. From here on,
    //    ICE/DTLS/SRTP run via udp_loop::serve identically to relay
    //    clients (see `udp_loop::serve` `relay_rx` arm).
    //
    //    Phase A Task A1: pair the inject with a fresh oneshot
    //    `close_signal` channel — the registry holds the sender and
    //    fires it when a newer upgrade for this `external_peer_id`
    //    arrives (session steal).
    let (close_signal_tx, mut close_signal_rx) = oneshot::channel::<CloseReason>();
    if inject_tx
        .send(PendingClient {
            rtc,
            room_id: room_id.clone(),
            external_peer_id: peer_id,
            close_signal: close_signal_tx,
        })
        .await
        .is_err()
    {
        tracing::error!(target: "sfu::client_ws", peer_id, %room_id,
            "client_ws: inject channel closed — UDP loop is shutting down");
        guard.set_close_code(close_code::SERVER_GOING_AWAY);
        close_with_code(socket, close_code::SERVER_GOING_AWAY, "shutting down").await;
        return Ok(());
    }

    // 6. Now send the answer — the browser may begin STUN immediately,
    //    and the client is already in the registry channel queue.
    if socket
        .send(Message::Text(answer_frame.into()))
        .await
        .is_err()
    {
        tracing::warn!(target: "sfu::client_ws", peer_id, %room_id, "client_ws: send(answer) failed; peer gone");
        // Default close_code 1000 from guard — peer gone is a normal close.
        return Ok(());
    }
    metrics.client_ws_answer_sent_total.inc();
    tracing::info!(target: "sfu::client_ws", peer_id, %room_id, bytes = answer_sdp.len(),
        "client_ws: answer sent; client already injected into registry");

    // 7. Park: keep the WS open and consume frames so future M4.A4 DC
    //    events can be sent in parallel. Trickle ICE candidates from the
    //    browser are accepted but logged-and-ignored today (non-trickle
    //    is the M4.A2 contract; M4.A4 introduces the registry→session
    //    backchannel needed to round-trip).
    //
    //    Phase A Task A1: also watch `close_signal_rx`. A steal beats
    //    normal traffic (`biased`) so the new session's WS B doesn't
    //    have to wait through queued frames before the older WS A
    //    receives its 4031 close.
    let stole = park_until_close_or_steal(
        &mut socket,
        &mut close_signal_rx,
        &room_id,
        peer_id,
        &mut guard,
    )
    .await;

    if stole {
        // Steal-driven close already wrote the 4031 frame; just drain
        // and return.
        let _ = tokio::time::timeout(CLOSE_DRAIN_TIMEOUT, async {
            while let Some(msg) = socket.recv().await {
                if matches!(msg, Ok(Message::Close(_)) | Err(_)) {
                    break;
                }
            }
        })
        .await;
        tracing::info!(target: "sfu::client_ws", peer_id, %room_id,
            "client_ws: session ended (replaced by newer upgrade)");
        return Ok(());
    }

    // Bound the close handshake — a misbehaving peer can otherwise pin
    // this task open via TCP keepalive.
    let _ = tokio::time::timeout(CLOSE_DRAIN_TIMEOUT, async {
        // If the peer hasn't already closed, send a clean close ourselves.
        let _ = socket
            .send(Message::Close(Some(CloseFrame {
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

/// Consume frames until either the peer closes or the registry signals
/// a session steal. Returns `true` when the steal path fired, `false`
/// when the peer closed normally. ICE-trickle frames from the browser
/// are accepted but ignored — see module doc.
///
/// Phase A Task A1: the steal arm is `biased` first, so an inbound
/// duplicate-upgrade reliably beats any queued normal traffic. On
/// fire, the `4031 session_replaced` close frame is written here (not
/// in the caller) so `ActiveSessionGuard` can record the right
/// `close_code` label without a second branch.
async fn park_until_close_or_steal(
    socket: &mut WebSocket,
    close_signal_rx: &mut oneshot::Receiver<CloseReason>,
    room_id: &str,
    peer_id: u64,
    guard: &mut ActiveSessionGuard,
) -> bool {
    loop {
        tokio::select! {
            biased;
            reason = &mut *close_signal_rx => {
                let reason = reason.unwrap_or(CloseReason::ServerShutdown);
                let code = reason.ws_close_code();
                tracing::warn!(
                    target: "sfu::client_ws",
                    peer_id, %room_id, reason = reason.as_label(), code,
                    "client_ws: server-initiated close (Phase A Task A1)"
                );
                guard.set_close_code(code);
                let _ = socket
                    .send(Message::Close(Some(CloseFrame {
                        code,
                        reason: reason.as_label().into(),
                    })))
                    .await;
                return true;
            }
            msg = socket.recv() => {
                let Some(msg) = msg else {
                    return false;
                };
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
                            return false;
                        }
                    }
                    Ok(Message::Pong(_)) => { /* ignore */ }
                    Ok(Message::Close(_)) => return false,
                    Err(e) => {
                        tracing::debug!(target: "sfu::client_ws", peer_id, %room_id,
                            error = %e, "client_ws: recv error");
                        return false;
                    }
                }
            }
        }
    }
}
