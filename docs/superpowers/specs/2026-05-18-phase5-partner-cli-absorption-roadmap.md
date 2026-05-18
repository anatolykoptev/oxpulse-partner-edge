# Phase 5 — partner-cli Absorption Roadmap

**Status:** Phase 5.1 **SHIPPED** (2026-05-18). Phase 5.2+ in queue.
**Owner:** krolik
**Goal:** absorb all partner-cli call sites into OPEC native Rust, making partner-cli a
build-time-only artifact (for the central registry) and eventually retire the binary from
install.sh / OPEC entirely.

## Background

After Phase 4 (install.sh decomposition), OPEC shells out to `partner-cli` in two places:
1. `opec secrets reality-keygen` → `partner-cli keygen` (x25519 keypair)
2. (future) `opec secrets register` → implied partner-cli usage for registration

The absorption pattern: copy the implementation from partner-cli into OPEC, keep the
shell-out path behind a `OPEC_*_LEGACY=1` env gate for one release cycle, then remove.

## Sub-phase ledger

| Phase | What moves | Status | Env gate removed |
|-------|-----------|--------|-----------------|
| 5.1 | `partner-cli keygen` → native `x25519::keygen_x25519()` in OPEC | **DONE** (2026-05-18, commit `cea6f75`) | `OPEC_REALITY_KEYGEN_LEGACY=1` → remove in 5.X |
| 5.2 | `wg genkey`/`wg pubkey` → native `wg_keypair::keygen_wg()` + `pub_from_priv_b64()` in OPEC | **DONE** (2026-05-18, commits `411070d`+`88476d2`) | `OPEC_AWG_KEYGEN_LEGACY=1` → remove in 5.X |
| 5.3 | Cleanup: remove all `LEGACY=1` env-gate branches + `--partner-cli` / `--wg` deprecated args from OPEC. Open partner-cli binary retirement (partner-cli no longer invoked by OPEC at runtime; can be removed from install.sh after one release cycle). | TODO | — |
| 5.N | Retire partner-cli binary from install.sh and the release asset | TODO | — |

## Phase 5.1 detail

**Files changed:**
- `crates/opec/Cargo.toml` — added `x25519-dalek 2`, `zeroize 1`, `rand 0.8`
- `crates/opec/src/secrets/x25519.rs` — new: `keygen_x25519()` + `base64_url_encode()` copied verbatim from partner-cli; RFC 4648 §5 encoding identity locked by test
- `crates/opec/src/secrets/mod.rs` — wire `pub mod x25519`; deprecation note on `--partner-cli` arg
- `crates/opec/src/secrets/reality.rs` — native path by default; `OPEC_REALITY_KEYGEN_LEGACY=1` falls back to `Command::new(partner-cli)`
- `crates/opec/tests/secrets_reality_native.rs` — new: 2 integration tests for native + legacy paths
- `crates/opec/tests/secrets_reality_unit.rs` — updated: shell-out tests now set `OPEC_REALITY_KEYGEN_LEGACY=1` + `#[serial]`

**Test delta:** 117 → 122 (+5 new tests: 3 x25519 unit, 2 native/legacy integration).

## Phase 5.2 detail

**What changed:** absorbed `wg genkey` / `wg pubkey` shell-outs from
`crates/opec/src/secrets/awg.rs` into a new native `wg_keypair` module.
WireGuard keys are x25519 keypairs (RFC 7748) with standard base64 + `=` padding
(44 chars), matching `wg` output exactly.

**Files changed:**
- `crates/opec/Cargo.toml` — added `base64 = "0.22"` (RFC 4648 §4 standard encoding)
- `crates/opec/src/secrets/wg_keypair.rs` — new: `keygen_wg()` + `pub_from_priv_b64()`;
  5 unit tests (format, randomness, round-trip, rejection)
- `crates/opec/src/secrets/mod.rs` — wire `pub mod wg_keypair`; `--wg` arg help updated
- `crates/opec/src/secrets/awg.rs` — native path by default; `OPEC_AWG_KEYGEN_LEGACY=1`
  falls back to `Command::new(wg)` shell-out; `priv_key` is `Zeroizing<String>` end-to-end
- `crates/opec/tests/secrets_awg_native.rs` — new: 3 integration tests (native fresh,
  native idempotent, legacy env gate)
- `crates/opec/tests/secrets_awg_unit.rs` — updated: shell-out tests now set
  `OPEC_AWG_KEYGEN_LEGACY=1` + `#[serial]`; rotate test converted to native path

**Test delta:** 122 → 130 (+8 tests: 5 wg_keypair unit, 3 native integration).

**OPEC shell-out status after Phase 5.2:**
- `opec secrets reality-keygen` → native (shell-out behind `OPEC_REALITY_KEYGEN_LEGACY=1`)
- `opec secrets awg-keygen` → native (shell-out behind `OPEC_AWG_KEYGEN_LEGACY=1`)
- `opec secrets sfu-signing-key` → direct HTTP (no shell-out, no absorption needed)
- `opec secrets register` → direct HTTP POST (no shell-out, no absorption needed)

**OPEC partner-cli surface is now empty** — no production code path in OPEC invokes
`partner-cli` or `wg` binaries without a `LEGACY=1` env gate.

## Phase 5.3 scope (cleanup)

Remove all legacy fallback code after one release cycle:
- Delete `OPEC_REALITY_KEYGEN_LEGACY=1` branch from `reality.rs`
- Delete `OPEC_AWG_KEYGEN_LEGACY=1` branch from `awg.rs` (including `keygen_legacy`,
  `run_wg`, `resolve_wg` helpers — ~50 LoC)
- Remove `--partner-cli` arg from `SecretsCommands::RealityKeygen` (currently deprecated)
- Remove `--wg` arg from `SecretsCommands::AwgKeygen` (currently deprecated)
- Remove `which` dep from `crates/opec/Cargo.toml` if no other users remain
- Open separate PR for partner-cli binary retirement from install.sh
  (partner-cli is still used by central registry tooling — OPEC-only retirement)

## Phase invariants (every sub-phase)

1. **No semantic change to output format** — file names, permissions, and content shape stay identical.
2. **43-char base64url invariant** — validated post-keygen in reality.rs (both native and legacy paths).
3. **Env-gate rollback** — one release cycle of `LEGACY=1` before cleanup.
4. **No partner-cli touch** — partner-cli is still used by other callers (central registry tooling); only call sites within OPEC are absorbed.
5. **TDD** — tests added before implementation for each phase.
