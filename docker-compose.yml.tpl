# Rendered by install.sh → /etc/oxpulse-partner-edge/docker-compose.yml
# DO NOT EDIT DIRECTLY — regenerated on reinstall / upgrade.
#
# Placeholders (all substituted at install time):
#   {{PARTNER_ID}} {{PARTNER_DOMAIN}} {{BACKEND_ENDPOINT}}
#   {{TURN_SECRET}} {{REALITY_UUID}} {{REALITY_PUBLIC_KEY}} {{REALITY_SHORT_ID}}
#   {{REALITY_SERVER_NAME}} {{PUBLIC_IP}} {{PRIVATE_IP}} {{IMAGE_VERSION}}
#   {{SFU_UDP_PORT}} {{SFU_METRICS_PORT}}

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
      PARTNER_ID: "{{PARTNER_ID}}"
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://127.0.0.1:{{SFU_METRICS_PORT}}/metrics >/dev/null 2>&1 || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s

volumes:
  caddy-data:
  caddy-config:
  coturn-log:

networks:
  edge:
    driver: bridge
