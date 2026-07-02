#!/bin/bash
# Behavioral regression: emit_metric() must OVERWRITE the Prometheus textfile
# per run, not accumulate across runs.
#
# Finding (bug-hunt federation-critical-surfaces-2026-07-01.md, T11,
# config_drift/high/certain): oxpulse-partner-edge-refresh.sh:44-51's doc
# comment promises "overwrites the file on every run so stale gauges do not
# accumulate" but the implementation only ever appends (`>>`, line 50). After
# the 2nd consecutive failing day partner_edge.prom holds duplicate
# `# TYPE` / duplicate-label lines -> invalid Prometheus exposition ->
# node_exporter's textfile collector errors on the whole file -> the
# central-unreachable / heartbeat-stale counters this file exists to surface
# silently stop being scraped at all.
#
# Test 1 reproduces the finding directly: run the keys-fetch-failure emit
# path twice (two failing days) and assert the resulting file contains
# exactly ONE `# TYPE partner_edge_keys_fetch_failure_total counter` line.
#
# Test 2 guards the other half of the fix's contract ("truncate once at the
# top of the run, not per emit_metric call"): within a SINGLE run where BOTH
# keys-fetch and heartbeat fail, both metrics must land in the same file —
# a naive per-call truncate would wipe the first metric before writing the
# second.
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SCRIPT="$REPO_ROOT/oxpulse-partner-edge-refresh.sh"

[[ -f "$SCRIPT" ]] || { echo "FAIL: refresh script not found at $SCRIPT"; exit 1; }

pass() { echo "OK: $*"; }
fail() { echo "FAIL: $*"; exit 1; }

# Helper: create a stub bin dir with essential POSIX utilities (matches the
# pattern used by test_refresh_heartbeat_decoupled.sh / test_refresh_heartbeat_resilience.sh).
make_bin() {
    local dir="$1"
    for cmd in bash sh date printf cat tee cp mv mkdir chmod install sleep \
                sed grep head tail wc stat cut tr expr test; do
        local loc
        loc=$(command -v "$cmd" 2>/dev/null || true)
        if [[ -n "$loc" ]]; then ln -sf "$loc" "$dir/$cmd"; fi
    done
    cat > "$dir/systemctl" <<'STUB'
#!/bin/sh
exit 0
STUB
    chmod +x "$dir/systemctl"
}

# ── Test 1: two consecutive failing-day runs → exactly ONE # TYPE line ────────
T1=$(mktemp -d)
trap 'rm -rf "$T1"' EXIT

make_bin "$T1"

if command -v jq >/dev/null 2>&1; then
    ln -sf "$(command -v jq)" "$T1/jq"
else
    fail "test1 setup: real jq required on test host"
fi

TEXTFILE_DIR1="$T1/textfile"
mkdir -p "$TEXTFILE_DIR1"

# curl stub: heartbeat always succeeds; keys fetch always fails (DNS error) —
# simulates the "central unreachable" failing-day scenario from the finding.
cat > "$T1/curl" <<CURLSTUB1
#!/bin/bash
for arg in "\$@"; do
    if [[ "\$arg" == *partner/heartbeat* ]]; then
        echo '{"ok":true}'
        echo '200'
        exit 0
    fi
done
echo 'curl: (6) Could not resolve host' >&2
exit 6
CURLSTUB1
chmod +x "$T1/curl"

mkdir -p "$T1/etc"
printf '{"node_id":"test-node-t11"}\n' > "$T1/etc/node-config.json"
mkdir -p "$T1/var"

run_day() {
    PATH="$T1" \
        LOG_FILE="$T1/refresh.log" \
        PARTNER_EDGE_PREFIX_ETC="$T1/etc" \
        PARTNER_EDGE_PREFIX_LIB="$T1/var" \
        PARTNER_EDGE_TEXTFILE_DIR="$TEXTFILE_DIR1" \
        OXPULSE_BACKEND_URL="http://broken-dns-hostname.invalid" \
        bash "$SCRIPT" >"$T1/out.txt" 2>&1
}

set +e
run_day
DAY1_EXIT=$?
set -e
[[ $DAY1_EXIT -eq 0 ]] \
    || fail "test1 day1: script must exit 0 even when keys fetch fails (got exit $DAY1_EXIT); output: $(cat "$T1/out.txt")"

set +e
run_day
DAY2_EXIT=$?
set -e
[[ $DAY2_EXIT -eq 0 ]] \
    || fail "test1 day2: script must exit 0 even when keys fetch fails (got exit $DAY2_EXIT); output: $(cat "$T1/out.txt")"

PROM_FILE1="$TEXTFILE_DIR1/partner_edge.prom"
[[ -f "$PROM_FILE1" ]] \
    || fail "test1: $PROM_FILE1 not created after 2 failing-day runs"

TYPE_COUNT=$(grep -c '^# TYPE partner_edge_keys_fetch_failure_total counter$' "$PROM_FILE1" || true)
[[ "$TYPE_COUNT" -eq 1 ]] \
    || fail "test1: expected exactly ONE '# TYPE partner_edge_keys_fetch_failure_total counter' line after 2 failing-day runs, got $TYPE_COUNT; file contents: $(cat "$PROM_FILE1")"

METRIC_LINE_COUNT=$(grep -c '^partner_edge_keys_fetch_failure_total{' "$PROM_FILE1" || true)
[[ "$METRIC_LINE_COUNT" -eq 1 ]] \
    || fail "test1: expected exactly ONE partner_edge_keys_fetch_failure_total sample line after 2 failing-day runs, got $METRIC_LINE_COUNT; file contents: $(cat "$PROM_FILE1")"

pass "test1: 2 consecutive failing-day runs -> exactly 1 # TYPE line + 1 sample line (no cross-run accumulation)"

trap - EXIT
rm -rf "$T1"

# ── Test 2: within ONE run, keys-fetch AND heartbeat both fail → both metrics
#    land in the same file (truncate must happen once at top-of-run, not per
#    emit_metric call — otherwise the 2nd call would wipe the 1st).
T2=$(mktemp -d)
trap 'rm -rf "$T2"' EXIT

make_bin "$T2"

if command -v jq >/dev/null 2>&1; then
    ln -sf "$(command -v jq)" "$T2/jq"
else
    fail "test2 setup: real jq required on test host"
fi

TEXTFILE_DIR2="$T2/textfile"
mkdir -p "$TEXTFILE_DIR2"

# curl stub: keys fetch fails (DNS), heartbeat reaches the server but gets 500.
cat > "$T2/curl" <<CURLSTUB2
#!/bin/bash
for arg in "\$@"; do
    if [[ "\$arg" == *partner/heartbeat* ]]; then
        echo '{"error":"internal"}'
        echo '500'
        exit 0
    fi
done
echo 'curl: (6) Could not resolve host' >&2
exit 6
CURLSTUB2
chmod +x "$T2/curl"

mkdir -p "$T2/etc"
printf '{"node_id":"test-node-t11b"}\n' > "$T2/etc/node-config.json"
mkdir -p "$T2/var"

set +e
PATH="$T2" \
    LOG_FILE="$T2/refresh.log" \
    PARTNER_EDGE_PREFIX_ETC="$T2/etc" \
    PARTNER_EDGE_PREFIX_LIB="$T2/var" \
    PARTNER_EDGE_TEXTFILE_DIR="$TEXTFILE_DIR2" \
    OXPULSE_BACKEND_URL="http://broken-dns-hostname.invalid" \
    bash "$SCRIPT" >"$T2/out.txt" 2>&1
EXIT2=$?
set -e
[[ $EXIT2 -eq 0 ]] \
    || fail "test2: script must exit 0 (got exit $EXIT2); output: $(cat "$T2/out.txt")"

PROM_FILE2="$TEXTFILE_DIR2/partner_edge.prom"
[[ -f "$PROM_FILE2" ]] \
    || fail "test2: $PROM_FILE2 not created"

grep -q '^partner_edge_keys_fetch_failure_total{' "$PROM_FILE2" \
    || fail "test2: partner_edge_keys_fetch_failure_total missing from same-run file; got: $(cat "$PROM_FILE2")"
grep -q '^partner_edge_heartbeat_failure_total{' "$PROM_FILE2" \
    || fail "test2: partner_edge_heartbeat_failure_total missing from same-run file (truncate must NOT run per-call); got: $(cat "$PROM_FILE2")"

pass "test2: keys-fetch + heartbeat both fail in ONE run -> both metrics present (per-run truncate, not per-call)"

trap - EXIT
rm -rf "$T2"

# ── Syntax check ──────────────────────────────────────────────────────────────
bash -n "$SCRIPT" \
    || fail "refresh script has syntax errors"
pass "syntax check clean"

echo ""
echo "All tests passed."
