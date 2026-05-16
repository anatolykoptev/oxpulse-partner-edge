# opec — OxPulse Partner Edge Controller

`opec` is a Rust CLI binary that manages multi-tenant configuration on each
OxPulse partner edge node. It is the typed, testable replacement for the
hand-edited Caddyfile fragments that previously required manual SSH sessions.

## Sub-phase 4.0 — Read-only (this crate)

This release implements the **foundation**: schema, parser, validator, and
three read-only subcommands. No Caddy admin API calls, no file writes, no
network requests.

```
opec tenant list   [--yaml <path>] [--format table|json]
opec tenant validate [--yaml <path>] [--format table|json]
opec tenant diff   <left.yaml> <right.yaml> [--format table|json]
```

Default yaml path: `/etc/oxpulse-partner-edge/tenants.yaml`

## Future sub-phases

| Sub-phase | Description |
|-----------|-------------|
| 4.1 | `opec tenant diff` — deep route-level diff |
| 4.2 | Caddy admin API client (read-only GET /config/) |
| 4.3 | `opec tenant reconcile [--dry-run]` — compute + PATCH |
| 4.4 | `opec tenant add / rm / edit` — scaffold + reconcile |
| 4.5 | `opec tenant import --from-caddyfile` — migrate existing vhosts |

## Crate layout

```
crates/opec/
  src/
    lib.rs              -- exposes tenant module for integration tests
    main.rs             -- clap CLI: tenant list|validate|diff
    tenant/
      mod.rs
      schema.rs         -- serde structs for tenants.yaml
      validate.rs       -- pure validators (collect all errors)
  tests/
    integration.rs      -- schema + validator + CLI tests
    fixtures/           -- yaml test fixtures (valid + invalid)
```

## Build

```bash
cargo build --release -p opec
./target/release/opec --help
```
