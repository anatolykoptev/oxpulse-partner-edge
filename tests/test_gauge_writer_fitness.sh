#!/bin/bash
# tests/test_gauge_writer_fitness.sh — P1b of the 2026-07-08
# refresh-lib-extraction-strangler plan: exactly ONE atomic own-file-per-gauge
# Prometheus textfile-writer implementation repo-wide.
#
# P1 authored lib/metric-sink-lib.sh's `_emit_prom_gauge_file` as the canonical
# atomic gauge shape (tmp+mv, own file per gauge, `# TYPE %s gauge` format),
# adopted verbatim from lib/reconcile.sh's pre-P1b `_reconcile_emit_prom_gauge`.
# Until P1b, lib/reconcile.sh still carried its OWN copy of that same body —
# two fleet-distributed implementations of one atomic primitive, silently
# divergeable (a future bugfix to one copy, e.g. a chmod/race fix, could be
# forgotten in the other). P1b retargets lib/reconcile.sh's
# `_reconcile_emit_prom_gauge` onto lib/metric-sink-lib.sh's
# `_emit_prom_gauge_file` via a lazy call-time source (reconcile.sh's own
# established convention for its lib/firewall-lib.sh and
# lib/telegram-alert-lib.sh dependencies) instead of re-implementing the write.
#
# Covers:
#   1. Fitness (static): the atomic-write printf body
#      (`printf '# TYPE %s gauge\n' ...`) exists in exactly ONE *.sh file
#      repo-wide — lib/metric-sink-lib.sh. lib/reconcile.sh's
#      `_reconcile_emit_prom_gauge` must no longer contain its own copy.
#   2. Wiring (static): lib/reconcile.sh's `_reconcile_emit_prom_gauge` calls
#      `_emit_prom_gauge_file` (delegates) rather than writing the file itself.
#   3. Behavioral: calling `_reconcile_emit_prom_gauge` through the real
#      lib/reconcile.sh (with only lib/metric-sink-lib.sh's
#      `_emit_prom_gauge_file` co-located, no other gauge implementation in
#      scope) produces output BYTE-FOR-BYTE identical to calling
#      `_emit_prom_gauge_file` directly — the consolidation did not change the
#      on-disk contract node_exporter's textfile collector parses.
#   4. All 3 existing wrapper callers (_reconcile_xray_emit_gauge,
#      _reconcile_caddy_emit_drift_gauge, _reconcile_firewall_emit_gauge) are
#      still defined, unchanged names/signatures, and still route through
#      `_reconcile_emit_prom_gauge` (no caller had to be touched).
set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
RECONCILE_LIB="$REPO_ROOT/lib/reconcile.sh"
METRIC_SINK_LIB="$REPO_ROOT/lib/metric-sink-lib.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

echo ""
echo "=== gauge-writer fitness (P1b: one atomic implementation repo-wide) ==="

if [[ ! -f "$RECONCILE_LIB" || ! -f "$METRIC_SINK_LIB" ]]; then
    fail "lib/reconcile.sh or lib/metric-sink-lib.sh not found"
    echo "FAIL: 0/$((PASS+FAIL)) tests passed"
    exit 1
fi
pass "lib/reconcile.sh and lib/metric-sink-lib.sh exist"

# ---------------------------------------------------------------------------
# 1. Exactly one atomic-write implementation repo-wide.
# ---------------------------------------------------------------------------
cd "$REPO_ROOT" || exit 1
HITS=$(git ls-files '*.sh' | xargs grep -lF "printf '# TYPE %s gauge" 2>/dev/null || true)
COUNT=$(printf '%s\n' "$HITS" | grep -c . || true)

if [[ "$COUNT" -eq 1 ]]; then
    pass "exactly one file contains the atomic gauge-write printf body ('printf '\''# TYPE %s gauge'\'')"
else
    fail "expected exactly 1 file with the atomic gauge-write printf body, found $COUNT: $HITS"
fi

if [[ "$HITS" == "lib/metric-sink-lib.sh" ]]; then
    pass "the sole implementation lives in lib/metric-sink-lib.sh (the canonical primitive)"
else
    fail "expected the sole implementation at lib/metric-sink-lib.sh, found: $HITS"
fi

if grep -qF "printf '# TYPE %s gauge" "$RECONCILE_LIB"; then
    fail "lib/reconcile.sh still contains its own atomic gauge-write printf body — duplicate not removed"
else
    pass "lib/reconcile.sh no longer contains its own atomic gauge-write printf body"
fi

# ---------------------------------------------------------------------------
# 2. Wiring: _reconcile_emit_prom_gauge delegates to _emit_prom_gauge_file.
# ---------------------------------------------------------------------------
BODY=$(awk '/^_reconcile_emit_prom_gauge\(\)/{found=1} found{print} /^}$/ && found{exit}' "$RECONCILE_LIB")
if echo "$BODY" | grep -q '_emit_prom_gauge_file "\$@"'; then
    pass "_reconcile_emit_prom_gauge delegates to _emit_prom_gauge_file"
else
    fail "_reconcile_emit_prom_gauge does not call _emit_prom_gauge_file — delegation missing"
fi

# ---------------------------------------------------------------------------
# 3. Behavioral: byte-for-byte identical output via the delegating wrapper vs.
#    the primitive called directly.
# ---------------------------------------------------------------------------
T1=$(mktemp -d)
T2=$(mktemp -d)
trap 'rm -rf "$T1" "$T2"' EXIT

export LIB_DIR="$REPO_ROOT/lib"

(
    # shellcheck source=lib/reconcile.sh
    . "$RECONCILE_LIB"
    warn() { :; }
    PARTNER_EDGE_TEXTFILE_DIR="$T1" _reconcile_emit_prom_gauge \
        "partner_edge_xray.prom" "partner_edge_xray_creds_unresolved" "1"
)
(
    # shellcheck source=lib/metric-sink-lib.sh
    . "$METRIC_SINK_LIB"
    PARTNER_EDGE_TEXTFILE_DIR="$T2" _emit_prom_gauge_file \
        "partner_edge_xray.prom" "partner_edge_xray_creds_unresolved" "1"
)

if [[ -f "$T1/partner_edge_xray.prom" && -f "$T2/partner_edge_xray.prom" ]]; then
    SHA1=$(sha256sum "$T1/partner_edge_xray.prom" | awk '{print $1}')
    SHA2=$(sha256sum "$T2/partner_edge_xray.prom" | awk '{print $1}')
    if [[ "$SHA1" == "$SHA2" ]]; then
        pass "_reconcile_emit_prom_gauge (delegating) output is byte-for-byte identical to _emit_prom_gauge_file called directly"
    else
        fail "output diverged: via-wrapper=$(cat "$T1/partner_edge_xray.prom") direct=$(cat "$T2/partner_edge_xray.prom")"
    fi
else
    fail "one or both gauge files were not created (T1=$T1 T2=$T2)"
fi

# ---------------------------------------------------------------------------
# 4. All 3 existing wrapper callers still defined, unchanged, still route
#    through _reconcile_emit_prom_gauge.
# ---------------------------------------------------------------------------
for fn in _reconcile_xray_emit_gauge _reconcile_caddy_emit_drift_gauge _reconcile_firewall_emit_gauge; do
    if ! grep -qE "^${fn}\\(\\)" "$RECONCILE_LIB"; then
        fail "$fn is no longer defined in lib/reconcile.sh"
        continue
    fi
    FBODY=$(awk "/^${fn}\\(\\)/{found=1} found{print} /^}\$/ && found{exit}" "$RECONCILE_LIB")
    if echo "$FBODY" | grep -q '_reconcile_emit_prom_gauge '; then
        pass "$fn is unchanged and still routes through _reconcile_emit_prom_gauge"
    else
        fail "$fn no longer calls _reconcile_emit_prom_gauge — caller was touched unexpectedly"
    fi
done

# ---------------------------------------------------------------------------
# Syntax check.
# ---------------------------------------------------------------------------
bash -n "$RECONCILE_LIB" && pass "lib/reconcile.sh syntax check clean" || fail "lib/reconcile.sh syntax error"
bash -n "$METRIC_SINK_LIB" && pass "lib/metric-sink-lib.sh syntax check clean" || fail "lib/metric-sink-lib.sh syntax error"

echo ""
echo "=== gauge-writer fitness: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
