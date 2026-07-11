#!/bin/bash
# Regression guard for the v0.12.20 edge-c rollback incident (2026-05-09).
#
# Incident: upgrade to v0.12.20 triggered an auto-rollback to v0.11.8 because
#   healthcheck checks 2 (API /api/health) and 10 (SPA GET /) failed after the
#   post-up "sleep 5" wait. Root cause: xray 26.5.3 with "randomized" uTLS
#   fingerprint performs per-connection TLS ClientHello diversification, which
#   adds ~3-6s to first-connection Reality tunnel establishment on cold start.
#   Combined with the existing 5s sleep, check 10's wget --timeout=5 expired
#   before Caddy received the SPA response from the xray→Reality tunnel.
#
# Fix:
#   1. upgrade.sh post-up sleep raised from 5s to 10s (this test guards that).
#   2. Both the post-upgrade sleep and the rollback sleep are updated.
#
# Note on fingerprint: "randomized" is intentional (CVE-2026-27017 mitigation,
#   PR #79). Do NOT add a test that enforces "chrome" — that would reverse the
#   security fix. The template fingerprint is NOT tested here.
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TPL="$REPO_ROOT/xray-client.json.tpl"
UPGRADE="$REPO_ROOT/upgrade.sh"

[[ -f "$TPL" ]] || { echo "FAIL: xray-client.json.tpl not found at $TPL"; exit 1; }
[[ -f "$UPGRADE" ]] || { echo "FAIL: upgrade.sh not found at $UPGRADE"; exit 1; }

# 1. Template must be valid JSON when placeholders are substituted.
rendered=$(sed \
    -e 's/{{REALITY_UUID}}/00000000-0000-0000-0000-000000000000/g' \
    -e 's/{{REALITY_ENCRYPTION}}/none/g' \
    -e 's/{{REALITY_PUBLIC_KEY}}/testpubkey123/g' \
    -e 's/{{REALITY_SHORT_ID}}/abcd1234/g' \
    -e 's/{{REALITY_SERVER_NAME}}/samsung.com/g' \
    -e 's/{{BACKEND_HOST}}/192.0.2.1/g' \
    -e 's/{{BACKEND_PORT}}/5349/g' \
    -e 's/{{BACKEND_ENDPOINT}}/192.0.2.1:5349/g' \
    -e 's/{{XRAY_XHTTP_MODE}}/packet-up/g' \
    -e 's/{{XRAY_XHTTP_PATH}}/\/xh/g' \
    -e 's/{{XRAY_XHTTP_XMUX_MAX_CONCURRENCY}}/1/g' \
    -e 's/{{XRAY_XHTTP_XMUX_C_MAX_REUSE_TIMES}}/64/g' \
    -e 's/{{XRAY_XHTTP_XMUX_C_MAX_LIFETIME_MS}}/15000/g' \
    -e 's/{{XRAY_XHTTP_X_PADDING_BYTES}}/100-1000/g' \
    "$TPL")

echo "$rendered" | python3 -m json.tool >/dev/null 2>&1 \
    || { echo "FAIL: xray-client.json.tpl does not produce valid JSON after placeholder substitution"; exit 1; }

# 2. The rendered realitySettings block must contain the required fields.
echo "$rendered" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for ob in d.get('outbounds', []):
    rs = ob.get('streamSettings', {}).get('realitySettings', {})
    if rs:
        for field in ['serverName', 'publicKey', 'shortId', 'fingerprint']:
            if field not in rs:
                print(f'FAIL: realitySettings missing field: {field}')
                sys.exit(1)
        sys.exit(0)
print('FAIL: no realitySettings block found in outbounds')
sys.exit(1)
" || exit 1

# 3. Cold-start settle margin before the post-upgrade healthcheck gate.
#    xray with a randomized fingerprint takes up to 8s to establish the Reality
#    tunnel on first connection; a fixed 5s sleep was insufficient (v0.12.20
#    rollback incident). That fragile fixed post-up `sleep` was REPLACED by
#    settle_healthcheck_with_retry() (upgrade.sh), which POLLS healthcheck every
#    3s up to a total budget (OXPULSE_UPGRADE_HEALTH_TIMEOUT, default 30s) — the
#    actual fix, strictly more robust than any fixed sleep. Assert the polling
#    settle gate is defined, invoked, and its total budget is ≥10s (the minimum
#    margin the old fixed-sleep guard demanded).
grep -qE '^settle_healthcheck_with_retry\(\)' "$UPGRADE" \
    || { echo "FAIL: settle_healthcheck_with_retry() not defined — cold-start settle gate missing"; exit 1; }
grep -qE 'settle_healthcheck_with_retry[[:space:]]+"' "$UPGRADE" \
    || { echo "FAIL: settle_healthcheck_with_retry not invoked (no call site) — post-upgrade gate not wired"; exit 1; }
settle_budget=$(grep -oE 'OXPULSE_UPGRADE_HEALTH_TIMEOUT:-[0-9]+' "$UPGRADE" | head -1 | grep -oE '[0-9]+$')
[[ "${settle_budget:-0}" -ge 10 ]] \
    || { echo "FAIL: settle budget is ${settle_budget:-missing}s (need ≥10s); xray Reality tunnel startup takes up to 8s"; exit 1; }

# 4. The rollback path must also give a ≥10s settle before its healthcheck
#    (same xray startup concern). The rollback-mode block still uses a fixed
#    sleep; anchor on the rollback-mode marker and read the first NUMERIC sleep
#    (ignoring poll-loop `sleep "$interval"` lines).
rollback_sleep=$(awk '
    /---- --rollback mode ----/ { in_rollback=1 }
    in_rollback && /^[[:space:]]*sleep [0-9]/ { match($0, /[0-9]+/); print substr($0, RSTART, RLENGTH); exit }
' "$UPGRADE")

[[ "${rollback_sleep:-0}" -ge 10 ]] \
    || { echo "FAIL: upgrade.sh rollback settle sleep is ${rollback_sleep:-missing}s (need ≥10s)"; exit 1; }

# 5. Sanity: upgrade.sh still parses.
bash -n "$UPGRADE" || { echo "FAIL: upgrade.sh has syntax errors"; exit 1; }

echo "OK: xray-client.json.tpl is valid JSON with required realitySettings fields; upgrade.sh waits ≥10s before healthcheck in both upgrade and rollback paths"
