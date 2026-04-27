# Rendered by install.sh → /etc/oxpulse-partner-edge/docker-compose.yml
# DO NOT EDIT DIRECTLY — regenerated on reinstall / upgrade.
#
# Placeholders (all substituted at install time):
#   {{PARTNER_ID}} {{PARTNER_DOMAIN}} {{BACKEND_ENDPOINT}}
#   {{TURN_SECRET}} {{REALITY_UUID}} {{REALITY_PUBLIC_KEY}} {{REALITY_SHORT_ID}}
#   {{REALITY_SERVER_NAME}} {{PUBLIC_IP}} {{PRIVATE_IP}} {{IMAGE_VERSION}}
#   {{SFU_UDP_PORT}} {{SFU_METRICS_PORT}} {{SFU_SIGNING_PUBLIC_KEY}}
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
    environment:
      SFU_BIND_ADDRESS: "0.0.0.0"
      SFU_UDP_PORT: "{{SFU_UDP_PORT}}"
      SFU_METRICS_PORT: "{{SFU_METRICS_PORT}}"
      RUST_LOG: "info"
      RELAY_JWT_SECRET: "{{RELAY_JWT_SECRET}}"
      SFU_RELAY_API_PORT: "8912"
      PARTNER_ID: "{{PARTNER_ID}}"
      # Phase 2: Ed25519 public key for asymmetric relay JWT verification.
      # Fetched from /api/partner/keys at install time; refreshed daily by
      # oxpulse-partner-edge-refresh.sh (written to sfu-keys.env).
      SFU_SIGNING_PUBLIC_KEY: "{{SFU_SIGNING_PUBLIC_KEY}}"
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
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://127.0.0.1:{{SFU_METRICS_PORT}}/metrics >/dev/null 2>&1 || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s

  # ── CH3 Hysteria2 client (fallback) ─────────────────────────────────────
  # Uncomment and set HYSTERIA2_* env vars when CH3 is provisioned by backend.
  # hysteria2-client:
  #   image: ghcr.io/apernet/hysteria:app-v2.8.1
  #   container_name: oxpulse-partner-hysteria2
  #   restart: unless-stopped
  #   network_mode: host
  #   volumes:
  #     - ./hysteria2-client.yaml:/etc/hysteria/config.yaml:ro
  #   command: ["client", "--config", "/etc/hysteria/config.yaml"]

  # ── CH5 NaiveProxy client (fallback) ────────────────────────────────────
  # Uncomment and set NAIVE_* env vars when CH5 is provisioned by backend.
  # naive-client:
  #   image: ghcr.io/klzgrad/naiveproxy:v130.0.6723.58-1
  #   container_name: oxpulse-partner-naive
  #   restart: unless-stopped
  #   network_mode: host
  #   volumes:
  #     - ./naive-client.json:/config.json:ro
  #   command: ["/config.json"]

volumes:
  caddy-data:
  caddy-config:
  coturn-log:

networks:
  edge:
    driver: bridge
