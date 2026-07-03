#!/bin/bash
# tests/test_health_gate_nonzero_snapshot.sh
#
# BUG 3 (false rollback) regression test — the baseline-aware health gate must
# judge a snapshot by its OUTPUT CONTENT, not by the healthcheck process EXIT
# CODE.
#
# Root cause under test:
#   settle_healthcheck_with_retry (upgrade.sh) and health_snapshot (reconcile.sh)
#   both captured the per-check snapshot with a `... --snapshot || return 1`
#   guard. A healthcheck whose `--snapshot` emits VALID `name=GREEN|RED` lines
#   but EXITS NON-ZERO when any check is RED (an older deployed healthcheck, or
#   the `exit 1`/`exit 2` edge paths in healthcheck.sh) made those helpers report
#   "snapshot failed". In settle that flips `_snap_supported=0`, dropping the run
#   into the absolute `--local` gate — which rolls back on ANY red, including a
#   PRE-EXISTING red the upgrade never touched. => FALSE rollback.
#
# Fix under test:
#   The snapshot capture no longer gates on the `--snapshot` exit code; it keeps
#   the output and validates by CONTENT (>=1 `name=GREEN|RED` line — the check
#   that was already there). A valid-but-red snapshot is treated as a valid
#   snapshot, so the baseline-aware regression diff (GREEN->RED only) runs and
#   pre-existing reds are drift, not rollback.
#
# Falsification (anti-vacuous):
#   A (pre-existing red, no new regression) is RED before the fix — the non-zero
#   `--snapshot` exit forces the absolute `--local` gate, which rolls back on the
#   pre-existing red. B (new regression GREEN->RED) proves the fix does NOT
#   disable real regression detection. Reverting either fix flips A back to a
#   rollback (test FAILs).
#
# REAL-CODE MANDATE: drives the real settle_healthcheck_with_retry (awk-extracted
# self-contained from upgrade.sh, same seam tests/test_upgrade_zero_downtime.sh
# uses) and the real health_snapshot (sourced from lib/reconcile.sh). Only the
# healthcheck binary is a fixture — it is the exact non-zero-exit-with-valid-lines
# shape the bug is about.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
UPGRADE="$REPO_ROOT/upgrade.sh"
RECONCILE_LIB="$REPO_ROOT/lib/reconcile.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

echo ""
echo "=== BUG3: health gate must content-gate (not exit-code-gate) the snapshot ==="

[[ -f "$UPGRADE" ]]       || { fail "P0: upgrade.sh not found"; exit 1; }
[[ -f "$RECONCILE_LIB" ]] || { fail "P0: lib/reconcile.sh not found"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --- Fixture healthcheck: valid snapshot lines with a RED, but EXIT NON-ZERO. ---
# This is the exact shape the bug is about: --snapshot output IS parseable, only
# the process exit code is non-zero (because a check is red). --local also fails
# (reds present), so the absolute-gate fallback would roll back.
HC="$TMP/healthcheck_nonzero.sh"
cat > "$HC" << 'HCEOF'
#!/bin/bash
if [[ "$*" == *"--snapshot"* ]]; then
    printf 'check_containers=GREEN\n'
    printf 'check_api=GREEN\n'
    printf 'check_sfu_metrics=RED\n'
    exit 1   # <-- non-zero exit despite valid, parseable snapshot output
fi
exit 1        # --local: fails (a check is red)
HCEOF
chmod +x "$HC"

# --- Extract the real settle_healthcheck_with_retry (self-contained fn). ---
SETTLE_FN="$TMP/settle_fn.sh"
{
    echo 'log()  { :; }'
    echo 'warn() { :; }'
    awk '/^settle_healthcheck_with_retry\(\)/{f=1} f{print} /^}$/ && f{exit}' "$UPGRADE"
} > "$SETTLE_FN"
if bash -n "$SETTLE_FN"; then
    pass "S1: extracted settle_healthcheck_with_retry parses (self-contained)"
else
    fail "S1: extracted settle_healthcheck_with_retry has syntax errors"; exit 1
fi

# Helper: run the real settle with a given baseline file; echo GATE_PASS/GATE_ROLLBACK.
_run_settle() {
    local _baseline="$1"
    env OXPULSE_ABSOLUTE_HEALTH_GATE=0 OXPULSE_UPGRADE_HEALTH_TIMEOUT=3 \
        HEALTHCHECK="$HC" bash -c "
set -uo pipefail
HEALTHCHECK='$HC'
# shellcheck source=/dev/null
source '$SETTLE_FN'
if settle_healthcheck_with_retry 'bug3-test' '$_baseline'; then
    echo GATE_PASS
else
    echo GATE_ROLLBACK
fi
" 2>/dev/null
}

# --- A: pre-existing red (baseline red == post red) => NO rollback. ---
BASELINE_A="$TMP/baseline_a.snap"
printf 'check_containers=GREEN\ncheck_api=GREEN\ncheck_sfu_metrics=RED\n' > "$BASELINE_A"
A_OUT=$(_run_settle "$BASELINE_A")
if echo "$A_OUT" | grep -q 'GATE_PASS'; then
    pass "A: pre-existing red + non-zero --snapshot exit => gate passes (no false rollback)"
else
    fail "A: pre-existing red rolled back (got '$A_OUT') — exit-code gate still active"
fi

# --- B: NEW regression (baseline all-green, post has a red) => rollback. ---
BASELINE_B="$TMP/baseline_b.snap"
printf 'check_containers=GREEN\ncheck_api=GREEN\ncheck_sfu_metrics=GREEN\n' > "$BASELINE_B"
B_OUT=$(_run_settle "$BASELINE_B")
if echo "$B_OUT" | grep -q 'GATE_ROLLBACK'; then
    pass "B: NEW regression (check_sfu_metrics GREEN->RED) => rollback (real detection intact)"
else
    fail "B: new GREEN->RED regression NOT rolled back (got '$B_OUT') — gate over-relaxed"
fi

# --- C: reconcile.sh health_snapshot must keep a valid-but-red snapshot ---
# (return 0 + populated file), not treat the non-zero exit as a failed capture.
C_OUT=$(bash -c "
set -uo pipefail
log()  { :; }
warn() { :; }
die()  { echo DIE >&2; exit 1; }
# shellcheck source=/dev/null
source '$RECONCILE_LIB'
_snap='$TMP/c_baseline.snap'
if health_snapshot '$HC' \"\$_snap\"; then
    echo SNAP_OK
else
    echo SNAP_FAIL
fi
# The snapshot file must contain the valid per-check lines regardless.
grep -qE '^check_sfu_metrics=RED\$' \"\$_snap\" && echo CONTENT_PRESENT || echo CONTENT_MISSING
" 2>/dev/null)
if echo "$C_OUT" | grep -q 'SNAP_OK'; then
    pass "C: health_snapshot returns success on a valid-but-red (non-zero-exit) snapshot"
else
    fail "C: health_snapshot returned failure on a valid snapshot (got '$C_OUT') — exit-code gate"
fi
if echo "$C_OUT" | grep -q 'CONTENT_PRESENT'; then
    pass "C2: health_snapshot captured the per-check lines (baseline non-empty, not discarded)"
else
    fail "C2: health_snapshot did not capture the snapshot content (got '$C_OUT')"
fi

echo ""
echo "=== BUG3 nonzero-snapshot gate tests: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
