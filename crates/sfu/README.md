# oxpulse-sfu

[![CI](https://github.com/anatolykoptev/oxpulse-partner-edge/actions/workflows/ci.yml/badge.svg)](https://github.com/anatolykoptev/oxpulse-partner-edge/actions/workflows/ci.yml)
[![License: MIT OR Apache-2.0](https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0-blue.svg)](../../LICENSE)

Rust WebRTC Selective Forwarding Unit for OxPulse encrypted group calls. Built on
[str0m](https://github.com/algesten/str0m) and
[oxpulse-sfu-kit](https://crates.io/crates/oxpulse-sfu-kit).

## Features

- **E2E encrypted forwarding** — SFrame (RFC 9605) payloads pass through opaque; relay nodes never decrypt media
- **Simulcast** — per-subscriber layer selection (`q`/`h`/`f`) via `BestFitSelector`
- **Kalman BWE** — GoogCC-style delay + loss bandwidth estimator drives adaptive layer switching
- **Dominant speaker** — Volfin & Cohen 2012 algorithm; reports `confidence` margin and top-3 speakers
- **Cascade relay** — JWT-authenticated `POST /relay/connect`; str0m as SDP offerer for edge-to-edge relay
- **RFC 9626 VFM** — Video Frame Marking temporal-layer drop for H.264 / VP9 / HEVC
- **Prometheus metrics** — per-peer BWE, speaker scores, layer transitions

## Run

```bash
# development
cargo run -p oxpulse-sfu

# custom ports
SFU_UDP_PORT=40000 SFU_METRICS_PORT=9400 cargo run -p oxpulse-sfu

# release
cargo build --release -p oxpulse-sfu
```

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `SFU_UDP_PORT` | `3478` | WebRTC media (DTLS/SRTP/STUN multiplexed) |
| `SFU_METRICS_PORT` | `9317` | Prometheus `/metrics` |
| `SFU_RELAY_API_PORT` | `8912` | Cascade relay HTTP API |
| `SFU_BIND_ADDRESS` | `0.0.0.0` | Bind interface |
| `RELAY_JWT_SECRET` | `change-me-in-production` | HMAC-SHA256 secret shared with oxpulse-chat |
| `RUST_LOG` | `info` | Log filter |

## Metrics

Scrape `GET http://<host>:9317/metrics` (Prometheus text 0.0.4).

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `sfu_active_participants` | Gauge | — | Connected clients |
| `sfu_forwarded_packets_total` | Counter | `kind` | Forwarded RTP packets |
| `sfu_layer_selection_total` | Counter | `layer` | Simulcast tier selections |
| `sfu_layer_transitions_total` | Counter | `from`, `to`, `peer` | Per-subscriber layer switches |
| `sfu_dominant_speaker_changes_total` | Counter | — | Speaker election changes |
| `sfu_dominant_speaker_hysteresis_ms` | Histogram | — | Inter-election interval |
| `sfu_bandwidth_estimate_bps` | Gauge | `peer` | Per-subscriber BWE estimate |
| `sfu_speaker_immediate_score` | Gauge | `peer` | Immediate-window activity score |
| `sfu_speaker_medium_score` | Gauge | `peer` | Medium-window activity score |
| `sfu_speaker_long_score` | Gauge | `peer` | Long-window activity score |
| `sfu_client_connect_total` | Counter | — | Total connects |
| `sfu_client_disconnect_total` | Counter | — | Total disconnects |

## Cascade relay API

```
POST http://<host>:8912/relay/connect
Content-Type: application/json

{
  "relay_token": "<HMAC-SHA256 signed JWT from oxpulse-chat>",
  "upstream_url": "wss://eu-edge.example/ws/sfu/ROOM-ID",
  "upstream_room_token": "<room JWT>"
}
```

On success, the SFU opens an outbound WebRTC connection to `upstream_url`, marks the client as `RelayFromSfu`, and routes keyframe requests upstream instead of back to the relay peer.

## DataChannel protocol

| DC ID | Label | Direction | Payload |
|-------|-------|-----------|---------|
| 2 | `sfu-budget` | client → SFU | `{"type":"budget","bps":500000}` |
| 3 | `sfu-active-speaker` | SFU → client | `{"type":"active_speaker","peerId":42,"confidence":0.95}` |
| 5 | `sfu-relay-source` | relay → upstream | `{"type":"relay_source","upstreamUrl":"wss://..."}` |

## License

MIT OR Apache-2.0
