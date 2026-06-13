#!/bin/bash
# tests/test_baseline_before_reconcile.sh — baseline captured BEFORE reconcile_all (MAJOR 2).
#
# Asserts ordering in upgrade.sh --with-templates path:
#   B1: `health_snapshot` call appears in upgrade.sh before `reconcile_all` call
#       (static grep — ordering in source = ordering at runtime for this linear flow).
#   B2: `sync_host_scripts` call appears before `health_snapshot` (ensures new
#       --snapshot-capable healthcheck is installed before baseline is taken).
#   B3: `reconcile_all` call appears before image pull (structural guard).
#
# Falsification (anti-vacuous):
#   If we revert MAJOR 2 (move baseline after reconcile_all), B1 FAILS.
#   The test greps for the ordering — any swap makes it RED.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
UPGRADE="$REPO_ROOT/upgrade.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

echo ""
echo "=== baseline-before-reconcile ordering tests ==="

[[ -f "$UPGRADE" ]] || { fail "B0: upgrade.sh not found"; exit 1; }
pass "B0: upgrade.sh present"

# Extract only the --with-templates branch from upgrade.sh.
# The branch starts after "with_templates)" or "MODE=with_templates" and ends at
# the next top-level ";;".  We grep for line numbers to check ordering.
# Strategy: find line numbers of key calls within the with_templates block.

# Find the with_templates mode block start
_wt_start=$(grep -n 'with_templates\b' "$UPGRADE" | grep -v '#' | head -1 | cut -d: -f1)
[[ -n "$_wt_start" ]] || { fail "B0a: with_templates block not found in upgrade.sh"; exit 1; }

# Find line numbers of key calls (searching from the wt block start)
_sync_line=$(awk "NR>$_wt_start && /sync_host_scripts/ && !/^[[:space:]]*#/ {print NR; exit}" "$UPGRADE")
_baseline_line=$(awk "NR>$_wt_start && /health_snapshot/ && !/^[[:space:]]*#/ {print NR; exit}" "$UPGRADE")
_reconcile_line=$(awk "NR>$_wt_start && /reconcile_all/ && !/^[[:space:]]*#/ {print NR; exit}" "$UPGRADE")
# For pull, find the one within the with_templates block (line 2181+), not earlier occurrences.
_pull_line=$(awk "NR>$_reconcile_line && /compose pull/ && !/^[[:space:]]*#/ {print NR; exit}" "$UPGRADE")

# Verify all were found
if [[ -z "$_sync_line" || -z "$_baseline_line" || -z "$_reconcile_line" || -z "$_pull_line" ]]; then
    fail "B0b: could not locate all key calls in upgrade.sh with_templates block"
    echo "  sync_host_scripts: line ${_sync_line:-(not found)}" >&2
    echo "  health_snapshot:   line ${_baseline_line:-(not found)}" >&2
    echo "  reconcile_all:     line ${_reconcile_line:-(not found)}" >&2
    echo "  compose pull:      line ${_pull_line:-(not found)}" >&2
    exit 1
fi

# B2: sync_host_scripts before health_snapshot
if [[ "$_sync_line" -lt "$_baseline_line" ]]; then
    pass "B2: sync_host_scripts (line $_sync_line) before health_snapshot (line $_baseline_line)"
else
    fail "B2: sync_host_scripts (line $_sync_line) NOT before health_snapshot (line $_baseline_line) — new healthcheck.sh may lack --snapshot support"
fi

# B1: health_snapshot before reconcile_all (MAJOR 2 fix)
if [[ "$_baseline_line" -lt "$_reconcile_line" ]]; then
    pass "B1: health_snapshot (line $_baseline_line) before reconcile_all (line $_reconcile_line) — baseline captured pre-reconcile"
else
    fail "B1: health_snapshot (line $_baseline_line) is AFTER reconcile_all (line $_reconcile_line) — MAJOR 2 regression: reconcile breakage enters baseline undetected"
fi

# B3: reconcile_all before pull
if [[ "$_reconcile_line" -lt "$_pull_line" ]]; then
    pass "B3: reconcile_all (line $_reconcile_line) before compose pull (line $_pull_line)"
else
    fail "B3: reconcile_all (line $_reconcile_line) NOT before compose pull (line $_pull_line)"
fi

echo ""
echo "=== baseline-before-reconcile: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
