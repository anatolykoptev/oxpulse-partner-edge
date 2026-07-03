# ADR-001 — Converge Engine Contract

**Status:** Accepted (Phase 1, 2026-06-13)
**Scope:** ONE_WAY once boxes adopt the converge contract; each phase is independently reversible until Phase 4 freezes the MANIFEST format.
**Supersedes:** ad-hoc per-script render/restart logic in install.sh and upgrade.sh.

## Context

The partner-edge installer/upgrader had four independent render mechanisms for the same template set, leading to seven structural failure classes (documented in the architecture review). The most acute: upgrade.sh's `re_render_caddy` rendered only 2 of 6 Caddyfile.tpl placeholders while install.sh and the CI golden test rendered all 6 — structural CI-vs-runtime drift guaranteed to recur on every future template addition.

The core invariant this ADR enforces:

> **A fresh-box install and an N-year-old box after one `converge` run must reach byte-identical managed state. No manual intervention is ever required to deliver a released fix to an existing box.**

## Decision 1 — One idempotent reconcile engine

`lib/reconcile.sh` provides the shared primitives:

- `atomic_swap(installed, candidate)` — sibling-temp + mv (rename(2)) for zero partial-write window.
- `assert_no_unresolved_placeholders(rendered_file)` — fail-closed pre-swap completeness guard; aborts if any `{{NAME}}` survives render.
- `_setup_caddy_render_env([tpl_file])` — resolves and exports all 6 Caddyfile.tpl env vars including the 4-tier NAIVE_SOCKS_PORT chain (env → STATE_FILE → docker inspect → die-if-templated).
- `reconcile_caddy_surface(candidate_dir)` — the per-surface engine step: set up env, `opec render caddy`, completeness assert, sha256 compute, checksum-compare vs installed, atomic_swap only if changed, CADDYFILE_SHA update, mark_restart.
- `mark_restart(unit)` + `apply_restarts()` — dedup-restart collector; accumulates units, deduplicates, applies once.

**install = bootstrap + converge; upgrade = converge-to-version.** The reconcile lib is the single place where "render + validate + atomic_swap + mark_restart" is implemented. All entry points call it.

## Decision 2 — Single render authority: `opec render` everywhere

`opec render caddy --tpl <src> --out <dst>` is the sole Caddyfile render path for:
- install.sh (was already using `opec render caddy` via `render_with_opec`; Phase 1 adds the completeness guard)
- upgrade.sh `--with-templates` runtime path (previously used bash `sed`; now calls `reconcile_caddy_surface`)
- upgrade.sh `--with-templates` dry-run conflict-check path (previously re-implemented sed inline; now calls `_setup_caddy_render_env` + `opec render caddy`)
- CI golden test `tests/test_caddyfile_golden.sh` (previously used sed; now uses opec — eliminating the CI-vs-runtime drift that allowed `{{NAIVE_SOCKS_PORT}}` to live in the golden JSON)

The bash `sed` renderer in `re_render_caddy()` (upgrade.sh) was retained dormant (Strangler Fig) while surfaces were manifest-declared and tests grew to cover the lib path end-to-end. It has since been **deleted** (in the caddy-strangler phase, ahead of the originally-planned Phase 6): reconcile.sh's opec-rendered caddy surface is now the sole Caddyfile renderer, so the dormant `sed` path has no remaining callers.

### Why opec as the authority

`opec render caddy` reads ALL `{{NAME}}` placeholders from ambient env via `std::env::var(NAME)`. Adding a placeholder to `Caddyfile.tpl` is a one-line template edit; the completeness guard ensures the matching env export exists before any render reaches a live edge. There is no hand-maintained sed list to drift.

`opec` also validates the rendered Caddyfile post-substitution (balanced braces, at least one site-block opener), rejecting structurally broken renders before the atomic_swap.

## Completeness guard

Every call to `reconcile_caddy_surface` runs `assert_no_unresolved_placeholders` on the rendered file before the atomic_swap. This is fail-closed: an unresolved placeholder aborts the swap and preserves the current installed file. The CI guard (`tests/test_render_completeness.sh`) additionally verifies at PR time that every `{{X}}` in `Caddyfile.tpl` has an `export X` in install.sh or upgrade.sh.

## NAIVE_SOCKS_PORT resolution contract

The `_setup_caddy_render_env` function implements a 4-tier resolution for NAIVE_SOCKS_PORT (moved from upgrade.sh's `_resolve_naive_socks_port` into the lib so both install.sh and upgrade.sh use identical logic):

1. `NAIVE_SOCKS_PORT` env var already exported by caller.
2. STATE_FILE (`install.env`) persisted value.
3. Live `docker inspect oxpulse-partner-naive` env.
4. **die** — if `{{NAIVE_SOCKS_PORT}}` is present in the template and nothing resolved. Never silently defaults to 1080 when the template uses the placeholder.

## conf.d invariant

The rendered Caddyfile keeps its `import /etc/oxpulse-partner-edge/conf.d/*.caddy` line. The reconcile engine NEVER reads or writes files under `conf.d/`. This is declared as an **unmanaged surface** per `docs/runbooks/conf-d.md`.

## Phase scope

Phase 1 wires the **caddyfile surface only**. Other surfaces (coturn, xray, firewall, compose) are Phase 4.

The reconcile lib is the **Expand step** of an Expand-Contract refactor. The Contract step (deleting the dormant sed renderer and per-script fetch/restart duplications) is Phase 6, contingent on all surfaces being manifest-declared and the twice-idempotent CI test passing.

## Consequences

- Adding a placeholder to `Caddyfile.tpl` without an env export fails CI at `test_render_completeness.sh` before merge. The class #1 failure (CI-vs-runtime render-map drift) is structurally eliminated.
- The CI golden test exercises the exact runtime render path. Golden drift = rendering bug, not test fidelity gap.
- A render that leaves any `{{X}}` in the Caddyfile never reaches an atomic_swap — the guard fires first and preserves the installed file.
- A piter-class node (no caddy service in compose) gets a graceful skip, not a die.
- The NAIVE_SOCKS_PORT die-loud behavior (PR #308 invariant) is preserved and centralized.
