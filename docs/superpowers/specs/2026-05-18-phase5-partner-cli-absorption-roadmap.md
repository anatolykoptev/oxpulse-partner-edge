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
| 5.2 | Ed25519 sfu-signing-key: absorb `partner-cli sfu-signing-key` logic (GET signing key, write env-file) into OPEC; same pattern as 5.1 | TODO | `OPEC_SFU_KEY_LEGACY=1` |
| 5.3 | Register HKDF / JWT: absorb `partner-cli register` handshake into OPEC (HTTP POST, JWT token derivation, env-file write) | TODO | `OPEC_REGISTER_LEGACY=1` |
| 5.X | Cleanup: remove all legacy env-gate branches and the `--partner-cli` / legacy CLI args from OPEC | TODO | — |
| 5.N | Retire partner-cli binary from install.sh and the release asset (partner-cli is no longer invoked at runtime) | TODO | — |

## Phase 5.1 detail

**Files changed:**
- `crates/opec/Cargo.toml` — added `x25519-dalek 2`, `zeroize 1`, `rand 0.8`
- `crates/opec/src/secrets/x25519.rs` — new: `keygen_x25519()` + `base64_url_encode()` copied verbatim from partner-cli; RFC 4648 §5 encoding identity locked by test
- `crates/opec/src/secrets/mod.rs` — wire `pub mod x25519`; deprecation note on `--partner-cli` arg
- `crates/opec/src/secrets/reality.rs` — native path by default; `OPEC_REALITY_KEYGEN_LEGACY=1` falls back to `Command::new(partner-cli)`
- `crates/opec/tests/secrets_reality_native.rs` — new: 2 integration tests for native + legacy paths
- `crates/opec/tests/secrets_reality_unit.rs` — updated: shell-out tests now set `OPEC_REALITY_KEYGEN_LEGACY=1` + `#[serial]`

**Test delta:** 117 → 122 (+5 new tests: 3 x25519 unit, 2 native/legacy integration).

## Phase 5.2 preview (Ed25519 sfu-signing-key)

The pattern is identical to 5.1 and will be very small:
- `partner-cli sfu-signing-key` currently fetches a GET endpoint and writes an env-file.
- OPEC already has `opec secrets sfu-signing-key` (`crates/opec/src/secrets/sfu_key.rs`).
- The native absorption is: add `ed25519-dalek` dep, copy signing key derivation into
  `crates/opec/src/secrets/ed25519.rs`, and make `sfu_key.rs` use it directly.

## Phase invariants (every sub-phase)

1. **No semantic change to output format** — file names, permissions, and content shape stay identical.
2. **43-char base64url invariant** — validated post-keygen in reality.rs (both native and legacy paths).
3. **Env-gate rollback** — one release cycle of `LEGACY=1` before cleanup.
4. **No partner-cli touch** — partner-cli is still used by other callers (central registry tooling); only call sites within OPEC are absorbed.
5. **TDD** — tests added before implementation for each phase.
