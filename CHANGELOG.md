# Changelog

All notable changes to oxpulse-partner-edge will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.9.0] — 2026-04-24

### Security — Phase 2

- **Ed25519 asymmetric relay JWT verification** — `SFU_SIGNING_PUBLIC_KEY` (fetched from `/api/partner/keys`) replaces `RELAY_JWT_SECRET` shared secret. A compromised edge node cannot forge tokens for others.
- **Ed25519 room token verification** — `verify_room_token_ed25519` in `room_auth.rs`. HS256 fallback retained until v1.0.0 cleanup.
- **FIPS 140-3 opt-in** — `--features fips` compiles with `aws-lc-fips-sys` (NIST-validated). `SFU_FIPS=1` env enforces the FIPS binary at startup.
- **`SFU_SIGNING_PUBLIC_KEY` auto-refresh** — `oxpulse-partner-edge-refresh.sh` now extracts and persists the Ed25519 public key from `/api/partner/keys` on every run (not only on Reality rotation days), writing to `/var/lib/oxpulse-partner-edge/sfu-keys.env`.

### Deployment notes

- Set `SFU_SIGNING_PRIVATE_KEY` on signaling server (generate: `openssl genpkey -algorithm Ed25519`).
- Partner-edge nodes fetch the public key automatically at install time and via the daily refresh. Manual: `sudo systemctl start oxpulse-partner-edge-refresh.service`.
- `RELAY_JWT_SECRET` still required during phased rollout; remove after all edges upgraded.

## [0.8.0] — 2026-04-23

### Added

- **oxpulse-sfu-kit v0.6 migration** — replaced inlined BWE, active speaker, and pacer with the published library (−1,881 lines). Active speaker now uses `rust-dominant-speaker` v0.3 (no_std/WASM, confidence margin in `ActiveSpeakerChanged`).
- **Cascade relay client** — `POST /relay/connect` HTTP endpoint (port 8912) with HMAC-SHA256 JWT authentication. Outbound WebRTC client using str0m as SDP offerer; establishes relay connection to upstream edge and sends `relay_source` DataChannel message.
- **`ClientOrigin::RelayFromSfu`** — marks relay connections from upstream SFU edges. Relay clients are excluded from dominant-speaker detection; keyframe requests are routed upstream via `Propagated::UpstreamKeyframeRequest`.
- **`Propagated::PublisherLayerHintForUpstream`** — Dynacast hints forwarded to upstream SFU.
- **RFC 9626 VFM** (`vfm` feature) — Video Frame Marking temporal-layer drop for H.264/VP9/HEVC.
- **`peer_audio_scores()` Prometheus gauges** — `sfu_speaker_{immediate,medium,long}_score{peer}`.
- **`current_top_k` DC broadcast** — top-3 speakers sent to clients on each tick.
- **CI workflow** — `cargo fmt`, `cargo clippy -D warnings`, `cargo test` on every PR.
- **`RELAY_JWT_SECRET`** env var (default `change-me-in-production`).
- **`SFU_RELAY_API_PORT`** env var (default `8912`).

### Changed

- `SFU_RELAY_API_PORT=8912` — new relay API port (expose in firewall alongside UDP 3478 and metrics 9317).
- Dominant speaker now includes `confidence: f64` (C2 margin) in `ActiveSpeakerChanged` events.

## [0.7.3] — 2026-04-22

### Added

- SFU-native dominant speaker detection via DataChannel id:3 (`{type:active_speaker,peerId:N}`).
- GCC-based bandwidth estimator and simulcast pacer.
- Multi-arch Docker builds (linux/amd64 + linux/arm64).

## [0.7.0] — 2026-04-22

### Added

- Initial partner-edge bundle: Caddy + xray-client + coturn + oxpulse-sfu.
- VLESS + ML-KEM + Reality + XHTTP tunnel to krolik backbone.
- TURNS-on-:443 via Caddy l4 SNI multiplexing.
- HMAC-SHA1 TURN credentials (`static-auth-secret`).
- One-command bootstrap installer (`bootstrap.sh` → `install.sh`).
- VM-clone hydration with sentinel-gated `hydrate.sh`.
- Cert-watch systemd unit for coturn TLS reload on renewal.

[0.8.0]: https://github.com/anatolykoptev/oxpulse-partner-edge/releases/tag/partner-edge-v0.8.0
[0.7.3]: https://github.com/anatolykoptev/oxpulse-partner-edge/releases/tag/partner-edge-v0.7.3
[0.7.0]: https://github.com/anatolykoptev/oxpulse-partner-edge/releases/tag/partner-edge-v0.7.0
