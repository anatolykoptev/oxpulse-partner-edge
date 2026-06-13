#!/bin/bash
# test_caddyfile_observability.sh
# Verifies Caddyfile.tpl contains the observability + error-handling directives
# added in the 2026-06-12 incident fix:
#   1. Per-site structured JSON access log with Auth/Cookie header deletion.
#   2. handle_errors 502 503 504 block with same-origin reload behavior.
#   3. lb_retries 2 in both tunnel_upstream and tunnel_upstream_default snippets.
#
# Also renders the template and validates syntax via caddy validate if Docker is
# available (self-SKIPs when daemon is unreachable).
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TPL="$REPO_ROOT/Caddyfile.tpl"

[[ -f "$TPL" ]] || { echo "FAIL: Caddyfile.tpl not found at $TPL"; exit 1; }

echo "==> Test 1: per-site log block with format filter is present"
grep -q 'format filter' "$TPL" \
    || { echo "FAIL: 'format filter' not found in Caddyfile.tpl"; exit 1; }
grep -q 'request>headers>Authorization delete' "$TPL" \
    || { echo "FAIL: Authorization header delete filter not found"; exit 1; }
grep -q 'request>headers>Cookie delete' "$TPL" \
    || { echo "FAIL: Cookie header delete filter not found"; exit 1; }
# Per-site log must appear inside the main site block (after tunnel snippets,
# before the www redirect block).
site_log_line=$(grep -n 'format filter' "$TPL" | head -1 | cut -d: -f1)
www_redirect_line=$(grep -n 'www\.{{PARTNER_DOMAIN}}' "$TPL" | head -1 | cut -d: -f1)
[[ -n "$site_log_line" && -n "$www_redirect_line" && "$site_log_line" -lt "$www_redirect_line" ]] \
    || { echo "FAIL: format filter log block not found before www redirect block"; exit 1; }
echo "OK: per-site log with filter present at line $site_log_line"

echo "==> Test 2: handle_errors 502 503 504 block is present inside site block"
grep -q 'handle_errors 502 503 504' "$TPL" \
    || { echo "FAIL: 'handle_errors 502 503 504' not found in Caddyfile.tpl"; exit 1; }
# Block must contain {err.status_code} to pass through the 5xx status.
grep -q '{err.status_code}' "$TPL" \
    || { echo "FAIL: {err.status_code} not found (status passthrough missing)"; exit 1; }
# Must contain a self-retry mechanism (JS exponential backoff with sessionStorage).
grep -q 'sessionStorage' "$TPL" \
    || { echo "FAIL: sessionStorage-based exponential backoff not found in error page HTML"; exit 1; }
# Must NOT contain a meta-refresh tag (removed in favour of JS backoff which can back off).
if grep -q 'meta http-equiv="refresh"' "$TPL"; then
    echo "FAIL: meta-refresh tag found — removed in favour of JS exponential backoff"
    exit 1
fi
# Must NOT contain href/src/redirect to api.oxpulse.chat in rendered HTML
# (DPI risk for RU users). Comments in the template are acceptable.
if grep -v '^[[:space:]]*#' "$TPL" | grep -q 'href=.*api\.oxpulse\.chat\|src=.*api\.oxpulse\.chat\|redir.*api\.oxpulse\.chat'; then
    echo "FAIL: error page must not link or redirect to api.oxpulse.chat — same-origin reload only"
    exit 1
fi
echo "OK: handle_errors block present with status passthrough and same-origin retry"

echo "==> Test 3: lb_retries 2 present in both tunnel snippets"
retry_count=$(grep -c 'lb_retries 2' "$TPL")
[[ "$retry_count" -ge 2 ]] \
    || { echo "FAIL: expected lb_retries 2 in >= 2 snippets, found $retry_count"; exit 1; }
# Confirm in both named snippets.
grep -A 20 '(tunnel_upstream)' "$TPL" | grep -q 'lb_retries 2' \
    || { echo "FAIL: lb_retries 2 missing from (tunnel_upstream) snippet"; exit 1; }
grep -A 20 '(tunnel_upstream_default)' "$TPL" | grep -q 'lb_retries 2' \
    || { echo "FAIL: lb_retries 2 missing from (tunnel_upstream_default) snippet"; exit 1; }
echo "OK: lb_retries 2 found in both tunnel snippets (count=$retry_count)"

echo "==> Test 4: rendered Caddyfile passes caddy validate (Docker required)"
if ! docker info >/dev/null 2>&1; then
    echo "SKIP: Docker daemon not available — skipping caddy validate"
else
    PARTNER_DOMAIN=test.example.com
    TURNS_SUBDOMAIN=turns
    AWG_MOTHERLY_IP=10.9.0.2
    HY2_FALLBACK_HOST=192.0.2.1
    HY2_FALLBACK_PORT=19443
    NAIVE_SOCKS_PORT=18892
    export PARTNER_DOMAIN TURNS_SUBDOMAIN AWG_MOTHERLY_IP HY2_FALLBACK_HOST HY2_FALLBACK_PORT NAIVE_SOCKS_PORT
    rendered=$(mktemp)
    python3 - "$TPL" "$rendered" <<'PYEOF'
import os, re, sys
with open(sys.argv[1]) as f:
    tpl = f.read()
out = re.sub(r'\{\{([A-Z][A-Z0-9_]*)\}\}', lambda m: os.environ.get(m.group(1), ''), tpl)
with open(sys.argv[2], 'w') as f:
    f.write(out)
PYEOF
    validate_out=$(docker run --rm \
        -v "${rendered}:/etc/caddy/Caddyfile:ro" \
        ghcr.io/anatolykoptev/partner-edge-caddy:latest \
        caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1)
    validate_rc=$?
    rm -f "$rendered"
    if [[ $validate_rc -ne 0 ]]; then
        echo "FAIL: caddy validate returned non-zero"
        echo "$validate_out"
        exit 1
    fi
    if ! echo "$validate_out" | grep -q "Valid configuration"; then
        echo "FAIL: caddy validate did not report 'Valid configuration'"
        echo "$validate_out"
        exit 1
    fi
    echo "OK: caddy validate reports 'Valid configuration'"
fi

echo "==> Test 5: ip_mask filters present in log block"
grep -q 'request>remote_ip ip_mask' "$TPL" \
    || { echo "FAIL: request>remote_ip ip_mask not found — client IPs are not masked"; exit 1; }
grep -q 'request>client_ip ip_mask' "$TPL" \
    || { echo "FAIL: request>client_ip ip_mask not found — client IPs are not masked"; exit 1; }
echo "OK: ip_mask filters present for both remote_ip and client_ip"

echo "==> Test 6: query-string strip filter present in log block"
grep -q 'request>uri regexp' "$TPL" \
    || { echo "FAIL: request>uri regexp filter not found — query strings are not stripped"; exit 1; }
echo "OK: query-strip regexp filter present on request>uri"

echo ""
echo "PASS: all Caddyfile observability tests passed"
