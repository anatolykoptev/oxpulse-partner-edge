# Changelog

All notable changes to oxpulse-partner-edge will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.12.20](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/partner-edge-v0.12.19...partner-edge-v0.12.20) (2026-05-09)


### Features

* **xray:** pin xray-core to v26.5.3 + weekly auto-update timer ([#80](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/80)) ([1bd7656](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/1bd7656a01842eb3d3b835463ca978c2732a76b4))


### Bug Fixes

* **refresh:** OS-aware dep error messages + add jq to install.sh deps ([#77](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/77)) ([3ef9d56](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/3ef9d568d0fcd41d8242b9fa6d50537a02f2ba11))
* **xray:** switch uTLS fingerprint from chrome to randomized ([#79](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/79)) ([3599f0f](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/3599f0fac6f5d834abd72e2ef9e19b290ec39e74))

## [0.12.19](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/partner-edge-v0.12.18...partner-edge-v0.12.19) (2026-05-09)


### Features

* **telemetry:** add service.instance.id / partner.id resource attrs for per-edge Jaeger filtering ([#74](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/74)) ([81cfb53](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/81cfb5321dda754bae827aa2cf5927b5cbf7b457))


### Bug Fixes

* **refresh:** die early when jq missing so heartbeat is never silently skipped ([#73](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/73)) ([47cf0a8](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/47cf0a8450a88a4d21de41f213792296ec65de3c))

## [0.12.18](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/partner-edge-v0.12.17...partner-edge-v0.12.18) (2026-05-09)


### Features

* **sfu:** M2 SDP renegotiation — complete group call media delivery ([#70](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/70)) ([2d412b0](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/2d412b0bc0b61d6596ac1763048b4ab3b3744e73))

## [0.12.17](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/partner-edge-v0.12.16...partner-edge-v0.12.17) (2026-05-08)


### Features

* **sfu:** deep forwarding-path observability — 4 new counter families ([#67](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/67)) ([cf34d58](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/cf34d58c8d359d7587419c703d4fb7c0dd0a6784))

## [0.12.16](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/partner-edge-v0.12.15...partner-edge-v0.12.16) (2026-05-08)


### Features

* **sfu:** Phase F2 — tracks_map WS backchannel for signaling-first stream binding ([#65](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/65)) ([91f75f6](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/91f75f672b1536395bd4a14e7cc03f33e5bf55a5))

## [0.12.15](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/partner-edge-v0.12.14...partner-edge-v0.12.15) (2026-05-08)


### Features

* **sfu:** Phase C sfu_sdp_msid_injected_total counter (A1 regression guard) ([#63](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/63)) ([bb934e3](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/bb934e3e1447d69150b4bdd38a3d2220b13835e7))

## [0.12.14](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/partner-edge-v0.12.13...partner-edge-v0.12.14) (2026-05-08)


### Features

* **sfu:** inject a=msid in answer SDP for browser stream attachment ([#60](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/60)) ([75fa812](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/75fa81216ca8b47d78416845c846769aa3015d39))

## [0.12.13](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/partner-edge-v0.12.12...partner-edge-v0.12.13) (2026-05-08)


### Bug Fixes

* **sfu:** pass real candidate_addr to handle_incoming — STUN destination match ([#58](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/58)) ([842f07a](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/842f07a7aff18fd476ec319349d4c66dccfc7a5d))

## [Unreleased]

### Bug Fixes

- **sfu/ice:** pass `candidate_addr` to `udp_loop::serve` — fixes `iceState:failed` on group calls. str0m's ICE agent silently dropped STUN binding requests whose destination didn't match the installed host candidate (wildcard 0.0.0.0:7878 vs SFU_PUBLIC_IP:7878).

## [0.12.12](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/partner-edge-v0.12.11...partner-edge-v0.12.12) (2026-05-08)


### Features

* **sfu:** OFFER_TIMEOUT 30s + parse_err sub-labels + ice_state counter ([#56](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/56)) ([a2df998](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/a2df9981489de971312226e374dbb245947f46f2))

## [0.12.11](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/partner-edge-v0.12.10...partner-edge-v0.12.11) (2026-05-07)


### Bug Fixes

* **metrics:** chat_relay_active_channels gauge .dec() on disconnect ([#53](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/53)) ([eed61b9](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/eed61b9dcdda058dd40a068513364eb80186db4f))

## [0.12.10](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/partner-edge-v0.12.9...partner-edge-v0.12.10) (2026-05-06)


### Features

* **sfu:** chat-data + chat-ctrl DC routing through SFU (Phase 2b) ([#40](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/40)) ([484bb43](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/484bb43e4b0d61983f0230cacbf23366f0d1c422))


### Bug Fixes

* **installer:** die on empty signaling_sfu_secret response ([#49](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/49)) ([c8047e0](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/c8047e078eee5601c5bb739793781070d9564ffe))
* **sfu/pacer:** F6-9 SUSPEND_STREAK parity + bump oxpulse-sfu-kit 0.7→0.8 ([#44](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/44)) ([8fa2960](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/8fa2960b80377af22c3b3aba4d757cad1f8f9c54))
* **sfu/pacer:** F7-5 symmetric exit hysteresis ([#45](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/45)) ([ce4a3fd](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/ce4a3fdbdb1cc14268fd71fe57e2ef3080c91d86))
* **sfu/registry:** F2b-2 reap chat_relay label series on disconnect ([#46](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/46)) ([e30d41c](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/e30d41c018cfc8fb1701ffd85abdbf67b9dbd71d))
* **sfu:** observability bundle — gauge fix + degraded-state visibility + healthcheck ([#48](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/48)) ([54130e1](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/54130e1d65a0eba3f2ab827102d3b7ae18f61c01))

## [0.12.12] (2026-05-08)

### Bug Fixes

* **sfu/ice:** pass candidate_addr to udp_loop::serve so str0m ICE agent can match STUN binding requests — fixes iceState:failed for group calls on wildcard-bound sockets (SFU_PUBLIC_IP != 0.0.0.0)

## [Unreleased]

### Bug Fixes

- **installer:** die on empty signaling_sfu_secret response (closes 2026-05-06 silent-fail class).

## [0.12.9](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/partner-edge-v0.12.8...partner-edge-v0.12.9) (2026-05-02)


### Features

* **install:** zero-touch AmneziaWG mesh + OTel onboarding ([#36](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/36)) ([1d7b7ec](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/1d7b7ec628e469064920254c418d9226f786f470))

## [0.12.8](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/partner-edge-v0.12.7...partner-edge-v0.12.8) (2026-05-02)


### Features

* **sfu:** OpenTelemetry / Jaeger trace pipeline (opt-in) ([#35](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/35)) ([9cbe75e](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/9cbe75ec25b777aa2a2d986e7d358b733804083d))


### Bug Fixes

* **install:** canonical metrics port + edge_id + spin-trap warn ([#33](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/33)) ([ab38b92](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/ab38b928f6ce2a9920797c58fd8c77444d8cc8b0))

## [0.12.7](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/partner-edge-v0.12.6...partner-edge-v0.12.7) (2026-05-02)


### Bug Fixes

* **install:** replace backticks with single quotes in --help (SC2215) ([#31](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/31)) ([a3b8df9](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/a3b8df9c0ab72fc3374c7a325f1122d80acd74b4))

## [0.12.6](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/partner-edge-v0.12.5...partner-edge-v0.12.6) (2026-05-02)


### Features

* **install:** --brand-* CLI shorthands for inline branding ([#29](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/29)) ([36ff498](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/36ff498fa26121eb07f308a058a5e452e655cb15))


### Bug Fixes

* **install:** die early when backend returns empty reality_encryption ([#28](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/28)) ([3580a3f](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/3580a3f382b7a38218e30020ef631e77445ea966))
* **install:** unblock fresh CentOS provisioning + 8 robustness fixes ([#27](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/27)) ([563c7e6](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/563c7e65b8a7f5847c4e9f8459dd08479e2515fd))
* **sfu:** eliminate udp_loop spin on closed inject channels ([#30](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/30)) ([fe193b5](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/fe193b50daa117ba72a11aad922a4d85141b9194))

## [0.12.5](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/partner-edge-v0.12.4...partner-edge-v0.12.5) (2026-04-30)


### Features

* **sfu/metrics:** observability follow-ups — sub-second buckets + per-peer media gauge + Phase 2 reserve annotations ([#22](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/22)) ([7b521fb](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/7b521fb0368971c14f29c6525d8af38d5bbc7a41))


### Bug Fixes

* **sfu/config:** serialize env-mutating tests — unbreak flaky CI ([#24](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/24)) ([51615fa](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/51615fa1fbd88e043b1e70eb228af7e19de2495c))

## [0.12.4](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/partner-edge-v0.12.3...partner-edge-v0.12.4) (2026-04-29)


### Features

* **sfu/A1:** peer_id-keyed session steal — close 4031 on duplicate /sfu/ws upgrade ([1b50ac5](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/1b50ac58938093f58fb9cb40242fe42f5238393d))
* **sfu:** peer_id-keyed session steal with WS close 4031 ([ca18972](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/ca18972a4a64f240180fbd809cfa05f95f94484b))

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
