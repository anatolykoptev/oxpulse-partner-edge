#!/bin/bash
# tests/test_update_sh.sh — behavioral test suite for update.sh.
#
# Covers:
#   1. Template mode: packet-up + xmux block present after render
#   2. Missing token + no node-config → exit 1 with clear message
#   3. API down → falls back to local node-config.json, renders and exits 0
#   4. Smoke test failure (real cert in logs) → exit 1
#   5. Healthy node → exits 0
#   6. Idempotency: run 3× → same final xray-client.json
#
# All tests run without touching a real partner edge or real hub backend.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SCRIPT="$REPO_ROOT/update.sh"
RENDER_LIB="$REPO_ROOT/channel-render-lib.sh"
TPL="$REPO_ROOT/xray-client.json.tpl"

[[ -f "$SCRIPT" ]]     || { echo "FAIL: update.sh not found at $SCRIPT"; exit 1; }
[[ -f "$RENDER_LIB" ]] || { echo "FAIL: channel-render-lib.sh not found at $RENDER_LIB"; exit 1; }
[[ -f "$TPL" ]]        || { echo "FAIL: xray-client.json.tpl not found at $TPL"; exit 1; }

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

# make_bin: symlink all the POSIX utilities the script needs into a stub dir,
# then we can add targeted stubs on top for curl/docker/ss.
make_bin() {
    local dir="$1"
    # Core POSIX tools — update.sh and channel-render-lib.sh use all of these.
    # We symlink them so subprocesses (python3, sed, etc.) resolve correctly.
    for cmd in bash sh date printf cat tee cp mv mkdir chmod install sleep \
                sed grep head tail wc stat cut tr expr test rm dirname mktemp \
                python3 jq; do
        local loc
        loc=$(command -v "$cmd" 2>/dev/null || true)
        if [[ -n "$loc" ]]; then ln -sf "$loc" "$dir/$cmd"; fi
    done
    # curl is intentionally NOT symlinked here — callers must write a stub.
    # docker and ss are NOT symlinked — callers must write stubs.
}

# write_stub: remove any existing symlink and write a new stub script.
# Must be called AFTER make_bin if overriding a symlinked binary.
write_stub() {
    local path="$1"
    local body="$2"
    rm -f "$path"
    printf '#!/bin/bash\n%s\n' "$body" > "$path"
    chmod +x "$path"
}

# Write a minimal full node-config.json with all required reality_* fields
write_full_node_config() {
    local path="$1"
    cat > "$path" <<'EOF'
{
  "node_id": "test-node-001",
  "partner_id": "edge-c",
  "edge_id": "edge-c1",
  "public_ip": "192.0.2.1",
  "awg_ip": "10.0.0.1",
  "reality_uuid": "00000000-0000-0000-0000-000000000001",
  "reality_public_key": "U6ea044JJjgiCjQAnYEBqBBlkeSqrQaLq3lcjnN2EFk",
  "reality_encryption": "none",
  "reality_short_id": "abcd1234",
  "reality_server_name": "www.samsung.com",
  "reality_server_names": ["www.samsung.com"],
  "backend_endpoint": "hub.example.com:5349"
}
EOF
}

# run_update: run update.sh with test env vars that point at local template
# and stub out network/container operations via the stub dir.
run_update_env() {
    local stub_dir="$1"
    local etc_dir="$2"
    local var_dir="$3"
    local xray_cfg="${4:-$etc_dir/xray-client.json}"
    PATH="$stub_dir:$(dirname "$(command -v python3)"):/usr/bin:/bin" \
    PARTNER_EDGE_PREFIX_ETC="$etc_dir" \
    PARTNER_EDGE_PREFIX_LIB="$var_dir" \
    OXPULSE_BACKEND_URL="http://broken.invalid" \
    XRAY_CFG="$xray_cfg" \
    OXPULSE_SMOKE_WAIT="0" \
    LOG_FILE="$var_dir/update.log" \
    bash "$SCRIPT" 2>&1
}

# ---------------------------------------------------------------------------
# Test 1: Template produces packet-up + xmux block
# ---------------------------------------------------------------------------
echo "=== Test 1: template has packet-up mode and xmux block ==="

rendered=$(sed \
    -e 's/{{REALITY_UUID}}/00000000-0000-0000-0000-000000000000/g' \
    -e 's/{{REALITY_ENCRYPTION}}/none/g' \
    -e 's/{{REALITY_PUBLIC_KEY}}/U6ea044JJjgiCjQAnYEBqBBlkeSqrQaLq3lcjnN2EFk/g' \
    -e 's/{{REALITY_SHORT_ID}}/abcd1234/g' \
    -e 's/{{REALITY_SERVER_NAME}}/www.samsung.com/g' \
    -e 's/{{BACKEND_HOST}}/hub.example.com/g' \
    -e 's/{{BACKEND_PORT}}/5349/g' \
    -e 's/{{BACKEND_ENDPOINT}}/hub.example.com:5349/g' \
    "$TPL")

if ! echo "$rendered" | python3 -m json.tool >/dev/null 2>&1; then
    fail "test1: rendered template is not valid JSON"
else
    mode=$(echo "$rendered" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for ob in d.get('outbounds', []):
    s = ob.get('streamSettings', {}).get('xhttpSettings', {})
    if s: print(s.get('mode', '')); sys.exit(0)
print('')
")
    if [[ "$mode" == "packet-up" ]]; then
        pass "test1a: mode=packet-up"
    else
        fail "test1a: mode is '$mode', expected 'packet-up'"
    fi

    xmux_ok=$(echo "$rendered" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for ob in d.get('outbounds', []):
    s = ob.get('streamSettings', {}).get('xhttpSettings', {})
    if 'xmux' in s:
        x = s['xmux']
        required = ['maxConcurrency', 'cMaxReuseTimes', 'cMaxLifetimeMs']
        missing = [k for k in required if k not in x]
        if missing: print('MISSING:' + ','.join(missing)); sys.exit(0)
        print('OK'); sys.exit(0)
print('NO_XMUX')
")
    case "$xmux_ok" in
        OK)       pass "test1b: xmux block present with required fields" ;;
        NO_XMUX)  fail "test1b: xmux block not found in xhttpSettings" ;;
        *)        fail "test1b: xmux block missing fields: $xmux_ok" ;;
    esac

    xmux_vals=$(echo "$rendered" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for ob in d.get('outbounds', []):
    s = ob.get('streamSettings', {}).get('xhttpSettings', {})
    if 'xmux' in s:
        x = s['xmux']
        errors = []
        if x.get('maxConcurrency') != 1: errors.append(f\"maxConcurrency={x.get('maxConcurrency')}\")
        if x.get('cMaxReuseTimes') != 64: errors.append(f\"cMaxReuseTimes={x.get('cMaxReuseTimes')}\")
        if x.get('cMaxLifetimeMs') != 15000: errors.append(f\"cMaxLifetimeMs={x.get('cMaxLifetimeMs')}\")
        if errors: print('BAD:' + ';'.join(errors))
        else: print('OK')
        sys.exit(0)
print('NO_XMUX')
")
    if [[ "$xmux_vals" == "OK" ]]; then
        pass "test1c: xmux values match hub server (maxConcurrency=1, cMaxReuseTimes=64, cMaxLifetimeMs=15000)"
    else
        fail "test1c: xmux values mismatch: $xmux_vals"
    fi
fi

# ---------------------------------------------------------------------------
# Test 2: Missing token AND no node-config → exit 1 with "token" in message
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 2: missing token + no node-config → exit 1 ==="
t2=$(mktemp -d)
trap 'rm -rf "$t2"' EXIT

mkdir -p "$t2/stub" "$t2/etc" "$t2/var"
make_bin "$t2/stub"

# Override curl stub so it doesn't actually reach the network
cat > "$t2/stub/curl" <<'CURLSTUB'
#!/bin/bash
echo 'curl: (7) Failed to connect' >&2
exit 7
CURLSTUB
chmod +x "$t2/stub/curl"

set +e
out2=$(PATH="$t2/stub:$PATH" \
    PARTNER_EDGE_PREFIX_ETC="$t2/etc" \
    PARTNER_EDGE_PREFIX_LIB="$t2/var" \
    OXPULSE_BACKEND_URL="http://unused.invalid" \
    OXPULSE_SMOKE_WAIT="0" \
    LOG_FILE="$t2/var/update.log" \
    bash "$SCRIPT" 2>&1)
exit2=$?
set -e

if [[ $exit2 -ne 0 ]] && echo "$out2" | grep -qi "token"; then
    pass "test2: exits non-zero with token-related error message"
else
    fail "test2: expected exit non-zero + 'token' in message; got exit=$exit2; msg: $out2"
fi

trap - EXIT
rm -rf "$t2"

# ---------------------------------------------------------------------------
# Test 3: API down → falls back to local node-config.json, exits 0
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 3: API down → fallback to local node-config.json ==="
t3=$(mktemp -d)
trap 'rm -rf "$t3"' EXIT

mkdir -p "$t3/stub" "$t3/etc" "$t3/var"
make_bin "$t3/stub"

# curl stub: always fail (API down)
cat > "$t3/stub/curl" <<'CURLSTUB'
#!/bin/bash
echo 'curl: (7) Failed to connect' >&2
exit 7
CURLSTUB
chmod +x "$t3/stub/curl"

# docker stub: compose restart succeeds, logs = no real cert (smoke passes)
cat > "$t3/stub/docker" <<'DOCKERSTUB'
#!/bin/bash
if [[ "$1" == "logs" ]]; then
    echo "VLESS: tunnel established"
    exit 0
fi
exit 0
DOCKERSTUB
chmod +x "$t3/stub/docker"

# ss stub: port 3080 open
cat > "$t3/stub/ss" <<'SSSTUB'
#!/bin/bash
echo "LISTEN 0 128 0.0.0.0:3080 0.0.0.0:*"
SSSTUB
chmod +x "$t3/stub/ss"

# Token file + full node-config
printf 'ptkn_test123\n' > "$t3/etc/token"
chmod 0600 "$t3/etc/token"
write_full_node_config "$t3/etc/node-config.json"

set +e
out3=$(PATH="$t3/stub:$PATH" \
    PARTNER_EDGE_PREFIX_ETC="$t3/etc" \
    PARTNER_EDGE_PREFIX_LIB="$t3/var" \
    OXPULSE_BACKEND_URL="http://broken.invalid" \
    XRAY_CFG="$t3/etc/xray-client.json" \
    OXPULSE_SMOKE_WAIT="0" \
    LOG_FILE="$t3/var/update.log" \
    bash "$SCRIPT" 2>&1)
exit3=$?
set -e

if [[ $exit3 -eq 0 ]]; then
    if [[ -f "$t3/etc/xray-client.json" ]]; then
        pass "test3: API down → fallback to local node-config, xray-client.json rendered, exits 0"
    else
        fail "test3: exited 0 but xray-client.json not rendered; output: $out3"
    fi
else
    fail "test3: should exit 0 when API down but local fallback available (exited $exit3); output: $out3"
fi

trap - EXIT
rm -rf "$t3"

# ---------------------------------------------------------------------------
# Test 4: Smoke test failure → exit 1
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 4: smoke failure (real cert in logs) → exit 1 ==="
t4=$(mktemp -d)
trap 'rm -rf "$t4"' EXIT

mkdir -p "$t4/stub" "$t4/etc" "$t4/var"
make_bin "$t4/stub"

cat > "$t4/stub/curl" <<'CURLSTUB'
#!/bin/bash
echo 'curl: (7) Failed to connect' >&2
exit 7
CURLSTUB
chmod +x "$t4/stub/curl"

# docker: logs emit "received real certificate" → smoke fails
cat > "$t4/stub/docker" <<'DOCKERSTUB'
#!/bin/bash
if [[ "$1" == "logs" ]]; then
    echo "received real certificate from www.samsung.com"
    exit 0
fi
exit 0
DOCKERSTUB
chmod +x "$t4/stub/docker"

cat > "$t4/stub/ss" <<'SSSTUB'
#!/bin/bash
echo "LISTEN 0 128 0.0.0.0:3080 0.0.0.0:*"
SSSTUB
chmod +x "$t4/stub/ss"

printf 'ptkn_test123\n' > "$t4/etc/token"
chmod 0600 "$t4/etc/token"
write_full_node_config "$t4/etc/node-config.json"

set +e
out4=$(PATH="$t4/stub:$PATH" \
    PARTNER_EDGE_PREFIX_ETC="$t4/etc" \
    PARTNER_EDGE_PREFIX_LIB="$t4/var" \
    OXPULSE_BACKEND_URL="http://broken.invalid" \
    XRAY_CFG="$t4/etc/xray-client.json" \
    OXPULSE_SMOKE_WAIT="0" \
    LOG_FILE="$t4/var/update.log" \
    bash "$SCRIPT" 2>&1)
exit4=$?
set -e

if [[ $exit4 -ne 0 ]]; then
    pass "test4a: smoke failure → exit non-zero"
    if echo "$out4" | grep -qi "smoke\|real certificate\|Reality\|handshake"; then
        pass "test4b: error message mentions smoke/Reality failure"
    else
        fail "test4b: exited $exit4 but message doesn't mention smoke failure; output: $out4"
    fi
else
    fail "test4: smoke failure must cause exit non-zero (exited 0); output: $out4"
fi

trap - EXIT
rm -rf "$t4"

# ---------------------------------------------------------------------------
# Test 5: Healthy node → exits 0
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 5: healthy node → exits 0 ==="
t5=$(mktemp -d)
trap 'rm -rf "$t5"' EXIT

mkdir -p "$t5/stub" "$t5/etc" "$t5/var"
make_bin "$t5/stub"

cat > "$t5/stub/curl" <<'CURLSTUB'
#!/bin/bash
echo 'curl: (7) Failed to connect' >&2
exit 7
CURLSTUB
chmod +x "$t5/stub/curl"

cat > "$t5/stub/docker" <<'DOCKERSTUB'
#!/bin/bash
if [[ "$1" == "logs" ]]; then
    echo "VLESS: tunnel established"
    exit 0
fi
exit 0
DOCKERSTUB
chmod +x "$t5/stub/docker"

cat > "$t5/stub/ss" <<'SSSTUB'
#!/bin/bash
echo "LISTEN 0 128 0.0.0.0:3080 0.0.0.0:*"
SSSTUB
chmod +x "$t5/stub/ss"

printf 'ptkn_test123\n' > "$t5/etc/token"
chmod 0600 "$t5/etc/token"
write_full_node_config "$t5/etc/node-config.json"

set +e
out5=$(PATH="$t5/stub:$PATH" \
    PARTNER_EDGE_PREFIX_ETC="$t5/etc" \
    PARTNER_EDGE_PREFIX_LIB="$t5/var" \
    OXPULSE_BACKEND_URL="http://broken.invalid" \
    XRAY_CFG="$t5/etc/xray-client.json" \
    OXPULSE_SMOKE_WAIT="0" \
    LOG_FILE="$t5/var/update.log" \
    bash "$SCRIPT" 2>&1)
exit5=$?
set -e

if [[ $exit5 -eq 0 ]]; then
    pass "test5: healthy node → exits 0"
else
    fail "test5: should exit 0 on healthy node (exited $exit5); output: $out5"
fi

trap - EXIT
rm -rf "$t5"

# ---------------------------------------------------------------------------
# Test 6: Idempotency — run 3× → same final xray-client.json hash
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 6: idempotency — 3 runs → same xray-client.json ==="
t6=$(mktemp -d)
trap 'rm -rf "$t6"' EXIT

mkdir -p "$t6/stub" "$t6/etc" "$t6/var"
make_bin "$t6/stub"

cat > "$t6/stub/curl" <<'CURLSTUB'
#!/bin/bash
echo 'curl: (7) Failed to connect' >&2
exit 7
CURLSTUB
chmod +x "$t6/stub/curl"

cat > "$t6/stub/docker" <<'DOCKERSTUB'
#!/bin/bash
if [[ "$1" == "logs" ]]; then
    echo "VLESS: tunnel established"
    exit 0
fi
exit 0
DOCKERSTUB
chmod +x "$t6/stub/docker"

cat > "$t6/stub/ss" <<'SSSTUB'
#!/bin/bash
echo "LISTEN 0 128 0.0.0.0:3080 0.0.0.0:*"
SSSTUB
chmod +x "$t6/stub/ss"

printf 'ptkn_test123\n' > "$t6/etc/token"
chmod 0600 "$t6/etc/token"
write_full_node_config "$t6/etc/node-config.json"

do_run() {
    PATH="$t6/stub:$PATH" \
    PARTNER_EDGE_PREFIX_ETC="$t6/etc" \
    PARTNER_EDGE_PREFIX_LIB="$t6/var" \
    OXPULSE_BACKEND_URL="http://broken.invalid" \
    XRAY_CFG="$t6/etc/xray-client.json" \
    OXPULSE_SMOKE_WAIT="0" \
    LOG_FILE="$t6/var/update.log" \
    bash "$SCRIPT" 2>/dev/null
}

set +e
do_run; e1=$?
hash1=$(md5sum "$t6/etc/xray-client.json" 2>/dev/null | cut -d' ' -f1 || echo "missing")
do_run; e2=$?
hash2=$(md5sum "$t6/etc/xray-client.json" 2>/dev/null | cut -d' ' -f1 || echo "missing")
do_run; e3=$?
hash3=$(md5sum "$t6/etc/xray-client.json" 2>/dev/null | cut -d' ' -f1 || echo "missing")
set -e

if [[ $e1 -eq 0 && $e2 -eq 0 && $e3 -eq 0 ]]; then
    pass "test6a: all 3 runs exit 0"
else
    fail "test6a: exit codes: $e1 $e2 $e3 (expected all 0)"
fi

if [[ "$hash1" == "$hash2" && "$hash2" == "$hash3" && "$hash1" != "missing" ]]; then
    pass "test6b: xray-client.json identical across all 3 runs (md5=$hash1)"
else
    fail "test6b: xray-client.json content differs across runs: run1=$hash1 run2=$hash2 run3=$hash3"
fi

trap - EXIT
rm -rf "$t6"

# ---------------------------------------------------------------------------
# Syntax check
# ---------------------------------------------------------------------------
echo ""
echo "=== Syntax check ==="
bash -n "$SCRIPT" && pass "update.sh syntax clean" || fail "update.sh has syntax errors"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
