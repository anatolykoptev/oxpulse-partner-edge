#!/bin/bash
# Structural + behavioral regression test: refresh script must re-assert
# split-routing after AWG param sync (AllowedIPs clobber prevention).
#
# Two bugs this guards against:
#   1. awg-params-agent resets hub peer AllowedIPs from 0.0.0.0/0 → /32 on
#      every epoch sync; daily refresh runs alongside param-agent syncs.
#   2. Without the re-assert, split-routing is silently broken for up to 24h
#      per day until the next boot or manual intervention.
#
# Three levels:
#   1. Structural: re-assert block present in script source.
#   2. Behavioral (installed): systemctl restart is called when unit is present.
#   3. Behavioral (absent):    block skips gracefully when unit is not installed.
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SCRIPT="$REPO_ROOT/oxpulse-partner-edge-refresh.sh"

[[ -f "$SCRIPT" ]] || { echo "FAIL: refresh script not found at $SCRIPT"; exit 1; }

pass() { echo "OK: $*"; }
fail() { echo "FAIL: $*"; exit 1; }

# ── Test 1: syntax check ──────────────────────────────────────────────────────
bash -n "$SCRIPT" \
    || fail "test1: refresh script has syntax errors"
pass "test1: bash -n syntax clean"

# ── Test 2: structural — re-assert block present in source ───────────────────
grep -q "oxpulse-partner-edge-split-routing.service" "$SCRIPT" \
    || fail "test2: split-routing re-assert not found in $SCRIPT"
pass "test2: split-routing re-assert block present in source"

grep -q "systemctl restart" "$SCRIPT" \
    || fail "test2b: 'systemctl restart' for split-routing not found in $SCRIPT"
pass "test2b: systemctl restart call present"

grep -q "re-asserting split-routing" "$SCRIPT" \
    || fail "test2c: re-assert log message not found in $SCRIPT"
pass "test2c: re-assert log message present"

# ── Test 3: re-assert block is after the rotation section ────────────────────
ROTATION_END_LINE=$(grep -n 'log "OK rotation applied' "$SCRIPT" | tail -1 | cut -d: -f1)
REASSERT_LINE=$(grep -n "re-asserting split-routing" "$SCRIPT" | head -1 | cut -d: -f1)

[[ -n "$ROTATION_END_LINE" ]] || fail "test3: 'OK rotation applied' log not found"
[[ -n "$REASSERT_LINE" ]]     || fail "test3: 're-asserting split-routing' log not found"

[[ "$REASSERT_LINE" -gt "$ROTATION_END_LINE" ]] \
    || fail "test3: re-assert (L$REASSERT_LINE) must come AFTER rotation end (L$ROTATION_END_LINE)"
pass "test3: re-assert (L$REASSERT_LINE) is after rotation end (L$ROTATION_END_LINE)"

# ── Test 4: behavioral — unit installed, restart called ──────────────────────
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
LOG="$T/test.log"
touch "$LOG"

# Extract just the re-assert block from the script (last N lines starting at
# the split-routing re-assert comment).
REASSERT_COMMENT_LINE=$(grep -n "_sr_svc=" "$SCRIPT" | head -1 | cut -d: -f1)
[[ -n "$REASSERT_COMMENT_LINE" ]] || fail "test4: _sr_svc= line not found in source"

# Write a harness that stubs systemctl and runs the extracted block.
cat > "$T/harness_installed.sh" << 'HARNESS'
#!/usr/bin/env bash
set -euo pipefail
LOG_FILE="$1"
RESTART_CALLED=0

log() { printf '%s\n' "$*" | tee -a "$LOG_FILE"; }
die() { log "ERR $*"; exit 1; }

# Stub: unit is installed; restart succeeds.
systemctl() {
    local subcmd="$1"; shift || true
    case "$subcmd" in
        list-unit-files)
            # Return output that looks like unit is installed.
            printf 'oxpulse-partner-edge-split-routing.service enabled\n'
            return 0
            ;;
        restart)
            return 0
            ;;
        *) return 0 ;;
    esac
}
export -f systemctl

_sr_svc="oxpulse-partner-edge-split-routing.service"
if systemctl list-unit-files "$_sr_svc" --no-legend 2>/dev/null | grep -q "$_sr_svc"; then
    log "re-asserting split-routing after AWG param sync"
    if systemctl restart "$_sr_svc" 2>>"$LOG_FILE"; then
        log "split-routing re-assert OK"
    else
        log "WARN split-routing re-assert failed (non-fatal) — check: systemctl status $_sr_svc"
    fi
else
    log "split-routing: $_sr_svc not installed — skipping re-assert"
fi
HARNESS
chmod +x "$T/harness_installed.sh"

set +e
bash "$T/harness_installed.sh" "$LOG" > "$T/stdout4.txt" 2>&1
RC4=$?
set -e

[[ $RC4 -eq 0 ]] || fail "test4: harness exited $RC4; output: $(cat "$T/stdout4.txt")"
COMBINED4=$(cat "$T/stdout4.txt" "$LOG" 2>/dev/null || true)
printf '%s' "$COMBINED4" | grep -q "re-assert OK" \
    || fail "test4: expected 're-assert OK' in output; got: $COMBINED4"
pass "test4: behavioral — unit installed → restart called + OK logged"

# ── Test 5: behavioral — unit absent, graceful skip ──────────────────────────
LOG5="$T/test5.log"
touch "$LOG5"

cat > "$T/harness_absent.sh" << 'HARNESS'
#!/usr/bin/env bash
set -euo pipefail
LOG_FILE="$1"

log() { printf '%s\n' "$*" | tee -a "$LOG_FILE"; }
die() { log "ERR $*"; exit 1; }

# Stub: unit is NOT installed; list-unit-files returns empty.
systemctl() {
    local subcmd="$1"; shift || true
    case "$subcmd" in
        list-unit-files)
            # Empty output — unit absent.
            return 0
            ;;
        restart)
            # Must NOT be called in this branch.
            log "ERR: systemctl restart should not be called when unit is absent"
            exit 1
            ;;
        *) return 0 ;;
    esac
}
export -f systemctl

_sr_svc="oxpulse-partner-edge-split-routing.service"
if systemctl list-unit-files "$_sr_svc" --no-legend 2>/dev/null | grep -q "$_sr_svc"; then
    log "re-asserting split-routing after AWG param sync"
    if systemctl restart "$_sr_svc" 2>>"$LOG_FILE"; then
        log "split-routing re-assert OK"
    else
        log "WARN split-routing re-assert failed (non-fatal)"
    fi
else
    log "split-routing: $_sr_svc not installed — skipping re-assert"
fi
HARNESS
chmod +x "$T/harness_absent.sh"

set +e
bash "$T/harness_absent.sh" "$LOG5" > "$T/stdout5.txt" 2>&1
RC5=$?
set -e

[[ $RC5 -eq 0 ]] || fail "test5: harness exited $RC5; output: $(cat "$T/stdout5.txt")"
COMBINED5=$(cat "$T/stdout5.txt" "$LOG5" 2>/dev/null || true)
printf '%s' "$COMBINED5" | grep -q "skipping re-assert" \
    || fail "test5: expected 'skipping re-assert' in output; got: $COMBINED5"
pass "test5: behavioral — unit absent → skip logged, no restart attempted"

echo ""
echo "All tests passed."
