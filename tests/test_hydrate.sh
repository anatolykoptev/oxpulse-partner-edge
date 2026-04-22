#!/bin/bash
# Structural sanity checks for hydrate.sh.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-/home/krolik/src/oxpulse-partner-edge}"
SCRIPT="$REPO_ROOT/deploy/partner-edge/hydrate.sh"

# 1. Script parses cleanly.
bash -n "$SCRIPT" || { echo "FAIL: bash -n failed on hydrate.sh"; exit 1; }

# 2. SENTINEL variable is defined.
grep -qE '^SENTINEL=' "$SCRIPT" || { echo "FAIL: SENTINEL= variable not found"; exit 1; }

# 3. Backend URL env var override is present (OXPULSE_BACKEND_URL).
grep -qE 'OXPULSE_BACKEND_URL' "$SCRIPT" || { echo "FAIL: OXPULSE_BACKEND_URL not referenced"; exit 1; }

# 4. Script fetches turns_subdomain from the registration response.
grep -q 'turns_subdomain' "$SCRIPT" || { echo "FAIL: turns_subdomain not referenced"; exit 1; }

# 5. POST /api/partner/register call is present.
grep -qE '/api/partner/register' "$SCRIPT" || { echo "FAIL: POST /api/partner/register not found"; exit 1; }

# 6. Caddy ACME wait with failure exit is present.
grep -qE 'Caddy did not obtain TLS cert' "$SCRIPT" || { echo "FAIL: Caddy ACME timeout error message not found"; exit 1; }

# 7. set -euo pipefail at the top (within first 15 lines, after the comment block).
head -15 "$SCRIPT" | grep -q 'set -euo pipefail' || { echo "FAIL: set -euo pipefail not found in first 15 lines"; exit 1; }

# 8. Script is executable.
[[ -x "$SCRIPT" ]] || { echo "FAIL: hydrate.sh is not executable"; exit 1; }

# 9. Sentinel write uses config_sha256 (idempotency key).
grep -q 'config_sha256' "$SCRIPT" || { echo "FAIL: config_sha256 not found in sentinel logic"; exit 1; }

# 10. No plaintext logging of secrets (TURN_SECRET value must not be echo'd raw).
if grep -E 'echo.*\$TURN_SECRET|log.*\$TURN_SECRET' "$SCRIPT" | grep -qv 'len=\${#TURN_SECRET}'; then
    echo "FAIL: TURN_SECRET may be logged in plain text"
    exit 1
fi

# 11: sed_esc helper exists and has the correct escape pattern.
grep -qE 'sed_esc\s*\(\s*\)\s*\{' "$SCRIPT" \
    || { echo "FAIL: sed_esc helper missing"; exit 1; }
grep -qE "s/\[\\\\\\\\&\|\]/\\\\\\\\&/g" "$SCRIPT" \
    || { echo "FAIL: sed_esc escape pattern missing"; exit 1; }

# 12: systemd unit file exists with negated ConditionPathExists + correct ExecStart.
UNIT="$REPO_ROOT/deploy/partner-edge/systemd/oxpulse-partner-edge-hydrate.service"
[ -f "$UNIT" ] || { echo "FAIL: $UNIT missing"; exit 1; }
grep -qE '^ConditionPathExists=!/var/lib/oxpulse-partner-edge/hydrated' "$UNIT" \
    || { echo "FAIL: negated sentinel condition missing in hydrate.service"; exit 1; }
grep -qE '^ExecStart=/usr/local/sbin/oxpulse-partner-edge-hydrate' "$UNIT" \
    || { echo "FAIL: ExecStart wrong in hydrate.service"; exit 1; }

echo "PASS: hydrate.sh structure OK"
