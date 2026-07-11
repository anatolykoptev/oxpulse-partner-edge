# Runbook: opec tenant — multi-tenant config on partner edge

## Where tenants.yaml lives

```
/etc/oxpulse-partner-edge/tenants.yaml   (mode 0644, owned by root)
```

This file is the source of truth for all tenants on a partner edge node.
Edit it with your preferred editor; then run `opec tenant validate` before
applying any changes.

## Tenant skeleton (copy-paste template)

```yaml
schema_version: 1
tenants:
  - id: your-tenant-id              # ^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$
    domains:
      - your-domain.example.com
    enabled: true
    routes:
      - path: /api/*
        action: proxy
        upstream: https://upstream.your-domain.example.com
        host_header: upstream.your-domain.example.com
      - path: /
        action: file_server
        root: /srv/your-tenant-static
        try_files: ["{path}", /index.html]
    redirects:
      - from_host: www.your-domain.example.com
        to: "https://your-domain.example.com{uri}"
        permanent: true
```

## Adding a tenant manually (sub-phase 4.0)

Sub-phase 4.3 will add `opec tenant add` for interactive scaffolding.
Until then:

1. Edit `/etc/oxpulse-partner-edge/tenants.yaml` — add your stanza.
2. Validate: `opec tenant validate`
3. If validation passes, apply (sub-phase 4.3+: `opec tenant reconcile`).

**Operator action for sub-phase 4.0: NONE.** The binary is read-only;
no behavioral changes on the edge.

## Validate before every edit

```bash
opec tenant validate
# OK — 3 tenant(s) valid

opec tenant validate --format json
# {"ok":true,"errors":[]}
```

Exit 0 = clean. Exit 1 = errors printed. Fix all before reconciling.

## Inspect current config

```bash
opec tenant list
# ID       DOMAINS                                  ENABLED  ROUTES
# -----------------------------------------------------------------------
# edge-a   edge-a.example, www.edge-a.example       true     4

opec tenant list --format json
```

## Compare two versions

```bash
opec tenant diff /etc/oxpulse-partner-edge/tenants.yaml tenants.yaml.new
# + beta-org  (added)
# ~ edge-a  (changed)
#     1 changed route(s): /api/landing-chat*
```

## Field reference

| Field | Required | Constraints |
|-------|----------|-------------|
| `id` | yes | `^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$` |
| `domains` | yes | valid hostnames, globally unique |
| `enabled` | yes | bool |
| `routes[].path` | yes | non-empty, starts with `/` |
| `routes[].action` | yes | `proxy` or `file_server` |
| `routes[].upstream` | proxy only | non-empty URL |
| `routes[].root` | file_server only | non-empty absolute path |
| `schema_version` | yes | must be `1` |

## Sub-phase 4.1 — dry-run reconcile

Before applying changes, preview the exact Caddy admin-API JSON that would
be PATCHed:

```bash
# Preview in human-readable form (default)
opec tenant reconcile --dry-run

# Preview as JSON (pipe to jq, save to file, etc.)
opec tenant reconcile --dry-run --format json | jq .

# Use a non-default yaml path
opec tenant reconcile --dry-run --yaml /tmp/tenants-draft.yaml
```

The output includes:
- `mode: dry-run` — confirms no HTTP call was made
- `tenants_count` — number of enabled tenants rendered
- `proposed_routes` — full Caddy route array for `apps/http/servers/srv0/routes`
- `patch_target` — the Caddy config path that will be PATCHed in 4.2

**Operator action: read-only.** No Caddy API calls, no file writes.
The actual PATCH arrives in sub-phase 4.2.

### Non-dry-run guard

Running `opec tenant reconcile` without `--dry-run` exits 1 in sub-phase 4.1:

```
opec error: real PATCH not yet implemented; use --dry-run in sub-phase 4.1.
```

This is intentional — 4.2 implements the HTTP client.
