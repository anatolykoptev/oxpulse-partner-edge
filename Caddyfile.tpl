# Rendered by install.sh → /etc/oxpulse-partner-edge/Caddyfile
# Placeholders: {{PARTNER_DOMAIN}}, {{TURNS_SUBDOMAIN}}
#
# Traffic split on partner edge:
#   / (SPA)         → xray-client:3080 (backend renders branded index.html)
#   /_app/immutable → xray-client:3080 BUT cached 1 year at Caddy
#   /api/*          → xray-client:3080 with X-Forwarded-Host header
#   /ws/*           → xray-client:3080 (WebSocket upgrade preserved by Caddy)
#   {{TURNS_SUBDOMAIN}}.{{PARTNER_DOMAIN}} TLS passthrough → coturn:5349
#
# caddy-l4 TURNS SNI mux: listener_wrappers peeks TLS ClientHello BEFORE Caddy
# HTTP app sees it. Matching SNI → raw TCP to coturn (coturn terminates own TLS).
# Any other SNI → falls through to HTTP app.

{
    # Global options
    # Caddy 2.11 tightened the default admin `origins` whitelist; container
    # healthcheck (`wget http://127.0.0.1:2019/config/`) started getting 403
    # "host not allowed" even though production traffic was fine. Explicit
    # origins list fixes the healthcheck without exposing admin beyond loopback.
    admin localhost:2019 {
        origins localhost 127.0.0.1
    }
    email admin@{{PARTNER_DOMAIN}}

    # M2b.2: DB-IP country lookup — DISABLED 2026-05-16.
    # The aksdb fork registered maxmind_geolocation as a global option;
    # porech v1.0.3 (current build) only exposes it as an HTTP matcher.
    # Caddy v2.11.2 rejects this block as "unrecognized global option".
    # X-Geo-Country header injections below now emit an empty string for
    # {vars.maxmind_country_code}; Rust upstream falls back to its own chain.
    # Follow-up: re-implement geo lookup using porech matcher form OR
    # a different plugin that supports a global db_path declaration.

    # NOTE: listener_wrappers MUST be at global servers{} scope — not in a
    # site-level snippet (Phase 2 PoC confirmed). layer4 applies to the listener
    # itself, not to per-site handlers.
    servers {
        # H3/QUIC disabled — ТСПУ entropy heuristic target (R1 Layer 0).
        protocols h1 h2
        # Phase 5.8: expose Prometheus metrics on localhost:2019/metrics.
        # Surfaces caddy_reverse_proxy_upstreams_healthy{upstream=...} for the
        # observability sidecar to scrape (Task 5 wires Telegram alerts off
        # this metric).
        metrics
        listener_wrappers {
            layer4 {
                @turns tls sni {{TURNS_SUBDOMAIN}}.{{PARTNER_DOMAIN}}
                route @turns {
                    # coturn runs in network_mode: host and binds 5349 on every
                    # host interface. From this Caddy container's perspective
                    # 127.0.0.1 is its own loopback (NOT the host) — wrong dest.
                    # host.docker.internal is provided by docker-compose
                    # extra_hosts: [host.docker.internal:host-gateway] and
                    # resolves to the bridge gateway, which IS a host interface
                    # coturn binds to. caddy-l4 then forwards the raw TLS TCP
                    # stream; coturn terminates its own TLS using the
                    # Caddy-issued cert mounted read-only.
                    proxy tcp/host.docker.internal:5349
                }
            }
            tls
        }
    }
    # Phase 1: structured JSON access logs to stdout.
    # Docker JSON driver collects to journald. Fields including request.host,
    # request.uri, resp_status, duration_ms, upstream_status,
    # upstream_duration_ms, upstream_address are emitted automatically
    # by caddy when format=json.
    log {
        format json
        level INFO
    }

}

# Phase 2: tunnel_upstream snippet — collapses the 4 repeated reverse_proxy
# blocks (api, ws, events, SPA fallback) into a single authoritative definition.
# {args[0]} receives the path pattern from `import tunnel_upstream /api/*`.
# A second snippet (tunnel_upstream_default) handles the no-path catch-all SPA
# fallback where there is no route argument.
(tunnel_upstream) {
    reverse_proxy {args[0]} xray-client:3080 {{HY2_FALLBACK_HOST}}:{{HY2_FALLBACK_PORT}} {
        lb_policy first
        lb_try_duration 5s
        lb_try_interval 250ms
        health_uri /api/health
        health_interval 10s
        health_timeout 3s
        health_status 2xx
        health_passes 2
        health_fails 3
        header_up X-Forwarded-Host {{PARTNER_DOMAIN}}
        header_up X-Forwarded-Proto https
        header_up Host oxpulse.chat
        header_up X-Geo-Country {vars.maxmind_country_code}
    }
}

(tunnel_upstream_default) {
    reverse_proxy xray-client:3080 {{HY2_FALLBACK_HOST}}:{{HY2_FALLBACK_PORT}} {
        lb_policy first
        lb_try_duration 5s
        lb_try_interval 250ms
        health_uri /api/health
        health_interval 10s
        health_timeout 3s
        health_status 2xx
        health_passes 2
        health_fails 3
        header_up X-Forwarded-Host {{PARTNER_DOMAIN}}
        header_up X-Forwarded-Proto https
        header_up Host oxpulse.chat
        header_up X-Geo-Country {vars.maxmind_country_code}
    }
}

{{PARTNER_DOMAIN}} {
    encode gzip zstd

    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        X-Content-Type-Options "nosniff"
        Referrer-Policy "no-referrer"
        X-Frame-Options "DENY"
        -Server
        -Via
        -Alt-Svc
    }

    # Active-probing defense removed 2026-04-20: the @probe matcher +
    # cover decoy combination interacted badly with Service Worker
    # precache (SW install fetches '/' with mode='cors' → matched as
    # probe → SW cached cover as the "/" response) and with Arc's
    # aggressive storage handling. Net effect was breaking legitimate
    # first visits instead of hiding the service from scanners. If we
    # need DPI defense again, do it at a different layer (fail2ban /
    # WAF rule on edge IP by UA fingerprint) so it never touches the
    # SPA contract. cover.html is still shipped for backwards-compat
    # with /etc/oxpulse-partner-edge/cover bind mount but unreachable.


    # Relay API — JWT-authenticated cascade relay endpoint.
    # Called by the signaling server for multi-region room bridging.
    # Routes directly to SFU relay port (not through tunnel).
    handle /relay/* {
        reverse_proxy host.docker.internal:8912
    }

    # Phase 7 M4.A5 — client-facing SFU WebSocket endpoint.
    # Browsers connect here with a room JWT in Sec-WebSocket-Protocol.
    # The SFU container runs network_mode: host, so 8920 is reachable via
    # the bridge gateway alias `host.docker.internal` (see extra_hosts in
    # docker-compose.yml.tpl). Caddy auto-handles the WS upgrade for any
    # reverse_proxy upstream (Connection/Upgrade headers preserved).
    # `handle` (not `handle_path`) keeps the full /sfu/ws/{room_id} path
    # so the SFU's axum router matches.
    # Port 8920 chosen because 8911 is squatted on krolik (San Jose).
    handle /sfu/ws/* {
        reverse_proxy host.docker.internal:8920
    }
    # Every GET / just serves the SPA.
    handle {
        # Cache SvelteKit hashed assets for a year (immutable by filename hash).
        @immutable path_regexp /_app/immutable/.*
        header @immutable Cache-Control "public, max-age=31536000, immutable"

        # API — preserve partner domain so backend branding resolver picks right config.
        import tunnel_upstream /api/*

        # WebSocket — Caddy auto-upgrades on Upgrade: websocket.
        import tunnel_upstream /ws/*

        # Event telemetry.
        import tunnel_upstream /events/*

        # SPA fallback — everything else goes through the tunnel so backend can
        # inject partner branding into index.html before shipping to browser.
        import tunnel_upstream_default
    }
}

# Stub vhost — Caddy issues + renews cert for TURNS subdomain via ACME
# HTTP-01 on :80 (Caddy still owns :80 unmultiplexed). The cert is written
# to the caddy-data volume and bind-mounted read-only into coturn.
# Actual :443 traffic for this SNI is routed by caddy-l4 above → coturn
# before this handler ever sees it — so this respond only fires for
# ACME-challenge + any stray request that bypassed the l4 mux.
{{TURNS_SUBDOMAIN}}.{{PARTNER_DOMAIN}} {
    tls {
        issuer acme {
            # CRITICAL: once l4 routes :443 for this SNI to coturn, Caddy can
            # no longer answer TLS-ALPN-01 (which would come in on :443).
            # Force HTTP-01 which uses :80 (Caddy still owns :80).
            # Silent failure if missing: cert renewal stops after 90 days.
            # Source: scratch/B-certs-client-security.md §1.1
            disable_tlsalpn_challenge
        }
    }
    respond 421
}

# =============================================================================
# Phase 1 canary site -- 127.0.0.1:9080 ONLY, never publicly exposed.
# Provides 4 diagnostic endpoints for healthcheck.sh and operators.
# DO NOT add to any public-facing listener or firewall rule.
# =============================================================================
http://127.0.0.1:9080 {
    # /canary/tunnel -- probe xray-client via /health path.
    # 2xx = tunnel reachable; non-2xx = upstream sick but container up.
    handle /canary/tunnel {
        reverse_proxy xray-client:3080/health {
            transport http {
                dial_timeout 2s
                response_header_timeout 2s
            }
        }
    }

    # /canary/upstream -- bypass tunnel health path, hit xray-client directly.
    # If this fails too, the xray-client container itself is down.
    handle /canary/upstream {
        reverse_proxy xray-client:3080 {
            transport http {
                dial_timeout 2s
                response_header_timeout 2s
            }
        }
    }

    # /canary/config-hash -- sha256 of the rendered Caddyfile.
    # install.sh writes CADDYFILE_SHA to install.env; healthcheck.sh check 15
    # compares these to detect operator drift edits.
    handle /canary/config-hash {
        respond "__CADDYFILE_SHA__" 200
    }

    # /canary/route-table -- static route manifest.
    # Placeholder for Phase 5 introspection; used now to confirm canary is live.
    handle /canary/route-table {
        respond `{"routes":["tunnel","sfu","relay","branding"]}` 200
    }
}

# =============================================================================
# Phase 3: operator override slot — conf.d/*.caddy
#
# Files placed in /etc/oxpulse-partner-edge/conf.d/ are loaded AFTER the
# rendered Caddyfile. They survive install.sh / update.sh / upgrade.sh reruns
# because those scripts never touch files inside conf.d/.
#
# Use cases:
#   - Per-tenant vhosts (e.g. cheburator.bot + www.cheburator.bot static sites)
#   - Hand-crafted route additions (webhook proxies, emergency overrides)
#   - Emergency patches that must survive the next scheduled upgrade
#
# File naming convention: <tenant>-<purpose>.caddy
#   Example: cheburator-vhosts.caddy
#
# Empty directory: Caddy emits a warning but exits 0 (validated 2026-05-15).
# Do NOT place secrets in conf.d/ files — they are world-readable by default.
# See docs/runbooks/conf-d.md for full guidance.
# =============================================================================
import /etc/oxpulse-partner-edge/conf.d/*.caddy
