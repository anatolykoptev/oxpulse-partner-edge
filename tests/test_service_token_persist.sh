#!/usr/bin/env bash
# Regression: install.sh service_token persist + fail-loud strand mode (Follow-up #2 PR-B)
#
# Tests the four-branch COALESCE-preserve decision tree:
#   Branch A — server returned token, file absent     → atomically write 0600
#   Branch B — server returned token, file present    → warn, preserve local
#   Branch C — server omitted token,  file absent     → die with recovery instructions
#   Branch D — server omitted token,  file present    → silent success (idempotent)
# Plus:
#   read_service_token helper: env-var override wins over file.
#
# Test method: static analysis of install.sh (awk/grep) + targeted execution
# of read_service_token in an isolated subshell. We do NOT execute the full
# install.sh (requires root + partner-cli + real infra).
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
INSTALL="$REPO_ROOT/install.sh"
TOKEN_LIB="$REPO_ROOT/oxpulse-token-lib.sh"

[[ -f "$INSTALL" ]]   || { echo "FAIL: install.sh not found at $INSTALL"; exit 1; }
[[ -f "$TOKEN_LIB" ]] || { echo "FAIL: oxpulse-token-lib.sh not found at $TOKEN_LIB"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Extract the service_token persist block: from SERVICE_TOKEN=$(jq … to the
# closing fi that terminates the outer if [[ -n "$SERVICE_TOKEN" ]] arm.
awk '
    /SERVICE_TOKEN=\$\(jq -r/ { capture=1 }
    capture { print }
    capture && /^\tfi$/ { exit }
' "$INSTALL" > "$TMP/svc_token_block.txt"

[[ -s "$TMP/svc_token_block.txt" ]] \
    || { echo "FAIL: could not locate service_token persist block in install.sh"; exit 1; }

# ── Test 1: install_persists_token_on_fresh_node (Branch A) ──────────────────
echo -n "Test 1: install_persists_token_on_fresh_node (Branch A) ... "
grep -q 'jq -r' "$TMP/svc_token_block.txt" \
    || { echo "FAIL: missing jq extraction for service_token"; exit 1; }
grep -q '! -e.*SVC_TOKEN_FILE' "$TMP/svc_token_block.txt" \
    || { echo "FAIL: missing file-absent check (! -e SVC_TOKEN_FILE) for Branch A"; exit 1; }
grep -q 'mktemp.*SVC_TOKEN_FILE' "$TMP/svc_token_block.txt" \
    || { echo "FAIL: Branch A must use mktemp for atomic write"; exit 1; }
grep -q 'mv.*_tok_tmp' "$TMP/svc_token_block.txt" \
    || { echo "FAIL: Branch A must mv (atomic rename) the tmp file"; exit 1; }
grep -q 'chmod 0600' "$TMP/svc_token_block.txt" \
    || { echo "FAIL: Branch A must set mode 0600"; exit 1; }
grep -qi 'service token persisted' "$TMP/svc_token_block.txt" \
    || { echo "FAIL: Branch A must log 'service token persisted'"; exit 1; }
echo "OK"

# ── Test 2: install_preserves_existing_token_on_re_install (Branch B) ────────
echo -n "Test 2: install_preserves_existing_token_on_re_install (Branch B) ... "
grep -qiE 'warn.*service token returned by server|preserved local copy|rotate-service-token' \
    "$TMP/svc_token_block.txt" \
    || { echo "FAIL: Branch B must warn about preserved local copy and rotation hint"; exit 1; }
echo "OK"

# ── Test 3: install_fails_loud_on_strand_mode (Branch C) ─────────────────────
echo -n "Test 3: install_fails_loud_on_strand_mode (Branch C) ... "
grep -q '\bdie\b' "$TMP/svc_token_block.txt" \
    || { echo "FAIL: Branch C must call die for strand mode"; exit 1; }
grep -q 'partner-cli rotate-service-token' "$TMP/svc_token_block.txt" \
    || { echo "FAIL: Branch C die message must mention 'partner-cli rotate-service-token'"; exit 1; }
grep -q 'OXPULSE_SERVICE_TOKEN' "$TMP/svc_token_block.txt" \
    || { echo "FAIL: Branch C recovery message must mention OXPULSE_SERVICE_TOKEN env override"; exit 1; }
echo "OK"

# ── Test 4: install_silent_success_on_idempotent_reinstall (Branch D) ─────────
echo -n "Test 4: install_silent_success_on_idempotent_reinstall (Branch D) ... "
grep -qi 'service token reused\|idempotent' "$TMP/svc_token_block.txt" \
    || { echo "FAIL: Branch D must log 'service token reused' or 'idempotent'"; exit 1; }
echo "OK"

# ── Test 5: read_service_token_prefers_env_over_file ─────────────────────────
echo -n "Test 5: read_service_token_prefers_env_over_file ... "
_env_tok="stkn_env_value_123"
_file_tok="stkn_file_value_456"

_test_etc="$TMP/etc"
mkdir -p "$_test_etc"
printf '%s' "$_file_tok" > "$_test_etc/token"
chmod 0600 "$_test_etc/token"

# Source the token lib and call read_service_token with env set.
_result=$(
    export OXPULSE_SERVICE_TOKEN="$_env_tok"
    _TOKEN_LIB_PREFIX_ETC="$_test_etc"
    # shellcheck source=/dev/null
    source "$TOKEN_LIB"
    read_service_token
)

[[ "$_result" == "$_env_tok" ]] \
    || { echo "FAIL: read_service_token returned '$_result', expected env value '$_env_tok'"; exit 1; }
echo "OK"

# ── Sanity: syntax check ──────────────────────────────────────────────────────
bash -n "$INSTALL"    || { echo "FAIL: install.sh has syntax errors"; exit 1; }
bash -n "$TOKEN_LIB"  || { echo "FAIL: oxpulse-token-lib.sh has syntax errors"; exit 1; }

echo ""
echo "OK: service_token persist — all 5 tests passed"
