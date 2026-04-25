# Changelog

All notable changes to oxpulse-partner-edge will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.8.1](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/partner-edge-v0.8.0...partner-edge-v0.8.1) (2026-04-25)


### Features

* add vfm temporal-layer cap + dynacast emit_publisher_layer_hints ([a2187d2](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/a2187d2189e50b4c19fb6cd694605d2250053900))
* **bwe:** GoogCC v2 — trendline delay detector + AIMD controller ([a28ee1d](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/a28ee1d06f0fef3b215d6ae6969c539b81e9663a))
* **bwe:** integrate GoogCcEstimator into Registry — trendline+AIMD conservative merge alongside Pacer ([c80f9cb](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/c80f9cbf1d2bb345fc757476025f84402828ef9f))
* **channels:** CH3/CH5 config templates — Hysteria2 + NaiveProxy fallback channels ([1538ea0](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/1538ea00827ea3f12617096e30168e261ec67ca1))
* **channels:** forward-compat channels[] schema + CHANNELS.md ([7b447e0](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/7b447e0acc77b0c97fbae688493897ece590149e))
* initial import — partner-edge bundle + SFU crate ([5d0ec06](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/5d0ec06690eefdd403167cf0666d113141e3775f))
* **install:** persist channels[] from registration response to node-config.json ([36de146](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/36de1465d10abebe54a61f77691f298ccc6335ab))
* **install:** provision RELAY_JWT_SECRET + Caddy relay route — enables cascade relay on new nodes ([66da82f](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/66da82f846efe2ce9baa05748732b0be38125313))
* oxpulse-sfu-kit migration + cascade relay client (Phase 1) ([1c6131a](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/1c6131a13c95f47548eac289506f5a06ef6f4a80))
* oxpulse-sfu-kit migration + cascade relay client (Phase 1) ([1c6131a](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/1c6131a13c95f47548eac289506f5a06ef6f4a80))
* peer_audio_scores Prometheus gauges + current_top_k DC broadcast + AudioCodecHint ([73ee65a](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/73ee65a6788b5e831943f014326f230c5a1ca24e))
* **refresh:** call POST /api/partner/heartbeat on each daily run ([#4](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/4)) ([b15a28f](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/b15a28f799bc508d2aeee63d39af5e1bf702ce8a))
* **refresh:** extract channel-render-lib.sh; channels_version triggers auto re-render ([780041e](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/780041e7cd8f7187c1a9b06e178ab63b159d4e85))
* **relay:** Client::new_outbound_relay() + relay_source_pending field — outbound relay clients know their origin at construction time ([b057d5f](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/b057d5f5533fcaeb85b59c27292d8e0e546bae90))
* **relay:** outbound WebRTC relay client (str0m offerer, relay_source DC) ([0da00d1](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/0da00d1ce0039b34c629ad13000947f26e84f0fd))
* **relay:** POST /relay/connect Axum endpoint + relay task channel ([c92e6e9](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/c92e6e990801e430b8eaea8c1e754286bd1ef3ad))
* **relay:** relay_api_port config + relay/websocket/hmac/serde deps ([ad9a30d](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/ad9a30dcbe963c6b8071ff08e44b4532e42c47b9))
* **relay:** RelayJwt HMAC-SHA256 sign/verify + relay types ([3907299](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/39072998311ee81d7abed4bc2bc66f971d3c7ae9))
* **relay:** send relay_source DC to upstream on Event::Connected — completes outbound relay handshake ([15e1a22](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/15e1a22dec4f8cb6332e8c6886b23111ba8b100d))
* **relay:** serve() accepts relay_rx channel — relay Rtc enters Registry, main UDP loop drives ICE/DTLS/SRTP ([dac19c0](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/dac19c0ce6011eb1afdf060769e006425aee6f9a))
* RelaySource integration — cascade SFU support for partner-edge deployments ([9ba1395](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/9ba1395cdae9fc7f459d65d4794023c8c49641b0))
* **relay:** wire real UDP addr + relay inject channel in main.rs — cascade relay stack complete, zero build errors ([5f0b52a](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/5f0b52aac200fcc067efff76d0bd1e13ba7fb014))
* **security/P2:** FIPS 140-3 + Ed25519 asymmetric JWT — eliminate shared secrets ([#3](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/3)) ([e95706f](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/e95706facf06059e82ed960092e6374f1899cb81))
* **sfu:** SFU-native dominant speaker via DC id:3 ([f54aa85](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/f54aa859b28ea7a9be9b7a35eeed66dadf491c85))
* **sni:** daily SNI rotation from server-provided pool ([a7e4d3e](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/a7e4d3ec45a52d6e4017ed9aa319df61e5710c18))
* **upgrade:** re-render xray config from upstream template on upgrade ([16d603e](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/16d603ee29fda8b20e4019eb4bb8d374dcfd7f0c))
* **xray:** enable XTLS Vision flow + stream-one mode + padding ([ac8295a](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/ac8295afadd764a505416113315670c0ab56c92a))


### Bug Fixes

* **ci:** add shellcheck source=/dev/null directive — unblock release CI ([a6ffcd6](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/a6ffcd629718a74396af248be0f7ebea799f6ae7))
* **ci:** cargo fmt + VERSION=0.11.1 — unblock release build ([f106d12](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/f106d1251d205f4950466cf238bdd3614293b948))
* **ci:** rewire workflow paths for flat repo layout ([215d304](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/215d30461ab3ff2cc66fe3b2284425298eeeac2f))
* **ci:** valid JSON in .release-please-manifest.json ([81d9e3c](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/81d9e3c90f689f667e2ee109099a344389fac7f5))
* **ci:** valid JSON in release-please-config.json ([6565476](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/65654764cfa2471ca561b0e52939f09d0797b806))
* **relay:** allow apex oxpulse.chat in is_allowed_upstream — cascade relay upstream_url uses apex domain not subdomain ([e76d8ac](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/e76d8ac9bff1ab7fec091c6b6a84d4a359476f28))
* **relay:** fallback to HS256 when EdDSA verification fails — allows signaling server (HS256 signer) to trigger cascade relay even when edge has EdDSA pubkey ([67e78c0](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/67e78c0997ad811e18e06c876ed8efaa9aa53b49))
* **relay:** make RELAY_JWT_SECRET optional — SFU standalone mode when unset ([a434da9](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/a434da9cf2c90639cb2dd5a92f5bb258514ee0a4))
* **release:** VERSION=0.11.3 — align with release tag ([d154260](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/d154260e44d73194967e83c35fa6e97df48f0ef3))
* **security:** CRITICAL SSRF + default-secret + panic — use JWT fields, require RELAY_JWT_SECRET ([44a6d5b](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/44a6d5b297b66365b7cf7fdb5a38bb7f2c12e80d))
* **security:** HIGH relay JWT replay protection (jti store) + MEDIUM clock skew check ([269d73e](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/269d73e80aac8d2536566b51d960865c52b990d7))
* **security:** MEDIUM-1 migrate relay JWT to jsonwebtoken (RFC 7519) + MEDIUM-2 upstream host allow-list in relay client ([9a8a10f](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/9a8a10f4043c227a97f8cd7ea14c32c0107f348d))
* **security:** MEDIUM-3 relay JWT iat forward-date check + test ([25f5875](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/25f58754593313b06660e9493a9c1be3a50e0637))
* **security:** tighten relay upstream allow-list + EdDSA fallback ([356289f](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/356289fb3183db62abb78d6da589d2b6edeee01d))
* **upgrade:** correct image name sed pattern in upgrade.sh ([e076e0e](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/e076e0e9b361f0ac1a3f6e31d2e298afabab5692))

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
