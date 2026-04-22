# oxpulse-sfu

Edge SFU (Selective Forwarding Unit) for OxPulse group calls. Built on
[`str0m`](https://github.com/algesten/str0m) — a sans-I/O Rust WebRTC
state machine — and designed to live on partner-edge nodes alongside
the existing `crates/turn` TURN credential service.

## Status: M1.5 — Milestone 1 complete

Core SFU is operational. Prometheus metrics exposed on `:metrics_port`.
Milestone 1 deliverables:

- M1.1 — UDP loop scaffold
- M1.2 — Multi-client registry + `Propagated` fan-out
- M1.3 — Simulcast layer selection (RID-aware)
- M1.4 — Dominant speaker detector (Jitsi port)
- M1.5 — Prometheus `/metrics` + integration tests *(this)*

## Metrics

Scrape `GET http://<host>:<metrics_port>/metrics` (Prometheus text format 0.0.4).

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `sfu_active_rooms` | Gauge | — | Always 1 (single-room M1.5; multi-room M2+) |
| `sfu_active_participants` | Gauge | — | Current live client count |
| `sfu_forwarded_packets_total` | Counter | `kind=audio\|video\|other` | RTP packets forwarded post-layer-filter |
| `sfu_layer_selection_total` | Counter | `layer=q\|h\|f` | Simulcast tier selection events |
| `sfu_dominant_speaker_changes_total` | Counter | — | Dominant speaker election changes |
| `sfu_client_connect_total` | Counter | — | Total client connects |
| `sfu_client_disconnect_total` | Counter | — | Total client disconnects |

## Run locally

```bash
# Defaults: UDP on :3478, metrics HTTP on :9317 (M1.5, not yet wired)
cargo run -p oxpulse-sfu

# Custom ports + debug logs
SFU_UDP_PORT=40000 RUST_LOG=oxpulse_sfu=debug cargo run -p oxpulse-sfu

# Release build for deployment
cargo build --release -p oxpulse-sfu --bin oxpulse-sfu
```

Ctrl-C / SIGTERM shuts the loop down cleanly.

## Environment

| Variable | Default | Purpose |
|----------|---------|---------|
| `SFU_UDP_PORT` | `3478` | WebRTC media multiplexed UDP port |
| `SFU_METRICS_PORT` | `9317` | HTTP `/metrics` Prometheus endpoint |
| `SFU_BIND_ADDRESS` | `0.0.0.0` | Bind interface for both sockets |
| `RUST_LOG` | `info` | `tracing_subscriber` directive |

## References

- ADR: `docs/superpowers/decisions/2026-04-21-group-calls-architecture.md`
  (decisions D3 `str0m` and D8 TURN+SFU co-located)
- Execution plan: `docs/superpowers/plans/2026-04-21-group-calls-execution.md`
- Research: `docs/superpowers/research/2026-04-21-group-calls-architecture.md`
  §3.5 `str0m` reality check, §6.5 SFU forwarding skeleton
- Upstream reference: <https://github.com/algesten/str0m/blob/main/examples/chat.rs>
