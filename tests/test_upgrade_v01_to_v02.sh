#!/bin/bash
# Structural sanity checks for v0.1→v0.2 transition preflight in upgrade.sh.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-/home/user/src/oxpulse-partner-edge}"
SCRIPT="$REPO_ROOT/upgrade.sh"

# 1. Script parses cleanly.
bash -n "$SCRIPT" || { echo "FAIL: bash -n failed on upgrade.sh" >&2; exit 1; }

# 2. Function definition is present.
grep -qE '^maybe_v01_to_v02_preflight\(\)' "$SCRIPT" \
    || { echo "FAIL: maybe_v01_to_v02_preflight() definition not found" >&2; exit 1; }

# 3. Function is invoked (call site, not just defined).
grep -cE '^maybe_v01_to_v02_preflight$' "$SCRIPT" | grep -qE '^[1-9]' \
    || { echo "FAIL: maybe_v01_to_v02_preflight call site not found" >&2; exit 1; }

# 4. v0.1 regex guard is present.
grep -qE '\^v0\\\.1' "$SCRIPT" \
    || { echo "FAIL: v0.1 version guard regex not found" >&2; exit 1; }

# 5. v0.2 regex guard is present.
grep -qE '\^v0\\\.2' "$SCRIPT" \
    || { echo "FAIL: v0.2 version guard regex not found" >&2; exit 1; }

# 6. dig +short call is present.
grep -qE 'dig \+short' "$SCRIPT" \
    || { echo "FAIL: 'dig +short' not found in upgrade.sh" >&2; exit 1; }

# 6a. DNS check uses multi-A membership (grep -Fxq) not single-line tail -n1 equality.
grep -qE 'grep -Fxq' "$SCRIPT" \
    || { echo "FAIL: multi-A membership check (grep -Fxq) not found — DNS check may be fragile" >&2; exit 1; }

# 6b. maybe_v01_to_v02_preflight is invoked before the rollback branch.
preflight_line=$(grep -n '^maybe_v01_to_v02_preflight$' "$SCRIPT" | head -n1 | cut -d: -f1)
rollback_line=$(grep -n 'MODE" == rollback' "$SCRIPT" | head -n1 | cut -d: -f1)
[[ -n "$preflight_line" && -n "$rollback_line" && "$preflight_line" -lt "$rollback_line" ]] \
    || { echo "FAIL: maybe_v01_to_v02_preflight must be invoked before rollback branch (preflight=${preflight_line:-missing} rollback=${rollback_line:-missing})" >&2; exit 1; }

# 7. TURNS_SUBDOMAIN is referenced.
grep -q 'TURNS_SUBDOMAIN' "$SCRIPT" \
    || { echo "FAIL: TURNS_SUBDOMAIN not referenced" >&2; exit 1; }

# 8. PARTNER_DOMAIN is referenced.
grep -q 'PARTNER_DOMAIN' "$SCRIPT" \
    || { echo "FAIL: PARTNER_DOMAIN not referenced" >&2; exit 1; }

# 9. --reseed is invoked only inside a V01_TO_V02-guarded block.
# Verify that the only occurrence of --reseed appears after a V01_TO_V02 check.
RESEED_LINE=$(grep -n '\-\-reseed' "$SCRIPT" | head -1 | cut -d: -f1)
[[ -n "$RESEED_LINE" ]] || { echo "FAIL: --reseed not found in upgrade.sh" >&2; exit 1; }
# The block just before it (within 10 lines) must contain V01_TO_V02.
BLOCK_START=$(( RESEED_LINE - 10 ))
[[ $BLOCK_START -lt 1 ]] && BLOCK_START=1
sed -n "${BLOCK_START},${RESEED_LINE}p" "$SCRIPT" | grep -q 'V01_TO_V02' \
    || { echo "FAIL: --reseed invocation is not inside a V01_TO_V02-guarded block" >&2; exit 1; }

# 10. Existing rollback/backup machinery is still present.
grep -q 'PREV_COMPOSE_FILE' "$SCRIPT" \
    || { echo "FAIL: PREV_COMPOSE_FILE variable not found (backup machinery removed?)" >&2; exit 1; }

grep -qE '\-\-rollback' "$SCRIPT" \
    || { echo "FAIL: --rollback case not found" >&2; exit 1; }

grep -q 'sed -i -E' "$SCRIPT" \
    || { echo "FAIL: sed tag-rewrite line not found" >&2; exit 1; }

echo "PASS: upgrade.sh v0.1→v0.2 preflight structure OK"
