# Changelog

All notable changes to oxpulse-partner-edge will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.12.3](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/partner-edge-v0.12.2...partner-edge-v0.12.3) (2026-04-28)


### Bug Fixes

* **sfu/client_ws:** accept `bearer.<token>` subprotocol (no-space form) ([87f2388](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/87f2388ae6b5bb21fd4ee0c16136d06107f1f44d))
* **sfu/client_ws:** accept bearer.&lt;token&gt; subprotocol (no-space form) ([146c5f7](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/146c5f79e9067042f051e38da9ec548898bee1fa))
* **sfu:** rate-limit udp send_to failed warns + udp_send_failed_total ([#12](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/12)) ([9e6e3ce](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/9e6e3ceb9cc001637f46902ab75a48f05d364c13))

## [0.12.2] — 2026-04-27

### Added — Phase 7 M4.B1 client_ws verification metrics

- **`sfu_client_ws_active_sessions`** — gauge of currently open M4.A1
  client_ws sessions. Inc on session-open, dec on close (Drop-guard
  protected so panics also decrement).
- **`sfu_client_ws_sessions_started_total`** — counter, every accepted
  upgrade (token verified, WS handshake succeeded).
- **`sfu_client_ws_handshake_failures_total{reason}`** — counter, rejection
  reasons before session start. Bounded reason set:
  `missing_token | invalid_token | expired_token | room_mismatch`.
  (`bad_subprotocol` from the original spec was dropped — handler does
  not currently validate the subprotocol list, only the `Bearer` entry.)
- **`sfu_client_ws_offer_processed_total{outcome}`** — counter, outcomes
  of SDP offer processing inside the session. Bounded outcome set:
  `ok | parse_err | sdp_err | ice_err`.
- **`sfu_client_ws_answer_sent_total`** — counter, every successful answer
  frame written to the browser.
- **`sfu_client_ws_session_ended_total{close_code}`** — counter, session
  terminations bucketed by close code: `1000 | 1001 | 4001 | 4002 | 4003 | other`.
- **`sfu_client_ws_session_duration_seconds`** — histogram of full
  session wall-clock duration (every upgrade, including short
  rejected sessions). Buckets: `[1, 5, 30, 60, 300, 1800, 3600, +Inf]`.

All metrics inherit the registry's const `edge_id` label automatically.

### Why this matters

After Phase 7 M4 SFU group-call cutover, central signaling correctly
emits `upgrade_to_sfu` and selects geo-nearest healthy edge — visible
in logs. But there was a verification gap: we had no way to prove the
client actually opens the WS to `/sfu/ws/{room_id}`, completes SDP
exchange, and forwards media. CloakBrowser headless tests don't
reliably trigger the WS path. With these counters, a single real
browser session generates ticks across the pipeline; counter values
prove which step works and which is blocked.

### Tests

- `crates/sfu/tests/client_ws_handshake.rs` — 4 new tests assert the
  `started`, `missing_token`, `room_mismatch`, and `expired_token`
  counters tick on real WS roundtrips.
- `crates/sfu/tests/client_ws_session.rs` — 2 new tests assert
  `offer_processed{outcome=ok|parse_err}` and `answer_sent_total`
  tick during real SDP exchange.

## [0.12.1] — 2026-04-25

### Fixed — Phase 7 M4.A6 (real-user blocker)

- **`SFU_PUBLIC_IP` env override for WebRTC host candidates.** Without
  this fix, the SFU advertised `Candidate::host(0.0.0.0:N)` (its bind
  address) in the SDP answer. Off-box browsers cannot route to
  `0.0.0.0`, so ICE silently failed for every real user — only loopback
  CloakBrowser tests on the same host worked. Set `SFU_PUBLIC_IP=<node
  public IPv4>` (already wired in `docker-compose.yml.tpl` to the
  install-time `$PUBLIC_IP` autodetect) and the SFU emits a routable
  candidate.
- **Fallback preserves dev/test behavior.** When `SFU_PUBLIC_IP` is
  unset (or unparseable), the SFU falls back to the bind address with a
  warn log — so loopback unit tests, dev workflows, and v0.12.0 nodes
  awaiting redeploy keep working in their current state.
- **Same fix applied to the cascade-relay path** (`relay::client::connect_relay`).
  Both call sites now thread the same `host_candidate_addr` computed in
  `main.rs`.

### Deployment notes

- `SFU_PUBLIC_IP` is rendered from `$PUBLIC_IP` (cloud metadata → ipify
  → ifconfig.me) into the docker-compose template — operators on the
  bundle install path get the fix automatically on the next refresh.
- For manual deploys (recipe in `docs/runbooks/m4a5-deploy.md`), add
  `-e SFU_PUBLIC_IP=<node public IPv4>` to the `docker run` line.
- v0.12.0 nodes (rvpn) keep working without the env var — they retain
  the v0.12.0 broken-for-off-box behavior until the env is supplied;
  there is no regression from the upgrade.

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
