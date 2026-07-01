#!/bin/bash
# tests/test_refresh_cross_probe_token.sh — cross-probe token daily re-mint leg
# in oxpulse-partner-edge-refresh.sh.
#
# Root cause 2026-07-01: the central mints cross_probe_token (xprb_) ONLY in
# the /api/partner/register response (persisted once, at first boot, by
# hydrate.sh / install.sh). TTL=7d → all 5 fleet edges (registered ~06-24
# 05:36) expired their tokens together, firing MeshCrossProbeRejectionStorm
# (stale_token) from 07-01 05:46. The central's GET
# /api/partner/cross-probe-token re-mint endpoint (T2.4.c) had zero
# consumers anywhere in this repo. This test covers the new refresh leg that
# consumes it from the daily refresh script.
#
# Same plain-bash ok/fail + curl-stub pattern as
# tests/test_refresh_heartbeat_decoupled.sh.
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SCRIPT="$REPO_ROOT/oxpulse-partner-edge-refresh.sh"

[[ -f "$SCRIPT" ]] || { echo "FAIL: refresh script not found at $SCRIPT"; exit 1; }

pass() { echo "OK: $*"; }
fail() { echo "FAIL: $*"; exit 1; }

# Helper: create a stub bin dir with essential POSIX utilities.
make_bin() {
    local dir="$1"
    for cmd in bash sh date printf cat tee cp mv mkdir chmod install sleep \
                sed grep head tail wc stat cut tr expr test touch \
                dirname mktemp basename; do
        local loc
        loc=$(command -v "$cmd" 2>/dev/null || true)
        if [[ -n "$loc" ]]; then ln -sf "$loc" "$dir/$cmd"; fi
    done
    cat > "$dir/systemctl" <<'STUB'
#!/bin/sh
exit 0
STUB
    chmod +x "$dir/systemctl"
    if command -v jq >/dev/null 2>&1; then
        ln -sf "$(command -v jq)" "$dir/jq"
    fi
}

# Baseline keys response: version/channels_version match what's already on
# disk so no Reality rotation / channel re-render path is exercised — this
# test is scoped to the cross-probe leg only.
KEYS_BODY='{"version":"v1","sfu_signing_public_key":"","channels_version":"c1","reality_public_key":"pk","reality_encryption":"enc","reality_server_names":[]}'

# curl stub factory: routes on URL substring.
#   $1 = dir to write the stub into
#   $2 = cross-probe-token endpoint behavior: "success" | "curl_fail" | "malformed"
#   $3 = marker file path — touched iff the cross-probe-token endpoint was hit
write_curl_stub() {
    local dir="$1" mode="$2" marker="$3"
    local xprb_body xprb_exit
    case "$mode" in
        success)
            xprb_body='{"cross_probe_token":"xprb_new_token_abc123","issued_at":"2026-07-01T06:00:00Z","ttl_secs":604800}'
            xprb_exit=0
            ;;
        curl_fail)
            xprb_body=""
            xprb_exit=1
            ;;
        malformed)
            xprb_body='{"error":"unauthorized"}'
            xprb_exit=0
            ;;
        *)
            echo "write_curl_stub: unknown mode $mode" >&2; exit 1 ;;
    esac
    cat > "$dir/curl" <<CURLSTUB
#!/bin/bash
for arg in "\$@"; do
    if [[ "\$arg" == *partner/heartbeat* ]]; then
        echo '{"ok":true}'
        echo '200'
        exit 0
    fi
    if [[ "\$arg" == *partner/cross-probe-token* ]]; then
        : > "$marker"
        if [[ $xprb_exit -ne 0 ]]; then
            echo 'curl: (28) Operation timed out' >&2
            exit $xprb_exit
        fi
        echo '$xprb_body'
        exit 0
    fi
done
# Default: keys endpoint
echo '$KEYS_BODY'
exit 0
CURLSTUB
    chmod +x "$dir/curl"
}

# run_refresh dir [service_token]
# service_token, when passed, is exported as OXPULSE_SERVICE_TOKEN; omitted
# means "no service token available" (tests the no-token skip path).
run_refresh() {
    local dir="$1" svc_token="${2:-}"
    PATH="$dir" \
        LOG_FILE="$dir/refresh.log" \
        PARTNER_EDGE_PREFIX_ETC="$dir/etc" \
        PARTNER_EDGE_PREFIX_LIB="$dir/var" \
        PARTNER_EDGE_TEXTFILE_DIR="$dir/textfile" \
        OXPULSE_BACKEND_URL="http://stub.invalid" \
        OXPULSE_SERVICE_TOKEN="$svc_token" \
        bash "$SCRIPT" >"$dir/out.txt" 2>&1
}

# ── Test 1: file missing → fetched and installed, 0600, exact content ────────
T1=$(mktemp -d)
trap 'rm -rf "$T1"' EXIT

make_bin "$T1"
MARKER1="$T1/xprb_hit"
write_curl_stub "$T1" success "$MARKER1"

mkdir -p "$T1/etc" "$T1/var"
printf '{"node_id":"test-node-xprb1"}\n' > "$T1/etc/node-config.json"
echo "v1" > "$T1/var/keys-version"
echo "c1" > "$T1/var/channels-version"
# node-config.json has no token file → deliberately missing to test that the
# refresh leg reads OXPULSE_SERVICE_TOKEN (env-var override, per
# oxpulse-token-lib.sh's read_service_token contract).

set +e
run_refresh "$T1" stkn_test_valid
EXIT1=$?
set -e

[[ $EXIT1 -eq 0 ]] \
    || fail "test1: script must exit 0 (got $EXIT1); output: $(cat "$T1/out.txt")"
[[ -f "$MARKER1" ]] \
    || fail "test1: cross-probe-token endpoint was never called; output: $(cat "$T1/out.txt")"

TOKEN_FILE1="$T1/etc/cross-probe-token"
[[ -f "$TOKEN_FILE1" ]] \
    || fail "test1: $TOKEN_FILE1 not created; output: $(cat "$T1/out.txt")"
CONTENT1=$(cat "$TOKEN_FILE1")
[[ "$CONTENT1" == "xprb_new_token_abc123" ]] \
    || fail "test1: token file content mismatch — got '$CONTENT1'"
PERMS1=$(stat -c '%a' "$TOKEN_FILE1" 2>/dev/null || stat -f '%A' "$TOKEN_FILE1" 2>/dev/null)
[[ "$PERMS1" == "600" ]] \
    || fail "test1: token file perms must be 0600 — got $PERMS1"
grep -q "cross-probe token refreshed" "$T1/out.txt" \
    || fail "test1: expected 'cross-probe token refreshed' log line; got: $(cat "$T1/out.txt")"

pass "test1: file missing → fetched, installed at 0600 with exact token content"

trap - EXIT
rm -rf "$T1"

# ── Test 2: file young (< half TTL) → fetch skipped entirely ─────────────────
T2=$(mktemp -d)
trap 'rm -rf "$T2"' EXIT

make_bin "$T2"
MARKER2="$T2/xprb_hit"
write_curl_stub "$T2" success "$MARKER2"

mkdir -p "$T2/etc" "$T2/var"
printf '{"node_id":"test-node-xprb2"}\n' > "$T2/etc/node-config.json"
echo "v1" > "$T2/var/keys-version"
echo "c1" > "$T2/var/channels-version"

TOKEN_FILE2="$T2/etc/cross-probe-token"
printf 'xprb_existing_fresh_token' > "$TOKEN_FILE2"
chmod 0600 "$TOKEN_FILE2"
touch "$TOKEN_FILE2"   # mtime = now → age 0s, well under the 302400s threshold

set +e
run_refresh "$T2" stkn_test_valid
EXIT2=$?
set -e

[[ $EXIT2 -eq 0 ]] \
    || fail "test2: script must exit 0 (got $EXIT2); output: $(cat "$T2/out.txt")"
[[ ! -f "$MARKER2" ]] \
    || fail "test2: cross-probe-token endpoint was called despite a fresh file; output: $(cat "$T2/out.txt")"
CONTENT2=$(cat "$TOKEN_FILE2")
[[ "$CONTENT2" == "xprb_existing_fresh_token" ]] \
    || fail "test2: token file content changed despite skip — got '$CONTENT2'"
grep -q "skipping" "$T2/out.txt" \
    || fail "test2: expected a skip log line; got: $(cat "$T2/out.txt")"

pass "test2: file younger than half TTL → fetch skipped, no network call, content untouched"

trap - EXIT
rm -rf "$T2"

# ── Test 3: file old + curl transient failure → existing token preserved ─────
T3=$(mktemp -d)
trap 'rm -rf "$T3"' EXIT

make_bin "$T3"
MARKER3="$T3/xprb_hit"
write_curl_stub "$T3" curl_fail "$MARKER3"

mkdir -p "$T3/etc" "$T3/var" "$T3/textfile"
printf '{"node_id":"test-node-xprb3"}\n' > "$T3/etc/node-config.json"
echo "v1" > "$T3/var/keys-version"
echo "c1" > "$T3/var/channels-version"

TOKEN_FILE3="$T3/etc/cross-probe-token"
printf 'xprb_existing_stale_token' > "$TOKEN_FILE3"
chmod 0600 "$TOKEN_FILE3"
# Backdate mtime well past the refresh threshold (302400s) so the leg attempts
# a fetch. touch -d not available in a minimal PATH-restricted stub env, so
# use python-free approach: set an old mtime via `touch -t`.
OLD_STAMP=$(date -d '@'"$(( $(date +%s) - 400000 ))" +%Y%m%d%H%M.%S 2>/dev/null \
    || date -r "$(( $(date +%s) - 400000 ))" +%Y%m%d%H%M.%S 2>/dev/null)
touch -t "$OLD_STAMP" "$TOKEN_FILE3" 2>/dev/null || true

set +e
run_refresh "$T3" stkn_test_valid
EXIT3=$?
set -e

[[ $EXIT3 -eq 0 ]] \
    || fail "test3: script must exit 0 even on cross-probe fetch failure (got $EXIT3); output: $(cat "$T3/out.txt")"
[[ -f "$MARKER3" ]] \
    || fail "test3: cross-probe-token endpoint was never attempted; output: $(cat "$T3/out.txt")"
CONTENT3=$(cat "$TOKEN_FILE3")
[[ "$CONTENT3" == "xprb_existing_stale_token" ]] \
    || fail "test3: existing token must be preserved on curl failure — got '$CONTENT3'"
grep -q "cross-probe token fetch failed" "$T3/out.txt" \
    || fail "test3: expected a fetch-failed warning; got: $(cat "$T3/out.txt")"
grep -q "preserved" "$T3/out.txt" \
    || fail "test3: expected 'preserved' language in the warning; got: $(cat "$T3/out.txt")"

PROM_FILE3="$T3/textfile/partner_edge.prom"
[[ -f "$PROM_FILE3" ]] \
    || fail "test3: $PROM_FILE3 not created after cross-probe fetch failure"
grep -q 'partner_edge_cross_probe_token_refresh_failure_total' "$PROM_FILE3" \
    || fail "test3: failure counter not emitted; got: $(cat "$PROM_FILE3")"

pass "test3: curl failure on an old token → existing file preserved untouched, failure counter emitted"

trap - EXIT
rm -rf "$T3"

# ── Test 4: file old + malformed response (no xprb_ token) → preserved ───────
T4=$(mktemp -d)
trap 'rm -rf "$T4"' EXIT

make_bin "$T4"
MARKER4="$T4/xprb_hit"
write_curl_stub "$T4" malformed "$MARKER4"

mkdir -p "$T4/etc" "$T4/var"
printf '{"node_id":"test-node-xprb4"}\n' > "$T4/etc/node-config.json"
echo "v1" > "$T4/var/keys-version"
echo "c1" > "$T4/var/channels-version"

TOKEN_FILE4="$T4/etc/cross-probe-token"
printf 'xprb_existing_stale_token_2' > "$TOKEN_FILE4"
chmod 0600 "$TOKEN_FILE4"
OLD_STAMP4=$(date -d '@'"$(( $(date +%s) - 400000 ))" +%Y%m%d%H%M.%S 2>/dev/null \
    || date -r "$(( $(date +%s) - 400000 ))" +%Y%m%d%H%M.%S 2>/dev/null)
touch -t "$OLD_STAMP4" "$TOKEN_FILE4" 2>/dev/null || true

set +e
run_refresh "$T4" stkn_test_valid
EXIT4=$?
set -e

[[ $EXIT4 -eq 0 ]] \
    || fail "test4: script must exit 0 on a malformed response (got $EXIT4); output: $(cat "$T4/out.txt")"
[[ -f "$MARKER4" ]] \
    || fail "test4: cross-probe-token endpoint was never attempted; output: $(cat "$T4/out.txt")"
CONTENT4=$(cat "$TOKEN_FILE4")
[[ "$CONTENT4" == "xprb_existing_stale_token_2" ]] \
    || fail "test4: existing token must be preserved on a malformed response — got '$CONTENT4'"
grep -q "missing/malformed response" "$T4/out.txt" \
    || fail "test4: expected a malformed-response warning; got: $(cat "$T4/out.txt")"

pass "test4: malformed/missing-prefix response on an old token → existing file preserved untouched"

trap - EXIT
rm -rf "$T4"

# ── Test 5: no service token available → endpoint never called, no crash ─────
T5=$(mktemp -d)
trap 'rm -rf "$T5"' EXIT

make_bin "$T5"
MARKER5="$T5/xprb_hit"
write_curl_stub "$T5" success "$MARKER5"

mkdir -p "$T5/etc" "$T5/var"
printf '{"node_id":"test-node-xprb5"}\n' > "$T5/etc/node-config.json"
echo "v1" > "$T5/var/keys-version"
echo "c1" > "$T5/var/channels-version"
# No cross-probe-token file, no $PREFIX_ETC/token, no OXPULSE_SERVICE_TOKEN.

set +e
run_refresh "$T5"
EXIT5=$?
set -e

[[ $EXIT5 -eq 0 ]] \
    || fail "test5: script must exit 0 with no service token available (got $EXIT5); output: $(cat "$T5/out.txt")"
[[ ! -f "$MARKER5" ]] \
    || fail "test5: cross-probe-token endpoint must not be called with no service token; output: $(cat "$T5/out.txt")"
[[ ! -f "$T5/etc/cross-probe-token" ]] \
    || fail "test5: no token file should have been created"
grep -q "no service token available" "$T5/out.txt" \
    || fail "test5: expected a 'no service token available' warning; got: $(cat "$T5/out.txt")"

pass "test5: no service token available → skipped gracefully, script still exits 0"

trap - EXIT
rm -rf "$T5"

# ── Syntax check ───────────────────────────────────────────────────────────
bash -n "$SCRIPT" \
    || fail "refresh script has syntax errors"
pass "syntax check clean"

echo ""
echo "All tests passed."
