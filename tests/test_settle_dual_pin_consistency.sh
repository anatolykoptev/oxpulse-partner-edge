#!/usr/bin/env bash
# tests/test_settle_dual_pin_consistency.sh — CI FITNESS FUNCTION for the settle
# gate's deliberate 2-way pin.
#
# upgrade.sh's settle_healthcheck_with_retry keeps INLINE, self-contained copies
# of the health snapshot/regression primitives (_settle_hc_snapshot /
# _settle_hc_regressions) so the whole function stays awk-extractable for the
# Section-F isolation tests (#318). lib/healthcheck-lib.sh keeps the canonical
# health_snapshot / health_regressions used off the upgrade path (reconcile
# lazy-source; upgrade.sh's own BASELINE capture). These two copies are a
# DOCUMENTED, INTENTIONAL duplicate — and the exact "two copies silently diverge"
# class behind the v0.13→v0.14.x xray-recreate regression on a different path.
#
# This test pins them behaviorally identical (same inputs → same verdict) so the
# baseline (captured by the lib copy) and the post diff (done by the inline copy)
# can never be measured with drifted semantics. It ALSO guards that the settle
# path carries the serve-ability-aware wiring (P3) and its tie to the server-side
# oracle, so neither can silently vanish.
#
# WHY the serve-ability logic is NOT itself dual-pinned into the lib: the
# serve-ability adjudication is a rollback DECISION, and the only rollback writer
# is settle_healthcheck_with_retry (reconcile.sh makes NO rollback/settle
# decision — verified: `grep -c 'settle\|rollback\|revert' lib/reconcile.sh` = 0).
# Adding it to the lib copy would be dead code. So the fitness pins the SHARED
# primitive (snapshot/regression) and asserts the serve-ability layer is present
# in its single authoritative home (settle).
#
# Plain bash, no bats (repo convention).
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
UPGRADE="$REPO_ROOT/upgrade.sh"
LIB="$REPO_ROOT/lib/healthcheck-lib.sh"

[[ -f "$UPGRADE" ]] || { echo "FAIL: $UPGRADE not found"; exit 1; }
[[ -f "$LIB" ]]     || { echo "FAIL: $LIB not found"; exit 1; }

PASS=0
FAIL=0
ok()  { echo "  PASS: $*"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

echo "test_settle_dual_pin_consistency.sh"
echo

# ── Extract the inline helpers (nested in settle, tab-indented), dedent, and
#    source them alongside the lib copies (distinct names, so both coexist). ──
HARNESS=$(mktemp)
trap 'rm -f "$HARNESS"' EXIT
{
    echo 'log(){ :; }'
    echo 'warn(){ :; }'
    awk '/^\t_settle_hc_snapshot\(\) \{/{f=1} f{print} /^\t\}$/ && f{exit}'    "$UPGRADE" | sed 's/^\t//'
    awk '/^\t_settle_hc_regressions\(\) \{/{f=1} f{print} /^\t\}$/ && f{exit}' "$UPGRADE" | sed 's/^\t//'
} > "$HARNESS"

if bash -n "$HARNESS" 2>/dev/null; then
    ok "P0a: inline _settle_hc_snapshot/_settle_hc_regressions extract & parse"
else
    bad "P0a: inline helper extraction failed to parse"
    echo "== extracted ==" >&2; cat "$HARNESS" >&2
fi

# shellcheck disable=SC1090
source "$HARNESS"
# shellcheck disable=SC1090
source "$LIB"

for fn in _settle_hc_regressions health_regressions _settle_hc_snapshot health_snapshot; do
    if declare -F "$fn" >/dev/null 2>&1; then
        ok "P0b: $fn is defined (pin copy present)"
    else
        bad "P0b: $fn NOT defined — a pin copy was removed/renamed"
    fi
done

# ── Regression-diff parity: same baseline/post → identical verdict. ──
_cmp_reg() {   # $1 baseline lines, $2 post lines → echoes rc or DIVERGE
    local bl po a b
    bl=$(mktemp); po=$(mktemp)
    printf '%s\n' "$1" > "$bl"
    printf '%s\n' "$2" > "$po"
    _settle_hc_regressions "$bl" "$po" >/dev/null 2>&1; a=$?
    health_regressions   "$bl" "$po" >/dev/null 2>&1; b=$?
    rm -f "$bl" "$po"
    if [[ "$a" == "$b" ]]; then printf '%s' "$a"; else printf 'DIVERGE(inline=%s lib=%s)' "$a" "$b"; fi
}

_reg_case() {   # name, baseline, post, expected_rc
    local got; got=$(_cmp_reg "$2" "$3")
    if [[ "$got" == "$4" ]]; then ok "$1 (rc=$got, both copies agree)"; else bad "$1: expected $4, got '$got'"; fi
}

_reg_case "P1: no regression (GREEN→GREEN)"      'check_01_containers=GREEN' 'check_01_containers=GREEN' 0
_reg_case "P2: regression (GREEN→RED)"           'check_01_containers=GREEN' 'check_01_containers=RED'   1
_reg_case "P3: pre-existing drift (RED→RED)"     'check_01_containers=RED'   'check_01_containers=RED'   0
_reg_case "P4: healed (RED→GREEN)"               'check_01_containers=RED'   'check_01_containers=GREEN' 0
_reg_case "P5: mixed regression+drift"           $'check_01_containers=GREEN\ncheck_02_api=RED' $'check_01_containers=RED\ncheck_02_api=RED' 1
_reg_case "P6: absent-in-post (conservative)"    'check_01_containers=GREEN' 'check_99_other=GREEN'      0

# absent baseline: both must skip the diff (rc 0).
BL_EMPTY=$(mktemp); PO=$(mktemp); printf 'check_01_containers=RED\n' > "$PO"
if _settle_hc_regressions "$BL_EMPTY" "$PO" >/dev/null 2>&1; then A=0; else A=$?; fi
if health_regressions     "$BL_EMPTY" "$PO" >/dev/null 2>&1; then B=0; else B=$?; fi
rm -f "$BL_EMPTY" "$PO"
if [[ "$A" == 0 && "$B" == 0 ]]; then ok "P7: absent/empty baseline → both skip diff (rc=0)"; else bad "P7: inline=$A lib=$B (expected 0/0)"; fi

# ── Snapshot capture parity: valid / garbage / non-executable / valid-but-exit-nonzero. ──
BIN=$(mktemp); OUT=$(mktemp)
_cmp_snap() {   # writes stub body from stdin, compares rc → echoes rc or DIVERGE
    cat > "$BIN"; chmod +x "$BIN"
    local a b
    : > "$OUT"; _settle_hc_snapshot "$BIN" "$OUT" >/dev/null 2>&1; a=$?
    : > "$OUT"; health_snapshot     "$BIN" "$OUT" >/dev/null 2>&1; b=$?
    if [[ "$a" == "$b" ]]; then printf '%s' "$a"; else printf 'DIVERGE(inline=%s lib=%s)' "$a" "$b"; fi
}

got=$(printf '#!/bin/sh\nprintf "check_01=GREEN\\n"\nexit 0\n' | _cmp_snap)
[[ "$got" == 0 ]] && ok "P8: valid snapshot → both rc=0" || bad "P8: expected 0, got '$got'"

got=$(printf '#!/bin/sh\nprintf "garbage no equals\\n"\nexit 0\n' | _cmp_snap)
[[ "$got" == 1 ]] && ok "P9: unparseable output → both rc=1" || bad "P9: expected 1, got '$got'"

# BUG3: valid parseable lines but non-zero exit → both must KEEP the snapshot (rc=0).
got=$(printf '#!/bin/sh\nprintf "check_01=RED\\n"\nexit 2\n' | _cmp_snap)
[[ "$got" == 0 ]] && ok "P10: valid-but-exit-nonzero (BUG3) → both rc=0 (no false rollback)" || bad "P10: expected 0, got '$got'"

chmod -x "$BIN"
: > "$OUT"; if _settle_hc_snapshot "$BIN" "$OUT" >/dev/null 2>&1; then A=0; else A=$?; fi
: > "$OUT"; if health_snapshot     "$BIN" "$OUT" >/dev/null 2>&1; then B=0; else B=$?; fi
if [[ "$A" == 1 && "$B" == 1 ]]; then ok "P11: non-executable binary → both rc=1"; else bad "P11: inline=$A lib=$B (expected 1/1)"; fi
rm -f "$BIN" "$OUT"

# ── Serve-ability wiring must be present in the settle path (P3) + tied to the
#    server-side oracle so neither drifts silently. ──
SETTLE=$(awk '/^settle_healthcheck_with_retry\(\)/{f=1} f{print} /^}$/ && f{exit}' "$UPGRADE")
grep -q '_settle_serveability_adjudicate' <<<"$SETTLE" \
    && ok "W1: settle wires _settle_serveability_adjudicate (serve-ability gate live)" \
    || bad "W1: settle no longer references _settle_serveability_adjudicate"
grep -q '_settle_nonchannel_regression' <<<"$SETTLE" \
    && ok "W2: settle wires _settle_nonchannel_regression (non-channel stays strict)" \
    || bad "W2: settle no longer references _settle_nonchannel_regression"
for fn in _settle_serveability_snapshot _settle_serveability_adjudicate _settle_serveability_alert _settle_nonchannel_regression; do
    grep -qE "^${fn}\(\) \{" "$UPGRADE" \
        && ok "W3: ${fn}() defined" \
        || bad "W3: ${fn}() missing"
done
grep -q 'health_poller.rs' "$UPGRADE" \
    && ok "W4: serve-ability OR-quorum ties to the server oracle (health_poller.rs) — divergence guard" \
    || bad "W4: lost the health_poller.rs tie comment (edge/server oracles may drift)"

echo
echo "── dual-pin fitness: $PASS passed, $FAIL failed ──"
[[ "$FAIL" -eq 0 ]] || exit 1
