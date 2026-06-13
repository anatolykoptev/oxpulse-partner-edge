# ADR-003: Manifest Format

**Status:** Accepted — Phase 4a (ONE_WAY freeze from this phase forward)
**Date:** 2026-06-13
**Phases:** Phases 4a-6

---

## Decision

Ship `manifest.yaml` at repo root as the single declaration of every managed surface.
The reconcile engine (`reconcile_all` in `lib/reconcile.sh`) reads it and acts on each
surface in declared topological order. Nothing on a box is managed unless it is declared
in the manifest.

`manifest_version` is frozen at `1` from this phase forward. Future format changes that
are backwards-incompatible MUST bump `manifest_version` and add a forward-migration path.

---

## Manifest format (v1)

```yaml
manifest_version: 1          # ONE_WAY — bumps only on incompatible format change
release_tag: "@RELEASE_TAG@" # substituted by release.yml at release time

surfaces:
  - id: <surface_id>
    kind: render_from_state | persist_rendered | sync_verified | network_apply
    # ... kind-specific fields (see below)
    wired: false              # optional; absent = wired; false = declared-but-not-yet-wired

unmanaged:
  - path: <path>
    reason: <why not managed>

state_schema:
  version: 1
  required_keys: [...]
  derivable_keys: [...]
```

### Surface kinds and required fields

| Kind | Required fields | Semantics |
|------|----------------|-----------|
| `render_from_state` | `template`, `out`, `renderer`, `placeholder_completeness`, `restart_unit` | Render from template × STATE; checksum-compare; atomic-swap if changed; restart `restart_unit` |
| `persist_rendered` | `out`, `secret_surface: true` | Artifact carries secrets. Never re-render from template. Patch image tags only. |
| `sync_verified` | `out`, `checksum_source` | Fetch for `release_tag`; SHA256SUMS-verify; atomic-swap if changed. |
| `network_apply` | `applier`, `scope` | Idempotent network state. Re-asserted every converge. Live re-assert is authority. |

### `wired: false` semantics

A surface with `wired: false` is **declared** (test_manifest_coverage validates its
fields) but **not yet reconciled** by `reconcile_all`. The engine logs
"declared, not yet wired (Phase 4b)" and skips it. This allows the full surface list to
be declared in Phase 4a while adopting surfaces one-by-one in Phase 4b.

### `sha_key`

Optional field on `render_from_state` surfaces. Names the STATE_FILE key that tracks the
rendered checksum (e.g. `CADDYFILE_SHA`). Used for drift detection and canary
config-hash comparison.

---

## Unmanaged exclusions

The following are explicitly EXCLUDED from management and must never be touched:

- `/etc/oxpulse-partner-edge/conf.d/` — operator override slot (conf-d.md canon §6)
- `/etc/oxpulse-partner-edge/ru-subnets.txt` — data feed with its own lifecycle
- `reality.priv`, `awg-private.key`, `token` — secrets, generate-once

The engine treats any path not in `surfaces[].out` as unmanaged; the `unmanaged:` block
documents the load-bearing exclusions for reviewers.

---

## Secret safety

`persist_rendered` surfaces mark `secret_surface: true`. The engine NEVER re-renders
these from their template (doing so would wipe secrets). The only permitted operation on
a `persist_rendered` surface is in-place patching (e.g. image tag updates via `sed`).

`render_from_state` surfaces may not carry secrets. If a template gains a secret
placeholder, it MUST be reclassified as `persist_rendered` (with its own secret-delivery
mechanism) or the secret must be derived from a separate secret store.

---

## Consequences

**Positive:**
- Single declaration: adding a surface requires one manifest entry; the engine handles it.
- Structural impossibility of undeclared writes (test_manifest_coverage enforces).
- Idempotency by construction: `reconcile_all` twice produces zero changes (S2).
- `apply_restarts` fires exactly once after the loop; deduplication built-in.

**Negative:**
- `manifest_version` is ONE_WAY: any incompatible format change requires a migration.
- The base64-encoded Python manifest parser (`_MANIFEST_PARSER_B64`) must be regenerated
  whenever the parser logic changes. The generator is in the repo history.

---

## Rollback

During Phases 4a-5, revert the manifest-reader wire-in in `lib/reconcile.sh` and the
`upgrade.sh` call to `reconcile_caddy_surface` directly. The manifest file itself is
inert without the lib reading it.

Phase 6 (Contract) deletes the old `reconcile_caddy_surface` call-sites; at that point
rollback requires restoring deleted code.
