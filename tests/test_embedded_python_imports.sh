#!/usr/bin/env bash
# tests/test_embedded_python_imports.sh — every python snippet embedded in a
# shell script must import every stdlib module it references (#513).
#
# #513: channel-render-lib.sh's sni_fallback snippet referenced `os` without
# `import os`. On any node-config carrying no server_name it raised
#   NameError: name 'os' is not defined
# Every live node happened to carry the field, so the branch was unreachable
# and the defect sat latent — armed fleet-wide by any upstream node-config
# shape change, with no staging signal. It detonates inside re_render_xray,
# which runs AFTER the health gate and outside the rollback window (#514).
#
# The fix landed incidentally in f27c29e (the #526 SNI work) and nothing
# guarded it: every test fixture in this repo supplies a server_name, so the
# NameError branch is not reachable from the suite at all. Reintroducing it
# would have been silent.
#
# These snippets are opaque strings to the shell — shellcheck, bash -n and the
# pipefail guard all stop at the quote. This test reaches inside them, and it
# checks the CLASS rather than the one line, because the next missing import
# will not be in the same block.
#
# Plain bash, no bats (repo convention).
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SCANNER="$REPO_ROOT/tests/scan_embedded_python.py"
[[ -f "$SCANNER" ]] || { echo "FAIL: $SCANNER not found"; exit 1; }

echo "test_embedded_python_imports.sh"
echo

out=$(python3 "$SCANNER" "$REPO_ROOT" 2>&1) || true
printf '%s\n' "$out"
echo

PASS=0
FAIL=0
ok()  { echo "  PASS: $*"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

_field() { printf '%s\n' "$out" | sed -n "s/^$1 *: *\([0-9]*\).*/\1/p"; }

scanned=$(_field "blocks scanned")
unparseable=$(_field "extraction failures")
violations=$(_field "violations")

# A scanner that finds nothing reports zero violations. That reads exactly like
# a clean repo, so the floor is the difference between a gate and a decoration.
# 30 is well under the 48 present when this was written, leaving room to delete
# snippets without a spurious failure.
if [[ "${scanned:-0}" -ge 30 ]]; then
    ok "scanner is non-vacuous: ${scanned} embedded python blocks examined"
else
    bad "only ${scanned:-0} blocks scanned — extraction is broken, so a green result here would mean nothing"
fi

if [[ "${unparseable:-1}" -eq 0 ]]; then
    ok "no extraction failures — nothing was skipped silently"
else
    bad "${unparseable} block(s) could not be extracted; a scanner that drops what it cannot read is a false green"
fi

if [[ "${violations:-1}" -eq 0 ]]; then
    ok "every embedded python block imports what it references"
else
    bad "${violations} embedded python block(s) reference a module they do not import (see FAIL lines above)"
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
