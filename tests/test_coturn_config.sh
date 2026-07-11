#!/bin/bash
# Structural validation of coturn.conf.tpl for Phase 3A v0.2.0.
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-/home/user/src/oxpulse-partner-edge}"
TPL="$REPO_ROOT/coturn.conf.tpl"

# TLS enablement + cert
grep -qE '^no-tls\b' "$TPL" && { echo "FAIL: no-tls still present — TLS disabled"; exit 1; }
grep -qE '^tls-listening-port=5349' "$TPL" || { echo "FAIL: no tls-listening-port=5349"; exit 1; }
grep -q '^cert=/data/caddy/certificates/' "$TPL" || { echo "FAIL: cert= path wrong or missing"; exit 1; }
grep -q '^pkey=/data/caddy/certificates/' "$TPL" || { echo "FAIL: pkey= path wrong or missing"; exit 1; }
grep -qE '^cipher-list=' "$TPL" || { echo "FAIL: cipher-list missing"; exit 1; }
grep -qE '^no-tlsv1\b' "$TPL" || { echo "FAIL: no-tlsv1 missing"; exit 1; }
grep -qE '^no-tlsv1_1' "$TPL" || { echo "FAIL: no-tlsv1_1 missing"; exit 1; }

# Active-probing hardening (R1 L2)
grep -qE '^no-rfc5780' "$TPL" || { echo "FAIL: no-rfc5780 missing"; exit 1; }

# Rate limits (R1 §5.3)
grep -qE '^user-quota=' "$TPL" || { echo "FAIL: user-quota missing"; exit 1; }
grep -qE '^max-bps=' "$TPL" || { echo "FAIL: max-bps missing"; exit 1; }
grep -qE '^bps-capacity=' "$TPL" || { echo "FAIL: bps-capacity missing"; exit 1; }
grep -qE '^total-quota=' "$TPL" || { echo "FAIL: total-quota missing"; exit 1; }

# IPv6 denied-peer-ip (anti-SSRF)
grep -q '^denied-peer-ip=::1\b' "$TPL" || { echo "FAIL: IPv6 loopback deny missing"; exit 1; }
grep -q '^denied-peer-ip=::ffff:' "$TPL" || { echo "FAIL: IPv4-mapped IPv6 deny missing"; exit 1; }
grep -q '^denied-peer-ip=fc00::' "$TPL" || { echo "FAIL: IPv6 ULA deny missing"; exit 1; }
grep -q '^denied-peer-ip=fe80::' "$TPL" || { echo "FAIL: IPv6 link-local deny missing"; exit 1; }

# Placeholders consistent
grep -q '{{TURNS_SUBDOMAIN}}' "$TPL" || { echo "FAIL: TURNS_SUBDOMAIN placeholder missing"; exit 1; }
grep -q '{{PARTNER_DOMAIN}}' "$TPL" || { echo "FAIL: PARTNER_DOMAIN placeholder missing"; exit 1; }

echo "PASS: coturn.conf.tpl hardening checks"
