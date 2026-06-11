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
# negative + leaked allocations (7-day RU media outage, zvonilka 2026-06-11).
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
