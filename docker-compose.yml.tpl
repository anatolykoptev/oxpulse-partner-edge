# Rendered by install.sh → /etc/oxpulse-partner-edge/docker-compose.yml
# DO NOT EDIT DIRECTLY — regenerated on reinstall / upgrade.
#
# Placeholders (all substituted at install time):
#   {{PARTNER_ID}} {{PARTNER_DOMAIN}} {{BACKEND_ENDPOINT}}
#   {{TURN_SECRET}} {{REALITY_UUID}} {{REALITY_PUBLIC_KEY}} {{REALITY_SHORT_ID}}
#   {{REALITY_SERVER_NAME}} {{PUBLIC_IP}} {{PRIVATE_IP}} {{IMAGE_VERSION}}
#   {{SFU_UDP_PORT}} {{SFU_METRICS_PORT}}
# SFU_SIGNING_PUBLIC_KEY is NOT a template placeholder — the sfu service reads it
# from env_file (sfu-keys.env), refreshed daily by oxpulse-partner-edge-refresh.sh.
#   {{SIGNALING_SFU_SECRET}}

name: oxpulse-partner-edge

services:
  caddy:
    image: ghcr.io/anatolykoptev/partner-edge-caddy:{{IMAGE_VERSION}}
    container_name: oxpulse-partner-caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      # Phase 1 canary endpoints: host-only bind so healthcheck.sh can reach them.
      - "127.0.0.1:9080:9080"
    environment:
      PARTNER_DOMAIN: "{{PARTNER_DOMAIN}}"
      PARTNER_ID: "{{PARTNER_ID}}"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy-data:/data
      - caddy-config:/config
      # Cover page for R1 Layer 2 active-probing defense (Task 3.1).
      # Partners can override by mounting their own cover/ directory.
      - ./cover:/srv/cover:ro
      # M2b.2: DB-IP mmdb for maxmind_geolocation country lookup.
      # Provisioned by install.sh; refreshed monthly by geoip-refresh.timer.
      # Read-only — Caddy only needs to read the file.
      - /var/lib/geoip:/var/lib/geoip:ro
      # Phase 3: operator override slot — conf.d/*.caddy
      # Caddyfile imports /etc/oxpulse-partner-edge/conf.d/*.caddy at the end.
      # Without this mount the import path does not exist inside the container
      # and the override slot is a silent no-op. install.sh creates conf.d/
      # with a README.txt before docker compose up, so the bind-mount source
      # always exists on the host for fresh installs.
      - ./conf.d:/etc/oxpulse-partner-edge/conf.d:ro
    depends_on:
      xray-client:
        condition: service_started
    networks:
      - edge
    extra_hosts:
      # host-gateway resolves to the bridge gateway IP (172.18.0.1 on the
      # default oxpulse-partner-edge_edge net) so caddy-l4 can reach
      # coturn:5349 — coturn runs in network_mode: host and binds every
      # host interface including the bridge gw. See Caddyfile.tpl.
      - "host.docker.internal:host-gateway"
    healthcheck:
      test: ["CMD", "wget", "-qO-", "--header=Host: localhost", "http://127.0.0.1:2019/config/"]
      interval: 30s
      timeout: 5s
      retries: 3

  xray-client:
    image: ghcr.io/anatolykoptev/partner-edge-xray:{{IMAGE_VERSION}}
    container_name: oxpulse-partner-xray
    restart: unless-stopped
    volumes:
      - ./xray-client.json:/etc/xray/config.json:ro
    networks:
      - edge
    # xray dokodemo-door on :3080 reachable only via docker network
    expose:
      - "3080"
    healthcheck:
      test: ["CMD-SHELL", "ss -ltn | grep -q ':3080' || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3

  coturn:
    image: ghcr.io/anatolykoptev/partner-edge-coturn:{{IMAGE_VERSION}}
    container_name: oxpulse-partner-coturn
    restart: unless-stopped
    network_mode: host        # TURN needs real public IP + UDP relay ports
    environment:
      TURN_SECRET: "{{TURN_SECRET}}"
      REALM: "{{PARTNER_DOMAIN}}"
      PUBLIC_IPV4: "{{PUBLIC_IP}}"
      PRIVATE_IPV4: "{{PRIVATE_IP}}"
      PARTNER_ID: "{{PARTNER_ID}}"
    volumes:
      - ./coturn.conf:/etc/coturn/turnserver.conf:ro
      - coturn-log:/var/log/turnserver
      # Read-only share of Caddy's ACME cert storage. coturn.conf.tpl references
      # /data/caddy/certificates/.../turns-sub.DOMAIN.crt from this mount.
      # Caddy container sets $XDG_DATA_HOME=/data, so the volume root holds
      # `caddy/certificates/...` — mount at /data (not /data/caddy) so the
      # in-container path mirrors Caddy's view. Renewals trigger systemd path
      # unit → docker exec coturn kill -USR2 1 (Task 2A.5 wires that).
      - caddy-data:/data:ro
    healthcheck:
      test: ["CMD-SHELL", "pgrep turnserver >/dev/null || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3

  # M2.1: str0m-based SFU co-located with coturn on partner-edge. Host
  # networking mirrors coturn — UDP media wants the real public IP and no NAT
  # translation. Media port defaults to 7878/udp (avoids coturn's 3478); the
  # Prometheus /metrics endpoint listens on 8878/tcp (rendered via healthcheck).
  sfu:
    image: ghcr.io/anatolykoptev/partner-edge-sfu:{{IMAGE_VERSION}}
    container_name: oxpulse-partner-sfu
    restart: unless-stopped
    network_mode: host
    depends_on:
      - caddy
    # Phase 2: Ed25519 signing pubkey for asymmetric relay-JWT verification is
    # supplied via env_file — NOT a baked `environment:` literal. A literal is
    # fixed at container creation and can never track a central key rotation, so
    # after any rotation the SFU would pin the stale pubkey forever and every
    # relay JWT would silently fall back to HS256 (epoch_apply_gap). The compose
    # CLI reads this file on the host at (re)creation; oxpulse-partner-edge-refresh.sh
    # rewrites it daily from /api/partner/keys and recreates the sfu service on
    # change, so a rotation propagates within one refresh cycle.
    #   - Absolute /var/lib path: compose runs from /etc/oxpulse-partner-edge
    #     (WorkingDirectory in oxpulse-partner-edge.service), but the file lives
    #     in the runtime state dir written by install (opec secrets
    #     sfu-signing-key) and by the daily refresh (PREFIX_LIB).
    #   - required: false — the whole stack must still boot when the key has not
    #     yet been provisioned (opec Ok-returns without writing an empty key).
    #     The SFU then falls back to HS256 / SIGNALING_SFU_SECRET, matching the
    #     previous empty-literal behaviour, until refresh writes the key + recreates.
    #     (env_file object form requires Docker Compose v2.24+, shipped by
    #     get.docker.com which install.sh uses.)
    env_file:
      - path: /var/lib/oxpulse-partner-edge/sfu-keys.env
        required: false
    environment:
      # SFU_BIND_ADDRESS stays at 0.0.0.0 because the UDP media socket MUST
      # listen on the public NIC for WebRTC ICE host candidates to be routable.
      # SFU_METRICS_BIND + SFU_RELAY_API_BIND override the bind for the
      # privileged HTTP sockets (Prometheus /metrics + relay API): mesh-only,
      # so they are not reachable from the public internet regardless of
      # host firewall state. Audit 2026-05-21 found these were leaking on the
      # public NIC across all 3 production partners. AWG_HOST_IP is the
      # partner's own mesh IP without CIDR prefix (e.g. 10.9.0.6 for
      # edge-b), stripped from AWG_ALLOCATED_IP (e.g. 10.9.0.6/24) which
      # central returns with prefix for awg0.conf. SFU v0.12.67+ strict
      # getaddrinfo rejects the /24 form. Empty when mesh disabled — SFU
      # then falls back to bind_address.
      SFU_BIND_ADDRESS: "0.0.0.0"
      SFU_METRICS_BIND: "{{AWG_HOST_IP}}"
      SFU_RELAY_API_BIND: "{{AWG_HOST_IP}}"
      SFU_UDP_PORT: "{{SFU_UDP_PORT}}"
      SFU_METRICS_PORT: "{{SFU_METRICS_PORT}}"
      # Per-edge label baked into every Prometheus series via the SFU's
      # const_label registry. Empty → "local" (default), which collides
      # with other edges in the central Prom view. Convention: <partner>1.
      SFU_EDGE_ID: "{{SFU_EDGE_ID}}"
      # OpenTelemetry trace export — empty / unset = exporter disabled at SFU
      # init (zero overhead). When set by install.sh from the central's awg
      # response (typical: http://10.9.0.2:4317), spans flow through awg0
      # to the central Jaeger.
      OTEL_EXPORTER_OTLP_ENDPOINT: "{{OTEL_EXPORTER_OTLP_ENDPOINT}}"
      RUST_LOG: "info"
      RELAY_JWT_SECRET: "{{RELAY_JWT_SECRET}}"
      SFU_RELAY_API_PORT: "8912"
      PARTNER_ID: "{{PARTNER_ID}}"
      # SFU_SIGNING_PUBLIC_KEY is injected from env_file (sfu-keys.env), NOT here.
      # A value under `environment:` would override env_file (compose precedence)
      # and re-introduce the stale-key bug, so it MUST NOT be listed in this block.
      # Phase 7 M4.A5 — client-facing WS endpoint /sfu/ws/{room_id}.
      # Caddy reverse_proxies to host.docker.internal:8920 (see Caddyfile).
      # The endpoint binds only when SIGNALING_SFU_SECRET is non-empty —
      # without an HS256 secret the SFU has no way to verify browser
      # room JWTs and refuses to expose an unauthenticated entry point.
      SFU_CLIENT_WS_PORT: "8920"
      SIGNALING_SFU_SECRET: "{{SIGNALING_SFU_SECRET}}"
      # Phase 7 M4.A6 — public IP advertised in WebRTC host candidates.
      # Without this the SFU emits `0.0.0.0:N` host candidates (the bind
      # address) and off-box browsers cannot complete ICE. The value
      # comes from install.sh `$PUBLIC_IP` autodetect (cloud metadata →
      # ipify → ifconfig.me). Operators may override at compose render
      # time via OXPULSE_PUBLIC_IP. Falls back to bind address when empty.
      SFU_PUBLIC_IP: "{{PUBLIC_IP}}"
    # 2026-05-06 post-mortem: probe all three planes (metrics, client_ws,
    # relay API). Previously only /metrics on {{SFU_METRICS_PORT}} was
    # checked; that listener starts independently of feature gates so
    # the container stayed green for 8 weeks while client_ws on :8920
    # was silently disabled (SIGNALING_SFU_SECRET unset). The TCP probes
    # use `nc -z` from netcat-openbsd, added to the runtime image in
    # the same bundle (images/Dockerfile.sfu).
    #
    # Round-2 review fix: gate the client_ws / relay-API probes on the
    # same env vars main.rs gates the listeners on, and honour
    # SFU_CLIENT_WS_PORT / SFU_RELAY_API_PORT env overrides. CMD-SHELL
    # is a /bin/sh -c context, so $VAR expands at container runtime
    # against the service's environment block.
    #
    # Bug #4 fix (2026-05-28 edge-d): SFU metrics and relay-API listeners bind
    # on the mesh IP (mesh-only, not 0.0.0.0). Probing 127.0.0.1 for those
    # planes → connection refused → container marked unhealthy → false
    # positive operator alarm. client_ws stays on 127.0.0.1 (SFU_BIND_ADDRESS
    # is 0.0.0.0).
    #
    # 2026-07-08 fix (env-var-by-construction, edge-d failingstreak=19471):
    # the Bug #4 fix above originally substituted the raw {{AWG_ALLOCATED_IP}}
    # template placeholder here — but that placeholder INTENTIONALLY keeps its
    # /CIDR suffix (e.g. 10.9.0.7/24, needed by `ip addr add` / awg0.conf
    # elsewhere), which a URL host / nc target cannot parse. That made this
    # healthcheck a SECOND, independently-drifting source of the mesh IP,
    # out of sync with the environment: block above which already derives the
    # CIDR-stripped {{AWG_HOST_IP}} into SFU_METRICS_BIND / SFU_RELAY_API_BIND
    # (see install.sh:744 AWG_HOST_IP="${AWG_ALLOCATED_IP%%/*}"). Referencing
    # ${SFU_METRICS_BIND} / ${SFU_RELAY_API_BIND} — the container's own
    # runtime env vars, already expanded in this CMD-SHELL context (see the
    # "Round-2 review fix" comment above) — collapses both probes onto the
    # SAME write site as the environment: block, eliminating the whole class
    # of "two placeholders that can independently drift" rather than just
    # swapping one drifted value for a fresher one. Empty bind (mesh
    # disabled) → probe fails → unhealthy (correct: SFU shouldn't run
    # without mesh) — same fail-closed behaviour as before.
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://${SFU_METRICS_BIND}:{{SFU_METRICS_PORT}}/metrics >/dev/null 2>&1 && { [ -z \"$SIGNALING_SFU_SECRET\" ] || nc -z 127.0.0.1 \"${SFU_CLIENT_WS_PORT:-8920}\"; } && { [ -z \"$RELAY_JWT_SECRET\" ] || nc -z ${SFU_RELAY_API_BIND} \"${SFU_RELAY_API_PORT:-8912}\"; } || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s

  # ── CH3 Hysteria2 client (fallback) ─────────────────────────────────────
  # Started only when install.sh renders hysteria2-client.yaml (backend
  # provisioned CH3). Activated via `docker compose --profile ch3 up -d`.
  # Traffic: QUIC + salamander obfuscation → looks like random UDP noise.
  # tcpForwarding listener on 127.0.0.1:18443 for local proxying.
  hysteria2-client:
    image: tobyxdd/hysteria:v2.8.2
    container_name: oxpulse-partner-hysteria2
    profiles: [ch3]
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./hysteria2-client.yaml:/etc/hysteria/config.yaml:ro
    command: ["client", "--config", "/etc/hysteria/config.yaml"]
    healthcheck:
      # Probe the local tcpForwarding listener that Hysteria2 exposes.
      test: ["CMD-SHELL", "nc -z 127.0.0.1 18443 || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 15s
    labels:
      oxpulse.channel: "hy2"
      oxpulse.phase: "1.7"

  # ── CH5 NaiveProxy client ───────────────────────────────────────────────────
  # HTTP/2 CONNECT proxy tunnelled over TLS:443 — ТСПУ-resilient channel.
  # Activated via `docker compose --profile ch5 up -d` (same pattern as CH3).
  # compose_strip_failed_channels() in lib/render-channel-lib.sh still removes
  # this block post-render as a defence-in-depth fallback when NAIVE_SERVER unset.
  # Image: partner-edge-naive (klzgrad/naiveproxy wrapper, Task 8).
  # Port bound to 127.0.0.1 only — Caddy reverse_proxy is the sole consumer.
  naive:
    image: ghcr.io/anatolykoptev/partner-edge-naive:{{IMAGE_VERSION}}
    container_name: oxpulse-partner-naive
    profiles: [ch5]
    restart: unless-stopped
    networks:
      - edge
    ports:
      - "127.0.0.1:{{NAIVE_SOCKS_PORT}}:{{NAIVE_SOCKS_PORT}}"
    volumes:
      - /etc/oxpulse-partner-edge/naive-client.json:/etc/naive/config.json:ro
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

volumes:
  caddy-data:
  caddy-config:
  coturn-log:

networks:
  edge:
    driver: bridge
