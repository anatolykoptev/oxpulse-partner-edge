# Changelog

All notable changes to oxpulse-partner-edge will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.12.34](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/partner-edge-v0.12.33...partner-edge-v0.12.34) (2026-05-17)


### Features

* **install:** Phase 4.4 — remove bash render fallback (opec now hard requirement) ([#164](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/164)) ([7f63d3a](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/7f63d3a53a22791556fd0a5c0319f141d3c2a132))
* **install:** Phase 4.4 — remove bash render fallback (opec now hard requirement) ([#165](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/165)) ([d6b17c0](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/d6b17c0776756b8b900450ef18c30e33e87dd0e8))
* **install:** Phase 4.6 — extract healthcheck (TURNS cert wait + poll) into lib/ ([#166](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/166)) ([9fcb170](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/9fcb170cfa80e08133e908fbe583054ab4b9d6cd))
* **install:** Phase 4.7 — extract systemd unit installation into lib/ ([#167](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/167)) ([a933ce4](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/a933ce4600b9722092c13703f96b27603aa88e6e))
* **install:** Phase 4.7-4.9 — systemd extract + retire fallbacks + args extract ([#169](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/169)) ([b8312fa](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/b8312faf875c2fd4f2cf5ccf3a3350e2a093069e))
* **install:** Phase 4.8 — retire bash fallbacks for opec secrets ([#168](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/168)) ([0dbda30](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/0dbda30707c0ded12452ed4f6f3e6578ebd587c2))
* **opec:** Phase 4.3c — opec secrets register (HTTP POST + env-file) ([#161](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/161)) ([e830314](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/e830314585557dfb53aee6d9c81b7c97c9186561))
* **opec:** Phase 4.3d — opec secrets sfu-signing-key ([#163](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/163)) ([082b9b4](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/082b9b42b240968718b98dce3e40f8b9f910cc54))

## [0.12.33](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/partner-edge-v0.12.32...partner-edge-v0.12.33) (2026-05-17)


### Features

* **channels:** edge-side channels-health reporter (M2.6a) ([#159](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/159)) ([6873794](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/6873794d5d22c810035e9cea05519e68ac69ba29))
* **healthcheck:** add authed probe for /api/partner/hy2-credentials (check 19) ([#157](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/157)) ([e9403cb](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/e9403cba84e7bc0283ba98574b0ae3ed072dde96))

## [0.12.32](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/partner-edge-v0.12.31...partner-edge-v0.12.32) (2026-05-17)


### Features

* **install:** persist service_token from register response with fail-loud strand mode (Follow-up [#2](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/2) PR-B) ([#152](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/152)) ([e36d949](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/e36d949267cd0cfbaa3146f5f1080374aa118e09))
* **install:** Phase 4.1 — extract preflight + deps into lib/ modules ([#153](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/153)) ([ed9978e](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/ed9978ec976616cc3af4bde82b79e5db73142181))
* **install:** Phase 4.2 — extract IP + region detect into lib/install-network.sh ([#154](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/154)) ([75e6695](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/75e66955f236f5d3e5dc778d4b1daa276ba36c57))
* **opec:** Phase 3 — absorb compose + caddy render into OPEC ([#151](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/151)) ([cf07e94](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/cf07e94b11aa8442487f4b0e8f7e493d4ec9964b))
* **opec:** Phase 4.3a — opec secrets reality-keygen + env-gated install.sh delegation ([#155](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/155)) ([c252743](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/c2527438464afed93e98d8ddfcce90e38ac24de0))


### Bug Fixes

* **install_amneziawg:** install Go 1.24 (system golang too old) ([#149](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/149)) ([24866d5](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/24866d55561dc21afcdfc08475037641ab188042))

## [0.12.31](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/partner-edge-v0.12.30...partner-edge-v0.12.31) (2026-05-17)


### Features

* **opec:** phase 2 — render module + xray/coturn/naive subcommands + install.sh delegation ([#147](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/147)) ([4d6b9c8](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/4d6b9c8085d2ebdba211a9779004f95d761af392))
* **release:** ship opec binary as release asset ([#148](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/148)) ([cd641a4](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/cd641a4542d049fed5836aa39eebdd5880b33bd6))
* **release:** ship partner-cli prebuilt binaries as release assets ([#145](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/145)) ([564ff75](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/564ff7501a2c6d249dc3f1f6b0d00dcc255b97c6))


### Bug Fixes

* **install:** hy2 template path mismatch — channel-render-lib couldnt find it ([#143](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/143)) ([0ee890f](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/0ee890fa434b679bd33ad4854c9fe42062d3477f))

## [0.12.30](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/partner-edge-v0.12.29...partner-edge-v0.12.30) (2026-05-17)


### Features

* **release:** publish install.sh as one-command installer asset ([#141](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/141)) ([b45e5c3](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/b45e5c3418aa72de540569aa8e40962e0d68996f))
* **shell:** phase 1 — render dedupe across install/hydrate/update ([#139](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/139)) ([e09693d](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/e09693d37412632264531e43492e9e9ac7f15f3d))


### Bug Fixes

* **install:** fetch channel-render-lib.sh in source block, not just Step 8 ([#142](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/142)) ([7673b80](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/7673b805bea9135cbbd8efc2c62c10d5c26a6787))

## [0.12.29](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/partner-edge-v0.12.28...partner-edge-v0.12.29) (2026-05-16)


### Bug Fixes

* **channel-render:** split local+assign to silence SC2155 (release lint gate) ([#137](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/137)) ([7caa72c](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/7caa72c2b3571680ca3dbe4a30d7e08d6355471a))

## [0.12.28](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/partner-edge-v0.12.27...partner-edge-v0.12.28) (2026-05-16)


### Features

* **caddy:** phase 1 — canary endpoints + structured JSON logs ([#122](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/122)) ([c1e0381](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/c1e038121176552dde6cd9e5a74fea7f57baf0e6))
* **caddy:** phase 2 — extract tunnel_upstream snippet + golden-file test ([#129](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/129)) ([d8b91fb](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/d8b91fb9abb21bec4d594e80bbb0da9b0d0bbade))
* **caddy:** phase 3 — conf.d/ override slot + install.sh --check ([#130](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/130)) ([6e8de6a](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/6e8de6aef41c43be8f817b93012d6c9388c07855))
* **channels:** Phase 1.7 — integrate hy2 second channel into installer ([#134](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/134)) ([567b569](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/567b5690b72ca6c670d371b7bf3a04509bb7d41f))
* **install,upgrade:** GHCR auth via --ghcr-token + persistent token file ([#120](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/120)) ([bcffd3b](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/bcffd3b92d05fc61df4e8f1db6ac305bfdc8b445))
* **opec:** phase 4.0 — tenant yaml schema + validator + read-only CLI ([#131](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/131)) ([dc95d49](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/dc95d497a3e0a7f7f505f96451f6c866ed012e43))
* **opec:** phase 4.1 — Caddy JSON renderer + tenant reconcile --dry-run ([#132](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/132)) ([7dbd3c4](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/7dbd3c4a089099f70c0ab0fccbd9ea34624f128c))
* **upgrade:** --dry-run surfaces concrete conflicts before apply ([#125](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/125)) ([c80c8fc](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/c80c8fcbeaf8ca47c6397d83997505e8b4507c6b))
* **upgrade:** --with-templates for atomic Caddyfile+healthcheck+image lockstep ([#124](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/124)) ([c45d805](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/c45d805e3f3d11cf542ba2bbf1e3b4665fc291f2))


### Bug Fixes

* **caddy:** remove unrecognized maxmind_geolocation global option ([#128](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/128)) ([cdcfe3c](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/cdcfe3c0e23ce579c326b680286fa2bcce675841))
* **compose:** publish canary port 9080 on host loopback ([#123](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/123)) ([a52771a](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/a52771a57ea27b1fe4637f2241ee056c66c79459))
* **installer:** correct hysteria2 image path, drop unbuildable naive client ([#135](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/135)) ([cfc821d](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/cfc821d8208259d410c73d6db3e2a29323246b8d))
* **installer:** render() handles multi-line values (SFU_SIGNING_PUBLIC_KEY PEM) ([#136](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/136)) ([a4c62ac](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/a4c62acc7682173bc8794c64e12ab66e388402af))
* **upgrade:** reviewer findings — cover_dir, atomic install, flock, rollback pull, healthcheck disambig ([#126](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/126)) ([92f7f5a](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/92f7f5a76c46c2986e568e60cde8b9fe191cb235))

## [Unreleased]

### Added
- **CH3 Hysteria2 client** as second control-plane channel alongside CH2 AmneziaWG mesh.
  - New service `hysteria2-client` in compose (image `tobyxdd/hysteria:latest`, host network, restart always).
  - New `re_render_hysteria2()` in `channel-render-lib.sh` (mirrors `re_render_xray` pattern).
  - Caddy `tunnel_upstream` snippet → 2-upstream pool (`10.9.0.2:8907` primary, `host.docker.internal:18443` fallback) with `lb_policy first` + active health probes at `/api/health` every 10s.
  - `install.sh` provisions hy2 if `/api/partner/hy2-credentials` returns creds OR env vars `OXPULSE_HY2_AUTH_PASS` + `OXPULSE_HY2_OBFS_PASS` present.
  - `upgrade.sh --templates-only` re-renders hy2 alongside xray on existing edges.
  - 2 new healthcheck items: hy2 container healthy + `:18443` listener (graceful on awg-only edges).
- Golden-file test for `hysteria2-client.yaml` rendering: `tests/test_hysteria2_render.sh`.

### Changed
- `Caddyfile.tpl` `(tunnel_upstream)` + `(tunnel_upstream_default)` snippets — now emit pool + health directives (backward-incompatible with single-upstream golden — bumped fixture).

### Notes
- Phase 1 uses fleet-shared hy2 credentials. Per-edge identity = Phase 7 (`partner_nodes.hy2_auth_hash` schema migration TBD).
- CH5 NaiveProxy deferred — caddy-forwardproxy `forbidden_zones` blocks RFC1918+loopback at krolik server-side; needs external relay (Phase 2).
- CH1 Reality reinstall blocked on oxpulse-chat PR #971 (XRAY_XHTTP_MODE env extraction).

## [0.12.27](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/partner-edge-v0.12.26...partner-edge-v0.12.27) (2026-05-15)


### Features

* **install:** M6 slice 2b — Reality keypair + UUID on install + register payload ([#115](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/115)) ([1d45b36](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/1d45b366cb3936ea329caf6492e54e10bcc5fd93))
* **partner-edge:** Caddy maxmind_geolocation defence-in-depth (M2b.2) ([20361cb](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/20361cb101d23e7540f7df578eed6d4e567990c4))
* **scripts:** idempotent update.sh + packet-up template ([#113](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/113)) ([e4661ea](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/e4661ea3562aeaf04de72da44f0a759742866578))
* **security:** cargo-deny + nextest for supply-chain hygiene ([#109](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/109)) ([acb71b0](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/acb71b0ed0bc94becf443930d88808436aee9e29))
* **sfu:** peer-suspended bridge via sfu-events DC id:8 (Phase 2c) ([#119](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/119)) ([763aaaa](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/763aaaa265cebfa919f44f5d7eb33b59b1a2e4be))
* **sfu:** Phase B — migrate pacer to oxpulse-sfu-kit v0.11 per-subscriber ([#116](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/116)) ([a644059](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/a644059ac67c818ad871f381109c33a0be430494))


### Bug Fixes

* **gitignore:** match target as file/symlink, not just directory ([#117](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/117)) ([31cfb87](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/31cfb87393c70826b81d7a4e92a7d4cb5b3a29c2))
* **install:** keygen idempotency guard — preserve existing identity on re-run ([#118](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/118)) ([f99890f](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/f99890f5947dff92e5db7a4c48d561b1fa3e5ed0))
* **refresh:** decouple heartbeat from keys fetch — fixes PartnerEdgeStaleHeartbeat alert ([#112](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/112)) ([1728504](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/1728504e9ebc8e4e365bf8d02f84394808f88244))

## [0.12.26](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/partner-edge-v0.12.25...partner-edge-v0.12.26) (2026-05-10)


### Bug Fixes

* **sfu:** relay DC id:1 sframe-keys cross-peer — KX never propagated ([#106](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/106)) ([a7cbd15](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/a7cbd156d938c9d86ba136efc6ccbb392a4eee04))

## [0.12.25](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/partner-edge-v0.12.24...partner-edge-v0.12.25) (2026-05-10)


### Bug Fixes

* **sfu:** drop bogon ICE destinations before send_to (mobile reliability) ([#104](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/104)) ([ce69639](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/ce69639b9052d1fea8aad4bf3fa7af2311a5a679))

## [0.12.24](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/partner-edge-v0.12.23...partner-edge-v0.12.24) (2026-05-10)


### Features

* **sfu:** open reactions-group DC id=7 (hearts fix) ([#101](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/101)) ([a546970](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/a546970))


## [0.12.23](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/partner-edge-v0.12.22...partner-edge-v0.12.23) (2026-05-10)


### Features

* **sfu:** bwe-hint message + `sfu_bwe_hint_received_total` counter (Phase 2c) ([#97](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/97)) ([4eeeca8](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/4eeeca8))


## [0.12.22](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/partner-edge-v0.12.21...partner-edge-v0.12.22) (2026-05-09)


### Features

* **sfu:** auto-kick solo peer after configurable hold timeout ([#96](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/96)) ([01d90ae](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/01d90aedbd5db02a996144d4dc0f4a48605900e4))
* **sfu:** mid-based tracks_map_update emission for Bug [#5](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/5) ([#93](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/93)) ([8093e6a](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/8093e6a213cf4d5ffe03919d9ece398fb9109ba3))


### Bug Fixes

* **sfu/renegotiation:** address code-quality reviewer findings 1-4 ([#88](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/88) follow-ups) ([#91](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/91)) ([1297131](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/1297131fe4d200d0d52b147205858464ca6889c9))
* **sfu:** Bug [#7](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/7) — timeout+ws_closed paths leave stuck Negotiating tracks and drop queued offers ([#95](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/95)) ([c45b704](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/c45b7045cf1ce7e8906fef777ff183c16b3b4021))
* **sfu:** PR [#93](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/93) followups — tracks_map_update silent drop, peer_id type, relay debug ([#94](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/94)) ([278ef3b](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/278ef3b87f1fef5c74291f251bf13026c5d167ef))
* **sfu:** str0m findings — correct SdpPendingOffer comment + write error metric ([#89](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/89)) ([2a2d981](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/2a2d9811cb8bba3da826fd2ad34334f04fbfcf81))

## [0.12.21](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/partner-edge-v0.12.20...partner-edge-v0.12.21) (2026-05-09)


### Features

* **sfu:** adopt str0m built-in stats API for RTT/loss/jitter observability ([#87](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/87)) ([5ebe30a](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/5ebe30a0a52dddbbaf7460373e3644e49a2e9d44))
* **xray-update:** env-overridable CONTAINER and IMAGE for piter reuse ([#85](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/85)) ([4b5e646](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/4b5e6467cad2d52f2f406e14e42e00aec69f88c4))


### Bug Fixes

* **refresh:** skip systemctl reload when unit absent on custom-stack nodes ([#84](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/84)) ([d77478e](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/d77478e96a916bc7ce9882bce0ff554d6715634b))
* **sfu:** transition TrackOut Negotiating→Open in accept_renegotiation_answer ([#88](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/88)) ([1e4d265](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/1e4d2656b227712de668ac9171328e39ca518f61))
* **upgrade:** raise post-up sleep to 10s to survive xray Reality tunnel startup ([#81](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/81)) ([1fe251a](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/1fe251ac4dbffb6e176ff8f18c39766cf3cb3987))
* **xray:** downgrade xray-core pin 26.5.3 → 26.4.25 ([#83](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/83)) ([0bcbc6b](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/0bcbc6bb43fa2ed95784e59e0054168abb549875))
* **xray:** remove flow=xtls-rprx-vision from CH1 xhttp outbound template ([#86](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/86)) ([df83840](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/df8384011a806805dda31306f97aec1e3208cde1))

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
