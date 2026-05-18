#!/usr/bin/env bash
# Regression: install.sh must export NAIVE_SOCKS_PORT before render_with_opec naive.
#
# Bug 1 (deferred from Phase 5.5): naive-client.json.tpl references {{NAIVE_SOCKS_PORT}}
# but install.sh never reads it from node-config or sets a default.  When NAIVE_SERVER is
# set and naive channel is provisioned, opec renders port as empty string → invalid JSON
# → validation rejects → install fails.
#
# This test covers:
#   Case 1: NAIVE_SOCKS_PORT is read from node-config in install.sh (json_get naive_socks_port)
#   Case 2: NAIVE_SOCKS_PORT has a default of 1080 if node-config does not supply it
#   Case 3: NAIVE_SOCKS_PORT is included in the export block before render_with_opec naive
#   Case 4: naive-client.json.tpl contains the {{NAIVE_SOCKS_PORT}} placeholder (template integrity)
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
INSTALL="$REPO_ROOT/install.sh"
TPL="$REPO_ROOT/naive-client.json.tpl"

[[ -f "$INSTALL" ]] || { echo "FAIL: install.sh not found at $INSTALL"; exit 1; }
[[ -f "$TPL" ]] || { echo "FAIL: naive-client.json.tpl not found at $TPL"; exit 1; }

FAIL=0

pass() { echo "OK: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }

# ── Case 1: json_get naive_socks_port is called in install.sh ────────────────
echo "==> Case 1: install.sh reads NAIVE_SOCKS_PORT from node-config"
if grep -q 'NAIVE_SOCKS_PORT.*json_get.*naive_socks_port' "$INSTALL"; then
	pass "NAIVE_SOCKS_PORT is read via json_get naive_socks_port"
else
	fail "NAIVE_SOCKS_PORT is not read from node-config in install.sh"
fi

# ── Case 2: NAIVE_SOCKS_PORT has a :- 1080 default ──────────────────────────
echo "==> Case 2: NAIVE_SOCKS_PORT has default 1080"
if grep -qE 'NAIVE_SOCKS_PORT.*1080' "$INSTALL"; then
	pass "NAIVE_SOCKS_PORT has default 1080"
else
	actual=$(grep 'NAIVE_SOCKS_PORT' "$INSTALL" | head -5 || echo "(not found)")
	fail "NAIVE_SOCKS_PORT does not have default 1080. Found: $actual"
fi

# ── Case 3: NAIVE_SOCKS_PORT is exported before render_with_opec naive ───────
echo "==> Case 3: NAIVE_SOCKS_PORT exported before render_with_opec naive"
# Extract block from naive export line to render_with_opec naive call
awk '/export NAIVE_SERVER/,/render_with_opec naive/' "$INSTALL" > /tmp/naive_export_block.txt
if grep -q 'NAIVE_SOCKS_PORT' /tmp/naive_export_block.txt; then
	pass "NAIVE_SOCKS_PORT found in export block before render_with_opec naive"
else
	fail "NAIVE_SOCKS_PORT not in export block before render_with_opec naive"
fi
rm -f /tmp/naive_export_block.txt

# ── Case 4: template integrity — placeholder present ─────────────────────────
echo "==> Case 4: naive-client.json.tpl contains {{NAIVE_SOCKS_PORT}} placeholder"
if grep -q '{{NAIVE_SOCKS_PORT}}' "$TPL"; then
	pass "{{NAIVE_SOCKS_PORT}} placeholder present in naive-client.json.tpl"
else
	fail "{{NAIVE_SOCKS_PORT}} placeholder missing from naive-client.json.tpl"
fi

# ── Result ───────────────────────────────────────────────────────────────────
if [[ $FAIL -ne 0 ]]; then
	echo "FAIL: one or more NAIVE_SOCKS_PORT export tests failed"
	exit 1
fi
echo "PASS: NAIVE_SOCKS_PORT export + default — all 4 cases verified"
