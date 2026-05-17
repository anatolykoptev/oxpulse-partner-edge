# Rendered by install.sh/hydrate.sh → /etc/oxpulse-partner-edge/coturn.conf
# DO NOT EDIT DIRECTLY — regenerated on reinstall / upgrade.
#
# Placeholders (substituted at render time):
#   {{TURN_SECRET}} {{PARTNER_DOMAIN}} {{TURNS_SUBDOMAIN}}
#   {{PUBLIC_IP}} {{EXTERNAL_IP_LINE}}
#
# Architecture (v0.2.0+):
# - TLS enabled on 5349 — caddy-l4 proxies TURNS:443 → 127.0.0.1:5349 (host network)
# - Cert issued by Caddy via ACME HTTP-01 for {{TURNS_SUBDOMAIN}}.{{PARTNER_DOMAIN}},
#   shared with coturn via read-only docker volume mount (see docker-compose.yml.tpl)
# - SIGUSR2 reloads cert without session drop (verified in coturn source
#   mainrelay.c:3422 → reload_ssl_certs handler)

# ─── Ports ──────────────────────────────────────────────────────────────
listening-port=3478
alt-listening-port=3479
tls-listening-port=5349

# ─── Auth: HMAC shared-secret (RFC 7635) ────────────────────────────────
fingerprint
lt-cred-mech
use-auth-secret
static-auth-secret={{TURN_SECRET}}
realm={{PARTNER_DOMAIN}}

# ─── Capacity / rate limits (R1 §5.3) ───────────────────────────────────
# Sized for ~100 concurrent calls. Each call has ~2 TURN channels.
total-quota=250
# Per-credential limit: handles multi-tab/multi-device; blocks runaway abuse.
user-quota=4
# Bandwidth cap per session: 2 Mbps (video call at 1080p30 peaks ~1.5 Mbps).
max-bps=250000
# Total server bandwidth cap: 200 Mbps conservative.
bps-capacity=25000000
stale-nonce=600

# ─── Peer policy ────────────────────────────────────────────────────────
no-loopback-peers
no-multicast-peers
no-tcp-relay
# R1 Layer 2: suppress STUN NAT-behavior-discovery response to active probers.
no-rfc5780

# ─── TLS cert / cipher hardening ────────────────────────────────────────
# Cert path inside the coturn container — Caddy's named volume mounted read-only
# at /data/caddy (see docker-compose.yml.tpl in Task 2A.4). Caddy's cert storage
# layout for ACME HTTP-01 issuer is documented + stable across Caddy 2.x.
cert=/data/caddy/certificates/acme-v02.api.letsencrypt.org-directory/{{TURNS_SUBDOMAIN}}.{{PARTNER_DOMAIN}}/{{TURNS_SUBDOMAIN}}.{{PARTNER_DOMAIN}}.crt
pkey=/data/caddy/certificates/acme-v02.api.letsencrypt.org-directory/{{TURNS_SUBDOMAIN}}.{{PARTNER_DOMAIN}}/{{TURNS_SUBDOMAIN}}.{{PARTNER_DOMAIN}}.key
# TLS version floor: drop 1.0/1.1 (R1 §5.5).
no-tlsv1
no-tlsv1_1
# Cipher-list aligned with Caddy/Go defaults — narrows JA3S divergence between
# Caddy and coturn TLS stacks (design §4.2 Conflict 2). Not perfect alignment
# (extension ordering + GREASE differ), but narrows flaggable anomaly surface.
cipher-list="ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384"
no-dtls

# ─── Anti-SSRF denied-peer-ip (IPv4 + IPv6) ─────────────────────────────
# Source: BBB template via scratch/C §BBB + scratch/B §3 IPv6 additions.
denied-peer-ip=0.0.0.0-0.255.255.255
denied-peer-ip=10.0.0.0-10.255.255.255
denied-peer-ip=100.64.0.0-100.127.255.255
denied-peer-ip=127.0.0.0-127.255.255.255
denied-peer-ip=169.254.0.0-169.254.255.255
denied-peer-ip=172.16.0.0-172.31.255.255
denied-peer-ip=192.0.0.0-192.0.0.255
denied-peer-ip=192.0.2.0-192.0.2.255
denied-peer-ip=192.168.0.0-192.168.255.255
denied-peer-ip=198.18.0.0-198.19.255.255
denied-peer-ip=198.51.100.0-198.51.100.255
denied-peer-ip=203.0.113.0-203.0.113.255
denied-peer-ip=224.0.0.0-239.255.255.255
denied-peer-ip=240.0.0.0-255.255.255.255
# IPv6 (coturn A-B range syntax, not CIDR)
denied-peer-ip=::1
denied-peer-ip=::ffff:0.0.0.0-::ffff:255.255.255.255
denied-peer-ip=fc00::-fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff
denied-peer-ip=fe80::-febf:ffff:ffff:ffff:ffff:ffff:ffff:ffff

# ─── Relay port range (must match firewall rules in install.sh) ─────────
min-port=49152
max-port=65535

external-ip={{EXTERNAL_IP_LINE}}

# ─── Logging ────────────────────────────────────────────────────────────
log-file=/var/log/turnserver/turn.log
pidfile=/var/run/turnserver/turnserver.pid
no-stdout-log
simple-log
syslog

no-cli
