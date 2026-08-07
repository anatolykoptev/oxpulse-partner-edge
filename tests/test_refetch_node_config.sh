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

# 5a: upgrade.sh calls refetch_node_config.  Count CALL LINES only — lines that
# END with `refetch_node_config` (a bare call or a guarded `... && refetch_node_
# config`), excluding comment lines and the function definition `refetch_node_
# config() {` (which ends with `{`, not the function name).  Counting every
# textual occurrence would include ~11 comment-block mentions in
# _ensure_channel_render_lib alone and pass with all real call sites deleted
# (a vacuous oracle).
#
# The count dropped from three to TWO in #547 (#514): the with-templates and
# apply paths previously each called refetch + re_render inline, and now share
# the single pair inside _render_gate, which brackets them with a health gate
# and a render-scoped rollback. The remaining two call sites are _render_gate
# and the --templates-only path (still ungated — tracked in #548).
#
# This is a non-vacuity floor only. The invariant this test actually protects is
# the PAIRING, asserted by 5b below, and that is unchanged: refetch_node_config
# still immediately precedes every re_render_xray.
refetch_count=$(grep -nE 'refetch_node_config$' "$UPGRADE_SH" | grep -vE '^[0-9]+:[[:space:]]*#' | wc -l)
if [[ "$refetch_count" -ge 2 ]]; then
    pass "test5a: upgrade.sh calls refetch_node_config ($refetch_count call sites)"
else
    fail "test5a: upgrade.sh has $refetch_count refetch_node_config call lines (expected >= 2)"
fi

# 5b: every re_render_xray call is preceded by a refetch_node_config call.
# Check each call site by looking for the pattern "refetch_node_config"
# immediately before "re_render_xray" in the script.  Filter ALL comment lines
# (column-0 AND indented) so an indented comment mentioning the name does not
# score as a call site — the previous `grep -v '^[0-9]*:#'` only dropped
# column-0 comments.
mismatch=0
while IFS= read -r line_num; do
    # Look backwards from the re_render_xray line for refetch_node_config
    # within 5 lines (allowing for blank lines / comments).
    ctx=$(sed -n "$((line_num > 5 ? line_num - 5 : 1)),${line_num}p" "$UPGRADE_SH")
    if ! echo "$ctx" | grep -E 'refetch_node_config' >/dev/null; then
        mismatch=$((mismatch + 1))
        echo "  re_render_xray at line $line_num has no preceding refetch_node_config" >&2
    fi
done < <(grep -nE '^[[:space:]]*re_render_xray$' "$UPGRADE_SH" | awk -F: '{print $1}')

if [[ "$mismatch" -eq 0 ]]; then
    pass "test5b: every re_render_xray call site is preceded by refetch_node_config"
else
    fail "test5b: $mismatch re_render_xray call site(s) missing preceding refetch_node_config"
fi

# 5c: the --templates-only block guards refetch_node_config with command -v.
# In the degrade path (stale local lib + unreachable REPO_RAW) the function is
# undefined; an unguarded call would exit 127 under set -e.  A static source
# check: the templates block (between 'if [[ "$MODE" == templates ]]' and its
# closing 'fi') must contain 'command -v refetch_node_config' before the
# refetch_node_config call.  Uses bash-native patterns (no piped grep/head —
# the pipefail early-exit guard scans test files for those).
templates_start=""
while IFS=: read -r ln rest; do
    templates_start="$ln"; break
done < <(grep -n 'if \[\[ "$MODE" == templates \]\]' "$UPGRADE_SH")
if [[ -n "$templates_start" ]]; then
    # Read forward from templates_start until the closing fi (max 30 lines).
    templates_block=""
    _idx=0
    while IFS= read -r bline; do
        templates_block+="$bline"$'\n'
        _idx=$((_idx + 1))
        [[ "$bline" == "fi" || "$_idx" -ge 30 ]] && break
    done < <(sed -n "${templates_start},\$p" "$UPGRADE_SH")
    if [[ "$templates_block" == *"command -v refetch_node_config"* ]]; then
        pass "test5c: --templates-only block guards refetch_node_config with command -v"
    else
        fail "test5c: --templates-only block does NOT guard refetch_node_config — degrade path would exit 127"
    fi
else
    fail "test5c: could not locate --templates-only block in upgrade.sh"
fi

# Extract _lookup_expected_hash + _source_lib + _ensure_channel_render_lib from
# upgrade.sh (the real functions, NOT stubbed — the point of these tests is to
# exercise the real resolution + the real tier-3 sha256 verify).  Sourced as one
# file so BASH_SOURCE[0] inside each function resolves to that file's directory
# (the tier-1 adjacent path and the ${_sd}/SHA256SUMS manifest lookup both key
# off dirname(BASH_SOURCE[0])).
extract_lib_funcs() {
    local out="$1"
    {
        awk '/^_lookup_expected_hash\(\)/{f=1} f{print} /^}$/ && f{exit}' "$UPGRADE_SH"
        echo
        awk '/^_source_lib\(\)/{f=1} f{print} /^}$/ && f{exit}' "$UPGRADE_SH"
        echo
        awk '/^_ensure_channel_render_lib\(\)/{f=1} f{print} /^}$/ && f{exit}' "$UPGRADE_SH"
    } > "$out"
}

# write_sha256sums FILE ENTRIES... — write a SHA256SUMS manifest.  Each ENTRIES
# arg is "name=hash"; a literal "name=REAL:<path>" resolves the hash from the
# file at <path> (so the entry matches that file's actual bytes).
write_sha256sums() {
    local out="$1"; shift
    : > "$out"
    local entry name val
    for entry in "$@"; do
        name="${entry%%=*}"
        val="${entry#*=}"
        if [[ "$val" == REAL:* ]]; then
            val=$(sha256sum "${val#REAL:}" | awk '{print $1}')
        fi
        printf '%s  %s\n' "$val" "$name" >> "$out"
    done
}

# ---------------------------------------------------------------------------
# Test 6: first-upgrade re-source — stale in-memory lib, fresh installed lib
#
# Reproduces the re-exec'd child on the first upgrade: the old
# channel-render-lib.sh (no refetch_node_config) is already loaded in this
# shell, but sync_host_scripts has since installed the new one under
# PREFIX_SBIN.  _ensure_channel_render_lib (now via _source_lib with
# refetch_node_config as the required symbol) must re-source from the installed
# copy before the call, otherwise the upgrade dies with
# "refetch_node_config: command not found" (exit 127).
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 6: first upgrade re-sources channel-render-lib from installed path ==="
t6=$(mktemp -d)
trap 'rm -rf "$t6"' EXIT

setup_env "$t6/stub" "$t6/etc"
mkdir -p "$t6/var" "$t6/sbin"

# New lib installed by sync_host_scripts (repo copy) at PREFIX_SBIN.
install -m 0644 "$LIB" "$t6/sbin/channel-render-lib.sh"

# Stale in-memory lib: the same file with refetch_node_config removed,
# simulating a pre-PR installed copy.
OLD_LIB="$t6/channel-render-lib.sh.old"
sed '/^refetch_node_config() {/,/^}/d' "$LIB" > "$OLD_LIB"

# curl stub: fresh node-config response.
write_fresh_node_config_json > "$t6/fresh_resp.json"
make_curl_stub "$t6/stub/curl" "$t6/fresh_resp.json" 0

# Extract the real _lookup_expected_hash + _source_lib + _ensure_channel_render_lib
# into PREFIX_SBIN so dirname(BASH_SOURCE[0]) == PREFIX_SBIN (the production
# collapse where adjacent == installed).  The fresh lib is the adjacent/installed
# candidate; _source_lib's content-aware tier-1 sources it and finds
# refetch_node_config → returns 0 without any network fetch.
extract_lib_funcs "$t6/sbin/funcs.sh"

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
    RELEASES_BASE="file://$t6/releases" \
    OXPULSE_UPGRADE_TAG="@RELEASE_TAG@" \
    RETRY_OPTS=() \
    OXPULSE_UPGRADE_NO_INTEGRITY=0 \
    LOG_FILE="$t6/var/render.log" \
    bash -c '
        set -euo pipefail
        log()  { printf "%s\n" "$*" >&2; }
        warn() { log "WARN $*"; }
        die()  { log "ERR $*"; exit 1; }
        _CLEANUP_PATHS=()
        source "'"$OLD_LIB"'"
        source "'"$t6"'/sbin/funcs.sh"
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
# make_curl_stub_lib: curl stub for the content-aware resolution tests below.
#   $1 = stub path
#   $2 = fresh lib path   (served when URL contains channel-render-lib.sh)
#   $3 = node-config resp (served when URL contains node-config)
#   $4 = lib-fetch exit   (0 reachable, 7 unreachable)
#   $5 = invocation log   (every http/file URL appended)
# Handles three fetch types: channel-render-lib.sh, node-config, xray-client
# template.  Ignores --proto/--tlsv1.2/--retry flags (it is a bash stub).
# ---------------------------------------------------------------------------
make_curl_stub_lib() {
    local stub="$1" lib="$2" resp="$3" lib_exit="${4:-0}" log="$5"
    write_stub "$stub" '
_out_file=""; _prev=""
for arg in "$@"; do
    if [[ "$_prev" == "-o" ]]; then _out_file="$arg"; fi
    _prev="$arg"
done
_is_lib=0; _is_tpl=0; _is_nodecfg=0
for arg in "$@"; do
    case "$arg" in
        *channel-render-lib.sh*) _is_lib=1 ;;
        *xray-client.json.tpl*)  _is_tpl=1 ;;
        *node-config*)           _is_nodecfg=1 ;;
    esac
done
for arg in "$@"; do
    case "$arg" in http://*|https://*|file://*) echo "$arg" >> "'"$log"'"; break;; esac
done
if [[ "$_is_tpl" -eq 1 ]]; then
    if [[ -n "$_out_file" ]]; then cat "'"$TPL"'" > "$_out_file"; else cat "'"$TPL"'"; fi
    exit 0
fi
if [[ "$_is_lib" -eq 1 ]]; then
    if [[ '"$lib_exit"' -ne 0 ]]; then echo "curl: ('"$lib_exit"') Failed to connect" >&2; exit '"$lib_exit"'; fi
    if [[ -n "$_out_file" ]]; then cp "'"$lib"'" "$_out_file"; else cat "'"$lib"'"; fi
    exit 0
fi
if [[ -n "$_out_file" ]]; then cp "'"$resp"'" "$_out_file"; else cat "'"$resp"'"; fi
exit 0
'
}

# ---------------------------------------------------------------------------
# Test 7 (F2): installed lib STALE, REPO_RAW reachable, manifest hash MATCHES
# → the verified tier-3 fetch is accepted, refetch_node_config resolves, and the
# render completes.  Reproduces the production tier-collapse (adjacent ==
# installed == same stale file) by placing the extracted funcs inside PREFIX_SBIN
# so dirname(BASH_SOURCE[0]) == PREFIX_SBIN.  The adjacent SHA256SUMS carries the
# REAL hash of the fresh lib the curl stub serves, so _source_lib's tier-3
# sha256 verify PASSES and sources the fetched lib.
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 7 (F2): stale installed lib, REPO_RAW reachable, hash matches → refetch completes ==="
t7=$(mktemp -d)
trap 'rm -rf "$t7"' EXIT
setup_env "$t7/stub" "$t7/etc"
mkdir -p "$t7/var" "$t7/sbin"

# Stale lib: repo copy with refetch_node_config removed (pre-PR shape).
OLD_LIB7="$t7/old_lib.sh"
sed '/^refetch_node_config() {/,/^}/d' "$LIB" > "$OLD_LIB7"

# Install the STALE lib at PREFIX_SBIN (the only on-disk copy).
install -m 0644 "$OLD_LIB7" "$t7/sbin/channel-render-lib.sh"

# Funcs extracted INTO sbin so BASH_SOURCE[0] dirname == PREFIX_SBIN (collapse).
extract_lib_funcs "$t7/sbin/funcs.sh"

# Adjacent SHA256SUMS with the REAL hash of the fresh lib the stub serves.
write_sha256sums "$t7/sbin/SHA256SUMS" "channel-render-lib.sh=REAL:$LIB"

write_fresh_node_config_json > "$t7/fresh_resp.json"
curl_log7="$t7/curl.log"
make_curl_stub_lib "$t7/stub/curl" "$LIB" "$t7/fresh_resp.json" 0 "$curl_log7"

set +e
out7=$(
    PATH="$t7/stub:$(dirname "$(command -v python3)"):/usr/bin:/bin" \
    PREFIX_ETC="$t7/etc" \
    PREFIX_LIB="$t7/var" \
    PREFIX_SBIN="$t7/sbin" \
    NODE_CFG="$t7/etc/node-config.json" \
    XRAY_CFG="$t7/etc/xray-client.json" \
    TOKEN_FILE="$t7/etc/token" \
    OXPULSE_BACKEND_URL="http://test-control-plane.invalid" \
    REPO_RAW="file://$REPO_ROOT" \
    RELEASES_BASE="file://$t7/releases" \
    OXPULSE_UPGRADE_TAG="@RELEASE_TAG@" \
    RETRY_OPTS=() \
    OXPULSE_UPGRADE_NO_INTEGRITY=0 \
    LOG_FILE="$t7/var/render.log" \
    bash -c '
        set -euo pipefail
        log()  { printf "%s\n" "$*" >&2; }
        warn() { log "WARN $*"; }
        die()  { log "ERR $*"; exit 1; }
        _CLEANUP_PATHS=()
        source "'"$OLD_LIB7"'"
        source "'"$t7"'/sbin/funcs.sh"
        _ensure_channel_render_lib
        refetch_node_config
        re_render_xray
    ' 2>&1
)
exit7=$?
set -e

if [[ $exit7 -ne 0 ]]; then
    fail "test7/F2: stale-lib refetch exited $exit7; output: $out7"
else
    rendered_sid7=$(extract_short_id "$t7/etc/xray-client.json")
    if [[ "$rendered_sid7" == "FRESH_NEW" ]]; then
        pass "test7/F2: stale installed lib fell through to verified REPO_RAW fetch; xray rendered with FRESH_NEW"
    else
        fail "test7/F2: rendered short_id '$rendered_sid7', expected FRESH_NEW; output: $out7"
    fi
fi
trap - EXIT
rm -rf "$t7"

# ---------------------------------------------------------------------------
# Test 8: installed lib STALE, REPO_RAW UNREACHABLE → die with a named reason;
# NOT exit 127, NOT a silent success.  The tier-3 fetch fails inside _source_lib
# (strict mode — MODE defaults to apply), which dies before any manifest check.
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 8: stale installed lib, REPO_RAW unreachable → die loudly ==="
t8=$(mktemp -d)
trap 'rm -rf "$t8"' EXIT
setup_env "$t8/stub" "$t8/etc"
mkdir -p "$t8/var" "$t8/sbin"

OLD_LIB8="$t8/old_lib.sh"
sed '/^refetch_node_config() {/,/^}/d' "$LIB" > "$OLD_LIB8"
install -m 0644 "$OLD_LIB8" "$t8/sbin/channel-render-lib.sh"
extract_lib_funcs "$t8/sbin/funcs.sh"

write_fresh_node_config_json > "$t8/fresh_resp.json"
curl_log8="$t8/curl.log"
# lib-fetch exit 7 (unreachable)
make_curl_stub_lib "$t8/stub/curl" "$LIB" "$t8/fresh_resp.json" 7 "$curl_log8"

set +e
out8=$(
    PATH="$t8/stub:$(dirname "$(command -v python3)"):/usr/bin:/bin" \
    PREFIX_ETC="$t8/etc" \
    PREFIX_LIB="$t8/var" \
    PREFIX_SBIN="$t8/sbin" \
    NODE_CFG="$t8/etc/node-config.json" \
    XRAY_CFG="$t8/etc/xray-client.json" \
    TOKEN_FILE="$t8/etc/token" \
    OXPULSE_BACKEND_URL="http://test-control-plane.invalid" \
    REPO_RAW="file://$REPO_ROOT" \
    RELEASES_BASE="file://$t8/releases" \
    OXPULSE_UPGRADE_TAG="@RELEASE_TAG@" \
    RETRY_OPTS=() \
    OXPULSE_UPGRADE_NO_INTEGRITY=0 \
    LOG_FILE="$t8/var/render.log" \
    bash -c '
        set -euo pipefail
        log()  { printf "%s\n" "$*" >&2; }
        warn() { log "WARN $*"; }
        die()  { log "ERR $*"; exit 1; }
        _CLEANUP_PATHS=()
        source "'"$OLD_LIB8"'"
        source "'"$t8"'/sbin/funcs.sh"
        _ensure_channel_render_lib
        refetch_node_config
        re_render_xray
    ' 2>&1
)
exit8=$?
set -e

# Must NOT be 127 (command-not-found) and must NOT be 0 (silent success).
if [[ $exit8 -eq 127 ]]; then
    fail "test8: exited 127 (command not found) — the blocker; output: $out8"
elif [[ $exit8 -eq 0 ]]; then
    fail "test8: exited 0 (silent success with stale lib) — worse than 127; output: $out8"
elif [[ "$out8" == *"command not found"* ]]; then
    fail "test8: output contains 'command not found' (exit $exit8); output: $out8"
else
    pass "test8: stale lib + unreachable REPO_RAW died loudly (exit $exit8) with a named reason"
fi
trap - EXIT
rm -rf "$t8"

# ---------------------------------------------------------------------------
# Test 9: installed lib FRESH → resolves locally, NO lib fetch.
# Asserts the curl log does NOT contain channel-render-lib.sh.
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 9: fresh installed lib → no REPO_RAW lib fetch ==="
t9=$(mktemp -d)
trap 'rm -rf "$t9"' EXIT
setup_env "$t9/stub" "$t9/etc"
mkdir -p "$t9/var" "$t9/sbin"

# FRESH lib at PREFIX_SBIN (the post-sync shape).
install -m 0644 "$LIB" "$t9/sbin/channel-render-lib.sh"
extract_lib_funcs "$t9/sbin/funcs.sh"

write_fresh_node_config_json > "$t9/fresh_resp.json"
curl_log9="$t9/curl.log"
make_curl_stub_lib "$t9/stub/curl" "$LIB" "$t9/fresh_resp.json" 0 "$curl_log9"

set +e
out9=$(
    PATH="$t9/stub:$(dirname "$(command -v python3)"):/usr/bin:/bin" \
    PREFIX_ETC="$t9/etc" \
    PREFIX_LIB="$t9/var" \
    PREFIX_SBIN="$t9/sbin" \
    NODE_CFG="$t9/etc/node-config.json" \
    XRAY_CFG="$t9/etc/xray-client.json" \
    TOKEN_FILE="$t9/etc/token" \
    OXPULSE_BACKEND_URL="http://test-control-plane.invalid" \
    REPO_RAW="file://$REPO_ROOT" \
    RELEASES_BASE="file://$t9/releases" \
    OXPULSE_UPGRADE_TAG="@RELEASE_TAG@" \
    RETRY_OPTS=() \
    OXPULSE_UPGRADE_NO_INTEGRITY=0 \
    LOG_FILE="$t9/var/render.log" \
    bash -c '
        set -euo pipefail
        log()  { printf "%s\n" "$*" >&2; }
        warn() { log "WARN $*"; }
        die()  { log "ERR $*"; exit 1; }
        _CLEANUP_PATHS=()
        source "'"$t9"'/sbin/channel-render-lib.sh"
        source "'"$t9"'/sbin/funcs.sh"
        _ensure_channel_render_lib
        refetch_node_config
        re_render_xray
    ' 2>&1
)
exit9=$?
set -e

if [[ $exit9 -ne 0 ]]; then
    fail "test9: fresh-lib run exited $exit9; output: $out9"
elif grep -q "channel-render-lib.sh" "$curl_log9" 2>/dev/null; then
    fail "test9: REPO_RAW lib fetch happened with a fresh local lib (curl log: $(cat "$curl_log9"))"
else
    rendered_sid9=$(extract_short_id "$t9/etc/xray-client.json")
    if [[ "$rendered_sid9" == "FRESH_NEW" ]]; then
        pass "test9: fresh lib resolved locally (no lib fetch); xray rendered with FRESH_NEW"
    else
        fail "test9: rendered short_id '$rendered_sid9', expected FRESH_NEW; output: $out9"
    fi
fi
trap - EXIT
rm -rf "$t9"

# ---------------------------------------------------------------------------
# Test 10: lib adjacent to upgrade.sh in a tmpdir, NO installed copy
# (dev/CI shape).  Resolves via the adjacent tier with no network call.
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 10: adjacent lib, no installed copy → no network ==="
t10=$(mktemp -d)
trap 'rm -rf "$t10"' EXIT
setup_env "$t10/stub" "$t10/etc"
mkdir -p "$t10/var" "$t10/sbin"

# FRESH lib adjacent to the extracted funcs (NOT in sbin).
install -m 0644 "$LIB" "$t10/channel-render-lib.sh"
extract_lib_funcs "$t10/funcs.sh"

write_fresh_node_config_json > "$t10/fresh_resp.json"
curl_log10="$t10/curl.log"
make_curl_stub_lib "$t10/stub/curl" "$LIB" "$t10/fresh_resp.json" 0 "$curl_log10"

set +e
out10=$(
    PATH="$t10/stub:$(dirname "$(command -v python3)"):/usr/bin:/bin" \
    PREFIX_ETC="$t10/etc" \
    PREFIX_LIB="$t10/var" \
    PREFIX_SBIN="$t10/sbin" \
    NODE_CFG="$t10/etc/node-config.json" \
    XRAY_CFG="$t10/etc/xray-client.json" \
    TOKEN_FILE="$t10/etc/token" \
    OXPULSE_BACKEND_URL="http://test-control-plane.invalid" \
    REPO_RAW="file://$REPO_ROOT" \
    RELEASES_BASE="file://$t10/releases" \
    OXPULSE_UPGRADE_TAG="@RELEASE_TAG@" \
    RETRY_OPTS=() \
    OXPULSE_UPGRADE_NO_INTEGRITY=0 \
    LOG_FILE="$t10/var/render.log" \
    bash -c '
        set -euo pipefail
        log()  { printf "%s\n" "$*" >&2; }
        warn() { log "WARN $*"; }
        die()  { log "ERR $*"; exit 1; }
        _CLEANUP_PATHS=()
        source "'"$t10"'/funcs.sh"
        _ensure_channel_render_lib
        refetch_node_config
        re_render_xray
    ' 2>&1
)
exit10=$?
set -e

if [[ $exit10 -ne 0 ]]; then
    fail "test10: adjacent-lib run exited $exit10; output: $out10"
elif grep -q "channel-render-lib.sh" "$curl_log10" 2>/dev/null; then
    fail "test10: REPO_RAW lib fetch happened with an adjacent fresh lib (curl log: $(cat "$curl_log10"))"
else
    rendered_sid10=$(extract_short_id "$t10/etc/xray-client.json")
    if [[ "$rendered_sid10" == "FRESH_NEW" ]]; then
        pass "test10: adjacent lib resolved locally (no lib fetch); xray rendered with FRESH_NEW"
    else
        fail "test10: rendered short_id '$rendered_sid10', expected FRESH_NEW; output: $out10"
    fi
fi
trap - EXIT
rm -rf "$t10"

# ---------------------------------------------------------------------------
# Test 11 (F1): tier-3 fetch whose bytes do NOT match the manifest entry is
# REFUSED — the run dies with "checksum mismatch", the fetched lib is NOT
# sourced (refetch_node_config stays undefined, REFETCH_RAN marker absent).
# Falsification: disable the mismatch die (`false && die`) → the mismatched lib
# is sourced → exit 0 + REFETCH_RAN → this test goes RED.
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 11 (F1): tier-3 hash MISMATCH → refused, dies, lib not sourced ==="
t11=$(mktemp -d)
trap 'rm -rf "$t11"' EXIT
setup_env "$t11/stub" "$t11/etc"
mkdir -p "$t11/var" "$t11/sbin"

OLD_LIB11="$t11/old_lib.sh"
sed '/^refetch_node_config() {/,/^}/d' "$LIB" > "$OLD_LIB11"
install -m 0644 "$OLD_LIB11" "$t11/sbin/channel-render-lib.sh"
extract_lib_funcs "$t11/sbin/funcs.sh"

# SHA256SUMS with a WRONG hash (all zeros) — the stub serves the real fresh lib,
# so the sha256 of the fetched bytes will NOT match this entry.
write_sha256sums "$t11/sbin/SHA256SUMS" "channel-render-lib.sh=0000000000000000000000000000000000000000000000000000000000000000"

write_fresh_node_config_json > "$t11/fresh_resp.json"
curl_log11="$t11/curl.log"
make_curl_stub_lib "$t11/stub/curl" "$LIB" "$t11/fresh_resp.json" 0 "$curl_log11"

set +e
out11=$(
    PATH="$t11/stub:$(dirname "$(command -v python3)"):/usr/bin:/bin" \
    PREFIX_ETC="$t11/etc" \
    PREFIX_LIB="$t11/var" \
    PREFIX_SBIN="$t11/sbin" \
    NODE_CFG="$t11/etc/node-config.json" \
    XRAY_CFG="$t11/etc/xray-client.json" \
    TOKEN_FILE="$t11/etc/token" \
    OXPULSE_BACKEND_URL="http://test-control-plane.invalid" \
    REPO_RAW="file://$REPO_ROOT" \
    RELEASES_BASE="file://$t11/releases" \
    OXPULSE_UPGRADE_TAG="@RELEASE_TAG@" \
    RETRY_OPTS=() \
    OXPULSE_UPGRADE_NO_INTEGRITY=0 \
    LOG_FILE="$t11/var/render.log" \
    bash -c '
        set -euo pipefail
        log()  { printf "%s\n" "$*" >&2; }
        warn() { log "WARN $*"; }
        die()  { log "ERR $*"; exit 1; }
        _CLEANUP_PATHS=()
        source "'"$OLD_LIB11"'"
        source "'"$t11"'/sbin/funcs.sh"
        _ensure_channel_render_lib
        refetch_node_config
        echo "REFETCH_RAN"
    ' 2>&1
)
exit11=$?
set -e

if [[ $exit11 -eq 0 ]]; then
    fail "test11/F1: mismatched lib was accepted (exit 0) — checksum verify bypassed; output: $out11"
elif [[ "$out11" == *"REFETCH_RAN"* ]]; then
    fail "test11/F1: mismatched lib was sourced (REFETCH_RAN present, exit $exit11); output: $out11"
elif [[ "$out11" == *"checksum mismatch"* ]]; then
    pass "test11/F1: tier-3 hash mismatch refused (exit $exit11), lib not sourced"
else
    fail "test11/F1: died (exit $exit11) but not with 'checksum mismatch'; output: $out11"
fi
trap - EXIT
rm -rf "$t11"

# ---------------------------------------------------------------------------
# Test 11b (F1b): SOFT mode does not weaken the integrity gate, and the tamper
# message REACHES THE OPERATOR.  Same tampered-manifest setup as test 11, but
# with MODE=templates so _ensure_channel_render_lib takes the SOFT_FETCH_FAIL
# branch.  A sha256 mismatch must still die, the mismatched lib must not be
# sourced, and "checksum mismatch" must appear in the output.
#
# Falsification, both measured:
#   • hoist the soft-fail branch above the mismatch die in _source_lib (soft
#     bypasses integrity) → the lib is sourced → REFETCH_RAN → RED.  That mutant
#     previously SURVIVED the whole suite 31/0.
#   • restore `2>/dev/null` on the templates-mode _source_lib call → output is
#     empty → RED.  log/warn/die all write to stderr, so redirecting the call
#     discards the tamper alert and leaves the operator a bare exit 1.
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 11b (F1b): SOFT mode still refuses a hash mismatch, and says so ==="
t11b=$(mktemp -d)
trap 'rm -rf "$t11b"' EXIT
setup_env "$t11b/stub" "$t11b/etc"
mkdir -p "$t11b/var" "$t11b/sbin"

OLD_LIB11B="$t11b/old_lib.sh"
sed '/^refetch_node_config() {/,/^}/d' "$LIB" > "$OLD_LIB11B"
install -m 0644 "$OLD_LIB11B" "$t11b/sbin/channel-render-lib.sh"
extract_lib_funcs "$t11b/sbin/funcs.sh"

write_sha256sums "$t11b/sbin/SHA256SUMS" "channel-render-lib.sh=0000000000000000000000000000000000000000000000000000000000000000"

write_fresh_node_config_json > "$t11b/fresh_resp.json"
curl_log11b="$t11b/curl.log"
make_curl_stub_lib "$t11b/stub/curl" "$LIB" "$t11b/fresh_resp.json" 0 "$curl_log11b"

set +e
out11b=$(
    PATH="$t11b/stub:$(dirname "$(command -v python3)"):/usr/bin:/bin" \
    PREFIX_ETC="$t11b/etc" \
    PREFIX_LIB="$t11b/var" \
    PREFIX_SBIN="$t11b/sbin" \
    NODE_CFG="$t11b/etc/node-config.json" \
    XRAY_CFG="$t11b/etc/xray-client.json" \
    TOKEN_FILE="$t11b/etc/token" \
    OXPULSE_BACKEND_URL="http://test-control-plane.invalid" \
    REPO_RAW="file://$REPO_ROOT" \
    RELEASES_BASE="file://$t11b/releases" \
    OXPULSE_UPGRADE_TAG="@RELEASE_TAG@" \
    RETRY_OPTS=() \
    OXPULSE_UPGRADE_NO_INTEGRITY=0 \
    MODE=templates \
    LOG_FILE="$t11b/var/render.log" \
    bash -c '
        set -euo pipefail
        log()  { printf "%s\n" "$*" >&2; }
        warn() { log "WARN $*"; }
        die()  { log "ERR $*"; exit 1; }
        _CLEANUP_PATHS=()
        source "'"$OLD_LIB11B"'"
        source "'"$t11b"'/sbin/funcs.sh"
        _ensure_channel_render_lib
        refetch_node_config
        echo "REFETCH_RAN"
    ' 2>&1
)
exit11b=$?
set -e

if [[ $exit11b -eq 0 ]]; then
    fail "test11b/F1b: SOFT mode accepted a mismatched lib (exit 0) — the integrity gate is bypassable via --templates-only; output: $out11b"
elif [[ "$out11b" == *"REFETCH_RAN"* ]]; then
    fail "test11b/F1b: SOFT mode sourced the mismatched lib (REFETCH_RAN present, exit $exit11b); output: $out11b"
elif [[ "$out11b" != *"checksum mismatch"* ]]; then
    fail "test11b/F1b: died (exit $exit11b) but the tamper message never reached the operator — a bare exit reads as a network problem; output: '$out11b'"
else
    pass "test11b/F1b: SOFT mode refused the mismatch (exit $exit11b), lib not sourced, operator told why"
fi
trap - EXIT
rm -rf "$t11b"

# ---------------------------------------------------------------------------
# Test 12 (F3): the file is ABSENT from the manifest → dies with "without a
# verified checksum", does NOT fall through to sourcing it.
# Falsification: treat a missing entry as a pass (source anyway) → exit 0 +
# REFETCH_RAN → RED.
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 12 (F3): file absent from manifest → dies, not sourced ==="
t12=$(mktemp -d)
trap 'rm -rf "$t12"' EXIT
setup_env "$t12/stub" "$t12/etc"
mkdir -p "$t12/var" "$t12/sbin"

OLD_LIB12="$t12/old_lib.sh"
sed '/^refetch_node_config() {/,/^}/d' "$LIB" > "$OLD_LIB12"
install -m 0644 "$OLD_LIB12" "$t12/sbin/channel-render-lib.sh"
extract_lib_funcs "$t12/sbin/funcs.sh"

# SHA256SUMS with an entry for a DIFFERENT file — channel-render-lib.sh is absent.
write_sha256sums "$t12/sbin/SHA256SUMS" "some-other-file.sh=0000000000000000000000000000000000000000000000000000000000000000"

write_fresh_node_config_json > "$t12/fresh_resp.json"
curl_log12="$t12/curl.log"
make_curl_stub_lib "$t12/stub/curl" "$LIB" "$t12/fresh_resp.json" 0 "$curl_log12"

set +e
out12=$(
    PATH="$t12/stub:$(dirname "$(command -v python3)"):/usr/bin:/bin" \
    PREFIX_ETC="$t12/etc" \
    PREFIX_LIB="$t12/var" \
    PREFIX_SBIN="$t12/sbin" \
    NODE_CFG="$t12/etc/node-config.json" \
    XRAY_CFG="$t12/etc/xray-client.json" \
    TOKEN_FILE="$t12/etc/token" \
    OXPULSE_BACKEND_URL="http://test-control-plane.invalid" \
    REPO_RAW="file://$REPO_ROOT" \
    RELEASES_BASE="file://$t12/releases" \
    OXPULSE_UPGRADE_TAG="@RELEASE_TAG@" \
    RETRY_OPTS=() \
    OXPULSE_UPGRADE_NO_INTEGRITY=0 \
    LOG_FILE="$t12/var/render.log" \
    bash -c '
        set -euo pipefail
        log()  { printf "%s\n" "$*" >&2; }
        warn() { log "WARN $*"; }
        die()  { log "ERR $*"; exit 1; }
        _CLEANUP_PATHS=()
        source "'"$OLD_LIB12"'"
        source "'"$t12"'/sbin/funcs.sh"
        _ensure_channel_render_lib
        refetch_node_config
        echo "REFETCH_RAN"
    ' 2>&1
)
exit12=$?
set -e

if [[ $exit12 -eq 0 ]]; then
    fail "test12/F3: unverified lib was accepted (exit 0) — missing-entry guard bypassed; output: $out12"
elif [[ "$out12" == *"REFETCH_RAN"* ]]; then
    fail "test12/F3: unverified lib was sourced (REFETCH_RAN, exit $exit12); output: $out12"
elif [[ "$out12" == *"without a verified checksum"* ]]; then
    pass "test12/F3: file absent from manifest → died (exit $exit12), lib not sourced"
else
    fail "test12/F3: died (exit $exit12) but not with 'without a verified checksum'; output: $out12"
fi
trap - EXIT
rm -rf "$t12"

# ---------------------------------------------------------------------------
# Test 13 (F4): --templates-only with a STALE local lib (has re_render_xray but
# NOT refetch_node_config) and REPO_RAW UNREACHABLE → DEGRADES (warn + render
# from the local node-config), does NOT die.  This is the recovery command: a
# stale render is the correct outcome on the recovery path; a die is not.
# Falsification: restore the unconditional die (remove the templates degrade
# path) → exit != 0 → RED.
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 13 (F4): --templates-only stale local + unreachable → degrade, render from local ==="
t13=$(mktemp -d)
trap 'rm -rf "$t13"' EXIT
setup_env "$t13/stub" "$t13/etc"
mkdir -p "$t13/var" "$t13/sbin"

OLD_LIB13="$t13/old_lib.sh"
sed '/^refetch_node_config() {/,/^}/d' "$LIB" > "$OLD_LIB13"
install -m 0644 "$OLD_LIB13" "$t13/sbin/channel-render-lib.sh"
extract_lib_funcs "$t13/sbin/funcs.sh"

write_fresh_node_config_json > "$t13/fresh_resp.json"
curl_log13="$t13/curl.log"
# lib-fetch exit 7 (unreachable); template + node-config fetches succeed.
make_curl_stub_lib "$t13/stub/curl" "$LIB" "$t13/fresh_resp.json" 7 "$curl_log13"

set +e
out13=$(
    PATH="$t13/stub:$(dirname "$(command -v python3)"):/usr/bin:/bin" \
    PREFIX_ETC="$t13/etc" \
    PREFIX_LIB="$t13/var" \
    PREFIX_SBIN="$t13/sbin" \
    NODE_CFG="$t13/etc/node-config.json" \
    XRAY_CFG="$t13/etc/xray-client.json" \
    TOKEN_FILE="$t13/etc/token" \
    OXPULSE_BACKEND_URL="http://test-control-plane.invalid" \
    REPO_RAW="file://$REPO_ROOT" \
    RELEASES_BASE="file://$t13/releases" \
    OXPULSE_UPGRADE_TAG="@RELEASE_TAG@" \
    RETRY_OPTS=() \
    OXPULSE_UPGRADE_NO_INTEGRITY=0 \
    MODE=templates \
    LOG_FILE="$t13/var/render.log" \
    bash -c '
        set -euo pipefail
        log()  { printf "%s\n" "$*" >&2; }
        warn() { log "WARN $*"; }
        die()  { log "ERR $*"; exit 1; }
        _CLEANUP_PATHS=()
        source "'"$OLD_LIB13"'"
        source "'"$t13"'/sbin/funcs.sh"
        _ensure_channel_render_lib
        # Mirror the templates block: guard refetch (absent in degrade), then render.
        command -v refetch_node_config >/dev/null 2>&1 && refetch_node_config
        re_render_xray
    ' 2>&1
)
exit13=$?
set -e

if [[ $exit13 -ne 0 ]]; then
    fail "test13/F4: --templates-only died (exit $exit13) instead of degrading; output: $out13"
elif [[ "$out13" != *"degraded"* ]]; then
    fail "test13/F4: completed (exit 0) but no 'degraded' warn in output; output: $out13"
elif [[ ! -s "$t13/etc/xray-client.json" ]]; then
    fail "test13/F4: degraded but xray-client.json was not rendered; output: $out13"
else
    pass "test13/F4: --templates-only degraded (stale local render) instead of dying — exit 0"
fi
trap - EXIT
rm -rf "$t13"

# ---------------------------------------------------------------------------
# Test 14 (F5): update.sh with a STALE installed lib (has re_render_xray but NOT
# refetch_node_config) → DEGRADES with a named warn and renders from the local
# node-config; NEVER reaches exit 127.  update.sh is the operator's explicit
# remediation tool, run when an edge is already degraded, and pre-PR it worked
# under exactly this skew because the refetch was inline and the stale lib still
# supplied re_render_xray.  Dying here would be a capability regression against
# main, so the degrade — not a die — is the contract.  Test 14b covers the case
# where the lib can do neither, which DOES die.
# Runs the REAL update.sh (copied into a tmpdir so _script_dir points at the
# stale adjacent lib), so the content-aware resolution is exercised end-to-end.
# Falsification: revert to existence-only resolution → sources the stale lib,
# returns, refetch_node_config at the call site → command not found → exit 127 →
# RED (the test asserts exit != 127).  Restore the unconditional die → the warn
# is absent → RED.
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 14 (F5): update.sh stale installed lib → named die, never 127 ==="
t14=$(mktemp -d)
trap 'rm -rf "$t14"' EXIT
mkdir -p "$t14/sbin" "$t14/etc"

# Copy the REAL update.sh into the tmpdir so _script_dir == tmpdir.
cp "$UPDATE_SH" "$t14/update.sh"

# Stale lib adjacent to update.sh (the local tier) — no refetch_node_config.
OLD_LIB14="$t14/channel-render-lib.sh"
sed '/^refetch_node_config() {/,/^}/d' "$LIB" > "$OLD_LIB14"

# PREFIX_SBIN points at an empty dir (no installed lib either).
# A token + node-config so any later pre-condition (unreached) does not trip.
echo "test-token" > "$t14/etc/token"
cat > "$t14/etc/node-config.json" <<'JSON'
{"short_id":"STALE","xray_host":"127.0.0.1","xray_port":443,"xray_uuid":"00000000-0000-0000-0000-000000000000"}
JSON

set +e
out14=$(
    PATH="/usr/bin:/bin" \
    PARTNER_EDGE_PREFIX_ETC="$t14/etc" \
    PREFIX_SBIN="$t14/sbin" \
    LOG_FILE="$t14/update.log" \
    bash "$t14/update.sh" 2>&1
)
exit14=$?
set -e

if [[ $exit14 -eq 127 ]]; then
    fail "test14/F5: update.sh exited 127 (command not found) — existence-only regression; output: $out14"
elif [[ "$out14" == *"provides re_render_xray but not refetch_node_config"* ]]; then
    pass "test14/F5: update.sh stale lib → degraded with a named warn (exit $exit14), never 127"
elif [[ "$out14" == *"does not provide refetch_node_config"* ]] \
  || [[ "$out14" == *"provides neither"* ]]; then
    fail "test14/F5: update.sh DIED on a skew it should degrade through — that is a capability regression against main; output: $out14"
else
    fail "test14/F5: update.sh neither degraded nor named the skew (exit $exit14); output: $out14"
fi
trap - EXIT
rm -rf "$t14"

# ---------------------------------------------------------------------------
# Test 14b (F5b): update.sh with a lib that provides NEITHER refetch_node_config
# NOR re_render_xray → dies with a named message, NEVER 127.  The degrade in
# test 14 is conditional on the lib still being able to render; without that
# there is nothing to fall back to and a die is correct.
# Falsification: make the degrade unconditional (warn and continue regardless) →
# no named die → RED.
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 14b (F5b): update.sh lib provides neither → named die, never 127 ==="
t14b=$(mktemp -d)
trap 'rm -rf "$t14b"' EXIT
mkdir -p "$t14b/sbin" "$t14b/etc"

cp "$UPDATE_SH" "$t14b/update.sh"

# Adjacent lib with BOTH functions stripped.
OLD_LIB14B="$t14b/channel-render-lib.sh"
sed -e '/^refetch_node_config() {/,/^}/d' -e '/^re_render_xray() {/,/^}/d' "$LIB" > "$OLD_LIB14B"

echo "test-token" > "$t14b/etc/token"
cat > "$t14b/etc/node-config.json" <<'JSON'
{"short_id":"STALE","xray_host":"127.0.0.1","xray_port":443,"xray_uuid":"00000000-0000-0000-0000-000000000000"}
JSON

set +e
out14b=$(
    PATH="/usr/bin:/bin" \
    PARTNER_EDGE_PREFIX_ETC="$t14b/etc" \
    PREFIX_SBIN="$t14b/sbin" \
    LOG_FILE="$t14b/update.log" \
    bash "$t14b/update.sh" 2>&1
)
exit14b=$?
set -e

if [[ $exit14b -eq 127 ]]; then
    fail "test14b/F5b: update.sh exited 127 (command not found); output: $out14b"
elif [[ $exit14b -eq 0 ]]; then
    fail "test14b/F5b: update.sh exited 0 with a lib that cannot render — the degrade must be conditional; output: $out14b"
elif [[ "$out14b" == *"provides neither"* ]] || [[ "$out14b" == *"not found (looked at"* ]]; then
    pass "test14b/F5b: update.sh unusable lib → named die (exit $exit14b), never 127"
else
    fail "test14b/F5b: died (exit $exit14b) but not with the named message; output: $out14b"
fi
trap - EXIT
rm -rf "$t14b"
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
