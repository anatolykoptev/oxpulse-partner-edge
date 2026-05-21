#!/bin/bash
# Regression: install.sh MUST die loudly when /api/partner/register returns
# an empty signaling_sfu_secret. Previously it warned and continued, which
# rendered docker-compose with SIGNALING_SFU_SECRET= empty, the SFU's
# client_ws API stayed disabled, and group calls silently failed end-to-end
# (motherly1 outage 2026-05-06, ~8 weeks of silent breakage). Same class of
# bug as the cover/cover.html regression — operator-visible breakage hidden
# by a warn-and-continue path.
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
INSTALL="$REPO_ROOT/install.sh"

[[ -f "$INSTALL" ]] || { echo "FAIL: install.sh not found at $INSTALL"; exit 1; }

# 1. The empty-secret guard must call die, not warn.
#    Locate the [[ -z "...SIGNALING_SFU_SECRET..." ]] guard block itself,
#    not the assignment site (assignment + guard can be separated by 100+
#    lines of unrelated code, breaking a naive line-range capture).
guard_block=$(awk '
    /^if \[\[ -z "\${SIGNALING_SFU_SECRET:-}" \]\]; then/ { capture=1 }
    capture { print }
    capture && /^fi$/ { exit }
' "$INSTALL")

[[ -n "$guard_block" ]] \
    || { echo "FAIL: could not locate SIGNALING_SFU_SECRET guard block (if [[ -z ... ]]; then ... fi) in $INSTALL"; exit 1; }

# 2. The guard must invoke die (hard exit), not warn (soft continue).
echo "$guard_block" | grep -qE '\bdie\b' \
    || { echo "FAIL: SIGNALING_SFU_SECRET empty guard does not call die"; \
         echo "---block---"; echo "$guard_block"; echo "---/block---"; exit 1; }

echo "$guard_block" | grep -qE '^[[:space:]]*warn\b' \
    && { echo "FAIL: SIGNALING_SFU_SECRET empty guard still uses warn (should die)"; \
         echo "---block---"; echo "$guard_block"; echo "---/block---"; exit 1; }

# 3. The error message must point the operator at the central-side fix.
#    Specifically mention SIGNALING_SFU_SECRET (so grep on logs surfaces it)
#    and "redeploy" / "motherly" (the actionable verb + target).
echo "$guard_block" | grep -q 'SIGNALING_SFU_SECRET' \
    || { echo "FAIL: die message missing SIGNALING_SFU_SECRET hint"; exit 1; }
# Use tr to flatten newlines so the test tolerates line wrap inside the
# die heredoc (e.g. group calls split across lines).
echo "$guard_block" | tr -s '[:space:]' ' ' | grep -qi 'group  *calls' \
    || { echo "FAIL: die message must explain group-call breakage"; exit 1; }

# 4. Sanity: install.sh still parses.
bash -n "$INSTALL" \
    || { echo "FAIL: install.sh has syntax errors"; exit 1; }

echo "OK: install.sh dies on empty signaling_sfu_secret with operator guidance"
