# SFU M2 SDP Renegotiation

## Problem

Group SFU calls delivered zero media. Root cause: `TrackOutState` had `Negotiating(Mid)` and
`Open(Mid)` variants but they were never assigned. `handle_track_open` pushed `ToOpen` and stopped.
The `fanout.rs` writer gate (`o.mid()` returns `None` for `ToOpen`) meant SRTP never left the wire.

## State Machine

```
                  ws_msg_tx present
ToOpen ──────────────────────────────────► Negotiating(Mid)
  │                                               │
  │ ws_msg_tx absent                  str0m Event::MediaAdded
  │ (relay/test)                      { direction: SendOnly }
  │                                               │
  └─────────────────────────────────────────── Open(Mid) ◄┘
```

- `ToOpen` → `Negotiating(mid)`: `start_renegotiation` allocates an m-line via `sdp_api().add_media`.
- `Negotiating(mid)` → `Open(mid)`: `dispatch.rs` on `Event::MediaAdded { direction: SendOnly }`.
- Only `Open(mid)` → `o.mid()` returns `Some(mid)` → `writer.write` fires → SRTP on wire.

## Wire Contract

Server → browser:
```json
{ "type": "offer-renegotiate", "sdp": "v=0...", "mid": "1" }
```

Browser → server:
```json
{ "type": "answer-renegotiate", "sdp": "v=0...", "mid": "1" }
```

Initial handshake (`{kind: "offer"}`, `{kind: "answer"}`) is unchanged.

## Sequence

1. Peer Y publishes → str0m `Event::MediaAdded { direction: RecvOnly }` → `track_in_added`.
2. Registry `fanout` calls `X.handle_track_open(weak_y_track)` for all other peers X.
3. `handle_track_open` (if `ws_msg_tx` present and no pending offer) → `start_renegotiation`:
   - `sdp_api().add_media(kind, SendOnly, Some("peer-N"), ...)` → `Mid`.
   - `api.apply()` → `Some((SdpOffer, SdpPendingOffer))`.
   - Push `TrackOut { state: Negotiating(mid) }`.
   - Store `SdpPendingOffer` in `pending_offer`.
   - Send `{ type: offer-renegotiate, sdp, mid }` via `ws_msg_tx`.
4. Browser: `setRemoteDescription(offer)` → `createAnswer()` → `setLocalDescription()` → send `answer-renegotiate`.
5. WS session `park_until_close_or_steal` parses `answer-renegotiate` → `ws_ctrl_tx.try_send(AnswerRenegotiate)`.
6. UDP loop calls `registry.pump_ws_ctrl()` → `client.drain_ws_ctrl()` → `accept_renegotiation_answer()`:
   - `rtc.sdp_api().accept_answer(pending, answer)`.
   - Bumps `sfu_renegotiation_answers_total{ok}`.
   - Drains `renegotiation_queue` for next pending track.
7. str0m emits `Event::MediaAdded { direction: SendOnly, mid }` → `dispatch.rs`:
   - Find `Negotiating(mid)` in `tracks_out`, flip to `Open(mid)`.
   - Bump `sfu_track_out_state_transitions_total{from=negotiating,to=open}`.
8. `fanout.rs`: `o.mid()` returns `Some(mid)` → `writer.write(pt, ...)` → SRTP → browser.
   - Bump `sfu_wire_written_total{kind}`.

## str0m API Used (v0.18.0)

```rust
// Allocate m-line
let mut api = rtc.sdp_api();
let mid = api.add_media(MediaKind::Video, Direction::SendOnly, Some(stream_id), None, None);
let Some((offer, pending)) = api.apply() else { return; };

// Accept answer (after SdpPendingOffer stored separately)
rtc.sdp_api().accept_answer(pending, answer)?;
```

Key invariants:
- `SdpPendingOffer` is invalidated by the next `sdp_api()` call.
- Only one in-flight renegotiation per `Rtc` — queue additional opens.
- `accept_answer` takes ownership of both `pending` and `answer`.

## Metrics

| Counter | Labels | Meaning |
|---------|--------|---------|
| `sfu_track_out_state_transitions_total` | `from, to` | State machine transitions |
| `sfu_renegotiation_offers_sent_total` | `kind` | Offers pushed to browser |
| `sfu_renegotiation_answers_total` | `outcome` | Answer processing (ok/err) |
| `sfu_wire_written_total` | `kind` | Actual SRTP wire writes |

## Files Changed

| File | Change |
|------|--------|
| `client/tracks.rs` | `TrackOutState` doc updated, unit tests added |
| `client/renegotiation.rs` | New module: `handle_track_open`, `start_renegotiation`, `accept_renegotiation_answer`, `drain_ws_ctrl` |
| `client/dispatch.rs` | Gate `MediaAdded` on `direction.is_sending()` |
| `client/fanout.rs` | Add `sfu_wire_written_total` after `writer.write` |
| `client/construct.rs` | `with_ws_msg_tx`, `with_ws_ctrl_rx` builders |
| `client_ws/session.rs` | `WsClientCtrl` enum, `ws_ctrl_rx` in `PendingClient`, `answer-renegotiate` parser |
| `udp_loop.rs` | Thread channels onto Client; call `pump_ws_ctrl` |
| `registry/poll.rs` | `pump_ws_ctrl` method |
| `metrics/mod.rs` | 4 new counters |
| `tests/m2_sdp_renegotiation.rs` | Integration tests |

## Known Limitations

- Queue drain is sequential (one offer-renegotiate in flight at a time per `Rtc`).
  In a 6-peer room a new joiner receives 5 cross-advertises sequentially rather than
  in parallel — each must complete its offer/answer round-trip (~50-200ms) before the
  next begins. For the current room cap this is acceptable.
- Perfect-negotiation collision (browser also initiating a renegotiation) is not handled.
  Browser-side guard in `useGroupCall-sfu-ws.ts` queues offers when `signalingState != stable`.
