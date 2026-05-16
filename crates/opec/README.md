# opec — OxPulse Partner Edge Controller

`opec` is a Rust CLI binary that manages multi-tenant configuration on each
OxPulse partner edge node. It is the typed, testable replacement for the
hand-edited Caddyfile fragments that previously required manual SSH sessions.

## Sub-phase 4.0 — Read-only

Schema, parser, validator, and three read-only subcommands. No admin API calls.

```
opec tenant list   [--yaml <path>] [--format table|json]
opec tenant validate [--yaml <path>] [--format table|json]
opec tenant diff   <left.yaml> <right.yaml> [--format table|json]
```

## Sub-phase 4.1 — Caddy JSON renderer + dry-run reconcile

Adds the Caddy admin-API JSON renderer and `reconcile --dry-run`.

```
opec tenant reconcile [--yaml <path>] [--admin-url <url>] --dry-run [--format text|json]
```

- Reads `tenants.yaml`, validates, renders to Caddy JSON, prints the PATCH payload.
- No HTTP call — pure render only. Real PATCH arrives in 4.2.
- Default `--admin-url`: `http://localhost:2019`

New modules:
- `caddy::render` — `render_tenant_routes(&[Tenant]) -> Vec<Value>` + shape validator
- `caddy::diff` — `diff_routes(live, proposed) -> RouteDiff` (used by 4.2)

## Future sub-phases

| Sub-phase | Description |
|-----------|-------------|
| 4.2 | Caddy admin API client — real PATCH + `tenant-state.json` + rollback |
| 4.3 | `opec tenant add / rm / edit` — scaffold + reconcile |
| 4.4 | `opec tenant import --from-caddyfile` — migrate existing vhosts |
| 4.5 | Systemd timer for hourly reconcile |

## Crate layout

```
crates/opec/
  src/
    lib.rs              -- exposes tenant + caddy modules for integration tests
    main.rs             -- clap CLI: tenant list|validate|diff|reconcile
    caddy/
      mod.rs
      render.rs         -- pure renderer: Tenant[] → Vec<serde_json::Value>
      diff.rs           -- route diff by @id (pub API for 4.2)
    tenant/
      mod.rs
      schema.rs         -- serde structs for tenants.yaml
      validate.rs       -- pure validators (collect all errors)
  tests/
    integration.rs      -- schema + validator + CLI tests (53 total)
    fixtures/           -- yaml test fixtures (valid + invalid)
```

## Build

```bash
cargo build --release -p opec
```
