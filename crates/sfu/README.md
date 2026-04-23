# oxpulse-sfu

Edge SFU (Selective Forwarding Unit) for OxPulse encrypted group calls.
Built on [`str0m`](https://github.com/algesten/str0m) — a sans-I/O Rust
WebRTC state machine — and the
[`oxpulse-sfu-kit`](https://crates.io/crates/oxpulse-sfu-kit) library.

## Features

- **Simulcast layer selection** — per-subscriber RID filter (`q`/`h`/`f`)
  with `BestFitSelector` accounting for publisher's active RIDs.
- **Kalman BWE** — GoogCC-inspired Kalman delay + loss-based bandwidth
  estimator; drives per-subscriber simulcast layer selection.
- **Dominant speaker** — Volfin & Cohen 2012 three-time-scale algorithm
  (`rust-dominant-speaker`). Reports `confidence: f64` (C2 margin) and
  top-3 speakers via DataChannel.
- **Cascade relay** — `POST /relay/connect` JWT-authenticated endpoint;
  outbound WebRTC client (str0m offerer) connects to upstream SFU edge and
  marks the connection as `RelayFromSfu`.
- **RFC 9626 VFM** — Video Frame Marking temporal-layer drop for
  H.264 / VP9 / HEVC.
- **E2E encryption** — SFrame (RFC 9605) key-epoch forwarding seam (`KeyEpoch`).
- **Prometheus metrics** — per-peer BWE, speaker activity scores, layer
  transitions, dominant speaker changes.

## Run locally

```bash
# Defaults: UDP :3478, metrics HTTP :9317, relay API :8912
cargo run -p oxpulse-sfu

# Custom ports + debug logs
SFU_UDP_PORT=40000 RUST_LOG=oxpulse_sfu=debug cargo run -p oxpulse-sfu

# Release build
cargo build --release -p oxpulse-sfu --bin oxpulse-sfu
```

## Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `SFU_UDP_PORT` | `3478` | WebRTC media (DTLS/SRTP/STUN multiplexed) |
| `SFU_METRICS_PORT` | `9317` | Prometheus `/metrics` HTTP endpoint |
| `SFU_RELAY_API_PORT` | `8912` | Relay API (`POST /relay/connect`) |
| `SFU_BIND_ADDRESS` | `0.0.0.0` | Bind interface |
| `RELAY_JWT_SECRET` | `change-me-in-production` | HMAC-SHA256 relay JWT secret. **Set before deployment.** |
| `RUST_LOG` | `info` | `tracing_subscriber` directive |

## Prometheus metrics

Scrape `GET http://<host>:9317/metrics`.

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `sfu_active_participants` | Gauge | — | Connected client count |
| `sfu_forwarded_packets_total` | Counter | `kind` | RTP packets forwarded |
| `sfu_layer_selection_total` | Counter | `layer` | Simulcast tier selections |
| `sfu_layer_transitions_total` | Counter | `from`, `to`, `peer` | Per-subscriber layer switches |
| `sfu_dominant_speaker_changes_total` | Counter | — | Speaker election changes |
| `sfu_dominant_speaker_hysteresis_ms` | Histogram | — | Inter-election interval |
| `sfu_bandwidth_estimate_bps` | Gauge | `peer` | Per-subscriber BWE estimate |
| `sfu_speaker_immediate_score` | Gauge | `peer` | Immediate-window activity |
| `sfu_speaker_medium_score` | Gauge | `peer` | Medium-window activity |
| `sfu_speaker_long_score` | Gauge | `peer` | Long-window activity |
| `sfu_client_connect_total` | Counter | — | Total client connects |
| `sfu_client_disconnect_total` | Counter | — | Total client disconnects |

## Cascade relay API

`POST http://<host>:8912/relay/connect`

```json
{
  "relay_token": "<HMAC-SHA256 signed JWT>",
  "upstream_url": "wss://eu-edge.example/ws/sfu/ROOM-ID",
  "upstream_room_token": "<room JWT>"
}
```

The relay token is signed by `RELAY_JWT_SECRET` (must match the oxpulse-chat
backend's `RELAY_JWT_SECRET`). On success, the SFU opens an outbound WebRTC
connection to `upstream_url` and marks it as a relay source — keyframe
requests are routed upstream rather than back to the relay peer.

## DataChannel protocol

| DC ID | Label | Direction | Purpose |
|-------|-------|-----------|---------|
| 2 | `sfu-budget` | client → SFU | Browser bandwidth budget hint `{"type":"budget","bps":N}` |
| 3 | `sfu-active-speaker` | SFU → client | `{"type":"active_speaker","peerId":N,"confidence":0.95}` |
| 5 | `sfu-relay-source` | relay → upstream | `{"type":"relay_source","upstreamUrl":"wss://..."}` |

## License

MIT OR Apache-2.0
