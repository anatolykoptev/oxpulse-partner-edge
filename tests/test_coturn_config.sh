#!/bin/bash
# Structural validation of coturn.conf.tpl for Phase 3A v0.2.0.
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TPL="$REPO_ROOT/coturn.conf.tpl"

# TLS enablement + cert
grep -qE '^no-tls\b' "$TPL" && { echo "FAIL: no-tls still present — TLS disabled"; exit 1; }
grep -qE '^tls-listening-port=5349' "$TPL" || { echo "FAIL: no tls-listening-port=5349"; exit 1; }
grep -q '^cert=/data/caddy/certificates/' "$TPL" || { echo "FAIL: cert= path wrong or missing"; exit 1; }
grep -q '^pkey=/data/caddy/certificates/' "$TPL" || { echo "FAIL: pkey= path wrong or missing"; exit 1; }
grep -qE '^cipher-list=' "$TPL" || { echo "FAIL: cipher-list missing"; exit 1; }

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

# Allocation lifetime cap (prevents probe allocation leak from wedging user-quota)
grep -qE ^max-allocate-lifetime=120 "$TPL" || { echo "FAIL: max-allocate-lifetime=120 missing"; exit 1; }
# allocation-default-timeout and no-loopback-peers are not options in coturn 4.6.x
# (absent from `turnserver --help`; the former is silently ignored, so it only
# looked like a control). Asserting their absence stops them creeping back.
# (Now: not options in ANY coturn version.)
# The edge image is coturn 4.18 (images/Dockerfile.coturn). There no-dtls /
# no-tlsv1 / no-tlsv1_1 no longer exist either (DTLS starts only with --dtls;
# TLS 1.0/1.1 are off by default) and an unknown key logs "Bad configuration
# format". They stay valid ONLY in relay/coturn-relay.conf.tpl (Ubuntu 4.6.1).
# Assert on the RENDERED conf, so a placeholder-driven line cannot slip past.
RENDERED="$(mktemp)"
trap 'rm -f "$RENDERED"' EXIT
sed -e 's/{{TURN_SECRET}}/throwaway-secret/g' -e 's/{{PARTNER_DOMAIN}}/example.test/g' \
    -e 's/{{TURNS_SUBDOMAIN}}/turns/g' -e 's/{{PUBLIC_IP}}/192.0.2.10/g' \
    -e 's#{{EXTERNAL_IP_LINE}}#192.0.2.10/10.0.0.5#g' \
    -e 's#{{ALLOWED_PEER_IP_LINE}}#allowed-peer-ip=10.0.0.5#g' "$TPL" > "$RENDERED"
! grep -q '{{' "$RENDERED" || { echo "FAIL: unrendered placeholder in test render"; exit 1; }
for key in allocation-default-timeout no-loopback-peers allow-loopback-peers no-dtls no-tlsv1 no-tlsv1_1; do
    if grep -qE "^${key}([=[:space:]]|$)" "$RENDERED"; then
        echo "FAIL: '${key}' rendered — not a coturn 4.18 option (or, for allow-loopback-peers, a loopback SSRF opening)"
        exit 1
    fi
done
echo "PASS: no phantom / removed coturn directives"
# NAT64 well-known prefix (GHSA-2x4g) and the IPv4-mapped range (GHSA-w4hf / GHSA-j8mm)
grep -qxF 'denied-peer-ip=64:ff9b::-64:ff9b::ffff:ffff' "$RENDERED" \
    || { echo "FAIL: NAT64 denied-peer-ip (64:ff9b::/96) missing"; exit 1; }
grep -qxF 'denied-peer-ip=::ffff:0.0.0.0-::ffff:255.255.255.255' "$RENDERED" \
    || { echo "FAIL: IPv4-mapped denied-peer-ip range missing"; exit 1; }
echo "PASS: NAT64 + IPv4-mapped peer denies present"
