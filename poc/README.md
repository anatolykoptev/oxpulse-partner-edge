# PoC — TURNS-on-443 Decision Gate

Sandbox for comparing Variant A' (caddy-l4 unified) vs Variant B (nginx stream sidecar).

## Purpose

Empirically validate which architectural variant to ship in partner-edge v0.2.0.
Measurement in Task 1.2. Design decision locked in Task 1.3.

## Setup

Both variants run on loopback (`127.0.0.1:18443` → container `:443`) to avoid
conflict with any real Caddy/nginx on the host. Self-signed certs via Caddy's
local CA (Variant A') or openssl init (Variant B).

**Requires Docker Compose ≥ v2.17** — Variant A' uses `dockerfile_inline`, which
older versions reject with a YAML parse error. Check: `docker compose version`.

**Only ONE variant at a time** — both bind `127.0.0.1:18443`, so starting the
second while the first is up fails with a port-bind error. Always `docker compose
down -v` before switching.

## Running Variant A'

```bash
cd deploy/partner-edge/poc/a-prime
docker compose up -d --build    # build is needed for caddy-l4 image
# Wait ~30s for Caddy to settle
```

## Running Variant B

```bash
cd deploy/partner-edge/poc/b
docker compose up -d
```

## Testing with curl

Use `--resolve` to bypass DNS:

```bash
# Main SNI — should return Caddy's "PoC app response OK"
curl -vk --resolve example.test:18443:127.0.0.1 \
     https://example.test:18443/

# TURNS SNI — A': should reach coturn (TLS handshake OK, then STUN/TURN protocol)
#              B': same (nginx routes by SNI)
openssl s_client -connect 127.0.0.1:18443 \
     -servername turns.example.test -showcerts </dev/null 2>&1 | head -30
```

## Teardown

```bash
docker compose down -v    # -v removes volumes (cert cache, caddy data)
```

## Task 1.2 will add

- `measure.sh` — automated JA3/latency/cert-renewal/H3-fallthrough measurements
- `results.md` — empirical comparison and recommendation

## Known PoC limitations

- Loopback binding only — does NOT exercise real-world host-network coturn topology
- Self-signed certs — cert renewal logic not fully testable
- No ACME test — PoC does not exercise the HTTP-01 / disable_tls_alpn_challenge gotcha
- nginx `network_mode: host` (Variant B production target) is NOT used here —
  bridge is used for isolation. Real prod nginx config will need host-net for
  host's `127.0.0.1:8443` Caddy reachability.

Production validation (Phase 3) will exercise the full topology.
