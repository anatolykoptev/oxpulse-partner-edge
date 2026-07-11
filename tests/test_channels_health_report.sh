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
    # openssl: needed for RFC 7635 ephemeral HMAC-SHA1 credential derivation.
    if command -v openssl >/dev/null 2>&1; then
        ln -sf "$(command -v openssl)" "$dir/openssl"
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

# docker stub: handles ch1 (ss -ltn :3080) and ch4 (turnutils_uclient / sed secret)
cat > "$T1/docker" <<'STUB'
#!/bin/bash
# Simulate: docker exec oxpulse-partner-xray ss -ltn → output containing :3080
if [[ "$*" == *"ss -ltn"* ]]; then
    echo "LISTEN 0 128 0.0.0.0:3080 0.0.0.0:*"
    exit 0
fi
# Simulate: docker exec oxpulse-partner-coturn sed (secret read) → return secret
if [[ "$*" == *"sed"* && "$*" == *"static-auth-secret"* ]]; then
    echo "test-secret"
    exit 0
fi
# Simulate: docker exec oxpulse-partner-coturn turnutils_uclient → success.
# Reject peerless invocations (missing -y or -e): those exit 255 in real coturn
# and should never reach here; this guard catches regressions.
if [[ "$*" == *"turnutils_uclient"* ]]; then
    if [[ "$*" != *" -y"* && "$*" != *" -e "* ]]; then
        echo "STUB-ERROR: turnutils_uclient called without -y or -e (peerless — would exit 255 on real coturn)" >&2
        exit 255
    fi
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

# Verify we got at least 4 lines of JSON (ch1/ch2/ch3/ch4 — ch5/ch6 skipped)
LINE_COUNT=$(printf '%s\n' "$OUTPUT" | grep -c '"channel_name"' 2>/dev/null || echo 0)
if [[ "$LINE_COUNT" -ge 4 ]]; then
    ok "test1: --dry-run emits $LINE_COUNT channel JSON lines"
else
    fail "test1: expected >=4 channel lines, got $LINE_COUNT; output: $OUTPUT"
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

# ── Test 2: ch1 real end-to-end tunnel (canary/tunnel 2xx) → handshake_ok=true
# Regression guard for the local-liveness blind spot: probe_ch1 no longer
# checks `docker exec ... ss -ltn` (which stays green even when the real
# VLESS-Reality path is ТСПУ-blocked — the edge-b incident this rewrite
# fixes, see Test 2b). It now curls the Phase 1 canary route
# (http://127.0.0.1:9080/canary/tunnel) that proxies through xray-client to
# the central backend end-to-end.
T2=$(mktemp -d)
trap 'rm -rf "$T2"' EXIT

make_bin "$T2"
mkdir -p "$T2/etc"
write_node_config "$T2/etc" '{"id":"ch1"}'

# curl stub: canary/tunnel → 200 (tunnel + backend both reachable).
cat > "$T2/curl" <<'STUB'
#!/bin/bash
for a in "$@"; do
    case "$a" in
        *canary/tunnel*) printf '200'; exit 0 ;;
    esac
done
printf '200'
exit 0
STUB
chmod +x "$T2/curl"

set +e
OUTPUT2=$(PATH="$T2:/usr/bin:/bin" \
    _NODE_CONFIG="$T2/etc/node-config.json" \
    _TOKEN_LIB=/nonexistent \
    OXPULSE_SERVICE_TOKEN="stkn_test" \
    bash "$SCRIPT" --dry-run 2>/dev/null)
set -e

if printf '%s\n' "$OUTPUT2" | jq -e 'select(.channel_name=="ch1" and .channel_handshake_ok==true)' >/dev/null 2>&1; then
    ok "test2: ch1 real tunnel reachable (canary/tunnel 200) → handshake_ok=true"
else
    fail "test2: ch1 with reachable tunnel should have handshake_ok=true; got: $OUTPUT2"
fi

# channel_rtt_ms must be present (real measured round trip, not omitted).
if printf '%s\n' "$OUTPUT2" | jq -e 'select(.channel_name=="ch1") | has("channel_rtt_ms")' >/dev/null 2>&1; then
    ok "test2: ch1 payload carries channel_rtt_ms"
else
    fail "test2: ch1 payload missing channel_rtt_ms; got: $OUTPUT2"
fi

trap - EXIT
rm -rf "$T2"

# ── Test 2b: ch1 real end-to-end tunnel BLOCKED (canary/tunnel 502) ──────────
# THE regression guard for the bug this whole rewrite exists to fix: live-
# verified on edge-b, xray was ТСПУ-blocked (502 on canary/tunnel, the real
# path) while the OLD local-liveness probe (docker exec ss -ltn) stayed green
# the entire time. probe_ch1 must now report handshake_ok=false when the real
# tunnel path fails, even though nothing here checks local container state at
# all any more.
T2B=$(mktemp -d)
trap 'rm -rf "$T2B"' EXIT

make_bin "$T2B"
mkdir -p "$T2B/etc"
write_node_config "$T2B/etc" '{"id":"ch1"}'

# curl stub: canary/tunnel → 502 (ТСПУ-blocked real tunnel path — edge-b).
cat > "$T2B/curl" <<'STUB'
#!/bin/bash
for a in "$@"; do
    case "$a" in
        *canary/tunnel*) printf '502'; exit 0 ;;
    esac
done
printf '200'
exit 0
STUB
chmod +x "$T2B/curl"

set +e
OUTPUT2B=$(PATH="$T2B:/usr/bin:/bin" \
    _NODE_CONFIG="$T2B/etc/node-config.json" \
    _TOKEN_LIB=/nonexistent \
    OXPULSE_SERVICE_TOKEN="stkn_test" \
    bash "$SCRIPT" --dry-run 2>/dev/null)
set -e

if printf '%s\n' "$OUTPUT2B" | jq -e 'select(.channel_name=="ch1" and .channel_handshake_ok==false)' >/dev/null 2>&1; then
    ok "test2b: EDGE-B REGRESSION GUARD — 502 on real tunnel path → handshake_ok=false"
else
    fail "test2b: REGRESSION — 502 on canary/tunnel must report handshake_ok=false; got: $OUTPUT2B"
fi

trap - EXIT
rm -rf "$T2B"

# ── Test 3: ch3 real end-to-end tunnel unreachable → handshake_ok=false ──────
# Regression guard + the core new deliverable: probe_ch3 no longer does a bare
# `nc -z` port check (which only proves the LOCAL hysteria2-client forwarder
# is listening, never that a byte reaches the backend) and, critically, it
# NEVER emitted channel_handshake_ok at all before this rewrite — the
# backend's ch1/ch2/ch3 OR'd signaling-health logic (health_poller.rs) had
# zero visibility into ch3. It now curls the local forwarder
# (127.0.0.1:$PORT/api/health, forwarded over the QUIC tunnel) and reports a
# real handshake_ok.
T3=$(mktemp -d)
trap 'rm -rf "$T3"' EXIT

make_bin "$T3"
mkdir -p "$T3/etc"
write_node_config "$T3/etc" '{"id":"ch3"}'

# curl stub: local hy2 forwarder unreachable — connection refused (curl's own
# "000" convention for a failed dial, matching _post_channel's own idiom).
cat > "$T3/curl" <<'STUB'
#!/bin/bash
for a in "$@"; do
    case "$a" in
        *:18443/api/health*) printf '000'; exit 0 ;;
    esac
done
printf '200'
exit 0
STUB
chmod +x "$T3/curl"

set +e
OUTPUT3=$(PATH="$T3:/usr/bin:/bin" \
    _NODE_CONFIG="$T3/etc/node-config.json" \
    _TOKEN_LIB=/nonexistent \
    OXPULSE_SERVICE_TOKEN="stkn_test" \
    bash "$SCRIPT" --dry-run 2>/dev/null)
set -e

if printf '%s\n' "$OUTPUT3" | jq -e 'select(.channel_name=="ch3" and .channel_handshake_ok==false)' >/dev/null 2>&1; then
    ok "test3: ch3 unreachable real tunnel → channel_handshake_ok=false (NEW field, was never emitted before)"
else
    fail "test3: expected ch3 channel_handshake_ok=false for unreachable tunnel; got: $OUTPUT3"
fi

# channel_rtt_ms must still be present and non-negative (real elapsed time,
# not a hardcoded magic 0 — the pre-rewrite contract).
GOT_RTT3=$(printf '%s\n' "$OUTPUT3" | jq -r 'select(.channel_name=="ch3") | .channel_rtt_ms' 2>/dev/null)
if [[ "$GOT_RTT3" =~ ^[0-9]+$ ]]; then
    ok "test3: ch3 channel_rtt_ms is a non-negative integer ($GOT_RTT3)"
else
    fail "test3: ch3 channel_rtt_ms should be a non-negative integer; got: $GOT_RTT3"
fi

trap - EXIT
rm -rf "$T3"

# ── Test 3b: ch3 real end-to-end tunnel reachable → handshake_ok=true ────────
# THE core new deliverable for ch3: it must start emitting handshake_ok at
# all. Positive-path complement to Test 3.
T3B=$(mktemp -d)
trap 'rm -rf "$T3B"' EXIT

make_bin "$T3B"
mkdir -p "$T3B/etc"
write_node_config "$T3B/etc" '{"id":"ch3"}'

cat > "$T3B/curl" <<'STUB'
#!/bin/bash
for a in "$@"; do
    case "$a" in
        *:18443/api/health*) printf '200'; exit 0 ;;
    esac
done
printf '200'
exit 0
STUB
chmod +x "$T3B/curl"

set +e
OUTPUT3B=$(PATH="$T3B:/usr/bin:/bin" \
    _NODE_CONFIG="$T3B/etc/node-config.json" \
    _TOKEN_LIB=/nonexistent \
    OXPULSE_SERVICE_TOKEN="stkn_test" \
    bash "$SCRIPT" --dry-run 2>/dev/null)
set -e

if printf '%s\n' "$OUTPUT3B" | jq -e 'select(.channel_name=="ch3" and .channel_handshake_ok==true)' >/dev/null 2>&1; then
    ok "test3b: ch3 real tunnel reachable → channel_handshake_ok=true (first time ch3 ever emits this field)"
else
    fail "test3b: expected ch3 channel_handshake_ok=true for reachable tunnel; got: $OUTPUT3B"
fi

trap - EXIT
rm -rf "$T3B"

# ── Test 4: only ch1+ch2+ch3 provisioned; ch5/ch6 not in output ──────────────
T4=$(mktemp -d)
trap 'rm -rf "$T4"' EXIT

make_bin "$T4"
mkdir -p "$T4/etc"
# Only ch1, ch2, ch3 in node-config
write_node_config "$T4/etc" '{"id":"ch1"},{"id":"ch2"},{"id":"ch3"}'

cat > "$T4/docker" <<'STUB'
#!/bin/bash
if [[ "$*" == *"ss -ltn"* ]]; then
    echo "LISTEN 0 128 0.0.0.0:3080 0.0.0.0:*"; exit 0
fi
exit 0
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

# Should have exactly 3 channel lines (ch4 not provisioned, ch5/ch6 skipped)
COUNT4=$(printf '%s\n' "$OUTPUT4" | grep -c '"channel_name"' 2>/dev/null || echo 0)
if [[ "$COUNT4" -eq 3 ]]; then
    ok "test4: exactly 3 channel entries (ch1/ch2/ch3), ch5-ch6 absent"
else
    fail "test4: expected 3 channels, got $COUNT4; output: $OUTPUT4"
fi

# ch5/ch6 must not appear (ch4 is now wired — only ch5/ch6 are skipped)
if printf '%s\n' "$OUTPUT4" | grep -qE '"channel_name":"ch[56]"'; then
    fail "test4: ch5/ch6 should not be in JSON output"
else
    ok "test4: ch5/ch6 correctly absent from JSON"
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

# ── Test 8: ch4 coturn Allocate OK → handshake_ok=true ────────────────────────
T8=$(mktemp -d)
trap 'rm -rf "$T8"' EXIT

make_bin "$T8"
mkdir -p "$T8/etc"
write_node_config "$T8/etc" '{"id":"ch4"}'

# docker stub: sed returns secret; turnutils_uclient succeeds (Allocate OK).
# Stub validates -y or -e is present; exits 255 if peerless (matches real coturn
# behaviour, catches regression to the old broken -c-only invocation).
cat > "$T8/docker" <<'STUB'
#!/bin/bash
if [[ "$*" == *"sed"* && "$*" == *"static-auth-secret"* ]]; then
    echo "probe-test-secret"
    exit 0
fi
if [[ "$*" == *"turnutils_uclient"* ]]; then
    if [[ "$*" != *" -y"* && "$*" != *" -e "* ]]; then
        echo "STUB-ERROR: peerless turnutils_uclient (no -y/-e) — fails on real coturn" >&2
        exit 255
    fi
    exit 0
fi
exit 1
STUB
chmod +x "$T8/docker"

set +e
OUTPUT8=$(PATH="$T8:/usr/bin:/bin" \
    _NODE_CONFIG="$T8/etc/node-config.json" \
    _TOKEN_LIB=/nonexistent \
    OXPULSE_SERVICE_TOKEN="stkn_test" \
    bash "$SCRIPT" --dry-run 2>/dev/null)
set -e

if printf '%s\n' "$OUTPUT8" | jq -e 'select(.channel_name=="coturn" and .channel_handshake_ok==true)' >/dev/null 2>&1; then
    ok "test8: ch4 TURN Allocate OK → channel_name=coturn handshake_ok=true"
else
    fail "test8: expected coturn handshake_ok=true; got: $OUTPUT8"
fi

trap - EXIT
rm -rf "$T8"

# ── Test 9: ch4 coturn Allocate fail → handshake_ok=false ─────────────────────
# Simulates 486 / dead allocator: turnutils_uclient exits non-zero.
T9=$(mktemp -d)
trap 'rm -rf "$T9"' EXIT

make_bin "$T9"
mkdir -p "$T9/etc"
write_node_config "$T9/etc" '{"id":"ch4"}'

# docker stub: sed returns secret; turnutils_uclient fails (e.g. 486/timeout).
# Validates -y/-e present even in the failure path (argv shape still must be correct).
cat > "$T9/docker" <<'STUB'
#!/bin/bash
if [[ "$*" == *"sed"* && "$*" == *"static-auth-secret"* ]]; then
    echo "probe-test-secret"
    exit 0
fi
if [[ "$*" == *"turnutils_uclient"* ]]; then
    if [[ "$*" != *" -y"* && "$*" != *" -e "* ]]; then
        echo "STUB-ERROR: peerless turnutils_uclient (no -y/-e) — fails on real coturn" >&2
        exit 255
    fi
    exit 1
fi
exit 1
STUB
chmod +x "$T9/docker"

set +e
OUTPUT9=$(PATH="$T9:/usr/bin:/bin" \
    _NODE_CONFIG="$T9/etc/node-config.json" \
    _TOKEN_LIB=/nonexistent \
    OXPULSE_SERVICE_TOKEN="stkn_test" \
    bash "$SCRIPT" --dry-run 2>/dev/null)
set -e

if printf '%s\n' "$OUTPUT9" | jq -e 'select(.channel_name=="coturn" and .channel_handshake_ok==false)' >/dev/null 2>&1; then
    ok "test9: ch4 TURN Allocate fail → channel_name=coturn handshake_ok=false"
else
    fail "test9: expected coturn handshake_ok=false; got: $OUTPUT9"
fi

trap - EXIT
rm -rf "$T9"

# ── Test 10: ch4 STUN Binding fallback when secret unavailable ────────────────
T10=$(mktemp -d)
trap 'rm -rf "$T10"' EXIT

make_bin "$T10"
mkdir -p "$T10/etc"
write_node_config "$T10/etc" '{"id":"ch4"}'

# docker stub: awk returns empty (no secret); turnutils_stunclient succeeds
cat > "$T10/docker" <<'STUB'
#!/bin/bash
if [[ "$*" == *"sed"* && "$*" == *"static-auth-secret"* ]]; then
    # Return empty — secret unavailable
    echo ""
    exit 0
fi
if [[ "$*" == *"turnutils_stunclient"* ]]; then
    exit 0
fi
exit 1
STUB
chmod +x "$T10/docker"

set +e
OUTPUT10=$(PATH="$T10:/usr/bin:/bin" \
    _NODE_CONFIG="$T10/etc/node-config.json" \
    _TOKEN_LIB=/nonexistent \
    OXPULSE_SERVICE_TOKEN="stkn_test" \
    bash "$SCRIPT" --dry-run 2>/dev/null)
set -e

if printf '%s\n' "$OUTPUT10" | jq -e 'select(.channel_name=="coturn" and .channel_handshake_ok==true)' >/dev/null 2>&1; then
    ok "test10: ch4 STUN Binding fallback (no secret) → handshake_ok=true"
else
    fail "test10: expected coturn handshake_ok=true via STUN fallback; got: $OUTPUT10"
fi

trap - EXIT
rm -rf "$T10"

# ── Test 11: leak-resistance — base secret NEVER on HMAC argv (SEC-CR-001) ────
# This guards the property that was violated TWICE: the long-term
# static-auth-secret must NOT appear on the argv of whatever computes the HMAC
# (/proc/<pid>/cmdline is world-readable on the edge). We wrap the HMAC binary
# (python3, via OXPULSE_HMAC_BIN) with a stub that records its full argv, then
# assert the secret marker is absent from the recording. The stub still emits a
# valid base64 HMAC (delegating to the real python3) so the probe completes.
T11=$(mktemp -d)
trap 'rm -rf "$T11"' EXIT

make_bin "$T11"
mkdir -p "$T11/etc"
write_node_config "$T11/etc" '{"id":"ch4"}'

# A high-entropy secret marker that would be unmistakable if it leaked to argv.
LEAK_MARKER="SECRETLEAKMARKER_d41d8cd98f00b204e9800998"
ARGV_LOG="$T11/hmac_argv.log"
REAL_PYTHON3=$(command -v python3)

# docker stub: serve the secret marker; accept the uclient invocation.
cat > "$T11/docker" <<STUB
#!/bin/bash
if [[ "\$*" == *"sed"* && "\$*" == *"static-auth-secret"* ]]; then
    echo "$LEAK_MARKER"
    exit 0
fi
if [[ "\$*" == *"turnutils_uclient"* ]]; then
    if [[ "\$*" != *" -y"* && "\$*" != *" -e "* ]]; then
        echo "STUB-ERROR: peerless turnutils_uclient" >&2
        exit 255
    fi
    exit 0
fi
exit 1
STUB
chmod +x "$T11/docker"

# HMAC stub: record argv (NOT env) to a log, then delegate to the real python3
# so a valid credential is still produced. Recording argv mirrors exactly what
# /proc/<pid>/cmdline would expose to a co-resident attacker.
cat > "$T11/hmac_stub" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$ARGV_LOG"
exec "$REAL_PYTHON3" "\$@"
STUB
chmod +x "$T11/hmac_stub"

set +e
OUTPUT11=$(PATH="$T11:/usr/bin:/bin" \
    _NODE_CONFIG="$T11/etc/node-config.json" \
    _TOKEN_LIB=/nonexistent \
    OXPULSE_SERVICE_TOKEN="stkn_test" \
    OXPULSE_HMAC_BIN="$T11/hmac_stub" \
    bash "$SCRIPT" --dry-run 2>/dev/null)
set -e

# The HMAC binary MUST have been invoked (proves we exercised the real path,
# not the STUN fallback — a fallback would silently make this test vacuous).
if [[ -s "$ARGV_LOG" ]]; then
    ok "test11: HMAC binary invoked (allocate path, not STUN fallback)"
else
    fail "test11: HMAC argv log empty — probe did not run the HMAC path; output: $OUTPUT11"
fi

# CORE ASSERTION: the base secret must NOT be present in the recorded argv.
if grep -q "$LEAK_MARKER" "$ARGV_LOG"; then
    fail "test11: SECRET LEAK — base static-auth-secret found on HMAC argv: $(cat "$ARGV_LOG")"
else
    ok "test11: base secret NOT present on HMAC argv (no /proc/cmdline leak)"
fi

# The probe must still have produced a coturn payload (credential derivation worked).
if printf '%s\n' "$OUTPUT11" | jq -e 'select(.channel_name=="coturn")' >/dev/null 2>&1; then
    ok "test11: coturn payload still emitted (env-delivered secret produced a valid HMAC)"
else
    fail "test11: expected coturn payload; got: $OUTPUT11"
fi

# Sanity: the canonical use-auth-secret username form "<ts>:userid" (SEC-CR-002)
# must be the HMAC input — assert the recorded argv contains the colon-joined form.
if grep -qE ':[0-9]*healthprobe|[0-9]+:healthprobe' "$ARGV_LOG"; then
    ok "test11: HMAC input uses canonical <ts>:healthprobe username (SEC-CR-002)"
else
    fail "test11: expected <ts>:healthprobe username on HMAC argv; got: $(cat "$ARGV_LOG")"
fi

trap - EXIT
rm -rf "$T11"

# ── Test 12: ch4 probe targets the PUBLIC external-ip, NOT 127.0.0.1 ──────────
# Regression guard for the anti-SSRF-vs-loopback collision: the -y self-test
# relayed peer is reached via the server-address argument; pointing it at
# 127.0.0.1 trips denied-peer-ip=127.0.0.0-127.255.255.255 → timeout → false
# negative + leaked allocations (7-day RU media outage, edge-b 2026-06-11).
#
# NOTE on fixture IPs: stubs below use 203.0.113.77 (TEST-NET-3, RFC 5737) and
# elsewhere 198.51.100.9 (TEST-NET-2, RFC 5737) as placeholder "public" IPs.
# These are IANA documentation ranges — guaranteed non-routable and never owned
# by any real host — chosen ONLY to verify that the correct address is passed
# through to argv.  A real probe target MUST be outside all denied-peer-ip
# ranges in coturn.conf.tpl (RFC 1918, loopback, link-local, TEST-NET-*, etc.).
# The probe must resolve external-ip from the container config and pass THAT.
T12=$(mktemp -d)
trap 'rm -rf "$T12"' EXIT

make_bin "$T12"
mkdir -p "$T12/etc"
write_node_config "$T12/etc" '{"id":"ch4"}'

UCLIENT_ARGV_LOG="$T12/uclient_argv.log"

# docker stub: serve secret + external-ip; record uclient argv; succeed.
cat > "$T12/docker" <<STUB
#!/bin/bash
if [[ "\$*" == *"sed"* && "\$*" == *"static-auth-secret"* ]]; then
    echo "probe-test-secret"; exit 0
fi
if [[ "\$*" == *"sed"* && "\$*" == *"external-ip"* ]]; then
    echo "203.0.113.77"; exit 0
fi
if [[ "\$*" == *"turnutils_uclient"* ]]; then
    printf '%s\n' "\$*" >> "$UCLIENT_ARGV_LOG"
    exit 0
fi
exit 1
STUB
chmod +x "$T12/docker"

set +e
OUTPUT12=$(PATH="$T12:/usr/bin:/bin" \
    _NODE_CONFIG="$T12/etc/node-config.json" \
    _TOKEN_LIB=/nonexistent \
    OXPULSE_SERVICE_TOKEN="stkn_test" \
    bash "$SCRIPT" --dry-run 2>/dev/null)
set -e

if grep -q '203.0.113.77' "$UCLIENT_ARGV_LOG" 2>/dev/null; then
    ok "test12: uclient targets the public external-ip (203.0.113.77)"
else
    fail "test12: uclient did not target the external-ip; argv: $(cat "$UCLIENT_ARGV_LOG" 2>/dev/null); payload: $OUTPUT12"
fi
# CORE REGRESSION GUARD: must NOT target loopback when a public target resolves.
if grep -q '127.0.0.1' "$UCLIENT_ARGV_LOG" 2>/dev/null; then
    fail "test12: REGRESSION — uclient targeted 127.0.0.1 (anti-SSRF denial); argv: $(cat "$UCLIENT_ARGV_LOG")"
else
    ok "test12: uclient does NOT target 127.0.0.1 (anti-SSRF collision avoided)"
fi

trap - EXIT
rm -rf "$T12"

# ── Test 13: OXPULSE_COTURN_PROBE_TARGET env override wins ─────────────────────
T13=$(mktemp -d)
trap 'rm -rf "$T13"' EXIT

make_bin "$T13"
mkdir -p "$T13/etc"
write_node_config "$T13/etc" '{"id":"ch4"}'

UCLIENT_ARGV_LOG13="$T13/uclient_argv.log"
cat > "$T13/docker" <<STUB
#!/bin/bash
if [[ "\$*" == *"sed"* && "\$*" == *"static-auth-secret"* ]]; then
    echo "probe-test-secret"; exit 0
fi
if [[ "\$*" == *"sed"* && "\$*" == *"external-ip"* ]]; then
    echo "203.0.113.77"; exit 0
fi
if [[ "\$*" == *"turnutils_uclient"* ]]; then
    printf '%s\n' "\$*" >> "$UCLIENT_ARGV_LOG13"; exit 0
fi
exit 1
STUB
chmod +x "$T13/docker"

set +e
PATH="$T13:/usr/bin:/bin" \
    _NODE_CONFIG="$T13/etc/node-config.json" \
    _TOKEN_LIB=/nonexistent \
    OXPULSE_SERVICE_TOKEN="stkn_test" \
    OXPULSE_COTURN_PROBE_TARGET="198.51.100.9" \
    bash "$SCRIPT" --dry-run >/dev/null 2>&1
set -e

if grep -q '198.51.100.9' "$UCLIENT_ARGV_LOG13" 2>/dev/null \
   && ! grep -q '203.0.113.77' "$UCLIENT_ARGV_LOG13" 2>/dev/null; then
    ok "test13: OXPULSE_COTURN_PROBE_TARGET overrides external-ip"
else
    fail "test13: env override not honoured; argv: $(cat "$UCLIENT_ARGV_LOG13" 2>/dev/null)"
fi

trap - EXIT
rm -rf "$T13"

# ── Test 14: NAT external-ip "public/private" strips to the public part ───────
T14=$(mktemp -d)
trap 'rm -rf "$T14"' EXIT

make_bin "$T14"
mkdir -p "$T14/etc"
write_node_config "$T14/etc" '{"id":"ch4"}'

UCLIENT_ARGV_LOG14="$T14/uclient_argv.log"
cat > "$T14/docker" <<STUB
#!/bin/bash
if [[ "\$*" == *"sed"* && "\$*" == *"static-auth-secret"* ]]; then
    echo "probe-test-secret"; exit 0
fi
if [[ "\$*" == *"sed"* && "\$*" == *"external-ip"* ]]; then
    # NAT form: install.sh renders "public/private" behind NAT.
    echo "203.0.113.77/10.0.0.5"; exit 0
fi
if [[ "\$*" == *"turnutils_uclient"* ]]; then
    printf '%s\n' "\$*" >> "$UCLIENT_ARGV_LOG14"; exit 0
fi
exit 1
STUB
chmod +x "$T14/docker"

set +e
PATH="$T14:/usr/bin:/bin" \
    _NODE_CONFIG="$T14/etc/node-config.json" \
    _TOKEN_LIB=/nonexistent \
    OXPULSE_SERVICE_TOKEN="stkn_test" \
    bash "$SCRIPT" --dry-run >/dev/null 2>&1
set -e

if grep -q '203.0.113.77' "$UCLIENT_ARGV_LOG14" 2>/dev/null \
   && ! grep -q '10.0.0.5' "$UCLIENT_ARGV_LOG14" 2>/dev/null; then
    ok "test14: NAT external-ip strips /private → public part only"
else
    fail "test14: NAT strip failed; argv: $(cat "$UCLIENT_ARGV_LOG14" 2>/dev/null)"
fi

trap - EXIT
rm -rf "$T14"

# ── Test 15: timeout-killed probe (exit 124) → channel_probe_reason="timeout" ─
# The false-negative class must carry its cause to the central server so an
# opaque handshake_ok=false is no longer indistinguishable from a real failure.
T15=$(mktemp -d)
trap 'rm -rf "$T15"' EXIT

make_bin "$T15"
mkdir -p "$T15/etc"
write_node_config "$T15/etc" '{"id":"ch4"}'

# docker stub: secret + external-ip OK; uclient simulates a timeout-kill (124).
cat > "$T15/docker" <<'STUB'
#!/bin/bash
if [[ "$*" == *"sed"* && "$*" == *"static-auth-secret"* ]]; then
    echo "probe-test-secret"; exit 0
fi
if [[ "$*" == *"sed"* && "$*" == *"external-ip"* ]]; then
    echo "203.0.113.77"; exit 0
fi
if [[ "$*" == *"turnutils_uclient"* ]]; then
    exit 124   # timeout(1) SIGTERM exit code
fi
exit 1
STUB
chmod +x "$T15/docker"

set +e
OUTPUT15=$(PATH="$T15:/usr/bin:/bin" \
    _NODE_CONFIG="$T15/etc/node-config.json" \
    _TOKEN_LIB=/nonexistent \
    OXPULSE_SERVICE_TOKEN="stkn_test" \
    bash "$SCRIPT" --dry-run 2>/dev/null)
set -e

if printf '%s\n' "$OUTPUT15" | jq -e 'select(.channel_name=="coturn" and .channel_handshake_ok==false and .channel_probe_reason=="timeout")' >/dev/null 2>&1; then
    ok "test15: timeout-killed probe → handshake_ok=false + channel_probe_reason=timeout"
else
    fail "test15: expected channel_probe_reason=timeout on exit 124; got: $OUTPUT15"
fi

trap - EXIT
rm -rf "$T15"

# ── Test 16: all probe-target sources absent → loopback-fallback, exit 0 ──────
# Regression guard for the case where OXPULSE_COTURN_PROBE_TARGET is unset,
# the container has no external-ip line, and node-config.json has no public_ip.
# The script MUST still exit 0 (degraded operation, not crash), the ch4 payload
# must be valid JSON, and COTURN_PROBE_TARGET_SOURCE must be "loopback-fallback"
# in the state file.  The probe itself times out (127.0.0.1 denied by
# denied-peer-ip / no-loopback-peers), so channel_probe_reason must be
# "loopback-fallback" in the payload — distinguishable from a real dead relay.
T16=$(mktemp -d)
trap 'rm -rf "$T16"' EXIT

make_bin "$T16"
mkdir -p "$T16/etc" "$T16/var/lib/oxpulse-partner-edge"

# node-config: only id, NO public_ip field.
printf '{"node_id":"test-node","channels":[{"id":"ch4"}]}\n' > "$T16/etc/node-config.json"

# docker stub: no external-ip line (sed returns empty); secret OK;
# uclient exits 124 (simulated timeout — the loopback target would be
# denied-peer-ip'd on real coturn, causing this same exit).
cat > "$T16/docker" <<'STUB'
#!/bin/bash
if [[ "$*" == *"sed"* && "$*" == *"static-auth-secret"* ]]; then
    echo "probe-test-secret"; exit 0
fi
if [[ "$*" == *"sed"* && "$*" == *"external-ip"* ]]; then
    # No external-ip line — simulate missing config.
    exit 0
fi
if [[ "$*" == *"turnutils_uclient"* ]]; then
    # Simulate timeout-kill (anti-SSRF loopback denial exits 124).
    exit 124
fi
exit 1
STUB
chmod +x "$T16/docker"

STATE_DIR16="$T16/var/lib/oxpulse-partner-edge"
set +e
OUTPUT16=$(PATH="$T16:/usr/bin:/bin" \
    _NODE_CONFIG="$T16/etc/node-config.json" \
    _TOKEN_LIB=/nonexistent \
    OXPULSE_SERVICE_TOKEN="stkn_test" \
    STATE_DIR="$STATE_DIR16" \
    bash "$SCRIPT" --dry-run 2>/dev/null)
EXIT16=$?
set -e

# 16a: script exits 0 (degraded but not crashed)
if [[ "$EXIT16" -eq 0 ]]; then
    ok "test16a: all-sources-fail → script exits 0 (degraded, not crash)"
else
    fail "test16a: all-sources-fail → unexpected exit $EXIT16"
fi

# 16b: ch4 payload is valid JSON
if printf '%s\n' "$OUTPUT16" | jq -e 'select(.channel_name=="coturn")' >/dev/null 2>&1; then
    ok "test16b: all-sources-fail → ch4 payload is valid JSON"
else
    fail "test16b: all-sources-fail → ch4 payload not valid JSON; got: $OUTPUT16"
fi

# 16c: state file records COTURN_PROBE_TARGET_SOURCE=loopback-fallback
STATE_FILE16="$STATE_DIR16/coturn-probe-mode.env"
if grep -q 'COTURN_PROBE_TARGET_SOURCE=loopback-fallback' "$STATE_FILE16" 2>/dev/null; then
    ok "test16c: all-sources-fail → state file records COTURN_PROBE_TARGET_SOURCE=loopback-fallback"
else
    fail "test16c: all-sources-fail → COTURN_PROBE_TARGET_SOURCE!=loopback-fallback; state: $(cat "$STATE_FILE16" 2>/dev/null)"
fi

# 16d: payload channel_probe_reason=loopback-fallback (distinguishable from dead relay)
if printf '%s\n' "$OUTPUT16" | jq -e 'select(.channel_name=="coturn" and .channel_probe_reason=="loopback-fallback")' >/dev/null 2>&1; then
    ok "test16d: all-sources-fail → channel_probe_reason=loopback-fallback in payload"
else
    fail "test16d: all-sources-fail → expected channel_probe_reason=loopback-fallback; got: $OUTPUT16"
fi

trap - EXIT
rm -rf "$T16"


# ── Test 17: ch2 real end-to-end tunnel (AWG mesh -> backend :8907/api/health)
# Regression guard for the ping-only blind spot: probe_ch2 no longer does a
# bare ICMP ping to the AWG "motherly" peer (which only proves the WireGuard
# handshake is up, nothing about whether routed DATA reaches the backend). It
# now curls the backend's /api/health directly through awg0, at
# OXPULSE_AWG_MOTHERLY_IP:OXPULSE_BACKEND_PORT -- reusing the SAME two config
# vars Caddyfile.tpl's own tunnel_upstream failover group already reads
# (config/defaults.conf).
T17=$(mktemp -d)
trap 'rm -rf "$T17"' EXIT

make_bin "$T17"
mkdir -p "$T17/etc"
write_node_config "$T17/etc" '{"id":"ch2"}'

CH2_ARGV_LOG="$T17/ch2_curl_argv.log"
cat > "$T17/curl" <<STUB
#!/bin/bash
for a in "\$@"; do
    case "\$a" in
        *:8907/api/health*)
            printf '%s\n' "\$*" >> "$CH2_ARGV_LOG"
            printf '200'; exit 0 ;;
    esac
done
printf '200'
exit 0
STUB
chmod +x "$T17/curl"

set +e
OUTPUT17=$(PATH="$T17:/usr/bin:/bin" \
    _NODE_CONFIG="$T17/etc/node-config.json" \
    _TOKEN_LIB=/nonexistent \
    OXPULSE_SERVICE_TOKEN="stkn_test" \
    bash "$SCRIPT" --dry-run 2>/dev/null)
set -e

if printf '%s\n' "$OUTPUT17" | jq -e 'select(.channel_name=="ch2" and .channel_handshake_ok==true)' >/dev/null 2>&1; then
    ok "test17: ch2 real tunnel reachable -> handshake_ok=true"
else
    fail "test17: expected ch2 handshake_ok=true; got: $OUTPUT17"
fi

if printf '%s\n' "$OUTPUT17" | jq -e 'select(.channel_name=="ch2") | has("channel_rtt_ms")' >/dev/null 2>&1; then
    ok "test17: ch2 payload NOW carries channel_rtt_ms (never emitted by the ping-based probe it replaces)"
else
    fail "test17: ch2 payload missing channel_rtt_ms; got: $OUTPUT17"
fi

if grep -q '10\.9\.0\.2:8907' "$CH2_ARGV_LOG" 2>/dev/null; then
    ok "test17: ch2 dials the default AWG motherly IP:port (10.9.0.2:8907)"
else
    fail "test17: ch2 did not dial 10.9.0.2:8907; argv log: $(cat "$CH2_ARGV_LOG" 2>/dev/null)"
fi

trap - EXIT
rm -rf "$T17"

# ── Test 18: ch2 honours OXPULSE_AWG_MOTHERLY_IP / OXPULSE_BACKEND_PORT overrides
T18=$(mktemp -d)
trap 'rm -rf "$T18"' EXIT

make_bin "$T18"
mkdir -p "$T18/etc"
write_node_config "$T18/etc" '{"id":"ch2"}'

CH2_ARGV_LOG18="$T18/ch2_curl_argv.log"
cat > "$T18/curl" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$CH2_ARGV_LOG18"
printf '200'
exit 0
STUB
chmod +x "$T18/curl"

set +e
PATH="$T18:/usr/bin:/bin" \
    _NODE_CONFIG="$T18/etc/node-config.json" \
    _TOKEN_LIB=/nonexistent \
    OXPULSE_SERVICE_TOKEN="stkn_test" \
    OXPULSE_AWG_MOTHERLY_IP="198.51.100.9" \
    OXPULSE_BACKEND_PORT="9917" \
    bash "$SCRIPT" --dry-run >/dev/null 2>&1
set -e

if grep -q '198\.51\.100\.9:9917' "$CH2_ARGV_LOG18" 2>/dev/null; then
    ok "test18: ch2 honours OXPULSE_AWG_MOTHERLY_IP + OXPULSE_BACKEND_PORT overrides"
else
    fail "test18: override not honoured; argv: $(cat "$CH2_ARGV_LOG18" 2>/dev/null)"
fi

trap - EXIT
rm -rf "$T18"

# ── Test 19: ch2 real tunnel unreachable -> handshake_ok=false ───────────────
T19=$(mktemp -d)
trap 'rm -rf "$T19"' EXIT

make_bin "$T19"
mkdir -p "$T19/etc"
write_node_config "$T19/etc" '{"id":"ch2"}'

cat > "$T19/curl" <<'STUB'
#!/bin/bash
for a in "$@"; do
    case "$a" in
        *:8907/api/health*) printf '000'; exit 0 ;;
    esac
done
printf '200'
exit 0
STUB
chmod +x "$T19/curl"

set +e
OUTPUT19=$(PATH="$T19:/usr/bin:/bin" \
    _NODE_CONFIG="$T19/etc/node-config.json" \
    _TOKEN_LIB=/nonexistent \
    OXPULSE_SERVICE_TOKEN="stkn_test" \
    bash "$SCRIPT" --dry-run 2>/dev/null)
set -e

if printf '%s\n' "$OUTPUT19" | jq -e 'select(.channel_name=="ch2" and .channel_handshake_ok==false)' >/dev/null 2>&1; then
    ok "test19: ch2 unreachable real tunnel (awg0 up, backend not reachable) -> handshake_ok=false"
else
    fail "test19: expected ch2 handshake_ok=false; got: $OUTPUT19"
fi

trap - EXIT
rm -rf "$T19"

# ── Test 20: ch1/ch2/ch3 all pass --max-time, honouring OXPULSE_CHANNEL_PROBE_TIMEOUT
T20=$(mktemp -d)
trap 'rm -rf "$T20"' EXIT

make_bin "$T20"
mkdir -p "$T20/etc"
write_node_config "$T20/etc" '{"id":"ch1"},{"id":"ch2"},{"id":"ch3"}'

ARGV_LOG20="$T20/curl_argv.log"
cat > "$T20/curl" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$ARGV_LOG20"
printf '200'
exit 0
STUB
chmod +x "$T20/curl"

set +e
PATH="$T20:/usr/bin:/bin" \
    _NODE_CONFIG="$T20/etc/node-config.json" \
    _TOKEN_LIB=/nonexistent \
    OXPULSE_SERVICE_TOKEN="stkn_test" \
    OXPULSE_CHANNEL_PROBE_TIMEOUT="7" \
    bash "$SCRIPT" --dry-run >/dev/null 2>&1
set -e

# All three probe curl invocations must carry --max-time 7 (OXPULSE_CHANNEL_PROBE_TIMEOUT, their hard timeout).
MAXTIME_COUNT=$(grep -c -- '--max-time 7' "$ARGV_LOG20" 2>/dev/null || true)
[[ -n "$MAXTIME_COUNT" ]] || MAXTIME_COUNT=0
if [[ "$MAXTIME_COUNT" -eq 3 ]]; then
    ok "test20: ch1/ch2/ch3 all pass --max-time 7 (OXPULSE_CHANNEL_PROBE_TIMEOUT honoured, exactly 3 calls)"
else
    fail "test20: expected exactly 3 curl calls with --max-time 7, got $MAXTIME_COUNT; argv: $(cat "$ARGV_LOG20" 2>/dev/null)"
fi

trap - EXIT
rm -rf "$T20"

# ── Test 21: ch1/ch2/ch3 run CONCURRENTLY -- total wall time bounded by the
#    SLOWEST probe, not the SUM of all three (the core "run concurrently"
#    requirement). Each probe's curl call sleeps 2s before responding; a
#    serial implementation would take ~6s+, a concurrent one ~2s.
T21=$(mktemp -d)
trap 'rm -rf "$T21"' EXIT

make_bin "$T21"
mkdir -p "$T21/etc"
write_node_config "$T21/etc" '{"id":"ch1"},{"id":"ch2"},{"id":"ch3"}'

# curl stub: sleep 2s ONLY for the three probe URLs (canary/tunnel,
# :8907/api/health, :18443/api/health) -- NOT for the POST endpoint, so the
# measurement isolates the PROBE phase specifically.
cat > "$T21/curl" <<'STUB'
#!/bin/bash
for a in "$@"; do
    case "$a" in
        *canary/tunnel*|*:8907/api/health*|*:18443/api/health*)
            sleep 2
            ;;
    esac
done
printf '200'
exit 0
STUB
chmod +x "$T21/curl"

START21=$(date +%s)
set +e
OUTPUT21=$(PATH="$T21:/usr/bin:/bin" \
    _NODE_CONFIG="$T21/etc/node-config.json" \
    _TOKEN_LIB=/nonexistent \
    OXPULSE_SERVICE_TOKEN="stkn_test" \
    bash "$SCRIPT" --dry-run 2>/dev/null)
set -e
END21=$(date +%s)
ELAPSED21=$((END21 - START21))

# Concurrent: ~2s (all three sleep in parallel). Serial would be ~6s+.
if [[ "$ELAPSED21" -le 5 ]]; then
    ok "test21: ch1/ch2/ch3 probed CONCURRENTLY -- total wall time ${ELAPSED21}s (bounded by slowest probe, not the sum)"
else
    fail "test21: REGRESSION -- probes ran serially (took ${ELAPSED21}s, expected <=5s for 3 concurrent 2s probes)"
fi

# Correctness: all three channels still present despite each being individually slow.
COUNT21=$(printf '%s\n' "$OUTPUT21" | grep -c '"channel_name"' 2>/dev/null || true)
[[ -n "$COUNT21" ]] || COUNT21=0
if [[ "$COUNT21" -eq 3 ]]; then
    ok "test21: all 3 channels still reported despite each probe being individually slow"
else
    fail "test21: expected 3 channel entries, got $COUNT21; output: $OUTPUT21"
fi

trap - EXIT
rm -rf "$T21"

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
