#!/usr/bin/env bash
# Fix #1 — naive-client.json must be mode 0640 gid 65532 (distroless nonroot).
#
# Evidence: Dockerfile.naive final stage = gcr.io/distroless/cc-debian12:nonroot
# → container user uid:gid 65532:65532. install.sh wrote mode 0600 root:root
# → container can't read → (1001) Can't read file crashloop.
#
# Fix: chmod 0640 + chown root:65532 so distroless nonroot gid can read the
# proxy password. Host has no uid/gid 65532 in /etc/passwd so wider exposure
# on the host is theoretical only.
#
# This test verifies the install.sh source carries the correct chmod/chown
# pattern and that the comment documenting the 0640 trade-off is present.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
INSTALL="$REPO_ROOT/install.sh"

[[ -f "$INSTALL" ]] || { echo "FAIL: install.sh not found at $INSTALL"; exit 1; }

FAIL=0
pass() { echo "OK: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }

# ── Case 1: chmod 0640 appears in the naive render block ─────────────────────
echo "==> Case 1: naive block uses chmod 0640 (not 0600)"
# Extract the naive render block (from render_channel_soft naive to rm -rf stage)
naive_block=$(awk '/render_channel_soft naive/,/rm -rf.*\$stage/' "$INSTALL")
if echo "$naive_block" | grep 'chmod 0640.*naive-client\.json' >/dev/null; then
    pass "chmod 0640 found in naive render block"
else
    fail "chmod 0640 not found in naive render block (still 0600?)"
fi

# ── Case 2: chown root:65532 appears in the naive render block ───────────────
echo "==> Case 2: naive block chowns to root:65532"
if echo "$naive_block" | grep -E 'chown[[:space:]]+root:65532.*naive-client\.json' >/dev/null; then
    pass "chown root:65532 found in naive render block"
else
    fail "chown root:65532 not found in naive render block"
fi

# ── Case 3: 0600 must NOT appear for naive-client.json in naive block ────────
echo "==> Case 3: naive block does NOT chmod 0600 naive-client.json"
if echo "$naive_block" | grep -E 'chmod[[:space:]]+0600.*naive-client\.json' >/dev/null; then
    fail "chmod 0600 still present in naive render block (should be 0640)"
else
    pass "chmod 0600 not present for naive-client.json in naive render block"
fi

# ── Case 4: trade-off comment is present near the chmod ───────────────────────
echo "==> Case 4: 0640 trade-off comment documented near chmod"
# Accept either 65532 or distroless in a comment within the naive render block.
# The comment may be before or after the chmod line.
naive_block=$(awk '/render_channel_soft naive/,/rm -rf.*\$stage/' "$INSTALL")
if echo "$naive_block" | grep -iE '#.*distroless|#.*65532|#.*nonroot' >/dev/null; then
    pass "trade-off comment (distroless/65532/nonroot) documented in naive render block"
else
    fail "trade-off comment missing in naive render block"
fi

# ── Result ────────────────────────────────────────────────────────────────────
if [[ $FAIL -ne 0 ]]; then
    echo "FAIL: naive-client.json perms test — one or more cases failed"
    exit 1
fi
echo "PASS: naive-client.json chmod 0640 + chown root:65532 — all cases verified"
