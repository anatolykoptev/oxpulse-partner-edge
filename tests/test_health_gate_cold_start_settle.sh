#!/bin/bash
# tests/test_health_gate_cold_start_settle.sh
#
# FIX 1 (settle cold-start false-rollback) regression test.
#
# Root cause under test:
#   settle_healthcheck_with_retry (upgrade.sh) treated "snapshot parseable" as
#   "system settled": the --snapshot poll loop broke on the FIRST parseable post
#   snapshot and diffed it against the (warm, pre-reconcile) baseline. A container
#   recreated by --with-templates (sfu/coturn digests change on EVERY upgrade) is
#   COLD at that first post-snapshot, so a transient GREEN->RED read (e.g.
#   check_14_canary_upstream while xray warms) was captured as a REGRESSION and
#   rolled the upgrade back. Post-rollback the same config is GREEN => a universal,
#   deterministic FALSE rollback on every drift-carrying box (the v0.14.2 canary).
#
# Fix under test:
#   On a detected regression the gate now RE-POLLS (same budget as the parse
#   retry) until the regression CLEARS (transient -> pass) or the budget is
#   exhausted (persistent -> REAL regression -> rollback). The real rollback path
#   is preserved: a genuinely persistent GREEN->RED still rolls back.
#
# Falsification (anti-vacuous):
#   T1 (transient: baseline GREEN, post RED then GREEN) is RED before the fix -
#   the pre-fix loop breaks on the first RED post-snapshot and rolls back. T2
#   (persistent: baseline GREEN, post always RED) proves the fix does NOT disable
#   real regression detection. Reverting the fix flips T1 to a rollback (FAIL).
#
# Also asserts FIX 3(b): the settle outcome is emitted as a labelled textfile
# gauge (partner_edge_settle_rollback{kind=...}) so the fleet can tell a
# cold-start (transient) rollback CONDITION from a REAL one.
#
# REAL-CODE MANDATE: drives the real settle_healthcheck_with_retry (awk-extracted
# self-contained from upgrade.sh, same seam test_health_gate_nonzero_snapshot.sh
# uses) and the real _reconcile_emit_prom_gauge (sourced from lib/reconcile.sh).
# Only the healthcheck binary is a fixture - a stateful stub that flips a check
# RED->GREEN across snapshot calls, i.e. the exact cold-start shape of the bug.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
UPGRADE="$REPO_ROOT/upgrade.sh"
RECONCILE_LIB="$REPO_ROOT/lib/reconcile.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

echo ""
echo "=== FIX 1: settle tolerates a transient cold-start regression, rolls back a persistent one ==="

[[ -f "$UPGRADE" ]]       || { fail "P0: upgrade.sh not found"; exit 1; }
[[ -f "$RECONCILE_LIB" ]] || { fail "P0: lib/reconcile.sh not found"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --- Extract the real settle_healthcheck_with_retry (self-contained fn). ---
SETTLE_FN="$TMP/settle_fn.sh"
awk '/^settle_healthcheck_with_retry\(\)/{f=1} f{print} /^}$/ && f{exit}' "$UPGRADE" > "$SETTLE_FN"
# Non-vacuous guard: `bash -n` on an EMPTY file trivially succeeds, so a drifted awk
# pattern (fn renamed / moved) would GREEN a test that never exercised the code. Assert
# the extraction captured the fn signature before parsing.
if [[ -s "$SETTLE_FN" ]] && grep -q '^settle_healthcheck_with_retry()' "$SETTLE_FN"; then
    pass "S0: extraction captured settle_healthcheck_with_retry (non-empty, has signature)"
else
    fail "S0: extraction empty or signature-less — awk pattern drifted from upgrade.sh"; exit 1
fi
if bash -n "$SETTLE_FN"; then
    pass "S1: extracted settle_healthcheck_with_retry parses (self-contained)"
else
    fail "S1: extracted settle_healthcheck_with_retry has syntax errors"; exit 1
fi

# --- Stateful fake healthcheck. --snapshot emits check_ok=GREEN always, and
# check_flap=RED until this binary has been called >= FLIP snapshot times, then
# GREEN (FLIP<=0 => always RED). A shared counter file persists across the
# separate healthcheck processes settle spawns (probe + one per attempt). ---
make_hc() {   # make_hc OUTFILE COUNTFILE FLIP
    local out="$1" cnt="$2" flip="$3"
    : > "$cnt"
    cat > "$out" <<HC
#!/bin/bash
if [[ "\$*" == *"--snapshot"* ]]; then
    n=\$(cat "$cnt" 2>/dev/null || echo 0); n=\$((n+1)); echo "\$n" > "$cnt"
    printf 'check_ok=GREEN\n'
    if [[ "$flip" -gt 0 && "\$n" -ge "$flip" ]]; then
        printf 'check_flap=GREEN\n'
    else
        printf 'check_flap=RED\n'
    fi
    exit 0
fi
exit 1
HC
    chmod +x "$out"
}

# Driver: source reconcile.sh (for the metric writer) + the extracted settle fn,
# run the real gate, print GATE_PASS / GATE_ROLLBACK. Metric lands in
# PARTNER_EDGE_TEXTFILE_DIR (env).
cat > "$TMP/driver.sh" <<'DRV'
#!/bin/bash
set -uo pipefail
log()  { :; }
warn() { :; }
die()  { echo "DIE: $*" >&2; exit 1; }
RECONCILE_LIB="$1"; SETTLE_FN="$2"; HEALTHCHECK="$3"; BASELINE="$4"
export HEALTHCHECK
# shellcheck source=/dev/null
source "$RECONCILE_LIB"
# shellcheck source=/dev/null
source "$SETTLE_FN"
if settle_healthcheck_with_retry cold-start-test "$BASELINE"; then
    echo GATE_PASS
else
    echo GATE_ROLLBACK
fi
DRV

run_settle() {   # run_settle HC BASELINE BUDGET TEXTDIR
    env OXPULSE_ABSOLUTE_HEALTH_GATE=0 OXPULSE_UPGRADE_HEALTH_TIMEOUT="$3" \
        PARTNER_EDGE_TEXTFILE_DIR="$4" \
        bash "$TMP/driver.sh" "$RECONCILE_LIB" "$SETTLE_FN" "$1" "$2" 2>/dev/null
}

metric_kind() {   # metric_kind TEXTDIR  -> prints the kind label present, or ""
    local f="$1/partner_edge_settle.prom"
    [[ -f "$f" ]] || { echo ""; return; }
    sed -n 's/.*kind="\([^"]*\)".*/\1/p' "$f" | head -1
}

# ---------------------------------------------------------------------------
# T1: transient cold-start regression (baseline GREEN, post RED then GREEN)
#     => gate must TOLERATE (no rollback) and record kind="transient_cleared".
# ---------------------------------------------------------------------------
T1_TD="$TMP/t1_text"; mkdir -p "$T1_TD"
T1_HC="$TMP/t1_hc.sh"
# FLIP=3: probe(call1)=RED, attempt1(call2)=RED [regression -> re-poll],
#         attempt2(call3)=GREEN [cleared]. Budget 9s = 3 attempts (slack).
make_hc "$T1_HC" "$TMP/t1.cnt" 3
printf 'check_ok=GREEN\ncheck_flap=GREEN\n' > "$TMP/t1_baseline.snap"
T1_OUT=$(run_settle "$T1_HC" "$TMP/t1_baseline.snap" 9 "$T1_TD")
if echo "$T1_OUT" | grep 'GATE_PASS' >/dev/null; then
    pass "T1: transient cold-start regression (check_flap RED->GREEN) tolerated => no false rollback"
else
    fail "T1: transient cold-start regression rolled back (got '$T1_OUT') - cold-start gate not re-polling"
fi
T1_KIND=$(metric_kind "$T1_TD")
if [[ "$T1_KIND" == "transient_cleared" ]]; then
    pass "T1b: settle metric records kind=transient_cleared (fleet 'was the rollback real?' signal)"
else
    fail "T1b: settle metric kind='$T1_KIND', expected transient_cleared"
fi

# ---------------------------------------------------------------------------
# T2: persistent regression (baseline GREEN, post always RED)
#     => gate must ROLL BACK (real rollback preserved) and record kind="real".
# ---------------------------------------------------------------------------
T2_TD="$TMP/t2_text"; mkdir -p "$T2_TD"
T2_HC="$TMP/t2_hc.sh"
make_hc "$T2_HC" "$TMP/t2.cnt" 0   # FLIP=0 => check_flap always RED
printf 'check_ok=GREEN\ncheck_flap=GREEN\n' > "$TMP/t2_baseline.snap"
T2_OUT=$(run_settle "$T2_HC" "$TMP/t2_baseline.snap" 6 "$T2_TD")
if echo "$T2_OUT" | grep 'GATE_ROLLBACK' >/dev/null; then
    pass "T2: persistent regression (check_flap stays RED past budget) => rollback (real path intact)"
else
    fail "T2: persistent regression NOT rolled back (got '$T2_OUT') - gate over-relaxed"
fi
T2_KIND=$(metric_kind "$T2_TD")
if [[ "$T2_KIND" == "real" ]]; then
    pass "T2b: settle metric records kind=real on a genuine rollback"
else
    fail "T2b: settle metric kind='$T2_KIND', expected real"
fi

# ---------------------------------------------------------------------------
# T3: clean settle (baseline GREEN, post GREEN) => pass, kind="none".
# ---------------------------------------------------------------------------
T3_TD="$TMP/t3_text"; mkdir -p "$T3_TD"
T3_HC="$TMP/t3_hc.sh"
make_hc "$T3_HC" "$TMP/t3.cnt" 1   # FLIP=1 => GREEN from the first call
printf 'check_ok=GREEN\ncheck_flap=GREEN\n' > "$TMP/t3_baseline.snap"
T3_OUT=$(run_settle "$T3_HC" "$TMP/t3_baseline.snap" 6 "$T3_TD")
if echo "$T3_OUT" | grep 'GATE_PASS' >/dev/null; then
    pass "T3: clean settle (no regression) => pass"
else
    fail "T3: clean settle incorrectly rolled back (got '$T3_OUT')"
fi
T3_KIND=$(metric_kind "$T3_TD")
if [[ "$T3_KIND" == "none" ]]; then
    pass "T3b: settle metric records kind=none on a clean settle"
else
    fail "T3b: settle metric kind='$T3_KIND', expected none"
fi

echo ""
echo "=== settle cold-start gate: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
