# Phase 4 — install.sh Decomposition Roadmap

**Status:** **COMPLETE** as of 2026-05-17 (PR #169 merged, install.sh = 1088 LoC). Phase 4.10 (AWG kmod build) deferred; Phase 5 (partner-cli absorption) deferred.
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
| 4.4 | Delete bash render_template fallback inside install.sh; opec now hard requirement | OPEC-only render | actual 30 | 1840→1810 |
| 4.5 | Step 5b mmdb + Step 6 compose start | `lib/install-runtime.sh` | actual 55 | 2073→2018 |
| 4.6 | Step 7 healthcheck loop | `lib/install-healthcheck.sh` | actual 51 | 2024→1855 |
| 4.7 | Step 8 systemd unit installation (re-scoped: bash module, NOT opec — code is file-copy, not heredoc templates) | `lib/install-systemd.sh` | actual 169 | 2024→1855 |
| 4.8 | Retire OPEC_SECRETS_{REALITY_KEYGEN,AWG_KEYGEN,REGISTER,SFU_KEY} env-gated bash fallbacks | — | actual 391 | 1855→1464 |
| 4.9 | Args parsing + token resolve + branding-config + brand-flag composition | `lib/install-args.sh` | actual 376 | 1464→**1088** ✓ |

**Final: install.sh 1991 → 1088 LoC (−903, −45%).** Original architect target was ~300 LoC; reality landed at ~1090 because per-Step wrappers + helpers don't compress further without absorbing the orchestration itself into OPEC (Phase 5+ territory).

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

## Reference — merged PRs

| Phase | PR | Commit on main | Per-phase plan doc |
|-------|----|----------------|--------------------|
| 3 closing | #151 | cf07e94 | (Phase 3) |
| 4.1 | #153 | ed9978e | `2026-05-17-phase4-1-preflight-deps.md` |
| 4.2 | #154 | 75e6695 | `2026-05-17-phase4-2-network.md` |
| 4.3a | #155 | c252743 | `2026-05-17-phase4-3a-opec-secrets-reality-keygen.md` |
| 4.3b | #156 | 8151c13 | `2026-05-17-phase4-3b-opec-secrets-awg-keygen.md` |
| 4.3c | #161 | e830314 | `2026-05-17-phase4-3c-opec-secrets-register.md` |
| 4.3d | #163 | 082b9b4 | (plan inline in PR body) |
| 4.4 | #164 | 7f63d3a | (plan inline in PR body) |
| 4.5 | #165 | d6b17c0 | (plan inline in PR body) |
| 4.6 | #166 | 9fcb170 | (plan inline in PR body) |
| 4.7-4.9 | #169 | b8312fa | (plan inline in PR body; PR #167 + #168 squash-merge failed silently, recovered via cherry-pick) |

## Lessons learned (post-execution)

- **Plan was a compass.** Architect's per-phase LoC estimates landed within 20% on small phases (4.1-4.2) but architect mis-predicted Phase 4.7 ("opec systemd subcommand with askama") — reality was file-copy boilerplate, bash module fit instead. **Re-scope when reading the actual code contradicts the roadmap.**
- **Quality reviewer ловил каждую security regression.** Phase 4.3c alone had: JSON-error leak vector, env-file `$()` injection, env-file newline injection, dry-run flag regression, host-DoS chmod /tmp. Each caught BEFORE merge, fixed via implementer re-dispatch.
- **GitHub API squash merge can silently fail.** PR #167 + #168 returned `"merged":true` but trees were empty (likely "branch not up-to-date" rejected merge but API returned success). **Always verify** `git diff base..HEAD --stat` after API merge.
- **Wrapper overhead before compression.** install.sh grew +33 LoC across Phase 4.1-4.6 (wrappers cost more than extractions saved). Real compression hit at Phase 4.7-4.9 once fallbacks retired and big arg-parsing block extracted.

## Out of scope / next phases

- **Phase 4.10 — AWG kmod build extraction** (`install_amneziawg`, ~400 LoC kernel module compile). Needs dedicated bats matrix per distro (RHEL/Debian/Ubuntu). High complexity, deferred.
- **Phase 5 — partner-cli absorption.** Pull native x25519/signing/JWT into OPEC, retire partner-cli binary. Weeks of work.
- **update.sh / upgrade.sh** — eventually share `lib/install-*.sh` modules; free win when those scripts touched next.
- **Caddy fixture drift followup** — fixed in this hygiene PR (added AWG_MOTHERLY_IP + HY2_FALLBACK_* to frozen_env).
