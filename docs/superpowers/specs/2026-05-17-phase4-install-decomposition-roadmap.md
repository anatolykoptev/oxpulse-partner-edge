# Phase 4 — install.sh Decomposition Roadmap

**Status:** active (Phase 3 merged at #151, cf07e94 on main)
**Owner:** krolik
**Target:** install.sh `1991 → ~300 LoC` orchestrator across 9 sub-phases

## Decomposition heuristic

- **Declarative state** (templates, JSON shape, secrets schema, systemd units) → **OPEC subcommand** (Rust). Already proven in Phase 1-3 for render kinds.
- **Imperative host glue** (dnf/apt, firewall-cmd, kmod, systemctl) → **`lib/install-*.sh`** bash module sourced by install.sh. Rust would shell out anyway — no typing win.
- **Edge case:** typed I/O (HTTP JSON, retry, structured error) → OPEC even when looks imperative. Secrets fetch qualifies.

## OPEC subcommand layout

Siblings of `render`/`tenant`, NOT god-subcommand `opec install <step>`. Phase 5 partner-cli absorption will drop in as another sibling. New siblings: `opec deps`, `opec secrets`, `opec systemd`, `opec preflight`.

## Defaults (operator decisions)

| # | Question | Decision |
|---|----------|----------|
| 1 | Module distribution | **Tarball** in GitHub release asset, per-file `REPO_RAW` as fallback for `curl|bash` flow |
| 2 | OPEC version pin | Hard-fail on `opec --version < X.Y.Z` + auto-refetch release asset |
| 3 | Canary order (Phase 4.3) | **cheburator first** (freshest install, lowest traffic) → rvpn → zvonilka → piter-seed |
| 4 | Fallback shim lifetime | Tied to minor version bump: `partner-edge-0.13.x` keeps fallback, `0.14.0` removes |
| 5 | AWG phase ordering | **Independent of Phase 5** — can run in parallel post-Phase 4 |
| 6 | `lib/` install location | `/usr/local/lib/partner-edge/` (FHS-correct; needs `ReadWritePaths` for systemd if used) |

## Sub-phase ledger

| Phase | What moves | Target | LoC cut | install.sh after |
|-------|------------|--------|---------|------------------|
| 4.1 | Step 1+1b+1c+1b'+Step 2 | `lib/install-preflight.sh` + `lib/install-deps.sh` | 155 | 1836 |
| 4.2 | Step 3 IP detect + 3b pre-pull | `lib/install-network.sh` | 133 | 1703 |
| 4.3 | Step 4 hydrate (secrets fetch + crypto + synthesis) | `opec secrets` subcommand | 616 | 1167 |
| 4.4 | Step 5 — delete bash render_template fallback bodies | OPEC-only render | 196 | 971 |
| 4.5 | Step 5b mmdb + Step 6 compose start | `lib/install-runtime.sh` | 57 | 914 |
| 4.6 | Step 7 healthcheck loop | `lib/install-healthcheck.sh` | 54 | 860 |
| 4.7 | Step 8 systemd unit heredocs | `opec systemd` subcommand | 147 | 713 |
| 4.8 | Remove `OPEC_SECRETS=0` + `OPEC_SYSTEMD=0` fallback shims | — | 110 | 603 |
| 4.9 | Step 10 report + arg parsing collapse | `lib/install-args.sh` | 300 | ~300 ✓ |

## Out of scope

- **AWG provisioning** (`install_amneziawg`, ~400 LoC of kmod build) — separate Phase 4.10 with dedicated bats matrix (RHEL/Debian/Ubuntu kernels)
- **partner-cli absorption** — Phase 5
- **update.sh** — shares `lib/install-*.sh` modules once they exist (free win)

## Phase invariants (every sub-phase)

1. **bats parity** — extracted module + integration test prove byte-identical stage output before/after
2. **Backward-compat shim** — `source` from `INSTALL_LIB_DIR` with `REPO_RAW` fetch fallback (mirrors `_chan_lib_tmp` pattern from Step 3b)
3. **Live-edge soak** — at least 24h on cheburator before next phase merge
4. **No big-bang** — each phase shippable independently, deletable as standalone PR if regression surfaces

## Cross-phase risk register

| Risk | Phase | Mitigation |
|------|-------|------------|
| `set -euo pipefail` propagation across `source` | 4.1+ | bats `assert_failure` on injected `false` in module |
| ipinfo.io rate-limit retry semantics drift | 4.2 | preserve exact retry count, parity-test envelope |
| Secret-material handling regression | 4.3 | per-edge canary roll + `OPEC_SECRETS=0` env rollback |
| OPEC version skew on live edges | 4.4 | install.sh sniffs `opec --version` at boot, refuses if older |
| Rollback path narrowing after Phase 4.8 | 4.8 | tag prior release `partner-edge-vX.Y.Z-rescue` |

## Reference

- Phase 3 closing: PR #151, `cf07e94` on main
- Phase 4.1 plan: `docs/superpowers/plans/2026-05-17-phase4-1-preflight-deps.md`
- Architect transcript: this doc IS the saved transcript (no separate output file)
