#!/usr/bin/env bash
# tests/test_coturn_probe_container_leak.sh — _coturn_probe_run must not leak
# containers in state `Created`.
#
# Live incident (relay node pillow, 2026-10-30): 130 never-started containers of
# the coturn image, entrypoint `timeout`, cmd `<N> turnutils_stunclient ...`,
# created 5-10/day. The outer `timeout` was the SAME value as the in-container
# one, so it killed the docker CLI while create/start was still in flight; the
# daemon aborts the start and `--rm` (AutoRemove, fires on exit of a STARTED
# container) never removes the corpse.
#
# The stub `docker run` models exactly that: it "creates" the container (a state
# file) first, then takes a while to "start" it, and only a run that survives to
# the end removes it again (the AutoRemove path). A run killed in between leaves
# the state file behind.
#
#   1  the docker-CLI timeout is strictly greater than the in-container bound
#   2  slow create/start (past the inner bound, inside the headroom) -> rc 0, no leak
#   3  CLI killed mid-start anyway -> the labelled container is force-removed by name
#   4  reaper removes stale labelled + legacy-signature Created probes, nothing else
#   5  the probe container carries the label and a unique name
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LIB="$REPO_ROOT/lib/channel-health-lib.sh"
[[ -f "$LIB" ]] || { echo "FAIL: $LIB not found"; exit 1; }

PASS=0; FAIL=0
ok()   { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
REAL_TIMEOUT=$(command -v timeout)

# stub dir: docker + a `timeout` wrapper that records its bound before delegating.
mk_stubs() { # mk_stubs DIR RUN_SLEEP
    local d="$1" run_sleep="$2"
    mkdir -p "$d/bin" "$d/state"
    : > "$d/docker.log"; : > "$d/timeout.log"
    cat > "$d/bin/timeout" <<STUB
#!/bin/bash
echo "\$*" >> "$d/timeout.log"
exec "$REAL_TIMEOUT" "\$@"
STUB
    cat > "$d/bin/docker" <<STUB
#!/bin/bash
echo "\$*" >> "$d/docker.log"
case "\$1" in
run)
    name=""
    for ((i = 1; i <= \$#; i++)); do [[ "\${!i}" == --name ]] && { j=\$((i + 1)); name="\${!j}"; }; done
    : > "$d/state/\$name"          # create
    sleep $run_sleep               # slow start; a SIGTERM here leaves the file
    rm -f "$d/state/\$name"        # started -> ran -> exited -> AutoRemove
    ;;
rm)
    shift; [[ "\$1" == -f ]] && shift
    for n in "\$@"; do rm -f "$d/state/\$n"; done
    ;;
ps)   # status=created listing for the reaper (rows file, optional)
    [[ -f "$d/rows" ]] && while IFS='|' read -r id _; do echo "\$id"; done < "$d/rows"
    ;;
inspect)
    shift; [[ "\$1" == --format ]] && shift 2
    [[ -f "$d/rows" ]] && while IFS= read -r row; do
        id=\${row%%|*}; for want in "\$@"; do [[ "\$want" == "\$id" ]] && echo "\$row"; done
    done < "$d/rows"
    ;;
esac
exit 0
STUB
    chmod +x "$d/bin/timeout" "$d/bin/docker"
}

# probe D SECS [HEADROOM] — source the lib in a subshell and run one probe.
probe() {
    local d="$1" secs="$2" headroom="${3:-}" rc
    set +e
    (
        export PATH="$d/bin:$PATH" OXPULSE_COTURN_PROBE_IMAGE=test-coturn-image
        log() { :; }; warn() { :; }
        _NODE_CONFIG="$d/node-config.json"
        # shellcheck disable=SC1090
        . "$LIB"
        [[ -n "$headroom" ]] && _COTURN_PROBE_CLIENT_HEADROOM="$headroom"
        _coturn_probe_run "$secs" turnutils_stunclient 203.0.113.9 -p 3478
    ) >/dev/null 2>&1
    rc=$?
    set -e
    return "$rc"
}

# ---- 1+2+5: slow start past the inner bound, inside the headroom ----------------
A="$TMP/a"; mk_stubs "$A" 2
rc=0; probe "$A" 1 || rc=$?
outer=$(awk '$2 == "docker" && $3 == "run" { print $1; exit }' "$A/timeout.log")
inner=$(awk '$1 == "run" { for (i = 1; i < NF; i++) if ($i ~ /^turnutils_/) { print $(i - 1); exit } }' "$A/docker.log")
if [[ -n "$outer" && -n "$inner" && "$outer" -gt "$inner" ]]; then
    ok "docker-CLI timeout ($outer) is greater than the in-container bound ($inner)"
else
    fail "docker-CLI timeout '$outer' is not greater than the in-container bound '$inner' (equal bounds kill the CLI mid-create)"
fi
if [[ "$rc" -eq 0 ]]; then
    ok "slow create/start inside the headroom completes (rc 0)"
else
    fail "slow create/start was killed by the outer timeout (rc $rc) — the Created-container leak"
fi
leftover=$(find "$A/state" -type f | wc -l)
[[ "$leftover" -eq 0 ]] && ok "no container left behind after a slow-but-successful run" \
    || fail "$leftover container(s) left behind"
run_line=$(grep -a '^run ' "$A/docker.log" || true)
if [[ "$run_line" == *"--label oxpulse.probe=coturn"* && "$run_line" =~ --name\ oxpulse-probe-turnutils_stunclient-[0-9]+-[0-9]+\  ]]; then
    ok "probe container is labelled oxpulse.probe=coturn and uniquely named"
else
    fail "probe container missing label/name: $run_line"
fi

# ---- 3: CLI killed mid-start (outer timeout fires) -> removed by name ------------
B="$TMP/b"; mk_stubs "$B" 3
rc=0; probe "$B" 1 0 || rc=$?   # headroom 0: outer fires at 1s, mid-"start"
rm_line=$(grep -a '^rm -f oxpulse-probe-' "$B/docker.log" || true)
leftover=$(find "$B/state" -type f | wc -l)
if [[ "$rc" -eq 124 && -n "$rm_line" && "$leftover" -eq 0 ]]; then
    ok "CLI killed mid-start: leftover Created container force-removed by name (rc 124 preserved)"
else
    fail "leak not cleaned: rc=$rc rm='$rm_line' leftover=$leftover"
fi

# ---- 4: stale reaper scope ------------------------------------------------------
C="$TMP/c"; mk_stubs "$C" 0
old=$(date -u -d '-10 minutes' +%Y-%m-%dT%H:%M:%S.000000000Z)
young=$(date -u -d '-1 minute' +%Y-%m-%dT%H:%M:%S.000000000Z)
cat > "$C/rows" <<ROWS
aaaa1|$old|timeout|coturn|5 turnutils_stunclient 203.0.113.9 -p 3478
bbbb2|$old|timeout||5 turnutils_stunclient 203.0.113.9 -p 3478
cccc3|$young|timeout||5 turnutils_stunclient 203.0.113.9 -p 3478
dddd4|$old|nginx||-g daemon off;
eeee5|$old|timeout||5 sleep 100
ffff6|$young|timeout|coturn|5 turnutils_stunclient 203.0.113.9 -p 3478
gggg7|$old|timeout||10 turnutils_uclient -u user -w pa|ss -y
ROWS
rc=0; probe "$C" 1 || rc=$?
reaped=$(grep -a '^rm -f aaaa1' "$C/docker.log" || true)
if [[ "$reaped" == "rm -f aaaa1 bbbb2 gggg7" ]]; then
    ok "reaper removes exactly the stale labelled + legacy-signature probes (old: aaaa1 bbbb2 gggg7)"
else
    fail "reaper scope wrong; rm line: '$reaped'; log: $(cat "$C/docker.log")"
fi
D="$TMP/d"; mk_stubs "$D" 0
rc=0; probe "$D" 1 || rc=$?
[[ -z $(grep -a -E '^rm -f [a-f0-9]+( |$)' "$D/docker.log" || true) && "$rc" -eq 0 ]] \
    && ok "no Created containers -> reaper removes nothing and the probe still runs" \
    || fail "unexpected reap with empty Created set: $(cat "$D/docker.log")"

echo
echo "coturn probe leak: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
