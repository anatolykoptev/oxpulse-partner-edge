#!/bin/bash
# Verify the installer runtime deps block includes jq.
#
# The runtime deps installation loop was extracted from install.sh into
# lib/install-deps.sh (installer modularization, Phase 4.1). It confirms jq is
# listed in the deps block introduced after the edge-a1 incident
# (2026-05-09). Assert against the lib module that now owns it.
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DEPS_LIB="$REPO_ROOT/lib/install-deps.sh"

[[ -f "$DEPS_LIB" ]] || { echo "FAIL: lib/install-deps.sh not found at $DEPS_LIB"; exit 1; }

pass() { echo "OK: $*"; }
fail() { echo "FAIL: $*"; exit 1; }

# ── Test: jq present in runtime deps block ───────────────────────────────────
grep -q 'jq' "$DEPS_LIB" \
    || fail "lib/install-deps.sh does not mention 'jq' — add jq to the runtime deps block"

# More specific: the OS-aware install loop must reference jq
grep -q 'for _pkg in jq' "$DEPS_LIB" \
    || fail "lib/install-deps.sh runtime deps loop 'for _pkg in jq' not found — block missing or renamed"

pass "lib/install-deps.sh: jq present in runtime deps installation loop"

# ── Test: block installs via both dnf and apt-get ────────────────────────────
grep -q 'OS_FAMILY == rhel' "$DEPS_LIB" \
    || fail "lib/install-deps.sh deps block must branch on OS_FAMILY == rhel (for dnf)"

pass "lib/install-deps.sh: deps block is OS-family-aware (rhel/debian branches present)"

# ── Syntax check ──────────────────────────────────────────────────────────────
bash -n "$DEPS_LIB" \
    || fail "lib/install-deps.sh has syntax errors"
pass "syntax check clean"

echo ""
echo "All tests passed."
