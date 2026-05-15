#!/bin/bash
# Regression: install.sh keygen idempotency guard
#
# Incident: 2026-05-14T19:00Z piter-seed reality_uuid overwritten by a
# subsequent edge-side register event with a freshly generated value.
# All distributed VLESS clients broke until manual rollback.
# Ref: federation plan §13 incident class.
#
# Guard contract:
#   - ALL three reality.{priv,pub,uuid} present → skip keygen, reuse identity
#   - ANY file missing (partial) → exit non-zero with recovery message, no mutation
#   - NONE present (fresh install) → run keygen, echo UUID
#   - --force-keygen OR --rotate-identity flag → backup existing + keygen
#
# Test method: static analysis of the keygen block in install.sh.
# We do NOT execute install.sh (it requires root + partner-cli + real infra).
# All four cases are verified by inspecting the conditional structure.
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
INSTALL="$REPO_ROOT/install.sh"

[[ -f "$INSTALL" ]] || { echo "FAIL: install.sh not found at $INSTALL"; exit 1; }

# Write install.sh to a temp file for grep (avoids SIGPIPE with set -o pipefail
# when piping from echo "$large_var" | grep -q — grep exits early, echo gets
# SIGPIPE 141, pipefail treats the pipeline as failed even on a match).
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Extract the Reality keygen block: everything from REALITY_PRIV_PATH= to end
# of the keygen section. Write to a file for safe grepping.
awk '/^REALITY_PRIV_PATH=/ { capture=1 } capture { print }' \
    "$INSTALL" > "$TMP/keygen_block.txt"

[[ -s "$TMP/keygen_block.txt" ]] \
    || { echo "FAIL: could not locate Reality keygen block in install.sh"; exit 1; }

# ── Case 1: Fresh install (all absent) → keygen fires ──────────────────────
# The keygen block must invoke partner-cli keygen somewhere for the fresh-install path.
grep -q 'partner-cli keygen' "$TMP/keygen_block.txt" \
    || { echo "FAIL [case1]: keygen block does not invoke partner-cli keygen for fresh install"; exit 1; }

# ── Case 2: Idempotent re-install (all 3 present) → skip keygen ────────────
# The guard must count all three files and set a flag / branch for all-present.
# Accept either a direct -s check on all three OR a counter+flag pattern.
grep -qE '(_reality_all_present|_reality_count.*-eq 3|_dry_count.*-eq 3|-s.*reality\.priv.*&&.*-s.*reality\.pub.*&&.*-s.*reality\.uuid)' \
    "$TMP/keygen_block.txt" \
    || { echo "FAIL [case2]: keygen block missing 3-file existence guard"; exit 1; }

# The reuse branch must echo/log the fact that the identity is being reused.
grep -qiE 'reusing|reuse|idempotent' "$TMP/keygen_block.txt" \
    || { echo "FAIL [case2]: reuse branch does not log/echo reuse of existing identity"; exit 1; }

# ── Case 3: Partial state → exit non-zero with recovery message ─────────────
# The guard must have a partial-state abort message in the keygen block.
grep -qE 'PARTIAL|[Pp]artial.*identit|Manual recovery|Aborting.*UUID|[Pp]artial.*identit' \
    "$TMP/keygen_block.txt" \
    || { echo "FAIL [case3]: no partial-state abort message in keygen block"; exit 1; }

# The partial branch must call die or exit 1 (not warn-and-continue).
# Extract partial-state sub-block: lines after "elif _reality_partial" until next branch.
awk '
    /_reality_partial.*-eq 1|_reality_partial -eq 1/ { capture=1; next }
    capture && /^[[:space:]]*(elif[[:space:]]|else$|else[[:space:]])/ { exit }
    capture { print }
' "$INSTALL" > "$TMP/partial_block.txt"

grep -qE '\bdie\b|exit 1' "$TMP/partial_block.txt" \
    || { echo "FAIL [case3]: partial-state branch does not call die or exit 1"; \
         echo "--- partial_block ---"; cat "$TMP/partial_block.txt"; echo "--- /partial_block ---"; exit 1; }

# Must NOT call partner-cli keygen in the partial branch.
if grep -q 'partner-cli keygen' "$TMP/partial_block.txt"; then
    echo "FAIL [case3]: partial-state branch must NOT invoke partner-cli keygen"
    exit 1
fi

# ── Case 4: --force-keygen / --rotate-identity flag ────────────────────────
# The arg parser must accept --force-keygen and/or --rotate-identity.
grep -qE -- '--force-keygen|--rotate-identity' "$INSTALL" \
    || { echo "FAIL [case4]: install.sh does not accept --force-keygen or --rotate-identity flag"; exit 1; }

# The force branch must backup existing files before keygen.
# Extract from first mention of FORCE_KEYGEN conditional to the partner-cli keygen invocation.
awk '
    /\[.*FORCE_KEYGEN.*-eq 1/ { capture=1; next }
    capture && /_keygen_out=\$\(partner-cli keygen\)/ { print; exit }
    capture { print }
' "$INSTALL" > "$TMP/force_block.txt"

grep -qE '\.bak\.|cp.*reality\.' "$TMP/force_block.txt" \
    || { echo "FAIL [case4]: --force-keygen branch does not backup existing identity files before keygen"; \
         echo "--- force_block ---"; cat "$TMP/force_block.txt"; echo "--- /force_block ---"; exit 1; }

grep -q 'partner-cli keygen' "$TMP/force_block.txt" \
    || { echo "FAIL [case4]: --force-keygen branch does not invoke partner-cli keygen"; exit 1; }

# ── Case 4b: force flag wired in arg parser ─────────────────────────────────
awk '/^while.*\$#/ { capture=1 } capture { print } capture && /^done$/ { exit }' \
    "$INSTALL" > "$TMP/arg_parser.txt"

grep -qE -- '--force-keygen|--rotate-identity' "$TMP/arg_parser.txt" \
    || { echo "FAIL [case4b]: --force-keygen not wired in the arg parser while-loop"; exit 1; }

# ── Case 5: Syntax check ────────────────────────────────────────────────────
bash -n "$INSTALL" \
    || { echo "FAIL: install.sh has syntax errors after patch"; exit 1; }

echo "OK: install.sh keygen idempotency guard — all 4 cases verified"
