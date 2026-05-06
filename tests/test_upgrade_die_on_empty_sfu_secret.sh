#!/bin/bash
# Regression: upgrade.sh MUST die loudly when the installed
# docker-compose.yml has SIGNALING_SFU_SECRET rendered empty. Existing
# edges that booted via install.sh BEFORE the 2026-05-06 die-on-empty
# fix kept running with an empty SIGNALING_SFU_SECRET; the SFU's
# /sfu/ws/{room_id} stayed disabled and group calls silently failed
# end-to-end. upgrade.sh is the only path that runs on those edges
# (no operator re-runs install.sh on existing fleet), so the
# postcondition has to live there too — install.sh alone does not
# heal pre-fix deployments.
#
# This test asserts upgrade.sh contains a postcondition that:
#   1. inspects the rendered docker-compose.yml at $COMPOSE_FILE
#   2. dies if SIGNALING_SFU_SECRET is empty
#   3. mentions SIGNALING_SFU_SECRET, "group calls", and the
#      remediation (re-run install.sh) in its die message.
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
UPGRADE="$REPO_ROOT/upgrade.sh"

[[ -f "$UPGRADE" ]] || { echo "FAIL: upgrade.sh not found at $UPGRADE"; exit 1; }

# 1. There must be a guard that grep-s the compose file for the
#    SIGNALING_SFU_SECRET line and tests for non-empty value.
grep -qE 'SIGNALING_SFU_SECRET' "$UPGRADE" \
    || { echo "FAIL: upgrade.sh has no SIGNALING_SFU_SECRET postcondition"; exit 1; }

# 2. The guard must call die (hard exit), and the die message must
#    name SIGNALING_SFU_SECRET, mention group-call breakage, and
#    point at install.sh as the remediation path.
guard_block=$(awk '
    /check_signaling_sfu_secret\(\)/ { capture=1 }
    capture { print }
    capture && /^}$/ { exit }
' "$UPGRADE")

[[ -n "$guard_block" ]] \
    || { echo "FAIL: could not locate check_signaling_sfu_secret() in $UPGRADE"; exit 1; }

echo "$guard_block" | grep -qE '\bdie\b' \
    || { echo "FAIL: postcondition does not call die"; exit 1; }
echo "$guard_block" | grep -q 'SIGNALING_SFU_SECRET' \
    || { echo "FAIL: die message missing SIGNALING_SFU_SECRET hint"; exit 1; }
echo "$guard_block" | grep -qi 'group calls' \
    || { echo "FAIL: die message must explain group-call breakage"; exit 1; }
echo "$guard_block" | grep -qi 'install\.sh' \
    || { echo "FAIL: die message must mention install.sh as remediation"; exit 1; }

# 3. The postcondition must actually be invoked, not just defined.
grep -qE '^[[:space:]]*check_signaling_sfu_secret([[:space:]]|$)' "$UPGRADE" \
    || { echo "FAIL: check_signaling_sfu_secret defined but never called"; exit 1; }

# 4. Behavioural test: simulate an installed bundle whose compose
#    file has SIGNALING_SFU_SECRET="" and confirm the function
#    exits non-zero with the right message.
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
cat > "$tmpdir/docker-compose.yml" <<'COMPOSE'
services:
  oxpulse-sfu:
    environment:
      SIGNALING_SFU_SECRET: ""
COMPOSE

# Source the function in a subshell with a fake COMPOSE_FILE so the
# real filesystem path /etc/oxpulse-partner-edge is not touched.
output=$(
    COMPOSE_FILE="$tmpdir/docker-compose.yml" \
    bash -c '
        # Minimal preamble: redefine die without exiting the test runner.
        die()  { while IFS= read -r _line; do printf "ERR %s\n" "$_line" >&2; done <<< "$*"; exit 1; }
        warn() { printf "!! %s\n" "$*" >&2; }
        log()  { printf "==> %s\n" "$*" >&2; }
        # Pull just the function definition out of upgrade.sh.
        eval "$(awk "/^check_signaling_sfu_secret\\(\\)/,/^}$/" "'"$UPGRADE"'")"
        check_signaling_sfu_secret
    ' 2>&1
) && rc=0 || rc=$?

[[ $rc -ne 0 ]] \
    || { echo "FAIL: upgrade.sh postcondition did not exit non-zero on empty secret"; \
         echo "---output---"; echo "$output"; echo "---/output---"; exit 1; }

echo "$output" | grep -qi 'SIGNALING_SFU_SECRET' \
    || { echo "FAIL: postcondition output missing SIGNALING_SFU_SECRET"; \
         echo "---output---"; echo "$output"; echo "---/output---"; exit 1; }

# 5. Behavioural test: with a non-empty secret, the function exits 0.
cat > "$tmpdir/docker-compose.yml" <<'COMPOSE'
services:
  oxpulse-sfu:
    environment:
      SIGNALING_SFU_SECRET: "real-secret-here"
COMPOSE

COMPOSE_FILE="$tmpdir/docker-compose.yml" \
bash -c '
    die()  { while IFS= read -r _line; do printf "ERR %s\n" "$_line" >&2; done <<< "$*"; exit 1; }
    warn() { printf "!! %s\n" "$*" >&2; }
    log()  { printf "==> %s\n" "$*" >&2; }
    eval "$(awk "/^check_signaling_sfu_secret\\(\\)/,/^}$/" "'"$UPGRADE"'")"
    check_signaling_sfu_secret
' \
    || { echo "FAIL: postcondition false-positive — exited non-zero on a valid secret"; exit 1; }

# 6. Sanity: upgrade.sh still parses.
bash -n "$UPGRADE" || { echo "FAIL: upgrade.sh has syntax errors"; exit 1; }

echo "OK: upgrade.sh dies on empty signaling_sfu_secret in installed compose"
