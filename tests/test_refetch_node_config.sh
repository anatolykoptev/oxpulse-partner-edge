#!/bin/bash
# tests/test_refetch_node_config.sh — refetch_node_config() behavioural suite.
#
# Covers the delivery half of ADR-G (per-node VLESS-Reality shortId
# diversification): upgrade.sh must re-fetch node-config.json from the
# authenticated control plane BEFORE re_render_xray, so a central
# per-node reassignment (e.g. SNI override) actually reaches the node.
#
# Tests (each must FAIL without its fix — mutate to verify):
#   1. Reachable control plane → local node-config replaced with fetched
#      one before render; rendered xray config reflects the FETCHED
#      short_id, not the stale local one.
#   2. Unreachable control plane → stale local file used, render still
#      completes, fallback announced visibly (warn at operator level).
#   3a. Valid JSON but missing required field → local file left untouched,
#       nothing partial written.
#   3b. Truncated mid-write (invalid JSON) → local file left untouched,
#       nothing partial written.
#   4. update.sh behaviour unchanged — assert it, do not assume it.
#   5. upgrade.sh calls refetch_node_config before every re_render_xray.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LIB="$REPO_ROOT/channel-render-lib.sh"
TPL="$REPO_ROOT/xray-client.json.tpl"
UPDATE_SH="$REPO_ROOT/update.sh"
UPGRADE_SH="$REPO_ROOT/upgrade.sh"

[[ -f "$LIB" ]]       || { echo "FAIL: channel-render-lib.sh not found at $LIB"; exit 1; }
[[ -f "$TPL" ]]       || { echo "FAIL: xray-client.json.tpl not found at $TPL"; exit 1; }
[[ -f "$UPDATE_SH" ]] || { echo "FAIL: update.sh not found at $UPDATE_SH"; exit 1; }
[[ -f "$UPGRADE_SH" ]] || { echo "FAIL: upgrade.sh not found at $UPGRADE_SH"; exit 1; }

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# ---------------------------------------------------------------------------
# Shared helpers (mirror test_update_sh.sh / test_refresh_emit_metric_idempotent.sh)
# ---------------------------------------------------------------------------

# make_bin: symlink POSIX utilities into a stub dir so subprocesses resolve.
make_bin() {
    local dir="$1"
    for cmd in bash sh date printf cat tee cp mv mkdir chmod install sleep \
                sed grep head tail wc stat cut tr expr test rm dirname mktemp \
                python3 jq sha256sum; do
        local loc
        loc=$(command -v "$cmd" 2>/dev/null || true)
        if [[ -n "$loc" ]]; then ln -sf "$loc" "$dir/$cmd"; fi
    done
}

# write_stub: remove symlink and write a new stub script.
write_stub() {
    local path="$1" body="$2"
    rm -f "$path"
    printf '#!/bin/bash\n%s\n' "$body" > "$path"
    chmod +x "$path"
}

# Stale local node-config (short_id = "STALE_OLD").
write_stale_node_config() {
    local path="$1"
    cat > "$path" <<'EOF'
{
  "node_id": "test-node-001",
  "partner_id": "edge-c",
  "reality_uuid": "00000000-0000-0000-0000-000000000001",
  "reality_public_key": "U6ea044JJjgiCjQAnYEBqBBlkeSqrQaLq3lcjnN2EFk",
  "reality_encryption": "none",
  "reality_short_id": "STALE_OLD",
  "reality_server_name": "www.samsung.com",
  "reality_server_names": ["www.samsung.com"],
  "backend_endpoint": "hub.example.com:5349"
}
EOF
}

# Fresh fetched node-config (short_id = "FRESH_NEW" — the diversified value).
write_fresh_node_config_json() {
    cat <<'EOF'
{
  "node_id": "test-node-001",
  "partner_id": "edge-c",
  "reality_uuid": "00000000-0000-0000-0000-000000000001",
  "reality_public_key": "U6ea044JJjgiCjQAnYEBqBBlkeSqrQaLq3lcjnN2EFk",
  "reality_encryption": "none",
  "reality_short_id": "FRESH_NEW",
  "reality_server_name": "www.samsung.com",
  "reality_server_names": ["www.samsung.com"],
  "backend_endpoint": "hub.example.com:5349"
}
EOF
}

# make_curl_stub: write a curl stub that handles -o <file> correctly.
#   $1 = stub path
#   $2 = path to a file containing the node-config response body
#   $3 = node-config exit code (0 for reachable, 7 for unreachable)
# The template fetch (xray-client.json.tpl) always succeeds and respects -o.
make_curl_stub() {
    local stub="$1" resp_file="$2" exit_code="${3:-0}"
    write_stub "$stub" '
# Parse -o <file> from args
_out_file=""
_prev=""
for arg in "$@"; do
    if [[ "$_prev" == "-o" ]]; then
        _out_file="$arg"
    fi
    _prev="$arg"
done
# Template fetch: always succeed, respect -o
for arg in "$@"; do
    if [[ "$arg" == *xray-client.json.tpl* ]]; then
        if [[ -n "$_out_file" ]]; then
            cat "'"$TPL"'" > "$_out_file"
        else
            cat "'"$TPL"'"
        fi
        exit 0
    fi
done
# Node-config fetch: use caller-supplied response file + exit code
if [[ '"$exit_code"' -ne 0 ]]; then
    echo "curl: (7) Failed to connect" >&2
    exit '"$exit_code"'
fi
if [[ -n "$_out_file" ]]; then
    cp "'"$resp_file"'" "$_out_file"
else
    cat "'"$resp_file"'"
fi
exit 0
'
}

# Set up the environment to source channel-render-lib.sh and call
# refetch_node_config + re_render_xray.  $1 = stub dir, $2 = etc dir.
# Caller must write_stub "$1/curl" BEFORE calling run_refetch_and_render.
setup_env() {
    local stub_dir="$1" etc_dir="$2"
    mkdir -p "$stub_dir" "$etc_dir"
    make_bin "$stub_dir"

    # docker stub: compose restart succeeds (re_render_xray calls it).
    write_stub "$stub_dir/docker" '
if [[ "$1" == "compose" ]]; then exit 0; fi
exit 0'

    # Token file
    printf 'ptkn_test123\n' > "$etc_dir/token"
    chmod 0600 "$etc_dir/token"

    # Stale local node-config
    write_stale_node_config "$etc_dir/node-config.json"
}

# Source the lib and run refetch + render.  Captures stdout+stderr.
# Args: stub_dir, etc_dir, var_dir
run_refetch_and_render() {
    local stub_dir="$1" etc_dir="$2" var_dir="$3"
    mkdir -p "$var_dir"
    PATH="$stub_dir:$(dirname "$(command -v python3)"):/usr/bin:/bin" \
    PREFIX_ETC="$etc_dir" \
    PREFIX_LIB="$var_dir" \
    NODE_CFG="$etc_dir/node-config.json" \
    XRAY_CFG="$etc_dir/xray-client.json" \
    TOKEN_FILE="$etc_dir/token" \
    OXPULSE_BACKEND_URL="http://test-control-plane.invalid" \
    REPO_RAW="file://$REPO_ROOT" \
    LOG_FILE="$var_dir/render.log" \
    bash -c '
        set -euo pipefail
        log()  { printf "%s\n" "$*" >&2; }
        warn() { log "WARN $*"; }
        die()  { log "ERR $*"; exit 1; }
        source "'"$LIB"'"
        refetch_node_config
        re_render_xray
    ' 2>&1
}

# Extract short_id from a rendered xray-client.json.
extract_short_id() {
    local cfg="$1"
    python3 -c "
import json,sys
c=json.load(open(sys.argv[1]))
for ob in c.get('outbounds',[]):
    ss=ob.get('streamSettings',{})
    r=ss.get('realitySettings',{})
    if r: print(r.get('shortId','')); sys.exit(0)
print('')
" "$cfg"
}

# ---------------------------------------------------------------------------
# Test 1: Reachable control plane → fetched value in rendered config
# ---------------------------------------------------------------------------
echo "=== Test 1: reachable control plane → fetched short_id in render ==="
t1=$(mktemp -d)
trap 'rm -rf "$t1"' EXIT

setup_env "$t1/stub" "$t1/etc"
mkdir -p "$t1/var"

# curl stub: returns the fresh node-config with short_id="FRESH_NEW".
write_fresh_node_config_json > "$t1/fresh_resp.json"
make_curl_stub "$t1/stub/curl" "$t1/fresh_resp.json" 0

set +e
out1=$(run_refetch_and_render "$t1/stub" "$t1/etc" "$t1/var")
exit1=$?
set -e

if [[ $exit1 -ne 0 ]]; then
    fail "test1: refetch+render exited $exit1; output: $out1"
else
    # Assert: node-config.json was replaced with the fetched one.
    fetched_sid=$(jq -r '.reality_short_id // empty' "$t1/etc/node-config.json" 2>/dev/null || true)
    if [[ "$fetched_sid" == "FRESH_NEW" ]]; then
        pass "test1a: node-config.json replaced with fetched value (short_id=$fetched_sid)"
    else
        fail "test1a: node-config.json short_id is '$fetched_sid', expected 'FRESH_NEW'; output: $out1"
    fi

    # Assert: rendered xray-client.json reflects the FETCHED short_id.
    rendered_sid=$(extract_short_id "$t1/etc/xray-client.json")
    if [[ "$rendered_sid" == "FRESH_NEW" ]]; then
        pass "test1b: rendered xray config has fetched short_id (FRESH_NEW), not stale (STALE_OLD)"
    else
        fail "test1b: rendered short_id is '$rendered_sid', expected 'FRESH_NEW'; output: $out1"
    fi
fi

trap - EXIT
rm -rf "$t1"

# ---------------------------------------------------------------------------
# Test 2: Unreachable control plane → fallback to local, visible warn
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 2: unreachable control plane → fallback, visible warn ==="
t2=$(mktemp -d)
trap 'rm -rf "$t2"' EXIT

setup_env "$t2/stub" "$t2/etc"
mkdir -p "$t2/var"

# curl stub: node-config fetch fails (unreachable), template fetch succeeds.
: > "$t2/empty_resp.json"
make_curl_stub "$t2/stub/curl" "$t2/empty_resp.json" 7

set +e
out2=$(run_refetch_and_render "$t2/stub" "$t2/etc" "$t2/var")
exit2=$?
set -e

if [[ $exit2 -ne 0 ]]; then
    fail "test2: refetch+render exited $exit2 on unreachable CP; output: $out2"
else
    # Assert: local node-config is unchanged (still STALE_OLD).
    local_sid=$(jq -r '.reality_short_id // empty' "$t2/etc/node-config.json" 2>/dev/null || true)
    if [[ "$local_sid" == "STALE_OLD" ]]; then
        pass "test2a: stale local node-config preserved (short_id=$local_sid)"
    else
        fail "test2a: node-config short_id is '$local_sid', expected 'STALE_OLD' (local should be untouched)"
    fi

    # Assert: rendered xray config uses the stale local value.
    rendered_sid=$(extract_short_id "$t2/etc/xray-client.json")
    if [[ "$rendered_sid" == "STALE_OLD" ]]; then
        pass "test2b: rendered xray config uses stale local value (STALE_OLD)"
    else
        fail "test2b: rendered short_id is '$rendered_sid', expected 'STALE_OLD'"
    fi

    # Assert: fallback was announced visibly (warn in output, not debug).
    if echo "$out2" | grep -E 'WARN.*using local node-config|API re-fetch failed' >/dev/null; then
        pass "test2c: fallback announced visibly (WARN in output)"
    else
        fail "test2c: no visible fallback warning in output; got: $out2"
    fi
fi

trap - EXIT
rm -rf "$t2"

# ---------------------------------------------------------------------------
# Test 3a: Valid JSON but missing required field → local untouched
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 3a: valid JSON missing required field → local untouched ==="
t3a=$(mktemp -d)
trap 'rm -rf "$t3a"' EXIT

setup_env "$t3a/stub" "$t3a/etc"
mkdir -p "$t3a/var"

# Snapshot the local node-config hash BEFORE the refetch.
local_hash_before=$(sha256sum "$t3a/etc/node-config.json" | awk '{print $1}')

# curl stub: returns valid JSON with node_id but NO reality_uuid/pub_key/backend.
printf '{"node_id":"test-node-001","partner_id":"edge-c"}\n' > "$t3a/malformed_resp.json"
make_curl_stub "$t3a/stub/curl" "$t3a/malformed_resp.json" 0

set +e
out3a=$(run_refetch_and_render "$t3a/stub" "$t3a/etc" "$t3a/var")
exit3a=$?
set -e

# Assert: local node-config is byte-identical to before.
local_hash_after=$(sha256sum "$t3a/etc/node-config.json" | awk '{print $1}')
if [[ "$local_hash_before" == "$local_hash_after" ]]; then
    pass "test3a: local node-config untouched (hash identical)"
else
    fail "test3a: local node-config was modified (before=$local_hash_before after=$local_hash_after)"
fi

# Assert: no temp file left behind.
temp_count=$(find "$t3a/etc" -name '.node-config.json.*.tmp' 2>/dev/null | wc -l | tr -d ' ')
if [[ "$temp_count" -eq 0 ]]; then
    pass "test3a: no partial temp file left behind"
else
    fail "test3a: $temp_count temp file(s) left behind in $t3a/etc"
fi

# Assert: rejection was announced visibly.
if echo "$out3a" | grep -E 'WARN.*missing required fields|WARN.*using local' >/dev/null; then
    pass "test3a: rejection announced visibly (WARN)"
else
    fail "test3a: no visible rejection warning; output: $out3a"
fi

trap - EXIT
rm -rf "$t3a"

# ---------------------------------------------------------------------------
# Test 3b: Truncated mid-write (invalid JSON) → local untouched
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 3b: truncated mid-write (invalid JSON) → local untouched ==="
t3b=$(mktemp -d)
trap 'rm -rf "$t3b"' EXIT

setup_env "$t3b/stub" "$t3b/etc"
mkdir -p "$t3b/var"

local_hash_before=$(sha256sum "$t3b/etc/node-config.json" | awk '{print $1}')

# curl stub: returns a truncated JSON response (cut off mid-string).
# This simulates a connection drop mid-transfer: the response starts as
# valid JSON but is cut off before the closing brace.
printf '{"node_id":"test-node-001","reality_uuid":"00000000-0000-0000-0000-000000000001","real' > "$t3b/truncated_resp.json"
make_curl_stub "$t3b/stub/curl" "$t3b/truncated_resp.json" 0

set +e
out3b=$(run_refetch_and_render "$t3b/stub" "$t3b/etc" "$t3b/var")
exit3b=$?
set -e

# Assert: local node-config is byte-identical to before.
local_hash_after=$(sha256sum "$t3b/etc/node-config.json" | awk '{print $1}')
if [[ "$local_hash_before" == "$local_hash_after" ]]; then
    pass "test3b: local node-config untouched after truncated response (hash identical)"
else
    fail "test3b: local node-config was modified by truncated response (before=$local_hash_before after=$local_hash_after)"
fi

# Assert: no temp file left behind.
temp_count=$(find "$t3b/etc" -name '.node-config.json.*.tmp' 2>/dev/null | wc -l | tr -d ' ')
if [[ "$temp_count" -eq 0 ]]; then
    pass "test3b: no partial temp file left behind"
else
    fail "test3b: $temp_count temp file(s) left behind in $t3b/etc"
fi

# Assert: rejection was announced visibly.
if echo "$out3b" | grep -E 'WARN.*not valid JSON|WARN.*missing node_id|WARN.*using local' >/dev/null; then
    pass "test3b: rejection announced visibly (WARN)"
else
    fail "test3b: no visible rejection warning; output: $out3b"
fi

trap - EXIT
rm -rf "$t3b"

# ---------------------------------------------------------------------------
# Test 4: update.sh behaviour unchanged — assert it, do not assume it
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 4: update.sh behaviour unchanged ==="

# 4a: update.sh sources channel-render-lib.sh and calls refetch_node_config
if grep -E 'refetch_node_config' "$UPDATE_SH" >/dev/null; then
    pass "test4a: update.sh calls refetch_node_config"
else
    fail "test4a: update.sh does not call refetch_node_config"
fi

# 4b: update.sh no longer has inline curl node-config fetch (the old Step-1).
if grep -E 'Authorization: Bearer.*node-config' "$UPDATE_SH" >/dev/null; then
    fail "test4b: update.sh still has inline Bearer curl to node-config (extraction incomplete)"
else
    pass "test4b: update.sh inline node-config curl removed (extracted to lib)"
fi

# 4c: update.sh still has the pre-condition die (no token + no local → die).
if grep -E 'no token at.*and no local node-config' "$UPDATE_SH" >/dev/null; then
    pass "test4c: update.sh pre-condition die preserved"
else
    fail "test4c: update.sh pre-condition die was removed"
fi

# 4d: update.sh still has the post-flight hash compare (render freshness gate).
if grep -E '"\$_pre_hash"[[:space:]]*=[[:space:]]*"\$_post_hash"' "$UPDATE_SH" >/dev/null; then
    pass "test4d: update.sh post-flight hash compare preserved"
else
    fail "test4d: update.sh post-flight hash compare was removed"
fi

# 4e: behavioural — API down → fallback to local, exit 0 (mirrors test_update_sh.sh test 3).
t4=$(mktemp -d)
trap 'rm -rf "$t4"' EXIT

setup_env "$t4/stub" "$t4/etc"
mkdir -p "$t4/var"

# curl stub: node-config fetch fails (API down), template fetch succeeds.
: > "$t4/empty_resp.json"
make_curl_stub "$t4/stub/curl" "$t4/empty_resp.json" 7

# ss stub: port 3080 open (smoke passes).
write_stub "$t4/stub/ss" 'echo "LISTEN 0 128 0.0.0.0:3080 0.0.0.0:*"'

# docker stub: logs = no real cert (smoke passes).
write_stub "$t4/stub/docker" '
if [[ "$1" == "logs" ]]; then
    echo "VLESS: tunnel established"
    exit 0
fi
exit 0'

set +e
out4=$(PATH="$t4/stub:$(dirname "$(command -v python3)"):/usr/bin:/bin" \
    PARTNER_EDGE_PREFIX_ETC="$t4/etc" \
    PARTNER_EDGE_PREFIX_LIB="$t4/var" \
    OXPULSE_BACKEND_URL="http://broken.invalid" \
    XRAY_CFG="$t4/etc/xray-client.json" \
    OXPULSE_SMOKE_WAIT="0" \
    LOG_FILE="$t4/var/update.log" \
    bash "$UPDATE_SH" 2>&1)
exit4=$?
set -e

if [[ $exit4 -eq 0 ]]; then
    pass "test4e: update.sh exits 0 on API-down + healthy local (behaviour unchanged)"
else
    fail "test4e: update.sh exited $exit4 on API-down (expected 0); output: $out4"
fi

trap - EXIT
rm -rf "$t4"

# ---------------------------------------------------------------------------
# Test 5: upgrade.sh calls refetch_node_config before every re_render_xray
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 5: upgrade.sh wiring — refetch before every re_render_xray ==="

# 5a: upgrade.sh calls refetch_node_config.
refetch_count=$(grep -c 'refetch_node_config' "$UPGRADE_SH" || true)
if [[ "$refetch_count" -ge 3 ]]; then
    pass "test5a: upgrade.sh calls refetch_node_config ($refetch_count sites)"
else
    fail "test5a: upgrade.sh has $refetch_count refetch_node_config calls (expected >= 3)"
fi

# 5b: every re_render_xray call is preceded by a refetch_node_config call.
# Check each of the 3 call sites by looking for the pattern
# "refetch_node_config" immediately before "re_render_xray" in the script.
mismatch=0
while IFS= read -r line_num; do
    # Look backwards from the re_render_xray line for refetch_node_config
    # within 5 lines (allowing for blank lines / comments).
    ctx=$(sed -n "$((line_num > 5 ? line_num - 5 : 1)),${line_num}p" "$UPGRADE_SH")
    if ! echo "$ctx" | grep -E 'refetch_node_config' >/dev/null; then
        mismatch=$((mismatch + 1))
        echo "  re_render_xray at line $line_num has no preceding refetch_node_config" >&2
    fi
done < <(grep -n 're_render_xray' "$UPGRADE_SH" | grep -v '^[0-9]*:#' | awk -F: '{print $1}')

if [[ "$mismatch" -eq 0 ]]; then
    pass "test5b: every re_render_xray call site is preceded by refetch_node_config"
else
    fail "test5b: $mismatch re_render_xray call site(s) missing preceding refetch_node_config"
fi

# ---------------------------------------------------------------------------
# Test 6: first-upgrade re-source — stale in-memory lib, fresh installed lib
#
# Reproduces the re-exec'd child on the first upgrade: the old
# channel-render-lib.sh (no refetch_node_config) is already loaded in this
# shell, but sync_host_scripts has since installed the new one under
# PREFIX_SBIN.  _ensure_channel_render_lib must re-source from the installed
# copy before the call, otherwise the upgrade dies with
# "refetch_node_config: command not found" (exit 127).
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 6: first upgrade re-sources channel-render-lib from installed path ==="
t6=$(mktemp -d)
trap 'rm -rf "$t6"' EXIT

setup_env "$t6/stub" "$t6/etc"
mkdir -p "$t6/var" "$t6/sbin"

# New lib installed by sync_host_scripts (repo copy).
install -m 0644 "$LIB" "$t6/sbin/channel-render-lib.sh"

# Stale in-memory lib: the same file with refetch_node_config removed,
# simulating a pre-PR installed copy.
OLD_LIB="$t6/channel-render-lib.sh.old"
sed '/^refetch_node_config() {/,/^}/d' "$LIB" > "$OLD_LIB"

# curl stub: fresh node-config response.
write_fresh_node_config_json > "$t6/fresh_resp.json"
make_curl_stub "$t6/stub/curl" "$t6/fresh_resp.json" 0

# Extract _ensure_channel_render_lib from upgrade.sh (uses _source_lib in
# fallback; stub it so a missed re-source fails the test rather than
# accidentally fetching from the network).
HELPER_FN="$t6/ensure_fn.sh"
awk '/^_ensure_channel_render_lib\(\)/{f=1} f{print} /^}$/ && f{exit}' "$UPGRADE_SH" > "$HELPER_FN"

set +e
out6=$(
    PATH="$t6/stub:$(dirname "$(command -v python3)"):/usr/bin:/bin" \
    PREFIX_ETC="$t6/etc" \
    PREFIX_LIB="$t6/var" \
    PREFIX_SBIN="$t6/sbin" \
    NODE_CFG="$t6/etc/node-config.json" \
    XRAY_CFG="$t6/etc/xray-client.json" \
    TOKEN_FILE="$t6/etc/token" \
    OXPULSE_BACKEND_URL="http://test-control-plane.invalid" \
    REPO_RAW="file://$REPO_ROOT" \
    LOG_FILE="$t6/var/render.log" \
    bash -c '
        set -euo pipefail
        log()  { printf "%s\n" "$*" >&2; }
        warn() { log "WARN $*"; }
        die()  { log "ERR $*"; exit 1; }
        _source_lib() { return 1; }
        source "'"$OLD_LIB"'"
        source "'"$HELPER_FN"'"
        _ensure_channel_render_lib
        refetch_node_config
        re_render_xray
    ' 2>&1
)
exit6=$?
set -e

if [[ $exit6 -ne 0 ]]; then
    fail "test6: first-upgrade refetch exited $exit6; output: $out6"
else
    rendered_sid6=$(extract_short_id "$t6/etc/xray-client.json")
    if [[ "$rendered_sid6" == "FRESH_NEW" ]]; then
        pass "test6: stale in-memory lib re-sourced from installed path; xray rendered with FRESH_NEW short_id"
    else
        fail "test6: rendered short_id is '$rendered_sid6', expected 'FRESH_NEW'; output: $out6"
    fi
fi

trap - EXIT
rm -rf "$t6"

# ---------------------------------------------------------------------------
# Syntax check
# ---------------------------------------------------------------------------
echo ""
echo "=== Syntax check ==="
bash -n "$LIB" && pass "channel-render-lib.sh syntax clean" || fail "channel-render-lib.sh has syntax errors"
bash -n "$UPDATE_SH" && pass "update.sh syntax clean" || fail "update.sh has syntax errors"
bash -n "$UPGRADE_SH" && pass "upgrade.sh syntax clean" || fail "upgrade.sh has syntax errors"

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
