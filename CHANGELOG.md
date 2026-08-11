# Changelog

All notable changes to oxpulse-partner-edge will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.16.22](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/v0.16.21...v0.16.22) (2026-08-11)


### Bug Fixes

* **selfheal:** compute the image keep-set per repository, not across all of them ([#591](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/591)) ([41e6b6a](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/41e6b6a82634dbce9633882970a533a7928e271f))

## [0.16.21](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/v0.16.20...v0.16.21) (2026-08-11)


### Features

* **selfheal:** collect our own stale release images, before touching anything shared ([#589](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/589)) ([5a7fc6f](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/5a7fc6f9c6dabe55d121c5bfedec8f5af36a2277))

## [0.16.20](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/v0.16.19...v0.16.20) (2026-08-10)


### Bug Fixes

* **selfheal:** bound a crashlooping unit, and a monthly timer that never ran at all ([#587](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/587)) ([6d93935](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/6d93935dfb5bc5b5917e9a504e916d5551848166))

## [0.16.19](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/v0.16.18...v0.16.19) (2026-08-10)


### Features

* **selfheal:** extend healing to units, enable-drift, stopped containers and disk ([#585](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/585)) ([e823fb8](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/e823fb8df412aea4f135c67fba7a01a29b27fdd4))

## [0.16.18](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/v0.16.17...v0.16.18) (2026-08-10)


### Bug Fixes

* **release:** upload the self-heal assets, and guard the class ([#583](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/583)) ([8312108](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/83121084fee6a364a7881176a47dd7a2a0cd3f76))

## [0.16.17](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/v0.16.16...v0.16.17) (2026-08-10)


### Features

* **selfheal:** restart an UNHEALTHY-but-running container, bounded and escalating ([#581](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/581)) ([352955d](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/352955d679587b432d78e72228062af41d8ea73d))

## [0.16.16](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/v0.16.15...v0.16.16) (2026-08-08)


### Bug Fixes

* **upgrade:** converge the compose profile set, or [#570](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/570) reaches no existing node ([#574](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/574)) ([abcc6a9](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/abcc6a976c1af1e60edc6ccd6cb4d55b6e39fa6c))

## [0.16.15](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/v0.16.14...v0.16.15) (2026-08-08)


### Features

* **metrics:** collect the partner_edge_* series the edges have always written ([#570](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/570)) ([012f0ac](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/012f0acac100aeb51475b454a1f742599472ee2f))


### Bug Fixes

* **metrics:** discard the pre-[#328](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/328) partner_edge.prom before anything scrapes it ([#571](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/571)) ([c305e4d](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/c305e4d67dda485e9b0a3506d695229b27b02c77))
* the SFU healthcheck's secret gates were inert, and an operator hint named a flag that does not exist ([#565](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/565)) ([7f655ce](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/7f655ce77ae7c4566cfe55d2f2723e9ca5b82061))

## [0.16.14](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/v0.16.13...v0.16.14) (2026-08-07)


### Features

* **edge:** cache /_app/immutable at the partner edges ([#553](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/553)) ([689ecda](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/689ecda1bbade4fa556f22d3fd922cc8eda3adc7))
* **upgrade:** converge the systemd surface, not just the unit files ([#558](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/558)) ([40bffa2](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/40bffa2a62f0f2e8beabf0d4f14ae58fc6c14db9))

## [0.16.13](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/v0.16.12...v0.16.13) (2026-08-07)


### Features

* **edge:** link cache-handler and gate Caddyfile loadability on apply ([#554](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/554)) ([2157bf9](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/2157bf97ca364a9a45228f9be0e89abae1031664))

## [0.16.12](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/v0.16.11...v0.16.12) (2026-08-07)


### Bug Fixes

* **refresh:** let partner_edge_sfu_pubkey_applied reach 1 ([#550](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/550)) ([#551](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/551)) ([177ebb9](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/177ebb9cadb10d99acff89e5b9d43a08d886a311))

## [0.16.11](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/v0.16.10...v0.16.11) (2026-08-07)


### Bug Fixes

* **caddy:** port-qualified admin origins — unbreaks healthcheck and caddy reload ([#542](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/542)) ([b69621a](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/b69621a2e882c8d959ca9a2a3ceac1df22d81bf6))
* **upgrade:** do not declare success over a container that wedges after the gate ([#522](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/522)) ([#545](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/545)) ([69d6156](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/69d615688e188155ba70c5218aa29d2d03871c90))
* **upgrade:** fail loudly when the node-config in use cannot be rendered ([#512](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/512)) ([#549](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/549)) ([3c2ccc8](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/3c2ccc8d7bf5fdc6843a42edd0df8bb94f2fb00e))
* **upgrade:** run the post-upgrade re-render under a health gate ([#514](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/514)) ([#547](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/547)) ([feecc31](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/feecc31c70967d7d526aeaaa76168cfdce0197a4))

## [0.16.10](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/v0.16.9...v0.16.10) (2026-07-31)


### Bug Fixes

* **sni:** renderer uses the same deterministic pick as the daily rotator, and the helper actually ships ([#526](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/526)) ([f27c29e](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/f27c29ea984b0595ac9f58d48407d22d5c89ff21))

## [0.16.9](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/v0.16.8...v0.16.9) (2026-07-30)


### Bug Fixes

* **upgrade:** re-fetch node-config before rendering, instead of trusting a stale local file ([#508](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/508)) ([786914b](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/786914bbc72064fb8672eb58b2fc7399257fe9ff))

## [0.16.8](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/v0.16.7...v0.16.8) (2026-07-29)


### Bug Fixes

* **edge:** healthcheck the xray tunnel path instead of a bound port ([#499](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/499)) ([34ece59](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/34ece59dd4688c9b50f5c51af3f7a5eac5704be5))
* **refresh:** re-derive channels-status.env instead of freezing the install-time verdict ([#507](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/507)) ([7d07ef2](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/7d07ef2bea4bfb8e5692a2eddf9015db6be2be1e))
* **tests:** stop SIGPIPE from failing passing assertions under pipefail ([#503](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/503)) ([3f9774f](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/3f9774f73480ae31ad29fe28b74a914d22f72660))

## [0.16.7](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/v0.16.6...v0.16.7) (2026-07-21)


### Features

* **sfu:** add hysteresis band on BWE temporal-cap 1↔uncapped rail (closes [#473](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/473)) ([#474](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/474)) ([6626702](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/6626702456f3f92f9b2ca93be4e1b2c13788549a))
* **sfu:** enable Dependency Descriptor extension parsing (G3 P0, observability-only) ([#466](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/466)) ([7adef27](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/7adef273bcdfa206869f36e578dcb31fe828f857))
* **sfu:** enable vfm temporal-drop subsystem in prod build + sfu_vfm_enabled marker (G3 P3a) ([#471](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/471)) ([a4740b2](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/a4740b2a7b0eebf0b26e884f51896919bea7404f))
* **sfu:** parse Dependency Descriptor + per-subscriber temporal-layer drop (G3 P1) ([#468](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/468)) ([4385a7d](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/4385a7d16bced4742ab4c818ed3a3da06dde3407))
* **sfu:** request keyframe on simulcast layer switch (G4) ([#464](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/464)) ([4843722](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/48437222190947a78f265d46a32cc093a1532426))
* **sfu:** SFU-BWE-driven per-subscriber temporal-layer cap (G3 P3b) ([#472](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/472)) ([e2a96cc](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/e2a96cc570f2e93ac370ed2bc77d7c622c0ba114))

## [0.16.6](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/v0.16.5...v0.16.6) (2026-07-19)


### Bug Fixes

* **sfu:** honor SFU_RELAY_HS256_FALLBACK in relay-source DC path ([#461](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/461)) ([47624a8](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/47624a8f7d11617adc426d37e7a6828c9938752b))

## [0.16.5](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/v0.16.4...v0.16.5) (2026-07-19)


### Features

* **fleet:** central-driven self-upgrade — refresh.sh consumes desired_release + upgrade.sh apply-path downgrade guard ([#457](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/457)) ([2168fec](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/2168feceffdefc0a2b3f9d85b620f95fdf40eb0c))

## [0.16.4](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/v0.16.3...v0.16.4) (2026-07-19)


### Features

* **hydrate:** consume central-authoritative public_ip from register response as highest-precedence tier ([#455](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/455)) ([f950e48](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/f950e4842b991355f118448efc004023fcdd97b7))

## [0.16.3](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/v0.16.2...v0.16.3) (2026-07-18)


### Bug Fixes

* **hydrate:** SFU_PUBLIC_IP DNS-authoritative + motherly-IP guard ([#453](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/453)) ([ed389f6](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/ed389f68bbbe6c525d4c5309ec2e8c8fab1ee3d7))

## [0.16.2](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/v0.16.1...v0.16.2) (2026-07-18)


### Bug Fixes

* **hydrate:** derive PUBLIC_IP from TURNS DNS A-record, not egress autodetect ([#451](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/451)) ([673bea7](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/673bea798c6b810041ba36120bc78f242312ed37))

## [0.16.1](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/v0.16.0...v0.16.1) (2026-07-17)


### Bug Fixes

* **coturn:** cap allocation lifetime to prevent probe leak wedge ([#440](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/440)) ([752acba](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/752acbaf80384e4f9edc0dbc466511e26302d24c))
* **cross-probe:** validate token file contract at read time ([#444](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/444)) ([f832465](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/f832465f40793aa49224cfccf9a87db287f1db46))
* **install:** guard python3 before awg_extract + add to deps_install ([#437](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/437)) ([3de06a8](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/3de06a81422b33c0745d1318f553c725c22bb4e2))
* **reconcile:** log warning on mktemp/mkdir failure in _write_coturn_skip_count ([#443](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/443)) ([e96efac](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/e96efac29bdaa84e424dc781184710a65a40b72e))
* **refresh:** pass compose service key to _channel_restart_if_changed ([#439](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/439)) ([9843681](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/9843681bfd8755e90ffe541b322cf25ef78bf2e8))
* **sfu:** bounded retry for renegotiation answer on full ws_ctrl_tx ([#441](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/441)) ([450f956](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/450f956e20fb4a79c4dc04cd812c00342949307f))
* **sfu:** log + count mutex poison in bwe-hint rate gate ([#438](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/438)) ([c892d8b](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/c892d8bd438953dcebccc579b243a0fc723e4047))

## [0.16.0](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/v0.15.1...v0.16.0) (2026-07-13)


### Features

* **sfu:** arm str0m native BWE on subscriber legs (T1) ([#405](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/405)) ([c811425](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/c8114252b01c43a9f6f09c4c1227fcb202113d4f))
* **sfu:** emit sfu_combined_bps_binding_term metric ([#2310](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/2310) V0) ([#409](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/409)) ([d679a49](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/d679a491799ba5144339a6b644c092abf13de72c))
* **sfu:** forward REMB as a receiver-side downlink BWE signal ([#407](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/407)) ([835a397](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/835a3973c22c37cd8fee11ada5c9b92bbbeabe46))


### Bug Fixes

* **sfu:** advertise private IP as second ICE candidate (OCI-hairpin fix for group calls) ([#396](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/396)) ([ac03c0b](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/ac03c0b52ea7d4b583037977538a22003db4bdfc))
* **sfu:** bind /metrics to loopback by default ([#404](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/404)) ([#406](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/406)) ([aef6dfe](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/aef6dfe6ad68b9c99d1a068391edbbda4e02741b))
* **sfu:** min-tick pacer floor + softened suspend to stop spurious video drops ([#399](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/399)) ([fbd0f7e](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/fbd0f7e81221af6f9d192f77a1a1ff4099442834))

## [0.15.1](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/v0.15.0...v0.15.1) (2026-07-11)


### Bug Fixes

* **firewall:** allow local Caddy→SFU WS path without exposing :8920 publicly ([#390](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/390)) ([cd0b492](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/cd0b492544260b8f508212a1a434c03021e95479))

## [0.15.0](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/v0.14.5...v0.15.0) (2026-07-09)


### ⚠ BREAKING CHANGES

* adopt oxpulse-sfu-kit 0.12.0 (str0m 0.21) + retire sfu_rid_to_rid shadow-dup

### Features

* adopt oxpulse-sfu-kit 0.12.0 (str0m 0.21) + retire sfu_rid_to_rid shadow-dup ([bd1372e](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/bd1372e0652900acd0d6607639967f7c62088547))

## [0.14.5](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/v0.14.4...v0.14.5) (2026-07-09)


### Bug Fixes

* SFU healthcheck CIDR-drift heal — env-var-by-construction (PR1/4 v0.14.5) ([#378](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/378)) ([71e2b68](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/71e2b68a02067f7a51ded6b274862265c1a740bd))
* **upgrade:** _source_lib manifest resolution falls through on a missing entry, not just an unresolved candidate ([#381](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/381)) ([f3ae31d](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/f3ae31da8146657f0cf56532eb50ec9960556ab0))
* **upgrade:** 429-aware curl retry + stage-once transitive-dep fetch ([#380](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/380)) ([08c0258](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/08c02588c84e9f4e6c0c22ef0731f739f64f1ee6))
* **upgrade:** self-update root-cause warn + RETRY_OPTS + fail-closed convergence gate (PR4/4 v0.14.5) ([#382](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/382)) ([c46108d](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/c46108ddbda2ad44bb39a27f4e5685a218ed9f61))

## [0.14.4](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/v0.14.3...v0.14.4) (2026-07-08)


### Bug Fixes

* Bug15 test bug + review nits from health-report strangler arc ([#369](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/369)) ([41968d3](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/41968d3dc0c1787a817d44225ec60b38b737cd13))
* CWE-214 argv hardening — cross-probe token refresh bearer via -K stdin ([#371](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/371)) ([c53d8e4](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/c53d8e4573d64aaeeb015ebf3d0d7ca7b9da97cb))
* P3 review residuals — lib-missing marker + CWE-214 argv hardening ([#370](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/370)) ([bafb45e](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/bafb45ef338f46fe15a492bbc8b1610e9ba3435b))
* **probe:** ch1/ch2/ch3 test the real end-to-end tunnel, not local liveness ([#362](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/362)) ([a46bde8](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/a46bde85d45bb44d58af8067d900010a59004cbb))
* SFU signing-key write — atomic + escaped (CWE-116/943 defense-in-depth) ([#372](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/372)) ([11a6a65](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/11a6a65b739ec8ece0a0e91ae89720c8fe9b031a))
* **upgrade:** serve-ability-aware settle gate — stop false rollbacks on multi-homed boxes ([#365](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/365)) ([2729a92](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/2729a923aba31a644e2978ad18158e0df820a52f))

## [0.14.3](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/v0.14.2...v0.14.3) (2026-07-04)


### Bug Fixes

* harden upgrade health-gate (settle cold-start) + self-update re-exec + reload observability ([#360](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/360)) ([e9a08e8](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/e9a08e84b09713151f00a37691ff88efbea765c8))

## [0.14.2](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/v0.14.1...v0.14.2) (2026-07-03)


### Bug Fixes

* **reconcile:** converge on-disk Caddyfile drift (P5 caddy strangler) ([#357](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/357)) ([ed9603b](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/ed9603b5623c72ce6c10d06090cbe0a63054442e))
* **upgrade:** fail-closed sha256 + TLS-pin on _source_lib tier-3 fetch (P0 supply-chain) ([#353](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/353)) ([7fab7b2](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/7fab7b2dc21f2906a1fd6a7c0114ea0de5d03702))

## [0.14.1](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/v0.14.0...v0.14.1) (2026-07-03)


### Bug Fixes

* cure 3 upgrade/reconcile-infra bugs blocking --with-templates rollout ([#351](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/351)) ([6fdec90](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/6fdec90a4afb18c081cfa3f3ea4890aeb992b0a4))

## [0.14.0](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/v0.13.1...v0.14.0) (2026-07-02)


### Features

* **sfu:** activate cascade-relay on Ed25519 signing key too (T8, re-stacked) ([#349](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/349)) ([ab3c4d5](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/ab3c4d5a138cf48d725a830b660be9a13860bd02))
* **sfu:** admission cap + udp histogram + relay-connect counters (T9+T10+T13 metrics cluster) ([#350](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/350)) ([c9fbf1e](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/c9fbf1e297d0afb78421f9365ccc821581c2f4e5))
* **sfu:** label + kill-switch the EdDSA-&gt;HS256 relay-JWT fallback (T4.3) ([#339](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/339)) ([2e42020](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/2e42020bf8122fab49c8b4c9fe0ef0498e3039c7))


### Bug Fixes

* **awg:** serialize awg0.conf writes with a shared flock (install/agent lost-update race) ([#330](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/330)) ([69aec3e](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/69aec3eaa073aa51804536794d797f4dc9e53982))
* **awg:** validate I1 charset before conf splice to block kernel peer injection ([#336](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/336)) ([6384a98](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/6384a983dc761ae437664d9cb15a4edbc8324160))
* **health-report:** route ch0/naive channel to honest not-yet-wired skip ([#346](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/346)) ([1d0267d](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/1d0267d33f39a4849051bbe87c92914b3758552f))
* **refresh:** re-render xray-client.json on Reality rotation (epoch_apply_gap) ([#332](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/332)) ([4699123](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/469912395b33a8a22d067c8bfe81622ae7124d4c))
* **sfu:** reconcile relay_source room-token verify with dual-credential rollout policy ([#338](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/338)) ([d9e3e69](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/d9e3e698931a5a6238dd12253beb499933a74f03))
* **sfu:** route InvalidAlgorithm to AlgorithmMismatch so HS256 relay-JWT fallback fires ([#337](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/337)) ([46a5df7](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/46a5df7090c8bb7a5b2a1ac07f3dfa194b51d56c))
* **sfu:** wire SFU signing-pubkey refresh to a live consumer (env_file + recreate) ([#331](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/331)) ([c1ab710](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/c1ab71097c3b43c245d810d552b24e76c6d594ff))

## [0.13.1](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/v0.13.0...v0.13.1) (2026-07-02)


### Bug Fixes

* **upgrade:** dead rollback under set -e + foreign-service pull scope (edge-c v0.13.0 incident) ([#333](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/333)) ([26b66af](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/26b66af178b12b91e6dd4e0a0525ca937d17f555))
* **upgrade:** sync healthcheck.sh in plain apply + repair CI test fragility ([#335](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/335)) ([204e506](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/204e50684fda7bcfc27e178fe629d7411872e4c1))

## [0.13.0](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/v0.12.79...v0.13.0) (2026-07-01)


### Features

* **observability:** surface consecutive coturn-skip count for stuck-edge detection ([7f7226f](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/7f7226f735d6f69efe26c0e3ac346542617a4f62))
* **observability:** surface consecutive coturn-skip count for stuck-edge detection ([fea6184](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/fea61847728beb29f4b746bc6746f81aec5a1576))
* **observability:** surface coturn-skip count in edge health report + cover no-op/dry-run resets ([acaa072](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/acaa0728533dfa1d850c3df879b1340ddda8fbdb))
* **reconcile:** wire coturn/xray_client/firewall/xray_env surfaces (Phase 4b) ([8de275b](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/8de275b45674f911b64bf3eefbd99f3c8ea920b9))
* **refresh:** daily cross-probe token re-mint via the T2.4.c endpoint ([#328](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/328)) ([df98c02](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/df98c02337eef237f75499914207431204c45080))


### Bug Fixes

* **probe:** treat 429/408 as transient, not a permanent 4xx (RFC 6585) ([#325](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/325)) ([cebcd1f](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/cebcd1f386aa031989e1563ef284e56cc4350bcc))
* **reconcile:** make coturn render deterministic + fail-closed; close HIGH/MEDIUM review findings ([aeba59a](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/aeba59a94b39f8b1c0ff98dd32ae53b1a7c6d5f4))

## [0.12.79](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/v0.12.78...v0.12.79) (2026-06-16)


### Bug Fixes

* **probe:** coturn-tls leg uses openssl s_client (turnutils can't drive caddy-l4 SNI-mux) ([#322](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/322)) ([c97608e](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/c97608e906d0dacfd027e36c82d51b6825903785))
* **probe:** pin cross-probe dial to the SSRF-vetted IP (SEC-CR-322-02 / SEC-CR-302) ([#324](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/324)) ([c3fa13e](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/c3fa13e3d36386e7ccda71622a6af4a116b0b76d))

## [0.12.78](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/v0.12.77...v0.12.78) (2026-06-16)


### Features

* **probe:** edge cross-probe loop — probe roster peers' TURNS:443 + prober-attributed report (P3b mesh producer) ([#306](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/306)) ([19aec4f](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/19aec4fe374a00f8d41fe89828fb789d52e09406))
* **probe:** P3b UDP STUN leg — coturn-udp peer-row for second vantage ([#321](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/321)) ([012c66f](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/012c66f93e6edfb7f0580503fa592d37ea2fe4f8))
* **reconcile:** baseline-aware health gate — rollback on regression not pre-existing red (Phase 3) ([#318](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/318)) ([092322e](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/092322e1fedfb6b7d64fc92f3e68e8d3ceb8c01d))
* **reconcile:** manifest-driven engine + apply_restarts wiring + caddy surface (Phase 4a, ADR-003) ([#319](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/319)) ([d13075d](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/d13075de0c107659c21a1d7fbfed166763f889b7))
* **reconcile:** Phase 1 — lib/reconcile.sh + caddyfile via opec render authority (ADR-001) ([#316](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/316)) ([27f7584](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/27f7584a3e544f82a90f6e4c7a77fe5efd842453))
* **reconcile:** state schema v1 + migrate_state + tier-3 NAIVE fix + opec probe (Phase 2, ADR-002) ([#317](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/317)) ([aa995c2](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/aa995c2c8ef37ca66bc68bfa94332bc4d32d882d))


### Bug Fixes

* **caddy:** mount conf.d into caddy container so the override slot actually loads ([#314](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/314)) ([6f15fc4](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/6f15fc4fac3805c6a85cdc60f2613e7494711d22))

## [0.12.77](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/v0.12.76...v0.12.77) (2026-06-13)


### Bug Fixes

* quote defaults.conf path in upgrade.sh bash -c (SC2027) + align PR shellcheck gate to release ([#312](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/312)) ([508fe0c](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/508fe0c65d0dd4982fab58375071c2f598eaa20c))

## [0.12.76](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/v0.12.75...v0.12.76) (2026-06-13)


### Bug Fixes

* **caddy:** access logs + handle_errors fallback page + lb_retries ([#307](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/307)) ([1db5949](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/1db594992ce10063d0d6ba24e609ed4a6b24b385))
* **healthcheck:** correct hy2 container name to oxpulse-partner-hysteria2 ([#310](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/310)) ([f485602](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/f48560210e613ba4430fa0a253c0d0489f53e9de))
* **install:** hy2 ch3 profile activation — dedup append + drop --profile flag + persist .env ([#296](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/296)) ([20b5b86](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/20b5b861a1d0f94c29bf1c574651824c1bce4ef0))
* **refresh:** re-assert split-routing AllowedIPs after AWG param sync ([#309](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/309)) ([bca2d94](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/bca2d949b7c487dd14db77fdc183f3b1c66c0eb1))
* **upgrade:** render all 6 Caddyfile.tpl placeholders + provision xray.env ([#308](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/308)) ([64d76f9](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/64d76f903cd2590ef25c6f4c33ce4aaf18532509))

## [0.12.75](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/v0.12.74...v0.12.75) (2026-06-11)


### Bug Fixes

* **firewall:** open coturn ephemeral UDP range 49152-65535 ([#302](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/302)) ([4da21e1](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/4da21e178f65ee76d1344f2942344438a4d95de9))
* **health:** point ch4 coturn probe at public external-ip, not loopback ([#304](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/304)) ([d55410c](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/d55410c85b250a7c79239dfe06a204c21dfeb4e5))

## [0.12.74](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/v0.12.73...v0.12.74) (2026-05-31)


### Bug Fixes

* **coturn:** raise user-quota 4→16 — WebRTC relay-policy clients exhausted it ([297e5ec](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/297e5ec64a6a631b06ccee370a9afabc735144b1))
* **coturn:** raise user-quota 4→16 — WebRTC relay-policy clients exhausted it ([aef441c](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/aef441c1b84aad96c7177b58916be59f795bcb37))

## [0.12.73](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/v0.12.72...v0.12.73) (2026-05-29)


### Features

* **channels:** X-Installer-Version header + installer_version body + channels[].id permanent fix ([7f5f1a9](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/7f5f1a975b724d228c00ac0ca3a095000d740778))
* **channels:** X-Installer-Version header + installer_version body + channels[].id permanent fix ([d8d361a](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/d8d361a947773a52a462927b96cc7f6227809085))


### Bug Fixes

* **installer-version:** install VERSION file path + tighten test regex + drop probe_ch5 mapping ([c58733c](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/c58733c2ea3aa876115befde658f4d36537b8814))

## [0.12.72](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/v0.12.71...v0.12.72) (2026-05-28)


### Bug Fixes

* **healthcheck:** probe SFU /metrics on SFU_METRICS_BIND, not 127.0.0.1 (bug [#7](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/7)) ([#295](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/295)) ([be4a52b](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/be4a52b90eaef85ed48310f2098360847b529fd7))

## [0.12.71](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/v0.12.70...v0.12.71) (2026-05-28)


### Bug Fixes

* **install:** restore install-firewall.sh in checksums + fix release tag sed scope ([#5](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/5) [#6](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/6)) ([#294](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/294)) ([3b8836b](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/3b8836bb13a609625ae171235c201b34a119a012))
* **install:** warn on legacy TURNS_SUBDOMAIN + add migration script ([#292](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/292)) ([19cec02](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/19cec02aa1c88129ac21568ec80c47eaf9fddd9b))

## [0.12.70](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/v0.12.69...v0.12.70) (2026-05-28)


### Bug Fixes

* **sfu:** strip CIDR prefix from AWG IP before passing to SFU bind env ([#288](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/288)) ([783c2ab](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/783c2ab90770602d88412b8c44b78430e1203348))

## [0.12.69](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/v0.12.68...v0.12.69) (2026-05-28)


### Bug Fixes

* **compose:** SFU healthcheck probes mesh IP for metrics+relay-API (bug [#4](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/4)) ([#289](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/289)) ([627c1c8](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/627c1c807a30a60fe125e1d460b5403d49255b85))

## [0.12.68](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/v0.12.67...v0.12.68) (2026-05-28)


### Bug Fixes

* **checksums:** regenerate lib/lib-checksums.txt + CI guard against drift ([#286](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/286)) ([fd582d7](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/fd582d72d2b1c804f45b5948a1d91b55c220d2a2))

## [0.12.67](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/v0.12.66...v0.12.67) (2026-05-28)


### Features

* **refresh:** self-bootstrap hy2 channel when node-config provides hysteria2_server ([#284](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/284)) ([bb646f5](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/bb646f58819730c3a7a62b8304c20a8c781c9038))

## [0.12.66](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/v0.12.65...v0.12.66) (2026-05-28)


### Features

* **enable-hy2:** add oxpulse-partner-edge-enable-hy2 host-script ([#282](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/282)) ([6960ca2](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/6960ca2225651336ee883e9cd7d387549a2fd295))

## [0.12.65](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/v0.12.64...v0.12.65) (2026-05-28)


### Features

* **split-routing:** ship artifacts via release pipeline + upgrade.sh ([#280](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/280)) ([f55a0f2](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/f55a0f2b7e825715baeb61e8888c11f43ea03945))

## [0.12.64](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/v0.12.63...v0.12.64) (2026-05-27)


### Features

* **split-routing:** RU-subnet feed (RIPE/ipdeny) + daily timer + install wiring ([#278](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/278)) ([7c512c6](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/7c512c6f6544110a635e36d1a254b574952701ce))
* **split-routing:** selective cgroup split-routing apply/disable scripts (RU profile) ([#274](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/274)) ([842f267](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/842f267a2d8d4b8d20af0bf6ecc0da85c6dcd141))
* **split-routing:** wire into install.sh behind --profile=russia ([#279](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/279)) ([3dccaad](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/3dccaade91f9ff1427241381bb21ad19c4b907c7))


### Bug Fixes

* **split-routing:** address CL-2 code-quality review findings ([#276](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/276)) ([d7402bb](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/d7402bb9dcad28d970545fc42491207332f2b0e7))
* **split-routing:** bats 1.4-compat in test (CI runner has bats &lt;1.5) ([#277](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/277)) ([479169f](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/479169f3e84f2fc786c03a9c3647d65547752086))

## [0.12.63](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/v0.12.62...v0.12.63) (2026-05-27)


### Bug Fixes

* **caddy:** canary /canary/tunnel — rewrite to backend liveness path, drop illegal upstream path (502 since [#122](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/122)) ([#273](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/273)) ([afe18ff](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/afe18ff02bc5be18f3a49244a843960b49caec90))
* **upgrade:** settle-retry post-recreate healthcheck (was single sleep 10, racy vs ~8s xray settle) ([#271](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/271)) ([7ddb973](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/7ddb973a736b3b9fca431cbb5a270135bf5203a9))

## [0.12.62](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/v0.12.61...v0.12.62) (2026-05-27)


### Bug Fixes

* **upgrade:** honor --dry-run in image path + rewrite compose tag to target before pull ([#268](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/268)) ([58e01d5](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/58e01d5548abf788291bbed2a2f2bd594d58a6a7))

## [0.12.61](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/v0.12.60...v0.12.61) (2026-05-27)


### Features

* **sfu:** multi-hub relay failover (B0) ([#266](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/266)) ([836fa30](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/836fa30d139640dcda8aec57a69edead7e943201))

## [0.12.60](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/v0.12.59...v0.12.60) (2026-05-27)


### Features

* add vfm temporal-layer cap + dynacast emit_publisher_layer_hints ([a2187d2](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/a2187d2189e50b4c19fb6cd694605d2250053900))
* **awg-agent:** conf_merge inserts missing obfuscation params (self-heal I1-less + bootstrap-only confs) ([bad25f4](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/bad25f4582ceb94fff9702a8290b3c4472c78849))
* **awg-agent:** re-read service token per request (survive rotation without restart; fixes 401-after-rotate) ([ef6b1e9](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/ef6b1e9e7a336b894ff37a73b7d41a04dea6e5dc))
* **awg-params-agent:** T1.3.x — apply I1 (InitString) in kernel conf merge ([#241](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/241)) ([20b0f0f](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/20b0f0fb0d2b80ab3e4074869a96f86e5778ea1a))
* **bwe:** GoogCC v2 — trendline delay detector + AIMD controller ([a28ee1d](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/a28ee1d06f0fef3b215d6ae6969c539b81e9663a))
* **bwe:** integrate GoogCcEstimator into Registry — trendline+AIMD conservative merge alongside Pacer ([c80f9cb](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/c80f9cbf1d2bb345fc757476025f84402828ef9f))
* **caddy:** phase 1 — canary endpoints + structured JSON logs ([#122](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/122)) ([c1e0381](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/c1e038121176552dde6cd9e5a74fea7f57baf0e6))
* **caddy:** phase 2 — extract tunnel_upstream snippet + golden-file test ([#129](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/129)) ([d8b91fb](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/d8b91fb9abb21bec4d594e80bbb0da9b0d0bbade))
* **caddy:** phase 3 — conf.d/ override slot + install.sh --check ([#130](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/130)) ([6e8de6a](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/6e8de6aef41c43be8f817b93012d6c9388c07855))
* **channels:** CH3/CH5 config templates — Hysteria2 + NaiveProxy fallback channels ([1538ea0](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/1538ea00827ea3f12617096e30168e261ec67ca1))
* **channels:** edge-side channels-health reporter (M2.6a) ([#159](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/159)) ([6873794](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/6873794d5d22c810035e9cea05519e68ac69ba29))
* **channels:** forward-compat channels[] schema + CHANNELS.md ([7b447e0](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/7b447e0acc77b0c97fbae688493897ece590149e))
* **channels:** Phase 1.7 — integrate hy2 second channel into installer ([#134](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/134)) ([567b569](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/567b5690b72ca6c670d371b7bf3a04509bb7d41f))
* **ci:** gate installer bash tests on every PR ([c6c6878](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/c6c6878f20bda8008ceb9499c297a24d31351264))
* **ci:** gate installer bash tests on every PR ([50a9824](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/50a9824d7ebc2f5d5d217b451c886a3780d04794))
* **deploy,M4.A5:** Caddy /sfu/ws/* reverse_proxy → localhost:8920 ([1e2521f](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/1e2521f07881dd9a3e47592dbac27fa859646fe3))
* **edge:** T1.3.d — awg-params-agent crate (poll + apply + report) ([#239](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/239)) ([4a8f30b](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/4a8f30ba0b38d23ccc59eb932a9a4c8475b733d1))
* **health:** add ch4 coturn TURN-allocate probe to channels-health reporter ([#253](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/253)) ([7ee7c59](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/7ee7c5999e5054443e0623b5ddde0db256cae26b))
* **healthcheck:** add authed probe for /api/partner/hy2-credentials (check 19) ([#157](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/157)) ([e9403cb](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/e9403cba84e7bc0283ba98574b0ae3ed072dde96))
* initial import — partner-edge bundle + SFU crate ([5d0ec06](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/5d0ec06690eefdd403167cf0666d113141e3775f))
* **install:** --brand-* CLI shorthands for inline branding ([#29](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/29)) ([36ff498](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/36ff498fa26121eb07f308a058a5e452e655cb15))
* **install,upgrade:** GHCR auth via --ghcr-token + persistent token file ([#120](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/120)) ([bcffd3b](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/bcffd3b92d05fc61df4e8f1db6ac305bfdc8b445))
* **installer:** Caddyfile.tpl — www.&lt;partner_domain&gt; → non-www 301 redirect ([#242](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/242)) ([41ef3fe](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/41ef3fecac1fce546964ea3fdb1246c2a2124c0a))
* **installer:** hint SFU slow-start in healthcheck timeout warn ([4d14439](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/4d14439e221f5995adc761e02347ee833ff61c28))
* **installer:** hint SFU slow-start in healthcheck timeout warn ([99e5734](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/99e57341d4681df455b544d143d0727742e601b4))
* **installer:** mirror-aware binary fetch (OXPULSE_MIRROR_BASE) + GitHub fallback ([b551058](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/b55105845140e5b4ef2c5cdc715c4bc09f46b737))
* **installer:** mirror-aware binary fetch with GitHub fallback ([0c1d8c7](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/0c1d8c7f8fd97c62efd4f7aad29b608d34f72cb7))
* **installer:** partner-edge host firewall hardening ([#231](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/231)) ([42f9c8c](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/42f9c8c5725e455483d92451e11df74c0ccd83f9))
* **install:** M6 slice 2b — Reality keypair + UUID on install + register payload ([#115](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/115)) ([1d45b36](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/1d45b366cb3936ea329caf6492e54e10bcc5fd93))
* **install:** persist channels[] from registration response to node-config.json ([36de146](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/36de1465d10abebe54a61f77691f298ccc6335ab))
* **install:** persist service_token from register response with fail-loud strand mode (Follow-up [#2](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/2) PR-B) ([#152](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/152)) ([e36d949](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/e36d949267cd0cfbaa3146f5f1080374aa118e09))
* **install:** Phase 4.1 — extract preflight + deps into lib/ modules ([#153](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/153)) ([ed9978e](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/ed9978ec976616cc3af4bde82b79e5db73142181))
* **install:** Phase 4.10 — extract AWG kmod build/config to lib/install-awg.sh ([#172](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/172)) ([a9f9046](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/a9f904647a0d87f3bad3661a7e5f8b8ea725573a))
* **install:** Phase 4.2 — extract IP + region detect into lib/install-network.sh ([#154](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/154)) ([75e6695](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/75e66955f236f5d3e5dc778d4b1daa276ba36c57))
* **install:** Phase 4.4 — remove bash render fallback (opec now hard requirement) ([#164](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/164)) ([7f63d3a](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/7f63d3a53a22791556fd0a5c0319f141d3c2a132))
* **install:** Phase 4.4 — remove bash render fallback (opec now hard requirement) ([#165](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/165)) ([d6b17c0](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/d6b17c0776756b8b900450ef18c30e33e87dd0e8))
* **install:** Phase 4.6 — extract healthcheck (TURNS cert wait + poll) into lib/ ([#166](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/166)) ([9fcb170](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/9fcb170cfa80e08133e908fbe583054ab4b9d6cd))
* **install:** Phase 4.7 — extract systemd unit installation into lib/ ([#167](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/167)) ([a933ce4](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/a933ce4600b9722092c13703f96b27603aa88e6e))
* **install:** Phase 4.7-4.9 — systemd extract + retire fallbacks + args extract ([#169](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/169)) ([b8312fa](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/b8312faf875c2fd4f2cf5ccf3a3350e2a093069e))
* **install:** Phase 4.8 — retire bash fallbacks for opec secrets ([#168](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/168)) ([0dbda30](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/0dbda30707c0ded12452ed4f6f3e6578ebd587c2))
* **install:** provision RELAY_JWT_SECRET + Caddy relay route — enables cascade relay on new nodes ([66da82f](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/66da82f846efe2ce9baa05748732b0be38125313))
* **install:** T1.3.f — install awg-params-agent binary + systemd unit + env config ([#240](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/240)) ([b24042c](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/b24042c0bbeb0f1776730754c1b82507f06ffd7c))
* **install:** zero-touch AmneziaWG mesh + OTel onboarding ([#36](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/36)) ([1d7b7ec](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/1d7b7ec628e469064920254c418d9226f786f470))
* **opec:** --serve-countries installer flag + opec body field ([97bf117](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/97bf117523b66c628cba8b4730cfd0f1bef49698))
* **opec:** --serve-countries installer flag + opec register body field ([76ae8d6](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/76ae8d653e9ca0bfa95d68a280a20471228a163c))
* **opec:** phase 2 — render module + xray/coturn/naive subcommands + install.sh delegation ([#147](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/147)) ([4d6b9c8](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/4d6b9c8085d2ebdba211a9779004f95d761af392))
* **opec:** Phase 3 — absorb compose + caddy render into OPEC ([#151](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/151)) ([cf07e94](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/cf07e94b11aa8442487f4b0e8f7e493d4ec9964b))
* **opec:** phase 4.0 — tenant yaml schema + validator + read-only CLI ([#131](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/131)) ([dc95d49](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/dc95d497a3e0a7f7f505f96451f6c866ed012e43))
* **opec:** phase 4.1 — Caddy JSON renderer + tenant reconcile --dry-run ([#132](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/132)) ([7dbd3c4](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/7dbd3c4a089099f70c0ab0fccbd9ea34624f128c))
* **opec:** Phase 4.3a — opec secrets reality-keygen + env-gated install.sh delegation ([#155](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/155)) ([c252743](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/c2527438464afed93e98d8ddfcce90e38ac24de0))
* **opec:** Phase 4.3b — opec secrets awg-keygen + env-gated install.sh delegation ([#156](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/156)) ([8151c13](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/8151c13912929436d59a2d597684cbe24713f3a0))
* **opec:** Phase 4.3c — opec secrets register (HTTP POST + env-file) ([#161](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/161)) ([e830314](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/e830314585557dfb53aee6d9c81b7c97c9186561))
* **opec:** Phase 4.3d — opec secrets sfu-signing-key ([#163](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/163)) ([082b9b4](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/082b9b42b240968718b98dce3e40f8b9f910cc54))
* **opec:** Phase 5.1 — native x25519 keygen for reality (retire partner-cli shell-out) ([#174](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/174)) ([9e8d36e](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/9e8d36e569fd1e7ac33cea3f5ce658ef837aea9a))
* **opec:** Phase 5.2 — native AWG/WireGuard keygen (retire wg-tools shell-out) ([#176](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/176)) ([a88ec05](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/a88ec05df633ff082a4240c5698d59a0ec444d3a))
* **opec:** Phase 5.3 — retire legacy keygen shell-outs ([#177](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/177)) ([5aad217](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/5aad217fcfaf99dc62ee616f38f76afc90a94778))
* oxpulse-sfu-kit migration + cascade relay client (Phase 1) ([1c6131a](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/1c6131a13c95f47548eac289506f5a06ef6f4a80))
* oxpulse-sfu-kit migration + cascade relay client (Phase 1) ([1c6131a](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/1c6131a13c95f47548eac289506f5a06ef6f4a80))
* **partner-edge:** Caddy maxmind_geolocation defence-in-depth (M2b.2) ([20361cb](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/20361cb101d23e7540f7df578eed6d4e567990c4))
* peer_audio_scores Prometheus gauges + current_top_k DC broadcast + AudioCodecHint ([73ee65a](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/73ee65a6788b5e831943f014326f230c5a1ca24e))
* Phase 5.5 — resilient multi-channel install with per-channel fail-soft ([#186](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/186)) ([808a993](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/808a99311d48b857b7412be82b37e119f41ab3c1))
* Phase 5.6 — healthcheck fixes + Phase 5.5 deferred bugs ([#189](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/189)) ([fcc7d38](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/fcc7d38ebbb767354cd647d45a23b3e0caf7e71e))
* Phase 5.7 — installer hardening (uninstall + AWG fail-soft + integrity + surgical refresh) ([#190](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/190)) ([b5dd2c8](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/b5dd2c8fd76b3529329faf7dc66bcb8aefa47016))
* production-ready installer — Phase 5.8 observability + Phase 5.10 naive (v0.12.43) ([#199](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/199)) ([27bcfef](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/27bcfef7578210776427710ac801690d221907ad))
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
* **release:** publish install.sh as one-command installer asset ([#141](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/141)) ([b45e5c3](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/b45e5c3418aa72de540569aa8e40962e0d68996f))
* **release:** ship opec binary as release asset ([#148](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/148)) ([cd641a4](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/cd641a4542d049fed5836aa39eebdd5880b33bd6))
* **release:** ship partner-cli prebuilt binaries as release assets ([#145](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/145)) ([564ff75](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/564ff7501a2c6d249dc3f1f6b0d00dcc255b97c6))
* **scripts:** idempotent update.sh + packet-up template ([#113](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/113)) ([e4661ea](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/e4661ea3562aeaf04de72da44f0a759742866578))
* **security/P2:** FIPS 140-3 + Ed25519 asymmetric JWT — eliminate shared secrets ([#3](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/3)) ([e95706f](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/e95706facf06059e82ed960092e6374f1899cb81))
* **security:** cargo-deny + nextest for supply-chain hygiene ([#109](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/109)) ([acb71b0](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/acb71b0ed0bc94becf443930d88808436aee9e29))
* **sfu,M4.A1:** client-facing /sfu/ws/{room_id} WebSocket endpoint with room_token auth ([855c33a](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/855c33a8cf3b89a08155554c5fcd86623e3c4355))
* **sfu,M4.A2:** browser-client SDP exchange + Registry registration ([9805082](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/98050827b103b9932d1bae8b26533c0e837fea6c))
* **sfu,M4.A3:** integration tests for browser-to-browser media + simulcast layer selection ([267e529](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/267e5294c0b4ed99543ea70a3d162ec536404a7b))
* **sfu,M4.A4:** integration test for active speaker — wire format + skip-self + cross-client isolation via test-utils seam ([9aaa9f2](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/9aaa9f2db599319e246cf099be7a786e1e4de283))
* **sfu,M4.A5:** SFU_CLIENT_WS_PORT default 8911 → 8920 (8911 squat on hub) ([a404758](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/a4047583afa7c8d9afe2f8e8f916911ebe964b88))
* **sfu,M4.B1:** client_ws verification metrics + bump VERSION 0.12.1 -&gt; 0.12.2 ([e61baf3](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/e61baf3dde2172596807c3a1bc41fc35dc79f6b1))
* **sfu/A1:** peer_id-keyed session steal — close 4031 on duplicate /sfu/ws upgrade ([1b50ac5](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/1b50ac58938093f58fb9cb40242fe42f5238393d))
* **sfu/metrics:** observability follow-ups — sub-second buckets + per-peer media gauge + Phase 2 reserve annotations ([#22](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/22)) ([7b521fb](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/7b521fb0368971c14f29c6525d8af38d5bbc7a41))
* **sfu:** adopt str0m built-in stats API for RTT/loss/jitter observability ([#87](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/87)) ([5ebe30a](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/5ebe30a0a52dddbbaf7460373e3644e49a2e9d44))
* **sfu:** auto-kick solo peer after configurable hold timeout ([#96](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/96)) ([01d90ae](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/01d90aedbd5db02a996144d4dc0f4a48605900e4))
* **sfu:** chat-data + chat-ctrl DC routing through SFU (Phase 2b) ([#40](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/40)) ([484bb43](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/484bb43e4b0d61983f0230cacbf23366f0d1c422))
* **sfu:** deep forwarding-path observability — 4 new counter families ([#67](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/67)) ([cf34d58](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/cf34d58c8d359d7587419c703d4fb7c0dd0a6784))
* **sfu:** inject a=msid in answer SDP for browser stream attachment ([#60](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/60)) ([75fa812](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/75fa81216ca8b47d78416845c846769aa3015d39))
* **sfu:** M2 SDP renegotiation — complete group call media delivery ([#70](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/70)) ([2d412b0](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/2d412b0bc0b61d6596ac1763048b4ab3b3744e73))
* **sfu:** mid-based tracks_map_update emission for Bug [#5](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/5) ([#93](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/93)) ([8093e6a](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/8093e6a213cf4d5ffe03919d9ece398fb9109ba3))
* **sfu:** OFFER_TIMEOUT 30s + parse_err sub-labels + ice_state counter ([#56](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/56)) ([a2df998](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/a2df9981489de971312226e374dbb245947f46f2))
* **sfu:** open reactions-group DC id=7 (hearts fix) ([#101](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/101)) ([a546970](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/a546970c3f3a380548bffbd304963b97e009359e))
* **sfu:** OpenTelemetry / Jaeger trace pipeline (opt-in) ([#35](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/35)) ([9cbe75e](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/9cbe75ec25b777aa2a2d986e7d358b733804083d))
* **sfu:** peer_id-keyed session steal with WS close 4031 ([ca18972](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/ca18972a4a64f240180fbd809cfa05f95f94484b))
* **sfu:** peer-suspended bridge via sfu-events DC id:8 (Phase 2c) ([#119](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/119)) ([763aaaa](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/763aaaa265cebfa919f44f5d7eb33b59b1a2e4be))
* **sfu:** Phase B — migrate pacer to oxpulse-sfu-kit v0.11 per-subscriber ([#116](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/116)) ([a644059](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/a644059ac67c818ad871f381109c33a0be430494))
* **sfu:** Phase C sfu_sdp_msid_injected_total counter (A1 regression guard) ([#63](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/63)) ([bb934e3](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/bb934e3e1447d69150b4bdd38a3d2220b13835e7))
* **sfu:** Phase F2 — tracks_map WS backchannel for signaling-first stream binding ([#65](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/65)) ([91f75f6](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/91f75f672b1536395bd4a14e7cc03f33e5bf55a5))
* **sfu:** SFU-native dominant speaker via DC id:3 ([f54aa85](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/f54aa859b28ea7a9be9b7a35eeed66dadf491c85))
* **sfu:** split bind address per socket (metrics + relay-API + WS) ([#232](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/232)) ([0b9d1af](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/0b9d1afc108186b3ed1b6ca4c4e6d078379e46fa))
* **sfu:** trust AWG mesh subnet for ws:// relay upstream (siege transport) ([#255](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/255)) ([0d579c5](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/0d579c5a91024b01289e0b19280702b7e72468fd))
* **shell:** phase 1 — render dedupe across install/hydrate/update ([#139](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/139)) ([e09693d](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/e09693d37412632264531e43492e9e9ac7f15f3d))
* **sni:** daily SNI rotation from server-provided pool ([a7e4d3e](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/a7e4d3ec45a52d6e4017ed9aa319df61e5710c18))
* **telemetry:** add service.instance.id / partner.id resource attrs for per-edge Jaeger filtering ([#74](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/74)) ([81cfb53](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/81cfb5321dda754bae827aa2cf5927b5cbf7b457))
* **upgrade:** --dry-run surfaces concrete conflicts before apply ([#125](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/125)) ([c80c8fc](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/c80c8fcbeaf8ca47c6397d83997505e8b4507c6b))
* **upgrade:** --with-templates for atomic Caddyfile+healthcheck+image lockstep ([#124](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/124)) ([c45d805](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/c45d805e3f3d11cf542ba2bbf1e3b4665fc291f2))
* **upgrade:** re-render xray config from upstream template on upgrade ([16d603e](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/16d603ee29fda8b20e4019eb4bb8d374dcfd7f0c))
* **upgrade:** sync host-scripts (health-report, units, lib) on upgrade, not just images ([#257](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/257)) ([867285c](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/867285cbf1800204d73237540628f0da679fe4b6))
* **xray-update:** env-overridable CONTAINER and IMAGE for relay-x reuse ([#85](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/85)) ([4b5e646](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/4b5e6467cad2d52f2f406e14e42e00aec69f88c4))
* **xray:** enable XTLS Vision flow + stream-one mode + padding ([ac8295a](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/ac8295afadd764a505416113315670c0ab56c92a))
* **xray:** pin xray-core to v26.5.3 + weekly auto-update timer ([#80](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/80)) ([1bd7656](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/1bd7656a01842eb3d3b835463ca978c2732a76b4))


### Bug Fixes

* Fix:  ([5f311b3](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/5f311b35943f4ae2d3482abb8bba2fdf2aaeea29))
* add step [5b/6] gated on --purge-packages (default off). ([0fd0185](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/0fd01859fa2fcc3b026bab540cf8dfba32e7b0f6))
* **awg-params-agent:** strip node_id from POST applied body — surfaced by T1.3.h canary 2026-05-23 ([ea1b2b6](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/ea1b2b660a20fa77fe461b7ad73a855b8653b4f0))
* **caddy:** remove unrecognized maxmind_geolocation global option ([#128](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/128)) ([cdcfe3c](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/cdcfe3c0e23ce579c326b680286fa2bcce675841))
* **caddy:** swap deleted aksdb/caddy-maxmind-geolocation to porech fork ([223bef0](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/223bef0a91e115b3e2ec1e2832f8037666ae91c1))
* **caddy:** upstream → xray-client:3080 (HTTPS 503 root cause across all partner edges) ([#187](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/187)) ([b88f44a](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/b88f44a39891666af8f04f77b4fe2cbdc63dfd78))
* **channel-render:** split local+assign to silence SC2155 (release lint gate) ([#137](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/137)) ([7caa72c](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/7caa72c2b3571680ca3dbe4a30d7e08d6355471a))
* **ci:** add shellcheck source=/dev/null directive — unblock release CI ([a6ffcd6](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/a6ffcd629718a74396af248be0f7ebea799f6ae7))
* **ci:** address code-quality findings on installer-bash-tests job ([04551ca](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/04551ca76164ae15a9cf3b1043dea50f5d6470e9))
* **ci:** cargo fmt + VERSION=0.11.1 — unblock release build ([f106d12](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/f106d1251d205f4950466cf238bdd3614293b948))
* **ci:** rewire workflow paths for flat repo layout ([215d304](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/215d30461ab3ff2cc66fe3b2284425298eeeac2f))
* **ci:** skip 2 stale tests (compose_strip + production_readiness) ([a53e5d7](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/a53e5d7e12b86a94743ee79437fa3f871b88f8a3))
* **ci:** skip 4 stale bats files with pre-existing drift ([9cd2c42](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/9cd2c42cf7375bc9b9ad8c6adf51c99cf5085bda))
* **ci:** valid JSON in .release-please-manifest.json ([81d9e3c](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/81d9e3c90f689f667e2ee109099a344389fac7f5))
* **ci:** valid JSON in release-please-config.json ([6565476](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/65654764cfa2471ca561b0e52939f09d0797b806))
* **compose:** publish canary port 9080 on host loopback ([#123](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/123)) ([a52771a](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/a52771a57ea27b1fe4637f2241ee056c66c79459))
* **deploy,M4.A6:** render SFU_PUBLIC_IP into docker-compose from $PUBLIC_IP ([5b280e5](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/5b280e5bf635519f23de417cb117f90e7d4d1306))
* **gitignore:** match target as file/symlink, not just directory ([#117](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/117)) ([31cfb87](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/31cfb87393c70826b81d7a4e92a7d4cb5b3a29c2))
* **install_amneziawg:** install Go 1.24 (system golang too old) ([#149](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/149)) ([24866d5](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/24866d55561dc21afcdfc08475037641ab188042))
* **install:** bug 3+4 from live edge install on ru.oxpulse.chat ([#184](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/184)) ([054f919](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/054f9192dfb1f62283303d8c97e89de7f92e244f))
* **install:** canonical metrics port + edge_id + spin-trap warn ([#33](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/33)) ([ab38b92](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/ab38b928f6ce2a9920797c58fd8c77444d8cc8b0))
* **install:** die early when backend returns empty reality_encryption ([#28](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/28)) ([3580a3f](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/3580a3f382b7a38218e30020ef631e77445ea966))
* **installer:** Bug 24 NAIVE_* env clobber + test robustness + v0.12.46 ([#206](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/206)) ([8e7cc3d](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/8e7cc3d1797e92c4f4f6e88950490a2ae3d9748d))
* **installer:** Bug E mkdir before reality-keygen + Bug C+D uninstall hardening ([2b9a963](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/2b9a9631d616bbc1623a9c8c7b93c9d1cf2bb4f9))
* **installer:** Bug M + Bug O — fetch render-channel-lib on curl|bash flow, gate naive via compose profiles ([4469943](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/446994317e91ca1f23cfd0476f201a3281d3677f))
* **installer:** Bug M + Bug O — fetch render-channel-lib on curl|bash flow, gate naive via compose profiles ([d92a906](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/d92a90697b4d0225c9d409fb530e47d6a72055c5))
* **installer:** channel-health reporter → api.oxpulse.chat (RCA 2026-05-26 heartbeat outage) ([8ae7866](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/8ae78663c3f8b8a6d91ae68a9347bd4b63e112a1))
* **installer:** channel-health reporter must target api.oxpulse.chat, not oxpulse.chat ([516f138](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/516f138b8b901e72143fceef7005233c6429d748))
* **installer:** close OPEC handoff regression — full backend response passthrough via --out-json ([31619b2](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/31619b2b428fbe7a2207e0e56ec64e82e36b47bc))
* **installer:** close OPEC handoff regression — full backend response passthrough via --out-json ([634874f](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/634874f368f4db400cdc130f4aee3f1a2a96a0a9))
* **installer:** contain die-class top-up failure in subshell ([dc447db](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/dc447dbb5bda65cf3bc84e8db896cbd9c5b40cab))
* **installer:** contain die-class top-up failure in subshell ([4cd9ca2](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/4cd9ca2b27cc9601d34a4420feccb0b64502c108))
* **installer:** correct hysteria2 image path, drop unbuildable naive client ([#135](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/135)) ([cfc821d](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/cfc821d8208259d410c73d6db3e2a29323246b8d))
* **installer:** create PREFIX_ETC before opec reality-keygen (Fix E) ([0e5f679](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/0e5f679533a2c4866d9971cf7ff68d05e5fe4d6b))
* **installer:** die on empty signaling_sfu_secret response ([#49](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/49)) ([c8047e0](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/c8047e078eee5601c5bb739793781070d9564ffe))
* **installer:** pin IMAGE_VERSION from VERSION file, not floating 'latest' ([#237](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/237)) ([37ccb73](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/37ccb7377e65595862fbf3850fc884d45e2971fb))
* **installer:** prod debts from 2026-05-20 fleet outage ([#225](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/225)) ([192840e](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/192840e864d4b9ae7ebc293d0ee712799ee8a926))
* **installer:** render() handles multi-line values (SFU_SIGNING_PUBLIC_KEY PEM) ([#136](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/136)) ([a4c62ac](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/a4c62acc7682173bc8794c64e12ab66e388402af))
* **installer:** three fresh-reinstall hardening fixes (Q, R, 8/10) ([#221](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/221)) ([c33411e](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/c33411e4704d2f8fb80b86ca28c52e17867f5d40))
* **installer:** top up awg-params-agent on re-run of an existing install (idempotent; was skipped before exit 0) ([b78f441](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/b78f44124429d782acd250f5cf4df33f6b7a3b5d))
* **install:** fetch channel-render-lib.sh in source block, not just Step 8 ([#142](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/142)) ([7673b80](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/7673b805bea9135cbbd8efc2c62c10d5c26a6787))
* **install:** hy2 template path mismatch — channel-render-lib couldnt find it ([#143](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/143)) ([0ee890f](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/0ee890fa434b679bd33ad4854c9fe42062d3477f))
* **install:** keygen idempotency guard — preserve existing identity on re-run ([#118](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/118)) ([f99890f](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/f99890f5947dff92e5db7a4c48d561b1fa3e5ed0))
* **install:** replace backticks with single quotes in --help (SC2215) ([#31](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/31)) ([a3b8df9](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/a3b8df9c0ab72fc3374c7a325f1122d80acd74b4))
* **install:** RETURN-trap unbound var + ship install-awg.sh in release ([#181](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/181)) ([ca0f4a7](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/ca0f4a7127a39d535d4675d14d821aa3a7c947bb))
* **install:** silence cross-file SC2034 from _install_lib_source indirection ([#179](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/179)) ([b8bf7f5](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/b8bf7f533db3c2372b9a959e8cf10e92f0c18c98))
* **install:** unblock fresh CentOS provisioning + 8 robustness fixes ([#27](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/27)) ([563c7e6](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/563c7e65b8a7f5847c4e9f8459dd08479e2515fd))
* **install:** validate AWG_* vars are non-empty after awg_extract ([#227](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/227)) ([555260f](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/555260f5e9244409345ac8d187be9a238da25a95))
* **integrity:** refresh lib-checksums.txt drift (render-channel-lib + install-healthcheck) ([5a25cb4](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/5a25cb46b257329e8f3e4ac1787add7beb610d1a))
* **integrity:** refresh lib-checksums.txt for render-channel-lib + install-healthcheck ([0b2b8b3](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/0b2b8b3f6352c448b6f63254075ceb162b73a867))
* **metrics:** chat_relay_active_channels gauge .dec() on disconnect ([#53](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/53)) ([eed61b9](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/eed61b9dcdda058dd40a068513364eb80186db4f))
* **naive:** address PR [#214](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/214) MAJORs + MINORs — extended fixture guard + hy2 perms ([56fa6fa](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/56fa6fa94143aa02345ad247972a04991e842956))
* **naive:** Dockerfile tar extraction (Bug 23) + v0.12.44 ([#202](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/202)) ([cee8ce3](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/cee8ce34b8af926b96392d50324d0098453a0755))
* **naive:** drop --version smoke в alpine fetcher + bump v0.12.45 (Bug 23 v2) ([#204](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/204)) ([0c2efb2](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/0c2efb23daaf94240301cc4d3c20344301e58bef))
* **naive:** perms 0640+gid-65532, fixture-host guard, granular channel status ([8075fcf](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/8075fcfe34645a259c116eb344fccb4998dbfa13))
* **naive:** perms 0640+gid-65532, fixture-host guard, granular channel status ([d649df6](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/d649df6f33e79c997f371cccdbf113e3cb61fcba))
* **opec:** accept missing relay_jwt_secret in register response ([8b2f647](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/8b2f6472f58b52e06e9c6d936433520ceda5a271))
* **opec:** accept missing relay_jwt_secret in register response ([4966323](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/4966323ca8f7879439a457b0a4d890c783d9aeab))
* **opec:** fix-loop on PR [#215](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/215) — BLOCKER + 3 MAJORs ([7d2d8df](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/7d2d8df6b7d71d091bc50173bfa1847c0ac0ddc9))
* **opec:** normalize empty relay_jwt_secret + warn when absent ([490f84f](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/490f84fcf1aa19a3477cbb93cbf6798dff700e7a))
* **opec:** release serde_norway migration (RUSTSEC-2025-0068) ([9b2b109](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/9b2b1091f799d7b9cedd9455d02b413b900f7632))
* **refresh:** decouple heartbeat from keys fetch — fixes PartnerEdgeStaleHeartbeat alert ([#112](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/112)) ([1728504](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/1728504e9ebc8e4e365bf8d02f84394808f88244))
* **refresh:** die early when jq missing so heartbeat is never silently skipped ([#73](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/73)) ([47cf0a8](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/47cf0a8450a88a4d21de41f213792296ec65de3c))
* **refresh:** OS-aware dep error messages + add jq to install.sh deps ([#77](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/77)) ([3ef9d56](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/3ef9d568d0fcd41d8242b9fa6d50537a02f2ba11))
* **refresh:** skip systemctl reload when unit absent on custom-stack nodes ([#84](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/84)) ([d77478e](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/d77478e96a916bc7ce9882bce0ff554d6715634b))
* **relay:** allow apex oxpulse.chat in is_allowed_upstream — cascade relay upstream_url uses apex domain not subdomain ([e76d8ac](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/e76d8ac9bff1ab7fec091c6b6a84d4a359476f28))
* **relay:** fallback to HS256 when EdDSA verification fails — allows signaling server (HS256 signer) to trigger cascade relay even when edge has EdDSA pubkey ([67e78c0](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/67e78c0997ad811e18e06c876ed8efaa9aa53b49))
* **relay:** make RELAY_JWT_SECRET optional — SFU standalone mode when unset ([a434da9](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/a434da9cf2c90639cb2dd5a92f5bb258514ee0a4))
* **release-please:** add version marker so VERSION auto-bumps + unblock v0.12.5 build ([#25](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/25)) ([7842d27](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/7842d278137795c72c3e4a19d24e46d0edbbc1d3))
* **release-please:** sync manifest to 0.11.9 (was stuck at 0.8.0) ([c109005](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/c1090051821c39fb4e0bc0a689fc381513e652c5))
* **release:** add naive to promote-stable workflow ([#205](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/205)) ([2110d9a](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/2110d9a7e13e821f224f85aa3619bc2e68e065fb))
* **release:** drop redundant partner-edge- tag prefix — one tag form (vX.Y.Z) ([#263](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/263)) ([6078f52](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/6078f5238aaa008652d2050133667d1222605099))
* **release:** drop self-cp of root-level host-scripts in Stage artifacts ([#259](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/259)) ([21709ec](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/21709ec13526c635781ac01de0cabbc16a65251d))
* **release:** remove same-file cp uninstall.sh that broke v0.12.41 build ([#196](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/196)) ([8c7e591](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/8c7e591dcd004dd0d435cbcf32f238f497c6eb50))
* **release:** remove same-file cp uninstall.sh that broke v0.12.41 build ([#197](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/197)) ([0bb0cd1](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/0bb0cd1105fe53650c5f6e530ce748c30cde88db))
* **release:** VERSION=0.11.3 — align with release tag ([d154260](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/d154260e44d73194967e83c35fa6e97df48f0ef3))
* **security:** CRITICAL SSRF + default-secret + panic — use JWT fields, require RELAY_JWT_SECRET ([44a6d5b](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/44a6d5b297b66365b7cf7fdb5a38bb7f2c12e80d))
* **security:** HIGH relay JWT replay protection (jti store) + MEDIUM clock skew check ([269d73e](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/269d73e80aac8d2536566b51d960865c52b990d7))
* **security:** MEDIUM-1 migrate relay JWT to jsonwebtoken (RFC 7519) + MEDIUM-2 upstream host allow-list in relay client ([9a8a10f](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/9a8a10f4043c227a97f8cd7ea14c32c0107f348d))
* **security:** MEDIUM-3 relay JWT iat forward-date check + test ([25f5875](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/25f58754593313b06660e9493a9c1be3a50e0637))
* **security:** tighten relay upstream allow-list + EdDSA fallback ([356289f](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/356289fb3183db62abb78d6da589d2b6edeee01d))
* **sfu,M4.A2-followup:** inject PendingClient before WS answer to avoid 'no client accepts' window ([3b39803](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/3b39803cedcd6b489da17099698c72445dde4d2c))
* **sfu,M4.A6:** public-IP host candidate — SFU_PUBLIC_IP env override ([32ff6c6](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/32ff6c65885841d15fd4828cd8698735a9059c94))
* **sfu/client_ws:** accept `bearer.<token>` subprotocol (no-space form) ([87f2388](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/87f2388ae6b5bb21fd4ee0c16136d06107f1f44d))
* **sfu/client_ws:** accept bearer.&lt;token&gt; subprotocol (no-space form) ([146c5f7](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/146c5f79e9067042f051e38da9ec548898bee1fa))
* **sfu/config:** serialize env-mutating tests — unbreak flaky CI ([#24](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/24)) ([51615fa](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/51615fa1fbd88e043b1e70eb228af7e19de2495c))
* **sfu/pacer:** F6-9 SUSPEND_STREAK parity + bump oxpulse-sfu-kit 0.7→0.8 ([#44](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/44)) ([8fa2960](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/8fa2960b80377af22c3b3aba4d757cad1f8f9c54))
* **sfu/pacer:** F7-5 symmetric exit hysteresis ([#45](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/45)) ([ce4a3fd](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/ce4a3fdbdb1cc14268fd71fe57e2ef3080c91d86))
* **sfu/registry:** F2b-2 reap chat_relay label series on disconnect ([#46](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/46)) ([e30d41c](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/e30d41c018cfc8fb1701ffd85abdbf67b9dbd71d))
* **sfu/renegotiation:** address code-quality reviewer findings 1-4 ([#88](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/88) follow-ups) ([#91](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/91)) ([1297131](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/1297131fe4d200d0d52b147205858464ca6889c9))
* **sfu:** Bug [#7](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/7) — timeout+ws_closed paths leave stuck Negotiating tracks and drop queued offers ([#95](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/95)) ([c45b704](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/c45b7045cf1ce7e8906fef777ff183c16b3b4021))
* **sfu:** drop bogon ICE destinations before send_to (mobile reliability) ([#104](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/104)) ([ce69639](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/ce69639b9052d1fea8aad4bf3fa7af2311a5a679))
* **sfu:** eliminate udp_loop spin on closed inject channels ([#30](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/30)) ([fe193b5](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/fe193b50daa117ba72a11aad922a4d85141b9194))
* **sfu:** observability bundle — gauge fix + degraded-state visibility + healthcheck ([#48](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/48)) ([54130e1](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/54130e1d65a0eba3f2ab827102d3b7ae18f61c01))
* **sfu:** pass real candidate_addr to handle_incoming — STUN destination match ([#58](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/58)) ([842f07a](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/842f07a7aff18fd476ec319349d4c66dccfc7a5d))
* **sfu:** PR [#93](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/93) followups — tracks_map_update silent drop, peer_id type, relay debug ([#94](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/94)) ([278ef3b](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/278ef3b87f1fef5c74291f251bf13026c5d167ef))
* **sfu:** rate-limit udp send_to failed warns + udp_send_failed_total ([#12](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/12)) ([9e6e3ce](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/9e6e3ceb9cc001637f46902ab75a48f05d364c13))
* **sfu:** relay DC id:1 sframe-keys cross-peer — KX never propagated ([#106](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/106)) ([a7cbd15](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/a7cbd156d938c9d86ba136efc6ccbb392a4eee04))
* **sfu:** str0m findings — correct SdpPendingOffer comment + write error metric ([#89](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/89)) ([2a2d981](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/2a2d9811cb8bba3da826fd2ad34334f04fbfcf81))
* **sfu:** transition TrackOut Negotiating→Open in accept_renegotiation_answer ([#88](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/88)) ([1e4d265](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/1e4d2656b227712de668ac9171328e39ca518f61))
* **systemd:** refresh.service Wants= instead of Requires= oxpulse-partner-edge ([#234](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/234)) ([cfeaf3c](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/cfeaf3c317f49f7998f45bc232906ce1aca04d83))
* **systemd:** sni-rotate + xray-update Wants= instead of Requires= ([#236](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/236)) ([007a4cf](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/007a4cfca259c2027a11b696d6713010d4fdc27b))
* **uninstall:** BLOCKER+4 MAJORs from PR [#212](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/212) reviewer ([574b71f](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/574b71f8abd00adf69a9e58b5faab7e7a76b82b1))
* **uninstall:** remove amneziawg build artifacts with --purge-packages (Fix D) ([0fd0185](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/0fd01859fa2fcc3b026bab540cf8dfba32e7b0f6))
* **uninstall:** remove docker named volumes on uninstall (Fix C) ([5f311b3](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/5f311b35943f4ae2d3482abb8bba2fdf2aaeea29))
* **upgrade:** correct image name sed pattern in upgrade.sh ([e076e0e](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/e076e0e9b361f0ac1a3f6e31d2e298afabab5692))
* **upgrade:** init OXPULSE_MIRROR_BASE default + digest-skip recreate + --host-scripts-only mode ([#261](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/261)) ([be6d11e](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/be6d11e2b40c5d8466c6c4d04e89176ae3672481))
* **upgrade:** raise post-up sleep to 10s to survive xray Reality tunnel startup ([#81](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/81)) ([1fe251a](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/1fe251ac4dbffb6e176ff8f18c39766cf3cb3987))
* **upgrade:** reviewer findings — cover_dir, atomic install, flock, rollback pull, healthcheck disambig ([#126](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/126)) ([92f7f5a](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/92f7f5a76c46c2986e568e60cde8b9fe191cb235))
* **xray:** downgrade xray-core pin 26.5.3 → 26.4.25 ([#83](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/83)) ([0bcbc6b](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/0bcbc6bb43fa2ed95784e59e0054168abb549875))
* **xray:** pin teddysun/xray to 26.5.9 (replace :latest) ([#223](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/223)) ([2b5cf95](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/2b5cf954441c9456361110a89ad78d4329bf66af))
* **xray:** remove flow=xtls-rprx-vision from CH1 xhttp outbound template ([#86](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/86)) ([df83840](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/df8384011a806805dda31306f97aec1e3208cde1))
* **xray:** switch uTLS fingerprint from chrome to randomized ([#79](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/79)) ([3599f0f](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/3599f0fac6f5d834abd72e2ef9e19b290ec39e74))

## [0.12.59](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/partner-edge-v0.12.58...partner-edge-v0.12.59) (2026-05-27)


### Bug Fixes

* **release:** drop self-cp of root-level host-scripts in Stage artifacts ([#259](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/259)) ([21709ec](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/21709ec13526c635781ac01de0cabbc16a65251d))
* **upgrade:** init OXPULSE_MIRROR_BASE default + digest-skip recreate + --host-scripts-only mode ([#261](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/261)) ([be6d11e](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/be6d11e2b40c5d8466c6c4d04e89176ae3672481))

## [0.12.58](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/partner-edge-v0.12.57...partner-edge-v0.12.58) (2026-05-27)


### Features

* **upgrade:** sync host-scripts (health-report, units, lib) on upgrade, not just images ([#257](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/257)) ([867285c](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/867285cbf1800204d73237540628f0da679fe4b6))

## [0.12.57](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/partner-edge-v0.12.56...partner-edge-v0.12.57) (2026-05-27)


### Features

* **sfu:** trust AWG mesh subnet for ws:// relay upstream (siege transport) ([#255](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/255)) ([0d579c5](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/0d579c5a91024b01289e0b19280702b7e72468fd))

## [0.12.56](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/partner-edge-v0.12.55...partner-edge-v0.12.56) (2026-05-26)


### Features

* **health:** add ch4 coturn TURN-allocate probe to channels-health reporter ([#253](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/253)) ([7ee7c59](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/7ee7c5999e5054443e0623b5ddde0db256cae26b))


### Bug Fixes

* **installer:** channel-health reporter → api.oxpulse.chat (RCA 2026-05-26 heartbeat outage) ([8ae7866](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/8ae78663c3f8b8a6d91ae68a9347bd4b63e112a1))
* **installer:** channel-health reporter must target api.oxpulse.chat, not oxpulse.chat ([516f138](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/516f138b8b901e72143fceef7005233c6429d748))

## [0.12.55](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/partner-edge-v0.12.54...partner-edge-v0.12.55) (2026-05-26)


### Bug Fixes

* **installer:** contain die-class top-up failure in subshell ([dc447db](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/dc447dbb5bda65cf3bc84e8db896cbd9c5b40cab))
* **installer:** contain die-class top-up failure in subshell ([4cd9ca2](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/4cd9ca2b27cc9601d34a4420feccb0b64502c108))
* **opec:** release serde_norway migration (RUSTSEC-2025-0068) ([9b2b109](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/9b2b1091f799d7b9cedd9455d02b413b900f7632))

## [0.12.54](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/partner-edge-v0.12.53...partner-edge-v0.12.54) (2026-05-25)


### Features

* **awg-agent:** conf_merge inserts missing obfuscation params (self-heal I1-less + bootstrap-only confs) ([bad25f4](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/bad25f4582ceb94fff9702a8290b3c4472c78849))
* **awg-agent:** re-read service token per request (survive rotation without restart; fixes 401-after-rotate) ([ef6b1e9](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/ef6b1e9e7a336b894ff37a73b7d41a04dea6e5dc))


### Bug Fixes

* **awg-params-agent:** strip node_id from POST applied body — surfaced by T1.3.h canary 2026-05-23 ([ea1b2b6](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/ea1b2b660a20fa77fe461b7ad73a855b8653b4f0))

## [0.12.53](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/partner-edge-v0.12.52...partner-edge-v0.12.53) (2026-05-25)


### Features

* **awg-params-agent:** T1.3.x — apply I1 (InitString) in kernel conf merge ([#241](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/241)) ([20b0f0f](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/20b0f0fb0d2b80ab3e4074869a96f86e5778ea1a))
* **edge:** T1.3.d — awg-params-agent crate (poll + apply + report) ([#239](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/239)) ([4a8f30b](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/4a8f30ba0b38d23ccc59eb932a9a4c8475b733d1))
* **installer:** Caddyfile.tpl — www.&lt;partner_domain&gt; → non-www 301 redirect ([#242](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/242)) ([41ef3fe](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/41ef3fecac1fce546964ea3fdb1246c2a2124c0a))
* **installer:** mirror-aware binary fetch (OXPULSE_MIRROR_BASE) + GitHub fallback ([b551058](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/b55105845140e5b4ef2c5cdc715c4bc09f46b737))
* **installer:** mirror-aware binary fetch with GitHub fallback ([0c1d8c7](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/0c1d8c7f8fd97c62efd4f7aad29b608d34f72cb7))
* **installer:** partner-edge host firewall hardening ([#231](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/231)) ([42f9c8c](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/42f9c8c5725e455483d92451e11df74c0ccd83f9))
* **install:** T1.3.f — install awg-params-agent binary + systemd unit + env config ([#240](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/240)) ([b24042c](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/b24042c0bbeb0f1776730754c1b82507f06ffd7c))
* **sfu:** split bind address per socket (metrics + relay-API + WS) ([#232](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/232)) ([0b9d1af](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/0b9d1afc108186b3ed1b6ca4c4e6d078379e46fa))


### Bug Fixes

* **installer:** pin IMAGE_VERSION from VERSION file, not floating 'latest' ([#237](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/237)) ([37ccb73](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/37ccb7377e65595862fbf3850fc884d45e2971fb))
* **installer:** three fresh-reinstall hardening fixes (Q, R, 8/10) ([#221](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/221)) ([c33411e](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/c33411e4704d2f8fb80b86ca28c52e17867f5d40))
* **systemd:** refresh.service Wants= instead of Requires= oxpulse-partner-edge ([#234](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/234)) ([cfeaf3c](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/cfeaf3c317f49f7998f45bc232906ce1aca04d83))
* **systemd:** sni-rotate + xray-update Wants= instead of Requires= ([#236](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/236)) ([007a4cf](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/007a4cfca259c2027a11b696d6713010d4fdc27b))

## [0.12.52](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/partner-edge-v0.12.51...partner-edge-v0.12.52) (2026-05-21)


### Bug Fixes

* **install:** validate AWG_* vars are non-empty after awg_extract ([#227](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/227)) ([555260f](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/555260f5e9244409345ac8d187be9a238da25a95))

## [0.12.51](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/partner-edge-v0.12.50...partner-edge-v0.12.51) (2026-05-21)


### Bug Fixes

* **installer:** prod debts from 2026-05-20 fleet outage ([#225](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/225)) ([192840e](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/192840e864d4b9ae7ebc293d0ee712799ee8a926))
* **xray:** pin teddysun/xray to 26.5.9 (replace :latest) ([#223](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/223)) ([2b5cf95](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/2b5cf954441c9456361110a89ad78d4329bf66af))

## [0.12.50](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/partner-edge-v0.12.49...partner-edge-v0.12.50) (2026-05-20)


### Features

* **opec:** --serve-countries installer flag + opec body field ([97bf117](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/97bf117523b66c628cba8b4730cfd0f1bef49698))
* **opec:** --serve-countries installer flag + opec register body field ([76ae8d6](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/76ae8d653e9ca0bfa95d68a280a20471228a163c))

## [0.12.49](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/partner-edge-v0.12.48...partner-edge-v0.12.49) (2026-05-20)


### Bug Fixes

* **installer:** Bug M + Bug O — fetch render-channel-lib on curl|bash flow, gate naive via compose profiles ([4469943](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/446994317e91ca1f23cfd0476f201a3281d3677f))
* **installer:** Bug M + Bug O — fetch render-channel-lib on curl|bash flow, gate naive via compose profiles ([d92a906](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/d92a90697b4d0225c9d409fb530e47d6a72055c5))

## [0.12.48](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/partner-edge-v0.12.47...partner-edge-v0.12.48) (2026-05-20)


### Bug Fixes

* **installer:** close OPEC handoff regression — full backend response passthrough via --out-json ([31619b2](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/31619b2b428fbe7a2207e0e56ec64e82e36b47bc))
* **installer:** close OPEC handoff regression — full backend response passthrough via --out-json ([634874f](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/634874f368f4db400cdc130f4aee3f1a2a96a0a9))
* **opec:** fix-loop on PR [#215](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/215) — BLOCKER + 3 MAJORs ([7d2d8df](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/7d2d8df6b7d71d091bc50173bfa1847c0ac0ddc9))

## [0.12.47](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/partner-edge-v0.12.46...partner-edge-v0.12.47) (2026-05-20)


### Features

* **ci:** gate installer bash tests on every PR ([c6c6878](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/c6c6878f20bda8008ceb9499c297a24d31351264))
* **ci:** gate installer bash tests on every PR ([50a9824](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/50a9824d7ebc2f5d5d217b451c886a3780d04794))
* **installer:** hint SFU slow-start in healthcheck timeout warn ([4d14439](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/4d14439e221f5995adc761e02347ee833ff61c28))
* **installer:** hint SFU slow-start in healthcheck timeout warn ([99e5734](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/99e57341d4681df455b544d143d0727742e601b4))


### Bug Fixes

* Fix:  ([5f311b3](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/5f311b35943f4ae2d3482abb8bba2fdf2aaeea29))
* add step [5b/6] gated on --purge-packages (default off). ([0fd0185](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/0fd01859fa2fcc3b026bab540cf8dfba32e7b0f6))
* **ci:** address code-quality findings on installer-bash-tests job ([04551ca](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/04551ca76164ae15a9cf3b1043dea50f5d6470e9))
* **ci:** skip 2 stale tests (compose_strip + production_readiness) ([a53e5d7](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/a53e5d7e12b86a94743ee79437fa3f871b88f8a3))
* **ci:** skip 4 stale bats files with pre-existing drift ([9cd2c42](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/9cd2c42cf7375bc9b9ad8c6adf51c99cf5085bda))
* **installer:** Bug E mkdir before reality-keygen + Bug C+D uninstall hardening ([2b9a963](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/2b9a9631d616bbc1623a9c8c7b93c9d1cf2bb4f9))
* **installer:** create PREFIX_ETC before opec reality-keygen (Fix E) ([0e5f679](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/0e5f679533a2c4866d9971cf7ff68d05e5fe4d6b))
* **integrity:** refresh lib-checksums.txt drift (render-channel-lib + install-healthcheck) ([5a25cb4](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/5a25cb46b257329e8f3e4ac1787add7beb610d1a))
* **integrity:** refresh lib-checksums.txt for render-channel-lib + install-healthcheck ([0b2b8b3](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/0b2b8b3f6352c448b6f63254075ceb162b73a867))
* **naive:** address PR [#214](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/214) MAJORs + MINORs — extended fixture guard + hy2 perms ([56fa6fa](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/56fa6fa94143aa02345ad247972a04991e842956))
* **naive:** perms 0640+gid-65532, fixture-host guard, granular channel status ([8075fcf](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/8075fcfe34645a259c116eb344fccb4998dbfa13))
* **naive:** perms 0640+gid-65532, fixture-host guard, granular channel status ([d649df6](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/d649df6f33e79c997f371cccdbf113e3cb61fcba))
* **opec:** accept missing relay_jwt_secret in register response ([8b2f647](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/8b2f6472f58b52e06e9c6d936433520ceda5a271))
* **opec:** accept missing relay_jwt_secret in register response ([4966323](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/4966323ca8f7879439a457b0a4d890c783d9aeab))
* **opec:** normalize empty relay_jwt_secret + warn when absent ([490f84f](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/490f84fcf1aa19a3477cbb93cbf6798dff700e7a))
* **uninstall:** BLOCKER+4 MAJORs from PR [#212](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/212) reviewer ([574b71f](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/574b71f8abd00adf69a9e58b5faab7e7a76b82b1))
* **uninstall:** remove amneziawg build artifacts with --purge-packages (Fix D) ([0fd0185](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/0fd01859fa2fcc3b026bab540cf8dfba32e7b0f6))
* **uninstall:** remove docker named volumes on uninstall (Fix C) ([5f311b3](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/5f311b35943f4ae2d3482abb8bba2fdf2aaeea29))

## [0.12.42](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/partner-edge-v0.12.41...partner-edge-v0.12.42) (2026-05-19)


### Bug Fixes

* **release:** remove same-file cp uninstall.sh that broke v0.12.41 build ([#197](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/197)) ([0bb0cd1](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/0bb0cd1105fe53650c5f6e530ce748c30cde88db))

## [0.12.40](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/partner-edge-v0.12.39...partner-edge-v0.12.40) (2026-05-19)


### Features

* Phase 5.7 — installer hardening (uninstall + AWG fail-soft + integrity + surgical refresh) ([#190](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/190)) ([b5dd2c8](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/b5dd2c8fd76b3529329faf7dc66bcb8aefa47016))

## [0.12.39](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/partner-edge-v0.12.38...partner-edge-v0.12.39) (2026-05-18)


### Features

* Phase 5.6 — healthcheck fixes + Phase 5.5 deferred bugs ([#189](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/189)) ([fcc7d38](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/fcc7d38ebbb767354cd647d45a23b3e0caf7e71e))


### Bug Fixes

* **caddy:** upstream → xray-client:3080 (HTTPS 503 root cause across all partner edges) ([#187](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/187)) ([b88f44a](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/b88f44a39891666af8f04f77b4fe2cbdc63dfd78))

## [0.12.38](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/partner-edge-v0.12.37...partner-edge-v0.12.38) (2026-05-18)


### Features

* Phase 5.5 — resilient multi-channel install with per-channel fail-soft ([#186](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/186)) ([808a993](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/808a99311d48b857b7412be82b37e119f41ab3c1))


### Bug Fixes

* **install:** bug 3+4 from live edge install on ru.oxpulse.chat ([#184](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/184)) ([054f919](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/054f9192dfb1f62283303d8c97e89de7f92e244f))

## [0.12.37](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/partner-edge-v0.12.36...partner-edge-v0.12.37) (2026-05-18)


### Bug Fixes

* **install:** RETURN-trap unbound var + ship install-awg.sh in release ([#181](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/181)) ([ca0f4a7](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/ca0f4a7127a39d535d4675d14d821aa3a7c947bb))

## [0.12.36](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/partner-edge-v0.12.35...partner-edge-v0.12.36) (2026-05-18)


### Features

* **opec:** Phase 5.3 — retire legacy keygen shell-outs ([#177](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/177)) ([5aad217](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/5aad217fcfaf99dc62ee616f38f76afc90a94778))

## [0.12.35](https://github.com/anatolykoptev/oxpulse-partner-edge/compare/partner-edge-v0.12.34...partner-edge-v0.12.35) (2026-05-18)


### Features

* **install:** Phase 4.10 — extract AWG kmod build/config to lib/install-awg.sh ([#172](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/172)) ([a9f9046](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/a9f904647a0d87f3bad3661a7e5f8b8ea725573a))
* **opec:** Phase 5.1 — native x25519 keygen for reality (retire partner-cli shell-out) ([#174](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/174)) ([9e8d36e](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/9e8d36e569fd1e7ac33cea3f5ce658ef837aea9a))
* **opec:** Phase 5.2 — native AWG/WireGuard keygen (retire wg-tools shell-out) ([#176](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/176)) ([a88ec05](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/a88ec05df633ff082a4240c5698d59a0ec444d3a))

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
- CH5 NaiveProxy deferred — caddy-forwardproxy `forbidden_zones` blocks RFC1918+loopback at hub server-side; needs external relay (Phase 2).
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
* **xray-update:** env-overridable CONTAINER and IMAGE for relay-x reuse ([#85](https://github.com/anatolykoptev/oxpulse-partner-edge/issues/85)) ([4b5e646](https://github.com/anatolykoptev/oxpulse-partner-edge/commit/4b5e6467cad2d52f2f406e14e42e00aec69f88c4))


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
- v0.12.0 nodes (edge-c) keep working without the env var — they retain
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
- VLESS + ML-KEM + Reality + XHTTP tunnel to hub backbone.
- TURNS-on-:443 via Caddy l4 SNI multiplexing.
- HMAC-SHA1 TURN credentials (`static-auth-secret`).
- One-command bootstrap installer (`bootstrap.sh` → `install.sh`).
- VM-clone hydration with sentinel-gated `hydrate.sh`.
- Cert-watch systemd unit for coturn TLS reload on renewal.

[0.8.0]: https://github.com/anatolykoptev/oxpulse-partner-edge/releases/tag/partner-edge-v0.8.0
[0.7.3]: https://github.com/anatolykoptev/oxpulse-partner-edge/releases/tag/partner-edge-v0.7.3
[0.7.0]: https://github.com/anatolykoptev/oxpulse-partner-edge/releases/tag/partner-edge-v0.7.0
