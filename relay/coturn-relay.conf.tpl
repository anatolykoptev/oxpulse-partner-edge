# Relay-only node coturn config. Rendered ONLY by:
#   opec render coturn --tpl coturn-relay.conf.tpl --out <conf> --secret-file <node-secret>
# Holds the node's own TURN secret(s) and nothing else; no registration, no
# backend-issued material. Do not edit the rendered file.

# ─── Ports ──────────────────────────────────────────────────────────────
listening-port=3478
# TURNS on 443: the censored cohort is TLS-first.
tls-listening-port=443
external-ip={{EXTERNAL_IP}}
realm={{RELAY_HOSTNAME}}
server-name={{RELAY_HOSTNAME}}

# ─── Auth: HMAC shared-secret (RFC 7635) ────────────────────────────────
fingerprint
lt-cred-mech
use-auth-secret
# One line per node secret: two lines only during an overlap rotation.
{{STATIC_AUTH_SECRET_LINES}}

# ─── Capacity (1 vCPU / 2 GB class box) ─────────────────────────────────
total-quota=150
user-quota=16
# ~5 Mbit/s per allocation (bytes/s): HD video headroom.
max-bps=625000
bps-capacity=25000000
stale-nonce=600
max-allocate-lifetime=120

# ─── Peer policy ────────────────────────────────────────────────────────
no-multicast-peers
no-tcp-relay
no-rfc5780
no-cli
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
denied-peer-ip=::1
denied-peer-ip=::ffff:0.0.0.0-::ffff:255.255.255.255
denied-peer-ip=fc00::-fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff
denied-peer-ip=fe80::-febf:ffff:ffff:ffff:ffff:ffff:ffff:ffff
denied-peer-ip=ff00::-ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff
# NAT64 and 6to4: reach v4 space through a translator.
# ('::' must NOT be denied here: on coturn 4.6.x a bare all-zero address parses
# to the [any,any] range — addr_any() holds for both ends — and ioa_addr_in_range()
# then matches EVERY peer, IPv4 included. A zero-address peer is refused anyway
# by ioa_addr_is_zero() in ns_turn_server.c.)
denied-peer-ip=64:ff9b::-64:ff9b::ffff:ffff
denied-peer-ip=2002::-2002:ffff:ffff:ffff:ffff:ffff:ffff:ffff

# ─── Relay port range (matches the relay firewall rule set and the guard) ─
min-port=49152
max-port=65535

# ─── TLS ────────────────────────────────────────────────────────────────
# Written by the certbot deploy hook (root:turnserver 0640).
cert=/etc/oxpulse-partner-edge/relay-certs/fullchain.pem
pkey=/etc/oxpulse-partner-edge/relay-certs/privkey.pem
no-tlsv1
no-tlsv1_1
cipher-list="ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384"
no-dtls

# ─── Logging: syslog only, no verbose (verbose logs credentials) ────────
syslog
no-stdout-log
simple-log
