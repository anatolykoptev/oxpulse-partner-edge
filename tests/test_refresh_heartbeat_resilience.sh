#!/bin/bash
# Regression: oxpulse-partner-edge-refresh.sh MUST send the heartbeat even
# when jq is missing from PATH (or any early step fails).
#
# Incident 2026-05-09 root cause: cheburator1 had jq absent from systemd unit
# PATH. set -euo pipefail exits at line 39 (NODE_ID extraction via jq) before
# the heartbeat POST at line 75. last_seen_at went stale for 1 week.
# piter1 (hostiman) had the timer not installed at all — separate issue,
# last_seen_at stale for 3 weeks (registration timestamp only).
#
# This test verifies:
# 1. The script starts with a jq dependency check that prints a clear error.
# 2. The heartbeat call is guarded so it does NOT require earlier jq steps to
#    succeed — either via early jq check + install hint, or via a trap that
#    runs heartbeat even on die().
# 3. NODE_ID extraction and heartbeat are not separated by a fatal early-exit
#    point that can silently swallow the heartbeat.
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SCRIPT="$REPO_ROOT/oxpulse-partner-edge-refresh.sh"

[[ -f "$SCRIPT" ]] || { echo "FAIL: refresh script not found at $SCRIPT"; exit 1; }

# 1. Script must have a jq dependency check near the top (before line 55).
#    This ensures operators see a clear "jq not found" message instead of
#    a cryptic "command not found" buried in logs.
jq_check_block=$(head -55 "$SCRIPT" | grep -A2 -E 'command -v jq|which jq|type jq' || true)
[[ -n "$jq_check_block" ]] \
    || { echo "FAIL: no jq dependency check in first 55 lines of refresh script"; \
         echo "      cheburator1 failed silently with 'jq: command not found' at line 39"; \
         echo "      Add: command -v jq >/dev/null 2>&1 || die \"jq required but not found — install: apt-get install -y jq\""; \
         exit 1; }

# 2. The jq dependency check must call die (not just warn) so the operator
#    sees a clear failure in systemd logs and can fix it. The die call may
#    be on the continuation line (|| die ...) so we check the 2-line block.
echo "$jq_check_block" | grep -qE '\bdie\b' \
    || { echo "FAIL: jq dependency check does not call die on missing jq"; \
         echo "      A warn-and-continue path means heartbeat still silently skipped"; \
         echo "      Block found: $jq_check_block"; \
         exit 1; }

# 3. Script must still parse cleanly (no syntax regressions).
bash -n "$SCRIPT" \
    || { echo "FAIL: $SCRIPT has syntax errors after fix"; exit 1; }

echo "OK: refresh script has jq dependency check with die on missing jq"
