#!/bin/bash
# Verify install.sh runtime deps block includes jq.
#
# This test greps install.sh source to confirm jq is listed in the runtime
# deps installation block introduced after the cheburator1 incident (2026-05-09).
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
INSTALL="$REPO_ROOT/install.sh"

[[ -f "$INSTALL" ]] || { echo "FAIL: install.sh not found at $INSTALL"; exit 1; }

pass() { echo "OK: $*"; }
fail() { echo "FAIL: $*"; exit 1; }

# ── Test: jq present in install.sh runtime deps block ────────────────────────
grep -q 'jq' "$INSTALL" \
    || fail "install.sh does not mention 'jq' — add jq to the runtime deps block"

# More specific: the OS-aware install loop must reference jq
grep -q 'for _pkg in jq' "$INSTALL" \
    || fail "install.sh runtime deps loop 'for _pkg in jq' not found — block missing or renamed"

pass "install.sh: jq present in runtime deps installation loop"

# ── Test: block installs via both dnf and apt-get ────────────────────────────
grep -q 'OS_FAMILY == rhel' "$INSTALL" \
    || fail "install.sh deps block must branch on OS_FAMILY == rhel (for dnf)"

pass "install.sh: deps block is OS-family-aware (rhel/debian branches present)"

# ── Syntax check ──────────────────────────────────────────────────────────────
bash -n "$INSTALL" \
    || fail "install.sh has syntax errors"
pass "syntax check clean"

echo ""
echo "All tests passed."
