#!/bin/bash
# tests/test_refresh_metric_sink.sh — emit_metric's textfile sink must stay a
# VALID Prometheus exposition file across repeated daily runs.
#
# PR review MED-4 on #328: the prior implementation `>>`-appended a fresh
# `# TYPE <name> counter` line on EVERY call, forever. Two consecutive daily
# failures of the SAME metric produce TWO `# TYPE` lines for that metric in
# the same file — invalid Prometheus exposition format (a metric family's
# TYPE line must appear exactly once, with its samples contiguous).
# node_exporter's textfile collector does not skip just the bad family on a
# parse error — it drops the ENTIRE .prom file, silently blackholing every
# counter this script emits, including metrics unrelated to the one that
# caused the duplicate.
#
# This test runs the refresh script 3 times against the SAME textfile dir
# (simulating 3 consecutive daily systemd-timer ticks that each hit a
# failure), across TWO distinct metric families at once (keys-fetch failure
# + cross-probe-token failure, both triggered by every run), and asserts:
#   1. exactly one `# TYPE` line per metric name (not 3, not interleaved)
#   2. each counter's value is the CUMULATIVE count across the 3 runs (not a
#      flat "1" re-written every day) — the actual increase()/rate() contract.
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SCRIPT="$REPO_ROOT/oxpulse-partner-edge-refresh.sh"

[[ -f "$SCRIPT" ]] || { echo "FAIL: refresh script not found at $SCRIPT"; exit 1; }

pass() { echo "OK: $*"; }
fail() { echo "FAIL: $*"; exit 1; }

make_bin() {
    local dir="$1"
    for cmd in bash sh date printf cat tee cp mv mkdir chmod install sleep \
                sed grep head tail wc stat cut tr expr test touch \
                dirname mktemp basename sha256sum; do
        local loc
        loc=$(command -v "$cmd" 2>/dev/null || true)
        if [[ -n "$loc" ]]; then ln -sf "$loc" "$dir/$cmd"; fi
    done
    cat > "$dir/systemctl" <<'STUB'
#!/bin/sh
exit 0
STUB
    chmod +x "$dir/systemctl"
    if command -v jq >/dev/null 2>&1; then ln -sf "$(command -v jq)" "$dir/jq"; fi
}

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

make_bin "$T"

# curl stub: keys endpoint fails (DNS-style), heartbeat succeeds, and we
# deliberately give NO service token so the cross-probe leg fails on its own
# independent reason (no_service_token) — both metric families fire on
# EVERY run.
cat > "$T/curl" <<'CURLSTUB'
#!/bin/bash
for arg in "$@"; do
    if [[ "$arg" == *partner/heartbeat* ]]; then
        echo '{"ok":true}'
        echo '200'
        exit 0
    fi
done
echo 'curl: (6) Could not resolve host' >&2
exit 6
CURLSTUB
chmod +x "$T/curl"

mkdir -p "$T/etc" "$T/var" "$T/textfile"
printf '{"node_id":"test-node-sink"}\n' > "$T/etc/node-config.json"

run_once() {
    PATH="$T" \
        LOG_FILE="$T/refresh.log" \
        PARTNER_EDGE_PREFIX_ETC="$T/etc" \
        PARTNER_EDGE_PREFIX_LIB="$T/var" \
        PARTNER_EDGE_TEXTFILE_DIR="$T/textfile" \
        OXPULSE_BACKEND_URL="http://broken-dns-hostname.invalid" \
        bash "$SCRIPT" >>"$T/out.txt" 2>&1
}

set +e
run_once; RC1=$?
run_once; RC2=$?
run_once; RC3=$?
set -e

[[ $RC1 -eq 0 && $RC2 -eq 0 && $RC3 -eq 0 ]] \
    || fail "all 3 runs must exit 0 (got $RC1 $RC2 $RC3); output: $(cat "$T/out.txt")"

PROM_FILE="$T/textfile/partner_edge.prom"
[[ -f "$PROM_FILE" ]] || fail "$PROM_FILE not created after 3 runs"

# ---- Test 1: exactly one # TYPE line per metric name ----
KEYS_TYPE_COUNT=$(grep -c '^# TYPE partner_edge_keys_fetch_failure_total counter$' "$PROM_FILE")
[[ "$KEYS_TYPE_COUNT" -eq 1 ]] \
    || fail "test1: expected exactly 1 '# TYPE partner_edge_keys_fetch_failure_total counter' line after 3 runs, got $KEYS_TYPE_COUNT; file: $(cat "$PROM_FILE")"

XPRB_TYPE_COUNT=$(grep -c '^# TYPE partner_edge_cross_probe_token_refresh_failure_total counter$' "$PROM_FILE")
[[ "$XPRB_TYPE_COUNT" -eq 1 ]] \
    || fail "test1: expected exactly 1 '# TYPE partner_edge_cross_probe_token_refresh_failure_total counter' line after 3 runs, got $XPRB_TYPE_COUNT; file: $(cat "$PROM_FILE")"

pass "test1: exactly one # TYPE line per metric name across 3 repeated daily runs (no duplicate-TYPE exposition corruption)"

# ---- Test 2: counters are CUMULATIVE across runs, not flat "1" ----
KEYS_VALUE=$(grep '^partner_edge_keys_fetch_failure_total{' "$PROM_FILE" | awk '{print $2}')
[[ "$KEYS_VALUE" == "3" ]] \
    || fail "test2: expected partner_edge_keys_fetch_failure_total to accumulate to 3 across 3 failing runs, got '$KEYS_VALUE' — a flat repeated \"1\" is invisible to increase()/rate(); file: $(cat "$PROM_FILE")"

XPRB_VALUE=$(grep '^partner_edge_cross_probe_token_refresh_failure_total{' "$PROM_FILE" | awk '{print $2}')
[[ "$XPRB_VALUE" == "3" ]] \
    || fail "test2: expected partner_edge_cross_probe_token_refresh_failure_total to accumulate to 3 across 3 failing runs, got '$XPRB_VALUE'; file: $(cat "$PROM_FILE")"

pass "test2: counters accumulate across runs (3 failing runs → value=3), usable by increase()/rate()"

# ---- Test 3: samples for each metric name stay contiguous under its TYPE ----
# (a mangled/interleaved family is also invalid exposition format even with
# a single TYPE line each — verify the sample immediately follows its TYPE).
awk '
    /^# TYPE / { expect = $3; next }
    /^[a-z]/ {
        name = $0; sub(/{.*/, "", name)
        if (name != expect) { print "MISMATCH: sample " name " not immediately after its own TYPE (expected " expect ")"; bad=1 }
    }
    END { if (bad) exit 1 }
' "$PROM_FILE" || fail "test3: a sample line does not immediately follow its own # TYPE line — invalid exposition grouping; file: $(cat "$PROM_FILE")"

pass "test3: every sample line immediately follows its own metric's # TYPE line (valid family grouping)"

# ---- Test 4 (PR review round 2, council LOW): a tampered state file survives ----
# Pre-seed the state file with a non-numeric 3rd (counter-value) field —
# simulates a hand-edited or otherwise corrupted partner_edge.prom.state.
# Without the `[[ $_v =~ ^[0-9]+$ ]] || _v=0` guard, `_v + delta` under
# `set -euo pipefail` throws an arithmetic error and takes down the WHOLE
# script — the same failure class HIGH-1 fixed for the write path, one line
# lower in emit_metric.
T4=$(mktemp -d)
trap 'rm -rf "$T4"' EXIT

make_bin "$T4"
cat > "$T4/curl" <<'CURLSTUB4'
#!/bin/bash
for arg in "$@"; do
    if [[ "$arg" == *partner/heartbeat* ]]; then
        echo '{"ok":true}'
        echo '200'
        exit 0
    fi
done
echo 'curl: (6) Could not resolve host' >&2
exit 6
CURLSTUB4
chmod +x "$T4/curl"

mkdir -p "$T4/etc" "$T4/var" "$T4/textfile"
printf '{"node_id":"test-node-tamper"}\n' > "$T4/etc/node-config.json"
printf 'partner_edge_keys_fetch_failure_total\tpartner_id="test-node-tamper"\tNOTANUMBER\n' \
    > "$T4/textfile/partner_edge.prom.state"

set +e
PATH="$T4" \
    LOG_FILE="$T4/refresh.log" \
    PARTNER_EDGE_PREFIX_ETC="$T4/etc" \
    PARTNER_EDGE_PREFIX_LIB="$T4/var" \
    PARTNER_EDGE_TEXTFILE_DIR="$T4/textfile" \
    OXPULSE_BACKEND_URL="http://broken-dns-hostname.invalid" \
    bash "$SCRIPT" >"$T4/out.txt" 2>&1
EXIT4=$?
set -e

[[ $EXIT4 -eq 0 ]] \
    || fail "test4: script must survive a tampered state file (non-numeric counter value), got exit $EXIT4; output: $(cat "$T4/out.txt")"

PROM_FILE4="$T4/textfile/partner_edge.prom"
[[ -f "$PROM_FILE4" ]] || fail "test4: $PROM_FILE4 not regenerated after a tampered state file"
VALUE4=$(grep '^partner_edge_keys_fetch_failure_total{' "$PROM_FILE4" | awk '{print $2}')
[[ "$VALUE4" == "1" ]] \
    || fail "test4: tampered value must reset to 0 before adding delta=1 (expected '1', got '$VALUE4')"

pass "test4 (arithmetic guard, round 2): a hand-tampered non-numeric state-file value resets to 0 instead of crashing the script"

trap - EXIT
rm -rf "$T4"

# ---- Syntax check ----
bash -n "$SCRIPT" || fail "refresh script has syntax errors"
pass "syntax check clean"

echo ""
echo "All tests passed."
