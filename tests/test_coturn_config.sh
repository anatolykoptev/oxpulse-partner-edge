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
# The rendered conf must be safe on BOTH binaries: it is written before the image
# is pulled, so a still-4.6.x container (rollback, a restart in the upgrade window,
# an edge not yet on 4.18) can read it. On 4.6.x the ABSENCE of no-dtls / no-tlsv1 /
# no-tlsv1_1 / no-cli silently turns on DTLS (5349/udp), TLS 1.0/1.1 and the telnet
# CLI; on 4.18 those four are inert (WARNING / deprecated-ERROR log lines only).
# So they MUST be present until the whole fleet is on >= 4.18 — when that is true,
# drop them from coturn.conf.tpl and flip LEGACY_KEYS below to the absent list.
# Assert on the RENDERED conf, so a placeholder-driven line cannot slip past.
RENDERED="$(mktemp)"
trap 'rm -f "$RENDERED"' EXIT
sed -e 's/{{TURN_SECRET}}/throwaway-secret/g' -e 's/{{PARTNER_DOMAIN}}/example.test/g' \
    -e 's/{{TURNS_SUBDOMAIN}}/turns/g' -e 's/{{PUBLIC_IP}}/192.0.2.10/g' \
    -e 's#{{EXTERNAL_IP_LINE}}#192.0.2.10/10.0.0.5#g' \
    -e 's#{{ALLOWED_PEER_IP_LINE}}#allowed-peer-ip=10.0.0.5#g' "$TPL" > "$RENDERED"
! grep -q '{{' "$RENDERED" || { echo "FAIL: unrendered placeholder in test render"; exit 1; }
LEGACY_KEYS="no-dtls no-tlsv1 no-tlsv1_1 no-cli"
for key in $LEGACY_KEYS; do
    [[ "$(grep -cxF "$key" "$RENDERED")" -eq 1 ]] \
        || { echo "FAIL: legacy 4.6 hardening line '${key}' must render exactly once (a 4.6 binary reading this conf would run without it)"; exit 1; }
done
echo "PASS: legacy 4.6 hardening lines present (safe on 4.6.x and 4.18)"
# Never options in any version / never wanted: allow-loopback-peers opens loopback
# SSRF, dtls starts DTLS listeners, cli starts the telnet CLI.
for key in allocation-default-timeout no-loopback-peers allow-loopback-peers dtls cli; do
    if grep -qE "^${key}([=[:space:]]|$)" "$RENDERED"; then
        echo "FAIL: '${key}' rendered — not a coturn option, or a loopback-SSRF / DTLS / CLI opening"
        exit 1
    fi
done
echo "PASS: no phantom / forbidden coturn directives"
# NAT64 well-known prefix (GHSA-2x4g) and the IPv4-mapped range (GHSA-w4hf / GHSA-j8mm)
grep -qxF 'denied-peer-ip=64:ff9b::-64:ff9b::ffff:ffff' "$RENDERED" \
    || { echo "FAIL: NAT64 denied-peer-ip (64:ff9b::/96) missing"; exit 1; }
grep -qxF 'denied-peer-ip=::ffff:0.0.0.0-::ffff:255.255.255.255' "$RENDERED" \
    || { echo "FAIL: IPv4-mapped denied-peer-ip range missing"; exit 1; }
echo "PASS: NAT64 + IPv4-mapped peer denies present"
# Every rendered key must be a coturn 4.6.1 option: the conf is read by a 4.6
# binary on rollback / in the upgrade window, where an unknown key is a startup
# warning at best. The list is the 4.6.1 `turnserver` usage (fixture header says how
# it was produced). A key only 4.18 knows (e.g. `dtls`) fails here.
OPTS46="$REPO_ROOT/tests/fixtures/coturn-4.6.1-options.txt"
[[ -s "$OPTS46" ]] || { echo "FAIL: 4.6.1 option fixture missing"; exit 1; }
while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    key="${line%%=*}"
    grep -qxF -- "$key" <(grep -v "^#" "$OPTS46") \
        || { echo "FAIL: rendered key \"${key}\" is not a coturn 4.6.1 option (4.18-only or a typo)"; exit 1; }
done < "$RENDERED"
echo "PASS: every rendered key is a coturn 4.6.1 option"
