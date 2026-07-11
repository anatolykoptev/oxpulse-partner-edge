# Caddy Admin API Mapping: tenants.yaml → JSON route objects

This document describes how each `tenants.yaml` route action maps to the
Caddy admin-API JSON shape used by `opec tenant reconcile`.

Reference: [Caddy admin API](https://caddyserver.com/docs/api),
`apps/http/servers/srv0/routes`.

## Top-level route object

Each enabled tenant produces one top-level Caddy route:

```json
{
  "@id": "tenant:<id>",
  "match": [{"host": ["<domain1>", "<domain2>"]}],
  "handle": [{"handler": "subroute", "routes": [...]}],
  "terminal": true
}
```

`@id` is Caddy's opaque metadata field — used by `opec` to identify
routes during diff and reconcile (PATCH by ID, not by position).

Disabled tenants (`enabled: false`) are skipped entirely.

## Route action mapping

### `action: proxy`

| YAML field | Caddy JSON |
|---|---|
| `upstream: https://host` | `upstreams[0].dial = "host:443"` |
| `upstream: http://host` | `upstreams[0].dial = "host:80"` |
| `upstream: https://…` | `transport = {"protocol":"http","tls":{}}` |
| `host_header: foo.com` | `headers.request.set.Host = ["foo.com"]` |
| *(no host_header)* | Host defaults to parsed upstream hostname |
| `sse: true` | `flush_interval = -1` (disables buffering) |

Full example (SSE proxy with TLS):

```json
{
  "match": [{"path": ["/api/landing-chat*"]}],
  "handle": [{
    "handler": "reverse_proxy",
    "upstreams": [{"dial": "webhooks.edge-a.edge-c.example:443"}],
    "transport": {"protocol": "http", "tls": {}},
    "headers": {"request": {"set": {"Host": ["webhooks.edge-a.edge-c.example"]}}},
    "flush_interval": -1
  }]
}
```

### `action: file_server`

Handler chain emitted in this order:

1. `rewrite` (if `strip_path_prefix` is set)
2. `file_server` (always)
3. `headers` with `Cache-Control` (if `cache_control` is set)

| YAML field | Caddy JSON |
|---|---|
| `root: /srv/x` | `file_server.root = "/srv/x"` |
| `try_files: ["{path}", /index.html]` | `file_server.try_files = [...]` |
| `strip_path_prefix: /static` | `rewrite.strip_path_prefix = "/static"` |
| `cache_control: "public, max-age=86400"` | `headers.response.set.Cache-Control = [...]` |

Full example (static site with SPA fallback):

```json
{
  "match": [{"path": ["/*"]}],
  "handle": [
    {"handler": "file_server", "root": "/srv/app",
     "try_files": ["{path}", "/index.html"]},
    {"handler": "headers", "response": {"set": {"Cache-Control": ["public, max-age=300"]}}}
  ]
}
```

Full example (static assets with strip):

```json
{
  "match": [{"path": ["/static/*"]}],
  "handle": [
    {"handler": "rewrite", "strip_path_prefix": "/static"},
    {"handler": "file_server", "root": "/srv/edge-a-static",
     "try_files": ["/favicon.ico"]},
    {"handler": "headers", "response": {"set": {"Cache-Control": ["public, max-age=86400"]}}}
  ]
}
```

## Redirects

Each entry in `redirects[]` produces a **separate top-level route** (not a subroute):

```json
{
  "@id": "tenant:<id>:redirect:<from_host>",
  "match": [{"host": ["<from_host>"]}],
  "handle": [{
    "handler": "static_response",
    "headers": {"Location": ["<to>"]},
    "status_code": 308
  }],
  "terminal": true
}
```

| YAML field | Caddy JSON |
|---|---|
| `from_host` | `match[0].host[0]` |
| `to` | `headers.Location[0]` |
| `permanent: true` | `status_code: 308` |
| `permanent: false` | `status_code: 307` |

## Route ordering

Within a tenant's subroute, routes appear in the order they are listed
in `tenants.yaml`. Caddy evaluates subroutes in order — first match wins.
Put more specific paths before catch-alls (`/`).

## Patch target

```
/config/apps/http/servers/srv0/routes
```

This replaces the full route array. `opec tenant reconcile` computes
which routes to add/remove/change via `@id` matching and produces a
minimal diff (sub-phase 4.2).
