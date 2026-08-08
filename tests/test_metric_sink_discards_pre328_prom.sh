#!/usr/bin/env bash
# tests/test_metric_sink_discards_pre328_prom.sh
#
# #328 fixed emit_metric's duplicate-TYPE-line bug. It did not clean up the
# files the broken version had already written, and nothing since has: the
# regeneration path runs inside emit_metric, whose only callers are FAILURE
# counters, so on a healthy node it may not run for months. Measured
# 2026-08-08, all five production edges still carried a pre-#328
# partner_edge.prom dated May or June, with duplicate series.
#
# Harmless while nothing read the directory. Not harmless once the collector
# from #570 lands: the textfile collector rejects a duplicate by discarding the
# WHOLE file and raising node_textfile_scrape_error, so a fresh collector's
# first report would be a parse error rather than data.
#
# This guards the migration that removes them, and — more importantly — guards
# the two ways the migration itself could do damage: deleting a file it should
# keep, and returning non-zero into a `set -e` caller.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO_ROOT/lib/metric-sink-lib.sh"
fails=0
_fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }
_ok()   { echo "  ok: $*"; }

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

# The lib reads $TEXTFILE_DIR at call time; every case below passes an explicit
# directory instead, so no case can leak into another.
TEXTFILE_DIR="$TMPD/unused"
# shellcheck source=lib/metric-sink-lib.sh
source "$LIB"

# The exposition that is actually on the fleet — duplicate TYPE line and a
# duplicate series, copied from rvpn 2026-08-08.
_fossil() {
    cat <<'EOF'
# TYPE partner_edge_keys_fetch_failure_total counter
partner_edge_keys_fetch_failure_total{partner_id="rvpn-seed"} 1
# TYPE partner_edge_heartbeat_failure_total counter
partner_edge_heartbeat_failure_total{partner_id="rvpn-seed"} 1
# TYPE partner_edge_keys_fetch_failure_total counter
partner_edge_keys_fetch_failure_total{partner_id="rvpn-seed"} 1
EOF
}

# ---------------------------------------------------------------------------
# S0. Anti-vacuous floor. Every case below calls the function; if it is absent
# or renamed, `command -v` fails here rather than each case quietly passing.
# ---------------------------------------------------------------------------
if ! command -v metric_sink_discard_pre328_prom >/dev/null 2>&1; then
    _fail "S0: metric_sink_discard_pre328_prom is not defined after sourcing $LIB"
    echo "RESULT: $fails failure(s)"; exit 1
fi
_ok "S0: function defined"

# Prove the fixture really is invalid exposition, so S1 is removing something
# that would genuinely break a collector rather than an arbitrary file.
dup_count=$(_fossil | grep -c '^# TYPE partner_edge_keys_fetch_failure_total counter')
if (( dup_count < 2 )); then
    _fail "S0b: fixture is not a duplicate-TYPE file ($dup_count TYPE lines) — the premise of this test"
else
    _ok "S0b: fixture carries $dup_count duplicate TYPE lines, as measured on the fleet"
fi

# ---------------------------------------------------------------------------
# S1. .prom without .state -> discarded, path reported.
# ---------------------------------------------------------------------------
d="$TMPD/case1"; mkdir -p "$d"
_fossil > "$d/partner_edge.prom"
out=$(metric_sink_discard_pre328_prom "$d"); rc=$?
if [[ -e "$d/partner_edge.prom" ]]; then
    _fail "S1: pre-#328 file survived the migration"
elif [[ "$out" != "$d/partner_edge.prom" ]]; then
    _fail "S1: discarded but did not report the path (got: '$out')"
elif (( rc != 0 )); then
    _fail "S1: returned $rc — a non-zero return kills a `set -e` caller"
else
    _ok "S1: stateless .prom discarded and reported"
fi

# ---------------------------------------------------------------------------
# S2. THE ONE THAT MATTERS FOR DAMAGE — .prom WITH .state is kept.
#
# A live file is the post-#328 writer's own output and its counters exist
# nowhere else. Deleting it would silently reset every counter on the node,
# turning a cleanup into data loss.
# ---------------------------------------------------------------------------
d="$TMPD/case2"; mkdir -p "$d"
printf '# TYPE partner_edge_x counter\npartner_edge_x{a="b"} 7\n' > "$d/partner_edge.prom"
printf 'partner_edge_x\ta="b"\t7\n' > "$d/partner_edge.prom.state"
out=$(metric_sink_discard_pre328_prom "$d"); rc=$?
if [[ ! -e "$d/partner_edge.prom" ]]; then
    _fail "S2: DATA LOSS — a live .prom with its .state beside it was deleted"
elif [[ -n "$out" ]]; then
    _fail "S2: reported a discard that did not happen (got: '$out')"
elif (( rc != 0 )); then
    _fail "S2: returned $rc on the no-op path"
else
    _ok "S2: live .prom with .state left untouched"
fi

# ---------------------------------------------------------------------------
# S3. Sibling files are never touched. emit_gauge owns its own per-metric
# files; only partner_edge.prom belongs to emit_metric.
# ---------------------------------------------------------------------------
d="$TMPD/case3"; mkdir -p "$d"
_fossil > "$d/partner_edge.prom"
printf '# TYPE partner_edge_sni_pick_index gauge\npartner_edge_sni_pick_index 3\n' \
    > "$d/partner_edge_sni_pick_index.prom"
printf '# TYPE partner_edge_xray gauge\npartner_edge_xray 1\n' > "$d/partner_edge_xray.prom"
metric_sink_discard_pre328_prom "$d" >/dev/null
survivors=$(find "$d" -name '*.prom' -exec basename {} \; | sort | tr '\n' ' ')
if [[ "$survivors" == "partner_edge_sni_pick_index.prom partner_edge_xray.prom " ]]; then
    _ok "S3: siblings survive, only partner_edge.prom removed ($survivors)"
else
    _fail "S3: wrong survivor set — got '$survivors'"
fi

# ---------------------------------------------------------------------------
# S4. Nothing to do: no .prom at all, and a missing directory.
# ---------------------------------------------------------------------------
d="$TMPD/case4"; mkdir -p "$d"
out=$(metric_sink_discard_pre328_prom "$d"); rc=$?
[[ -z "$out" && $rc -eq 0 ]] && _ok "S4a: empty dir is a silent no-op" \
                             || _fail "S4a: empty dir returned rc=$rc out='$out'"
out=$(metric_sink_discard_pre328_prom "$TMPD/does-not-exist"); rc=$?
[[ -z "$out" && $rc -eq 0 ]] && _ok "S4b: missing dir is a silent no-op" \
                             || _fail "S4b: missing dir returned rc=$rc out='$out'"

# ---------------------------------------------------------------------------
# S5. Round trip: after the discard, emit_metric produces VALID exposition.
# The migration is only worth doing if what replaces the fossil parses.
# ---------------------------------------------------------------------------
d="$TMPD/case5"; mkdir -p "$d"
_fossil > "$d/partner_edge.prom"
metric_sink_discard_pre328_prom "$d" >/dev/null
(
    TEXTFILE_DIR="$d"
    emit_metric "partner_edge_keys_fetch_failure_total" 'partner_id="rvpn"' 1
    emit_metric "partner_edge_keys_fetch_failure_total" 'partner_id="rvpn"' 1
    emit_metric "partner_edge_heartbeat_failure_total"  'partner_id="rvpn"' 1
)
new="$d/partner_edge.prom"
if [[ ! -f "$new" ]]; then
    _fail "S5: emit_metric produced no file after the discard"
else
    type_dups=$(grep '^# TYPE' "$new" | sort | uniq -d)
    series_dups=$(grep -v '^#' "$new" | sed 's/ [0-9]*$//' | sort | uniq -d)
    if [[ -n "$type_dups" || -n "$series_dups" ]]; then
        _fail "S5: regenerated file is still invalid — dupTYPE='$type_dups' dupSeries='$series_dups'"
    else
        _ok "S5: regenerated file is valid exposition"
    fi
    # Two increments of the same series must accumulate to 2, not appear twice.
    if grep -qE '^partner_edge_keys_fetch_failure_total\{partner_id="rvpn"\} 2$' "$new"; then
        _ok "S5b: repeated emits accumulate (counter reads 2)"
    else
        _fail "S5b: counter did not accumulate — file says: $(grep keys_fetch "$new" | tr '\n' ' ')"
    fi
    # Validate the OUTPUT SHAPE, never the exit code. BSD stat spells the mode
    # `-f %Lp` and GNU spells it `-c %a` — but GNU's `-f` means --file-system,
    # so on a box where GNU coreutils is first in PATH the BSD form SUCCEEDS
    # and prints filesystem stats. An `A || B` fallback therefore never reaches
    # B, and the check silently compares against garbage.
    mode=""
    for _statfmt in "-c %a" "-f %Lp"; do
        # shellcheck disable=SC2086  # intentional word-split of the format flag
        _m=$(stat $_statfmt "$new" 2>/dev/null | tr -d '[:space:]')
        if [[ "$_m" =~ ^[0-7]{3,4}$ ]]; then mode="$_m"; break; fi
    done
    if [[ -z "$mode" ]]; then
        _fail "S5c: could not read the file mode with either stat dialect"
    elif [[ "$mode" == "644" || "$mode" == "0644" ]]; then
        _ok "S5c: regenerated file is 0644 (readable by the unprivileged collector)"
    else
        _fail "S5c: mode is $mode — the collector runs unprivileged and needs 0644"
    fi
fi

# ---------------------------------------------------------------------------
# S6. WIRING. Everything above tests a function; none of it would notice if
# nothing ever called it. A migration that exists and is never invoked is
# indistinguishable from no migration at all, and reads as done in review.
# ---------------------------------------------------------------------------
REFRESH="$REPO_ROOT/oxpulse-partner-edge-refresh.sh"
if [[ ! -f "$REFRESH" ]]; then
    _fail "S6: $REFRESH not found"
else
    call_line=$(grep -n 'metric_sink_discard_pre328_prom' "$REFRESH" | grep -v '^\s*#' | head -1 | cut -d: -f1)
    source_line=$(grep -n 'source "\$_MSL_LOCAL"' "$REFRESH" | head -1 | cut -d: -f1)
    if [[ -z "$call_line" ]]; then
        _fail "S6: oxpulse-partner-edge-refresh.sh never calls metric_sink_discard_pre328_prom — the migration would never run on a real node"
    elif [[ -z "$source_line" ]]; then
        _fail "S6: could not locate where the refresh script sources metric-sink-lib.sh — ordering is unverifiable"
    elif (( call_line < source_line )); then
        _fail "S6: the call (line $call_line) precedes sourcing the lib (line $source_line) — it would fail with 'command not found'"
    else
        _ok "S6: refresh script calls the migration at line $call_line, after sourcing at line $source_line"
    fi
fi

echo
if (( fails == 0 )); then echo "RESULT: all checks passed"; exit 0; fi
echo "RESULT: $fails failure(s)"; exit 1
