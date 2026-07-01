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
                dirname mktemp basename sha256sum sync; do
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
#   $3 = marker file path — one line APPENDED per cross-probe-token call, so
#        `wc -l < marker` doubles as an attempt-count assertion for the
#        retry-on-5xx / no-retry-on-4xx regression tests below.
write_curl_stub() {
    local dir="$1" mode="$2" marker="$3"
    local xprb_body xprb_code xprb_exit
    case "$mode" in
        success)
            xprb_body='{"cross_probe_token":"xprb_new_token_abc123","issued_at":"2026-07-01T06:00:00Z","ttl_secs":604800}'
            xprb_code=200
            xprb_exit=0
            ;;
        curl_fail)
            # Total transfer failure (DNS/connect/TLS/timeout): curl prints
            # nothing to stdout (no -w output either — the transfer never
            # completed) and exits nonzero. No marker of an HTTP code.
            xprb_body=""
            xprb_code=""
            xprb_exit=1
            ;;
        malformed)
            # Completed 200 response, but no (valid) cross_probe_token in it.
            xprb_body='{"error":"unauthorized"}'
            xprb_code=200
            xprb_exit=0
            ;;
        malformed_with_leak)
            # Completed 200 response with no *valid* cross_probe_token field
            # (missing the xprb_ prefix requirement checked by the caller),
            # but an xprb_-shaped string appears elsewhere in the body — the
            # credential-leak regression case for HIGH-2.
            xprb_body='{"error":"token xprb_should_never_leak_into_logs_12345 is stale, mint a new one"}'
            xprb_code=200
            xprb_exit=0
            ;;
        empty_body)
            # Completed 200 response with a genuinely empty body.
            xprb_body=""
            xprb_code=200
            xprb_exit=0
            ;;
        http_error)
            # Completed transfer, non-2xx status. No -f flag on the real
            # call, so curl exits 0 here — the caller branches on $xprb_code.
            xprb_body='{"error":"invalid service token"}'
            xprb_code=401
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
        printf 'call\n' >> "$marker"
        if [[ $xprb_exit -ne 0 ]]; then
            echo 'curl: (28) Operation timed out' >&2
            exit $xprb_exit
        fi
        # Mirrors real curl -w '\n%{http_code}': body line(s), then the
        # status code as the LAST line.
        echo '$xprb_body'
        echo '$xprb_code'
        exit 0
    fi
done
# Default: keys endpoint
echo '$KEYS_BODY'
exit 0
CURLSTUB
    chmod +x "$dir/curl"
}

# write_curl_stub_retry_then_success dir marker succeed_at
# Stateful cross-probe-token stub for the retry-on-5xx regression (PR review
# round 2): returns HTTP 503 on every call before attempt $succeed_at, then
# a valid 200+token response. Attempt number is derived from $marker's line
# count (one line appended per call, read BEFORE incrementing) — same
# counting convention as write_curl_stub's marker.
write_curl_stub_retry_then_success() {
    local dir="$1" marker="$2" succeed_at="$3"
    cat > "$dir/curl" <<CURLSTUB
#!/bin/bash
for arg in "\$@"; do
    if [[ "\$arg" == *partner/heartbeat* ]]; then
        echo '{"ok":true}'
        echo '200'
        exit 0
    fi
    if [[ "\$arg" == *partner/cross-probe-token* ]]; then
        _n=\$(( \$(wc -l < "$marker" 2>/dev/null || echo 0) + 1 ))
        printf 'call\n' >> "$marker"
        if [[ "\$_n" -ge $succeed_at ]]; then
            echo '{"cross_probe_token":"xprb_retry_success_token","issued_at":"2026-07-01T06:00:00Z","ttl_secs":604800}'
            echo '200'
        else
            echo '{"error":"backend overloaded, try again"}'
            echo '503'
        fi
        exit 0
    fi
done
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

# backdate_mtime file — set mtime to (now - 400000s), well past the
# 302400s (half of the default 604800s TTL) refresh threshold, so the
# refresh leg actually attempts a fetch instead of skipping.
backdate_mtime() {
    local f="$1" stamp
    stamp=$(date -d '@'"$(( $(date +%s) - 400000 ))" +%Y%m%d%H%M.%S 2>/dev/null \
        || date -r "$(( $(date +%s) - 400000 ))" +%Y%m%d%H%M.%S 2>/dev/null)
    touch -t "$stamp" "$f" 2>/dev/null || true
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
backdate_mtime "$TOKEN_FILE3"

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
CALLS3=$(wc -l < "$MARKER3")
[[ "$CALLS3" -eq 3 ]] \
    || fail "test3: a persistent transport failure must exhaust all 3 retry attempts (2s/5s backoff), got $CALLS3 call(s)"

pass "test3: curl failure on an old token → all 3 retry attempts exhausted, existing file preserved, failure counter emitted"

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
backdate_mtime "$TOKEN_FILE4"

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
grep -q "missing/malformed cross_probe_token in response" "$T4/out.txt" \
    || fail "test4: expected a malformed-response warning; got: $(cat "$T4/out.txt")"
grep -q "body sha256=" "$T4/out.txt" \
    || fail "test4: expected a sha256 correlation prefix, not the raw body, in the warning; got: $(cat "$T4/out.txt")"

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

# ── Test 6 (MED-3): HTTP 200 + empty body → explicit warn+metric, preserved ──
T6=$(mktemp -d)
trap 'rm -rf "$T6"' EXIT

make_bin "$T6"
MARKER6="$T6/xprb_hit"
write_curl_stub "$T6" empty_body "$MARKER6"

mkdir -p "$T6/etc" "$T6/var" "$T6/textfile"
printf '{"node_id":"test-node-xprb6"}\n' > "$T6/etc/node-config.json"
echo "v1" > "$T6/var/keys-version"
echo "c1" > "$T6/var/channels-version"

TOKEN_FILE6="$T6/etc/cross-probe-token"
printf 'xprb_existing_stale_token_6' > "$TOKEN_FILE6"
chmod 0600 "$TOKEN_FILE6"
backdate_mtime "$TOKEN_FILE6"

set +e
run_refresh "$T6" stkn_test_valid
EXIT6=$?
set -e

[[ $EXIT6 -eq 0 ]] \
    || fail "test6: script must exit 0 on an empty 200 body (got $EXIT6); output: $(cat "$T6/out.txt")"
CONTENT6=$(cat "$TOKEN_FILE6")
[[ "$CONTENT6" == "xprb_existing_stale_token_6" ]] \
    || fail "test6: existing token must be preserved on an empty response body — got '$CONTENT6'"
grep -q "empty response body on HTTP 200" "$T6/out.txt" \
    || fail "test6: expected an explicit empty-body warning (previously matched NEITHER the success nor malformed arm); got: $(cat "$T6/out.txt")"
grep -q 'reason="empty_response"' "$T6/textfile/partner_edge.prom" \
    || fail "test6: expected reason=\"empty_response\" in the emitted metric; got: $(cat "$T6/textfile/partner_edge.prom" 2>/dev/null)"

pass "test6 (MED-3): empty 200 body → explicit warn + empty_response metric, existing file preserved"

trap - EXIT
rm -rf "$T6"

# ── Test 7 (HIGH-2): a token-shaped string in a malformed body never logs ────
T7=$(mktemp -d)
trap 'rm -rf "$T7"' EXIT

make_bin "$T7"
MARKER7="$T7/xprb_hit"
write_curl_stub "$T7" malformed_with_leak "$MARKER7"

mkdir -p "$T7/etc" "$T7/var"
printf '{"node_id":"test-node-xprb7"}\n' > "$T7/etc/node-config.json"
echo "v1" > "$T7/var/keys-version"
echo "c1" > "$T7/var/channels-version"

TOKEN_FILE7="$T7/etc/cross-probe-token"
printf 'xprb_existing_stale_token_7' > "$TOKEN_FILE7"
chmod 0600 "$TOKEN_FILE7"
backdate_mtime "$TOKEN_FILE7"

set +e
run_refresh "$T7" stkn_test_valid
EXIT7=$?
set -e

[[ $EXIT7 -eq 0 ]] \
    || fail "test7: script must exit 0 (got $EXIT7); output: $(cat "$T7/out.txt")"
[[ -f "$MARKER7" ]] \
    || fail "test7: cross-probe-token endpoint was never attempted; output: $(cat "$T7/out.txt")"
if grep -qE 'xprb_[A-Za-z0-9_]+' "$T7/out.txt"; then
    fail "test7: the credential-issuing endpoint's raw response body leaked into logs verbatim (contains an xprb_ token): $(cat "$T7/out.txt")"
fi
grep -q "body sha256=" "$T7/out.txt" \
    || fail "test7: expected a sha256 correlation prefix instead of the raw body; got: $(cat "$T7/out.txt")"
CONTENT7=$(cat "$TOKEN_FILE7")
[[ "$CONTENT7" == "xprb_existing_stale_token_7" ]] \
    || fail "test7: existing token must be preserved — got '$CONTENT7'"

pass "test7 (HIGH-2): xprb_-shaped string inside a malformed body never reaches the log verbatim"

trap - EXIT
rm -rf "$T7"

# ── Test 8 (HIGH-1): read-only \$PREFIX_ETC must not kill the whole script ───
# Regression for the exact failure the reviewer reproduced: mktemp/chmod/mv
# in the write path, unguarded, dies the WHOLE script under
# `set -euo pipefail` the moment $PREFIX_ETC is unwritable — skipping
# channels re-render AND Reality-key rotation entirely. This test forces a
# real Reality-key rotation (NEW_VERSION != stored version) and asserts the
# script still reaches — and completes — that code path.
#
# Two layers, both exercised:
#  (a) $PREFIX_ETC actually chmod'd 0500 (r-x, no write) — the literal
#      scenario named in the review.
#  (b) `mktemp` itself stubbed to unconditionally fail — deterministic and
#      portable across hosts. (a) alone is NOT sufficient as a REVERT-safe
#      regression guard on every host: GNU coreutils `install -d -m MODE`
#      re-chmods an EXISTING, same-owner directory back to MODE (verified
#      empirically — `install -d -m 0700` on a 0500 dir this process owns
#      silently heals it before mktemp ever runs), which is incidentally
#      what the ORIGINAL code's `install -d -m 0700 "$PREFIX_ETC" || true`
#      line did — so a bare chmod-0500 test can pass against the OLD code
#      too on a GNU host, purely by that healing side effect, not because
#      the old code was actually guarded. (b) removes that confound and
#      isolates exactly the guarantee HIGH-1 requires: mktemp failing, for
#      ANY reason (permission, disk full, quota, a non-GNU `install` that
#      doesn't re-chmod existing dirs), must never kill the script.
T8=$(mktemp -d)
trap 'rm -rf "$T8"' EXIT

make_bin "$T8"
MARKER8="$T8/xprb_hit"
write_curl_stub "$T8" success "$MARKER8"
# Stub mktemp AFTER make_bin symlinks the real one — override it to fail
# unconditionally, simulating an unwritable/missing $PREFIX_ETC regardless
# of any install -d healing behavior. Remove the symlink first: `cat >`
# follows symlinks when opening for write, so writing straight over it would
# try (and fail, as non-root) to overwrite the REAL system mktemp binary.
rm -f "$T8/mktemp"
cat > "$T8/mktemp" <<'MKTEMPSTUB'
#!/bin/sh
echo "mktemp: cannot create: Permission denied" >&2
exit 1
MKTEMPSTUB
chmod +x "$T8/mktemp"

mkdir -p "$T8/etc" "$T8/var" "$T8/textfile"
printf '{"node_id":"test-node-xprb8"}\n' > "$T8/etc/node-config.json"
echo "v1" > "$T8/var/keys-version"
echo "c1" > "$T8/var/channels-version"
# No cross-probe-token file → the leg always attempts a fetch+write here.

chmod 0500 "$T8/etc"   # (a) literal read-only reproduction, belt-and-suspenders
trap 'chmod 0700 "$T8/etc" 2>/dev/null || true; rm -rf "$T8"' EXIT

set +e
run_refresh "$T8" stkn_test_valid
EXIT8=$?
set -e

[[ $EXIT8 -eq 0 ]] \
    || fail "test8: script must exit 0 even with an unwritable \$PREFIX_ETC (got $EXIT8); output: $(cat "$T8/out.txt")"
grep -q "no rotation: version=v1" "$T8/out.txt" \
    || fail "test8: script must still reach the Reality-rotation code (terminal 'no rotation' log line) despite the cross-probe write failure; output: $(cat "$T8/out.txt")"
grep -q "cross-probe token persist failed" "$T8/out.txt" \
    || fail "test8: expected a persist-failed warning for the unwritable dir; got: $(cat "$T8/out.txt")"

pass "test8 (HIGH-1): unwritable \$PREFIX_ETC → write fails loudly but the script still completes to the Reality-rotation check"

chmod 0700 "$T8/etc" 2>/dev/null || true
trap - EXIT
rm -rf "$T8"

# ── Test 9: HTTP non-200 status → explicit warn, body never logged ───────────
T9=$(mktemp -d)
trap 'rm -rf "$T9"' EXIT

make_bin "$T9"
MARKER9="$T9/xprb_hit"
write_curl_stub "$T9" http_error "$MARKER9"

mkdir -p "$T9/etc" "$T9/var" "$T9/textfile"
printf '{"node_id":"test-node-xprb9"}\n' > "$T9/etc/node-config.json"
echo "v1" > "$T9/var/keys-version"
echo "c1" > "$T9/var/channels-version"

TOKEN_FILE9="$T9/etc/cross-probe-token"
printf 'xprb_existing_stale_token_9' > "$TOKEN_FILE9"
chmod 0600 "$TOKEN_FILE9"
backdate_mtime "$TOKEN_FILE9"

set +e
run_refresh "$T9" stkn_test_valid
EXIT9=$?
set -e

[[ $EXIT9 -eq 0 ]] \
    || fail "test9: script must exit 0 on a non-200 status (got $EXIT9); output: $(cat "$T9/out.txt")"
grep -q "HTTP 401" "$T9/out.txt" \
    || fail "test9: expected the HTTP status in the warning; got: $(cat "$T9/out.txt")"
grep -q "invalid service token" "$T9/out.txt" \
    && fail "test9: the error response body must not be logged verbatim; got: $(cat "$T9/out.txt")"
grep -q 'reason="http_401"' "$T9/textfile/partner_edge.prom" \
    || fail "test9: expected reason=\"http_401\" in the emitted metric; got: $(cat "$T9/textfile/partner_edge.prom" 2>/dev/null)"
CALLS9=$(wc -l < "$MARKER9")
[[ "$CALLS9" -eq 1 ]] \
    || fail "test9 (retry-on-5xx round 2): a 4xx is deterministic and must NEVER be retried, got $CALLS9 call(s)"

pass "test9: non-200 status → status logged, body withheld, http_401 metric emitted, NOT retried (exactly 1 attempt)"

trap - EXIT
rm -rf "$T9"

# ── Test 10 (retry-on-5xx round 2): transient 5xx retried, THEN succeeds ─────
# Backend returns 503 on attempts 1-2, then a valid token on attempt 3 — the
# exact scenario the gating MEDIUM named: a transient backend blip must not
# defer re-mint by a full day. Asserts the token IS installed (retry
# recovered) and all 3 attempts were actually consumed.
T10=$(mktemp -d)
trap 'rm -rf "$T10"' EXIT

make_bin "$T10"
MARKER10="$T10/xprb_hit"
write_curl_stub_retry_then_success "$T10" "$MARKER10" 3

mkdir -p "$T10/etc" "$T10/var" "$T10/textfile"
printf '{"node_id":"test-node-xprb10"}\n' > "$T10/etc/node-config.json"
echo "v1" > "$T10/var/keys-version"
echo "c1" > "$T10/var/channels-version"
# No cross-probe-token file → the leg always attempts a fetch here.

set +e
run_refresh "$T10" stkn_test_valid
EXIT10=$?
set -e

[[ $EXIT10 -eq 0 ]] \
    || fail "test10: script must exit 0 (got $EXIT10); output: $(cat "$T10/out.txt")"
TOKEN_FILE10="$T10/etc/cross-probe-token"
[[ -f "$TOKEN_FILE10" ]] \
    || fail "test10: token file not created despite eventual success on attempt 3; output: $(cat "$T10/out.txt")"
CONTENT10=$(cat "$TOKEN_FILE10")
[[ "$CONTENT10" == "xprb_retry_success_token" ]] \
    || fail "test10: expected the attempt-3 token, got '$CONTENT10'"
CALLS10=$(wc -l < "$MARKER10")
[[ "$CALLS10" -eq 3 ]] \
    || fail "test10: expected exactly 3 attempts (2 x 503 + 1 success), got $CALLS10"
grep -q "cross-probe token refreshed" "$T10/out.txt" \
    || fail "test10: expected a success log line; got: $(cat "$T10/out.txt")"

pass "test10 (retry-on-5xx round 2): 503 on attempts 1-2, success on attempt 3 → token installed, all 3 attempts consumed"

trap - EXIT
rm -rf "$T10"

# ── Test 11 (retry-on-5xx round 2): persistent 5xx exhausts retries cleanly ──
# Same shape as test3 (curl transport failure) but for an HTTP-level 5xx
# that never recovers — confirms the retry loop hands back the LAST 503
# response (not a transport-failure code path) after exhausting attempts,
# and the existing token is preserved.
T11=$(mktemp -d)
trap 'rm -rf "$T11"' EXIT

make_bin "$T11"
MARKER11="$T11/xprb_hit"
write_curl_stub_retry_then_success "$T11" "$MARKER11" 99   # never reaches attempt 99 → always 503

mkdir -p "$T11/etc" "$T11/var" "$T11/textfile"
printf '{"node_id":"test-node-xprb11"}\n' > "$T11/etc/node-config.json"
echo "v1" > "$T11/var/keys-version"
echo "c1" > "$T11/var/channels-version"

TOKEN_FILE11="$T11/etc/cross-probe-token"
printf 'xprb_existing_stale_token_11' > "$TOKEN_FILE11"
chmod 0600 "$TOKEN_FILE11"
backdate_mtime "$TOKEN_FILE11"

set +e
run_refresh "$T11" stkn_test_valid
EXIT11=$?
set -e

[[ $EXIT11 -eq 0 ]] \
    || fail "test11: script must exit 0 on a persistent 5xx (got $EXIT11); output: $(cat "$T11/out.txt")"
CALLS11=$(wc -l < "$MARKER11")
[[ "$CALLS11" -eq 3 ]] \
    || fail "test11: a persistent 503 must exhaust all 3 retry attempts, got $CALLS11"
grep -q "HTTP 503" "$T11/out.txt" \
    || fail "test11: expected the final 503 status in the warning; got: $(cat "$T11/out.txt")"
grep -q "backend overloaded" "$T11/out.txt" \
    && fail "test11: the 5xx error body must not be logged verbatim; got: $(cat "$T11/out.txt")"
CONTENT11=$(cat "$TOKEN_FILE11")
[[ "$CONTENT11" == "xprb_existing_stale_token_11" ]] \
    || fail "test11: existing token must be preserved after exhausting retries — got '$CONTENT11'"

pass "test11 (retry-on-5xx round 2): persistent 503 exhausts all 3 attempts, existing token preserved, body never logged"

trap - EXIT
rm -rf "$T11"

# ── Test 12 (fsync-before-rename round 2): a failing `sync` must not break ───
# the write path. write_secret_atomic's new durability step is explicitly
# advisory (log-only) — a host/filesystem that rejects fsync entirely (or
# lacks the `sync` binary) must still complete the write.
T12=$(mktemp -d)
trap 'rm -rf "$T12"' EXIT

make_bin "$T12"
MARKER12="$T12/xprb_hit"
write_curl_stub "$T12" success "$MARKER12"
# Remove the real symlink first — `cat >` follows symlinks when opening for
# write, so writing straight over it would try to overwrite the real
# system sync binary (same gotcha as the mktemp stub in test8).
rm -f "$T12/sync"
cat > "$T12/sync" <<'SYNCSTUB'
#!/bin/sh
echo "sync: Function not implemented" >&2
exit 1
SYNCSTUB
chmod +x "$T12/sync"

mkdir -p "$T12/etc" "$T12/var"
printf '{"node_id":"test-node-xprb12"}\n' > "$T12/etc/node-config.json"
echo "v1" > "$T12/var/keys-version"
echo "c1" > "$T12/var/channels-version"
# No cross-probe-token file → the leg always attempts a fetch+write here.

set +e
run_refresh "$T12" stkn_test_valid
EXIT12=$?
set -e

[[ $EXIT12 -eq 0 ]] \
    || fail "test12: script must exit 0 even when sync always fails (got $EXIT12); output: $(cat "$T12/out.txt")"
TOKEN_FILE12="$T12/etc/cross-probe-token"
[[ -f "$TOKEN_FILE12" ]] \
    || fail "test12: token file must still be written when sync fails (advisory-only durability step); output: $(cat "$T12/out.txt")"
CONTENT12=$(cat "$TOKEN_FILE12")
[[ "$CONTENT12" == "xprb_new_token_abc123" ]] \
    || fail "test12: token content mismatch despite sync failure — got '$CONTENT12'"
grep -q "cross-probe token refreshed" "$T12/out.txt" \
    || fail "test12: expected the normal success log line despite sync failing; got: $(cat "$T12/out.txt")"

pass "test12 (fsync-before-rename round 2): a failing sync is advisory-only — write still completes"

trap - EXIT
rm -rf "$T12"

# ── Syntax check ───────────────────────────────────────────────────────────
bash -n "$SCRIPT" \
    || fail "refresh script has syntax errors"
pass "syntax check clean"

echo ""
echo "All tests passed."
