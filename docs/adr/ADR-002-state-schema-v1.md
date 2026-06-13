# ADR-002 — State Schema v1 + Forward Migration

**Status:** Accepted (Phase 2, 2026-06-13)
**Scope:** ONE_WAY once a box has SCHEMA_VERSION=1 in its state file; old readers ignore the key (additive).
**Supersedes:** scattered "state file is from a pre-Phase-6 build, re-run install.sh" die()s in upgrade.sh and install.sh.

## Context

The installer writes `install.env` (the "state file") at first install. As the installer evolved, new required keys were added — TURNS_SUBDOMAIN (Phase 6 of the old naming), BACKEND_API (v0.12.53), NAIVE_SOCKS_PORT (Phase 1 of converge, 2026-06-13), CADDYFILE_SHA (Phase 1). Boxes that installed at an older vintage and never ran a full reinstall have a state file missing these keys.

Before this ADR, the code handled this with die()s like:

```
die "TURNS_SUBDOMAIN missing from $STATE_FILE — state file is from a pre-Phase-6 build, re-run install.sh"
```

This forces reinstall on an otherwise-healthy box just because one metadata key is absent. An N-year-old box with a perfectly-working partition should not require a wipe to upgrade.

## Decision — Monotonic schema_version + forward-only migration chain

### Schema version key

`SCHEMA_VERSION=1` is appended to `install.env` by install.sh (Phase 2 onward). All future schema changes bump this integer. Readers that don't recognise a version can log a warning and refuse (they won't silently corrupt).

### migrate_state() function

`lib/reconcile.sh` provides `migrate_state()`. Called by upgrade.sh immediately after `. "$STATE_FILE"` (skipped on `--check` and `--dry-run` modes). Idempotent: a v1 state returns immediately.

#### Migration rules

| Key | How derived | Die if undeducible? |
|-----|-------------|---------------------|
| `CADDYFILE_SHA` | sha256 of live `/etc/oxpulse-partner-edge/Caddyfile` | No — left absent; set on next reconcile |
| `TURNS_SUBDOMAIN` | `turns_subdomain` field in node-config.json | No — left absent if not parseable |
| `NAIVE_SOCKS_PORT` | docker inspect `oxpulse-partner-naive` (println fix); default 1080 | No — defaults to 1080 |
| `BACKEND_API` | `backend_endpoint` from node-config.json (port suffix stripped) | **YES** — only if genuinely undeducible |
| `OXPULSE_MIRROR_BASE` | Optional; not derived (absent on non-mirror installs is correct) | No |

#### One-actionable-die rule

If a genuinely required key cannot be derived, `migrate_state()` emits **exactly one actionable line** naming the specific key and the manual fix:

```
migrate_state: BACKEND_API missing from /var/lib/oxpulse-partner-edge/install.env
and cannot be derived from node-config.json.
Provide it: echo 'BACKEND_API=https://api.oxpulse.chat' >> /var/lib/oxpulse-partner-edge/install.env
```

No "re-run install.sh" catch-all. One key. One fix. Operator can provide it and re-run upgrade.

### Constraint: never derive secrets

`migrate_state()` NEVER reads or writes:
- `reality.priv` / `awg-private.key` — generate-once key material
- `service_token_hash` — HMAC of the one-use bootstrap token
- signaling/SFU keys — derived from node registration, not derivable from live artefacts
- `GHCR_TOKEN` / other PATs

These live in their own dedicated files, not in `install.env`, and `migrate_state()` does not touch those files.

## Consequences

### Positive

- N-year-old boxes converge without reinstall.
- The die paths that demanded reinstall are replaced with self-healing migration.
- Schema version is a contract: future key additions add a migration step here, not a die() at call sites.
- Forward-only chain: migration steps only add keys, never remove them, so rollback of the migration code itself is safe (the extra key is ignored by old code).

### Negative / mitigations

- The derive-from-live logic is conservative (won't guess a secret). Boxes missing BACKEND_API AND lacking node-config.json still require one manual key provision. This is intentional: better to fail with a precise actionable message than to silently derive a wrong value.
- Boxes on a very new install that haven't converged yet will have SCHEMA_VERSION=1 from install.sh; the migration is a no-op. No double-write risk.

## Rollback

`SCHEMA_VERSION` is additive. Old upgrade.sh versions (pre-Phase-2) ignore it. If Phase 2 is reverted:
- The SCHEMA_VERSION=1 line in existing state files is harmless (silently ignored).
- The missing-key die()s come back; they'll fire on boxes where migration already ran, which means those keys are now present — die()s won't fire.
- Net: rollback is safe.

## Vintage matrix tested

| Vintage | Missing keys at install time | migrate_state result |
|---------|-----------------------------|--------------------|
| v0.12.50 (+ node-config.json) | BACKEND_API, NAIVE_SOCKS_PORT, CADDYFILE_SHA | Derives BACKEND_API from node-config; defaults NAIVE_SOCKS_PORT=1080; sets SCHEMA_VERSION=1 |
| v0.12.50 (no node-config.json) | BACKEND_API (undeducible) | Die with one actionable line naming BACKEND_API |
| v0.12.63 | NAIVE_SOCKS_PORT, CADDYFILE_SHA | Defaults NAIVE_SOCKS_PORT=1080; sets SCHEMA_VERSION=1 |
| v0.12.73 | CADDYFILE_SHA | Tries to hash live Caddyfile (if present); sets SCHEMA_VERSION=1 |
| v0.12.78+ (Phase 1) | SCHEMA_VERSION | Sets SCHEMA_VERSION=1 (idempotent) |
