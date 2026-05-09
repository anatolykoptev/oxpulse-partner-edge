#!/bin/bash
# Regression guard for the v0.12.20 rvpn rollback incident (2026-05-09).
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

# 3. upgrade.sh post-up sleep must be ≥10s.
#    xray 26.5.3 with randomized fingerprint takes up to 8s to establish
#    the Reality tunnel on first connection. 5s was insufficient (v0.12.20
#    rollback incident). Any value <10s risks a false-negative on check 10.
#
#    The 'sleep N' after 'docker compose up -d --force-recreate' (post-upgrade
#    path) is the critical one. Check both occurrences of sleep in the upgrade
#    path (post-upgrade AND rollback) are ≥10.
post_upgrade_sleep=$(awk '
    /docker compose up -d --force-recreate/ { found=1 }
    found && /^sleep / { match($0, /[0-9]+/); print substr($0, RSTART, RLENGTH); found=0 }
' "$UPGRADE" | tail -1)

[[ "${post_upgrade_sleep:-0}" -ge 10 ]] \
    || { echo "FAIL: upgrade.sh post-up sleep is ${post_upgrade_sleep:-missing}s (need ≥10s); xray 26.5.3 Reality tunnel startup takes up to 8s"; exit 1; }

# 4. The rollback path sleep must also be ≥10s (same xray startup concern).
rollback_sleep=$(awk '
    /--rollback/ { in_rollback=1 }
    in_rollback && /^[[:space:]]*sleep / { match($0, /[0-9]+/); print substr($0, RSTART, RLENGTH); exit }
' "$UPGRADE")

[[ "${rollback_sleep:-0}" -ge 10 ]] \
    || { echo "FAIL: upgrade.sh rollback sleep is ${rollback_sleep:-missing}s (need ≥10s)"; exit 1; }

# 5. Sanity: upgrade.sh still parses.
bash -n "$UPGRADE" || { echo "FAIL: upgrade.sh has syntax errors"; exit 1; }

echo "OK: xray-client.json.tpl is valid JSON with required realitySettings fields; upgrade.sh waits ≥10s before healthcheck in both upgrade and rollback paths"
