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

    # M2b.2: DB-IP country lookup — sets {vars.maxmind_country_code} for
    # downstream header injection. If the mmdb file is absent (fresh node
    # before install.sh provisions /var/lib/geoip/) the handler is a no-op
    # and the placeholder resolves to an empty string. Rust upstream reads
    # X-Geo-Country and falls back to its own chain when the value is empty.
    maxmind_geolocation {
        db_path /var/lib/geoip/dbip-country-lite.mmdb
    }

    # NOTE: listener_wrappers MUST be at global servers{} scope — not in a
    # site-level snippet (Phase 2 PoC confirmed). layer4 applies to the listener
    # itself, not to per-site handlers.
    servers {
        # H3/QUIC disabled — ТСПУ entropy heuristic target (R1 Layer 0).
        protocols h1 h2
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
        reverse_proxy /api/* xray-client:3080 {
            header_up X-Forwarded-Host {{PARTNER_DOMAIN}}
            header_up X-Forwarded-Proto https
            header_up Host oxpulse.chat
            header_up X-Geo-Country {vars.maxmind_country_code}
        }

        # WebSocket — Caddy auto-upgrades on Upgrade: websocket.
        reverse_proxy /ws/* xray-client:3080 {
            header_up X-Forwarded-Host {{PARTNER_DOMAIN}}
            header_up X-Forwarded-Proto https
            header_up Host oxpulse.chat
            header_up X-Geo-Country {vars.maxmind_country_code}
        }

        # Event telemetry.
        reverse_proxy /events/* xray-client:3080 {
            header_up X-Forwarded-Host {{PARTNER_DOMAIN}}
            header_up X-Forwarded-Proto https
            header_up Host oxpulse.chat
            header_up X-Geo-Country {vars.maxmind_country_code}
        }

        # SPA fallback — everything else goes through the tunnel so backend can
        # inject partner branding into index.html before shipping to browser.
        reverse_proxy xray-client:3080 {
            header_up X-Forwarded-Host {{PARTNER_DOMAIN}}
            header_up X-Forwarded-Proto https
            header_up Host oxpulse.chat
            header_up X-Geo-Country {vars.maxmind_country_code}
        }
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
