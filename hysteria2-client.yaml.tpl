# Rendered by oxpulse-partner-edge install.sh / update.sh.
# Phase 1.7 — hy2 as 2nd partner-edge control-plane channel.
server: {{HY2_SERVER}}

auth: {{HY2_AUTH_PASS}}

obfs:
  type: salamander
  salamander:
    password: {{HY2_OBFS_PASS}}

tls:
  insecure: true

bandwidth:
  up: 50 mbps
  down: 200 mbps

tcpForwarding:
  - listen: {{HY2_LOCAL_LISTEN}}
    remote: {{HY2_REMOTE_BACKEND}}
