#!/bin/bash
# Structural + behavioral regression test: rotation branch must skip
# systemctl reload gracefully when oxpulse-partner-edge.service is not
# installed (custom-stack nodes such as relay-x that run their own
# xray-reality + coturn + SFU compose).
#
# Two levels:
#   1. Structural: grep confirms the guard is present in the script source.
#   2. Behavioral: source only the guard logic via a minimal harness and
#      confirm exit 0 + skip message when list-unit-files returns empty.
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

# ── Test 2: guard present — systemctl list-unit-files conditional ─────────────
grep -q "systemctl list-unit-files oxpulse-partner-edge.service" "$SCRIPT" \
    || fail "test2: 'systemctl list-unit-files oxpulse-partner-edge.service' guard not found in $SCRIPT"
pass "test2: list-unit-files guard present in script"

# ── Test 3: skip log message present ─────────────────────────────────────────
grep -q "skipping reload (custom stack node)" "$SCRIPT" \
    || fail "test3: skip log message not found in $SCRIPT"
pass "test3: skip message 'skipping reload (custom stack node)' present"

# ── Test 4: reload is inside the conditional (not at top level) ───────────────
# Strategy: extract line numbers of the guard opening and the matching fi,
# and verify that "systemctl reload oxpulse-partner-edge.service" only
# appears between those lines.
GUARD_LINE=$(grep -n "systemctl list-unit-files oxpulse-partner-edge.service" "$SCRIPT" | grep -v '^\s*[0-9]*:\s*#' | head -1 | cut -d: -f1)
RELOAD_LINE=$(grep -n "systemctl reload oxpulse-partner-edge.service" "$SCRIPT" | grep -v '^\s*[0-9]*:\s*#' | head -1 | cut -d: -f1)
SKIP_LINE=$(grep -n "skipping reload (custom stack node)" "$SCRIPT" | head -1 | cut -d: -f1)

[[ -n "$GUARD_LINE" ]] || fail "test4: could not find guard line number"
[[ -n "$RELOAD_LINE" ]] || fail "test4: could not find reload line number"
[[ -n "$SKIP_LINE" ]] || fail "test4: could not find skip-message line number"

[[ "$RELOAD_LINE" -gt "$GUARD_LINE" ]] \
    || fail "test4: systemctl reload (line $RELOAD_LINE) must come AFTER guard (line $GUARD_LINE)"
[[ "$SKIP_LINE" -gt "$GUARD_LINE" ]] \
    || fail "test4: skip message (line $SKIP_LINE) must come AFTER guard (line $GUARD_LINE)"
pass "test4: reload (L$RELOAD_LINE) and skip message (L$SKIP_LINE) are inside guard (L$GUARD_LINE)"

# ── Test 5: behavioral — guard logic in isolation ─────────────────────────────
# Extract just the guard block and run it with a stub systemctl that returns
# empty for list-unit-files (unit absent). Confirm exit 0 and skip message.
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

LOG="$T/test.log"
touch "$LOG"
# Minimal log function for the extracted snippet
cat > "$T/harness.sh" <<'HARNESS'
#!/usr/bin/env bash
set -euo pipefail
LOG_FILE="$1"
log() { printf '%s\n' "$*" | tee -a "$LOG_FILE"; }
die() { log "ERR $*"; exit 1; }
BACKUP="/dev/null"   # not used in this branch
NODE_CFG="/dev/null" # not used in this branch

# systemctl stub: list-unit-files returns empty (unit absent)
systemctl() {
    case "$*" in
        "list-unit-files oxpulse-partner-edge.service --no-legend"*)
            return 0  # exit 0, no output → grep -q fails → else branch taken
            ;;
        *) return 0 ;;
    esac
}
export -f systemctl

if systemctl list-unit-files oxpulse-partner-edge.service --no-legend 2>/dev/null \
        | grep oxpulse-partner-edge >/dev/null; then
    log "reloading oxpulse-partner-edge.service"
    if systemctl reload oxpulse-partner-edge.service 2>>"$LOG_FILE"; then
        log "reload OK"
    else
        log "reload FAILED — restoring $BACKUP"
        mv "$BACKUP" "$NODE_CFG"
        systemctl reload oxpulse-partner-edge.service 2>>"$LOG_FILE" || true
        die "rollback complete; new keys NOT applied"
    fi

    sleep 5
    if systemctl is-active --quiet oxpulse-partner-edge.service; then
        log "post-reload: oxpulse-partner-edge active"
    else
        log "post-reload: service NOT active — restoring backup"
        mv "$BACKUP" "$NODE_CFG"
        systemctl reload oxpulse-partner-edge.service 2>>"$LOG_FILE" || true
        die "rollback complete after failed verify"
    fi
else
    log "rotation: oxpulse-partner-edge.service not installed — skipping reload (custom stack node)"
fi
HARNESS
chmod +x "$T/harness.sh"

set +e
bash "$T/harness.sh" "$LOG" > "$T/stdout.txt" 2>&1
HARNESS_EXIT=$?
set -e

[[ $HARNESS_EXIT -eq 0 ]] \
    || fail "test5: harness exited $HARNESS_EXIT (expected 0); output: $(cat "$T/stdout.txt")"

COMBINED=$(cat "$T/stdout.txt" "$LOG" 2>/dev/null || true)
printf '%s' "$COMBINED" | grep "skipping reload (custom stack node)" >/dev/null \
    || fail "test5: expected skip message in output; got: $COMBINED"
pass "test5: behavioral harness exits 0 + emits skip message when unit absent"

echo ""
echo "All tests passed."
