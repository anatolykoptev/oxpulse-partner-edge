#!/usr/bin/env bash
# tests/test_channels_health_report.sh — behavioral tests for
# oxpulse-channels-health-report.sh (M2.6a channel health reporter).
#
# Does NOT require bats — uses the same pass/fail/ok/fail pattern as
# other tests in this repo (plain bash, no external test runner).
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SCRIPT="$REPO_ROOT/oxpulse-channels-health-report.sh"

[[ -f "$SCRIPT" ]] || { echo "FAIL: reporter script not found at $SCRIPT"; exit 1; }

PASS=0
FAIL=0

ok()   { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# ---------- helper: create stub bin dir ----------
make_bin() {
    local dir="$1"
    # Do NOT include ping or nc — they need capabilities; tests provide stubs.
    # Include dirname and realpath — the reporter uses them for config path.
    for cmd in bash sh date printf cat tee cp mv mkdir chmod install sleep \
                sed grep head tail wc stat cut tr expr test awk dirname realpath; do
        local loc
        loc=$(command -v "$cmd" 2>/dev/null || true)
        [[ -n "$loc" ]] && ln -sf "$loc" "$dir/$cmd"
    done
    # Default no-op stubs for ping and nc (tests override as needed).
    printf '#!/bin/sh\nexit 0\n' > "$dir/ping"; chmod +x "$dir/ping"
    printf '#!/bin/sh\nexit 0\n' > "$dir/nc";   chmod +x "$dir/nc"
    if command -v jq >/dev/null 2>&1; then
        ln -sf "$(command -v jq)" "$dir/jq"
    fi
    # curl: always provide a no-op stub (real curl may have permission issues via symlink)
    printf '#!/bin/sh\nprintf "200"\nexit 0\n' > "$dir/curl"; chmod +x "$dir/curl"
    cat > "$dir/systemctl" <<'STUB'
#!/bin/sh
exit 0
STUB
    chmod +x "$dir/systemctl"
}

# ---------- helper: minimal node-config.json ----------
write_node_config() {
    local dir="$1"; shift
    local channels="${1:-}"
    local cfg
    if [[ -n "$channels" ]]; then
        cfg=$(printf '{"node_id":"test-node","channels":[%s]}' "$channels")
    else
        cfg='{"node_id":"test-node","channels":[]}'
    fi
    printf '%s\n' "$cfg" > "$dir/node-config.json"
}

echo "test_channels_health_report.sh"
echo

# ── Test 1: --dry-run emits valid JSON for all provisioned channels ────────────
T1=$(mktemp -d)
trap 'rm -rf "$T1"' EXIT

make_bin "$T1"

mkdir -p "$T1/etc" "$T1/var"
write_node_config "$T1/etc" \
    '{"id":"ch1"},{"id":"ch2"},{"id":"ch3"},{"id":"ch4"},{"id":"ch5"},{"id":"ch6"}'

# docker stub: ss -ltn shows :3080 for ch1 probe
cat > "$T1/docker" <<'STUB'
#!/bin/bash
# Simulate: docker exec oxpulse-partner-xray ss -ltn → output containing :3080
if [[ "$*" == *"ss -ltn"* ]]; then
    echo "LISTEN 0 128 0.0.0.0:3080 0.0.0.0:*"
    exit 0
fi
exit 1
STUB
chmod +x "$T1/docker"

# ping stub: succeed
cat > "$T1/ping" <<'STUB'
#!/bin/sh
exit 0
STUB
chmod +x "$T1/ping"

# nc stub: succeed
cat > "$T1/nc" <<'STUB'
#!/bin/sh
exit 0
STUB
chmod +x "$T1/nc"

set +e
OUTPUT=$(PATH="$T1:/usr/bin:/bin" \
    _NODE_CONFIG="$T1/etc/node-config.json" \
    _TOKEN_LIB=/nonexistent \
    OXPULSE_SERVICE_TOKEN="stkn_test" \
    bash "$SCRIPT" --dry-run 2>/dev/null)
EXIT1=$?
set -e

# Verify we got at least 3 lines of JSON (ch1/ch2/ch3 — ch4/ch5/ch6 skipped)
LINE_COUNT=$(printf '%s\n' "$OUTPUT" | grep -c '"channel_name"' 2>/dev/null || echo 0)
if [[ "$LINE_COUNT" -ge 3 ]]; then
    ok "test1: --dry-run emits $LINE_COUNT channel JSON lines"
else
    fail "test1: expected >=3 channel lines, got $LINE_COUNT; output: $OUTPUT"
fi

# Validate all JSON objects in the output (output may be pretty-printed multi-line).
# Use jq to extract all top-level objects from the concatenated output stream.
if printf '%s\n' "$OUTPUT" | jq -e '.' >/dev/null 2>&1; then
    ok "test1: all channel JSON objects are valid"
else
    fail "test1: output contains invalid JSON; got: $OUTPUT"
fi

# node_id present
if printf '%s\n' "$OUTPUT" | grep -q '"node_id"'; then
    ok "test1: node_id present in output"
else
    fail "test1: node_id missing from output"
fi

trap - EXIT
rm -rf "$T1"

# ── Test 2: running xray → ch1 handshake_ok=true ──────────────────────────────
T2=$(mktemp -d)
trap 'rm -rf "$T2"' EXIT

make_bin "$T2"
mkdir -p "$T2/etc"
write_node_config "$T2/etc" '{"id":"ch1"}'

cat > "$T2/docker" <<'STUB'
#!/bin/bash
if [[ "$*" == *"ss -ltn"* ]]; then
    echo "LISTEN 0 128 0.0.0.0:3080 0.0.0.0:*"
    exit 0
fi
exit 1
STUB
chmod +x "$T2/docker"

set +e
OUTPUT2=$(PATH="$T2:/usr/bin:/bin" \
    _NODE_CONFIG="$T2/etc/node-config.json" \
    _TOKEN_LIB=/nonexistent \
    OXPULSE_SERVICE_TOKEN="stkn_test" \
    bash "$SCRIPT" --dry-run 2>/dev/null)
set -e

if printf '%s\n' "$OUTPUT2" | jq -e 'select(.channel_name=="ch1" and .channel_handshake_ok==true)' >/dev/null 2>&1; then
    ok "test2: ch1 with running xray → handshake_ok=true"
else
    fail "test2: ch1 with running xray should have handshake_ok=true; got: $OUTPUT2"
fi

trap - EXIT
rm -rf "$T2"

# ── Test 3: dead hy2 listener → ch3 rtt_ms=0 ─────────────────────────────────
T3=$(mktemp -d)
trap 'rm -rf "$T3"' EXIT

make_bin "$T3"
mkdir -p "$T3/etc"
write_node_config "$T3/etc" '{"id":"ch3"}'

# nc stub: fail (port not listening)
cat > "$T3/nc" <<'STUB'
#!/bin/sh
exit 1
STUB
chmod +x "$T3/nc"

set +e
OUTPUT3=$(PATH="$T3:/usr/bin:/bin" \
    _NODE_CONFIG="$T3/etc/node-config.json" \
    _TOKEN_LIB=/nonexistent \
    OXPULSE_SERVICE_TOKEN="stkn_test" \
    bash "$SCRIPT" --dry-run 2>/dev/null)
set -e

if printf '%s\n' "$OUTPUT3" | jq -e 'select(.channel_name=="ch3" and .channel_rtt_ms==0)' >/dev/null 2>&1; then
    ok "test3: dead hy2 listener → ch3 rtt_ms=0"
else
    fail "test3: expected ch3 rtt_ms=0 for dead listener; got: $OUTPUT3"
fi

trap - EXIT
rm -rf "$T3"

# ── Test 4: only ch1+ch2+ch3 provisioned; ch4-ch6 not in output ──────────────
T4=$(mktemp -d)
trap 'rm -rf "$T4"' EXIT

make_bin "$T4"
mkdir -p "$T4/etc"
# Only ch1, ch2, ch3 in node-config
write_node_config "$T4/etc" '{"id":"ch1"},{"id":"ch2"},{"id":"ch3"}'

cat > "$T4/docker" <<'STUB'
#!/bin/bash
echo "LISTEN 0 128 0.0.0.0:3080 0.0.0.0:*"; exit 0
STUB
chmod +x "$T4/docker"
cat > "$T4/ping" <<'STUB'
#!/bin/sh
exit 0
STUB
chmod +x "$T4/ping"
cat > "$T4/nc" <<'STUB'
#!/bin/sh
exit 0
STUB
chmod +x "$T4/nc"

set +e
OUTPUT4=$(PATH="$T4:/usr/bin:/bin" \
    _NODE_CONFIG="$T4/etc/node-config.json" \
    _TOKEN_LIB=/nonexistent \
    OXPULSE_SERVICE_TOKEN="stkn_test" \
    bash "$SCRIPT" --dry-run 2>/dev/null)
set -e

# Should have exactly 3 channel lines
COUNT4=$(printf '%s\n' "$OUTPUT4" | grep -c '"channel_name"' 2>/dev/null || echo 0)
if [[ "$COUNT4" -eq 3 ]]; then
    ok "test4: exactly 3 channel entries (ch1/ch2/ch3), ch4-ch6 absent"
else
    fail "test4: expected 3 channels, got $COUNT4; output: $OUTPUT4"
fi

# ch4/ch5/ch6 must not appear
if printf '%s\n' "$OUTPUT4" | grep -qE '"channel_name":"ch[456]"'; then
    fail "test4: ch4/ch5/ch6 should not be in JSON output"
else
    ok "test4: ch4/ch5/ch6 correctly absent from JSON"
fi

trap - EXIT
rm -rf "$T4"

# ── Test 5: --curl-trace flag emits Authorization header to stderr ─────────────
T5=$(mktemp -d)
trap 'rm -rf "$T5"' EXIT

make_bin "$T5"
mkdir -p "$T5/etc"
write_node_config "$T5/etc" '{"id":"ch1"}'

cat > "$T5/docker" <<'STUB'
#!/bin/bash
echo "LISTEN 0 128 0.0.0.0:3080 0.0.0.0:*"; exit 0
STUB
chmod +x "$T5/docker"

set +e
STDERR5=$(PATH="$T5:/usr/bin:/bin" \
    _NODE_CONFIG="$T5/etc/node-config.json" \
    _TOKEN_LIB=/nonexistent \
    OXPULSE_SERVICE_TOKEN="stkn_trace_token" \
    bash "$SCRIPT" --dry-run --curl-trace 2>&1 >/dev/null)
set -e

if printf '%s\n' "$STDERR5" | grep -q 'Authorization: Bearer stkn_trace_token'; then
    ok "test5: --curl-trace emits Authorization header to stderr"
else
    fail "test5: Authorization header not found in stderr; got: $STDERR5"
fi

trap - EXIT
rm -rf "$T5"

# ── Test 6: mock backend 503 → exit 0 + warn log ──────────────────────────────
T6=$(mktemp -d)
trap 'rm -rf "$T6"' EXIT

make_bin "$T6"
mkdir -p "$T6/etc"
write_node_config "$T6/etc" '{"id":"ch1"}'

cat > "$T6/docker" <<'STUB'
#!/bin/bash
echo "LISTEN 0 128 0.0.0.0:3080 0.0.0.0:*"; exit 0
STUB
chmod +x "$T6/docker"

# curl stub: always return 503
cat > "$T6/curl" <<'STUB'
#!/bin/bash
printf '503'
exit 0
STUB
chmod +x "$T6/curl"

set +e
STDERR6=$(PATH="$T6:/usr/bin:/bin" \
    _NODE_CONFIG="$T6/etc/node-config.json" \
    _TOKEN_LIB=/nonexistent \
    OXPULSE_SERVICE_TOKEN="stkn_test" \
    OXPULSE_BACKEND_API="http://mock.invalid" \
    bash "$SCRIPT" 2>&1)
EXIT6=$?
set -e

if [[ "$EXIT6" -eq 0 ]]; then
    ok "test6: 5xx response → exit 0 (server hiccup, retry next tick)"
else
    fail "test6: 5xx response should exit 0, got exit $EXIT6"
fi
if printf '%s\n' "$STDERR6" | grep -qi "warn\|hiccup\|retry"; then
    ok "test6: warn log emitted on 5xx"
else
    fail "test6: expected warn log on 5xx; got: $STDERR6"
fi

trap - EXIT
rm -rf "$T6"

# ── Test 7: mock backend 401 → exit 1 + error log ─────────────────────────────
T7=$(mktemp -d)
trap 'rm -rf "$T7"' EXIT

make_bin "$T7"
mkdir -p "$T7/etc"
write_node_config "$T7/etc" '{"id":"ch1"}'

cat > "$T7/docker" <<'STUB'
#!/bin/bash
echo "LISTEN 0 128 0.0.0.0:3080 0.0.0.0:*"; exit 0
STUB
chmod +x "$T7/docker"

# curl stub: return 401
cat > "$T7/curl" <<'STUB'
#!/bin/bash
printf '401'
exit 0
STUB
chmod +x "$T7/curl"

set +e
STDERR7=$(PATH="$T7:/usr/bin:/bin" \
    _NODE_CONFIG="$T7/etc/node-config.json" \
    _TOKEN_LIB=/nonexistent \
    OXPULSE_SERVICE_TOKEN="stkn_bad" \
    OXPULSE_BACKEND_API="http://mock.invalid" \
    bash "$SCRIPT" 2>&1)
EXIT7=$?
set -e

if [[ "$EXIT7" -eq 1 ]]; then
    ok "test7: 401 response → exit 1"
else
    fail "test7: 401 should exit 1, got exit $EXIT7"
fi
if printf '%s\n' "$STDERR7" | grep -qi "warn\|token\|auth"; then
    ok "test7: auth error log emitted on 401"
else
    fail "test7: expected warn log on 401; got: $STDERR7"
fi

trap - EXIT
rm -rf "$T7"

# ---------- syntax check ----------
bash -n "$SCRIPT" && ok "syntax check: oxpulse-channels-health-report.sh"

echo
if [[ "$FAIL" -eq 0 ]]; then
    echo "PASS: all $PASS checks passed"
    exit 0
else
    echo "FAIL: $FAIL check(s) failed ($PASS passed)"
    exit 1
fi
