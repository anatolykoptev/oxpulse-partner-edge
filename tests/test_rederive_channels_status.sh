#!/bin/bash
# tests/test_rederive_channels_status.sh — oxpulse-partner-edge#505
#
# Proves that channels-status.env is re-derived from live state on each
# refresh, not frozen at install time. The specific defect: a channel
# marked "skipped" at install (because HYSTERIA2_SERVER was empty then)
# that now has its inputs present + container running must become "active"
# after one re-derivation, and _channel_restart_if_changed must then act
# on it instead of skipping.
#
# Before/after structure:
#   BEFORE: hysteria2=skipped → _channel_restart_if_changed skips (no docker call)
#   REDERIVE: inputs present + container running → hysteria2 becomes active
#   AFTER:  hysteria2=active  → _channel_restart_if_changed acts (docker call made)
#
# Also verifies failed_at_* statuses are NOT promoted (sticky failures —
# "we tried and it broke" ≠ "we had nothing to try with").
set -uo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REFRESH="$REPO_ROOT/oxpulse-partner-edge-refresh.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

echo ""
echo "=== oxpulse-partner-edge#505: channels-status.env re-derivation ==="

# We test _rederive_channels_status + _channel_restart_if_changed by sourcing
# the refresh script's function definitions in a controlled environment with
# shims for docker / systemctl / jq. The refresh script has top-level code
# that runs on source (network calls, etc.), so we extract just the two
# functions via sed and source them in isolation — same pattern as
# test_refresh_surgical_restart.sh's inline logic extraction.

setup_env() {
    TMP="$(mktemp -d)"
    PREFIX_ETC="$TMP/etc"
    PREFIX_LIB="$TMP/lib"
    mkdir -p "$PREFIX_ETC" "$PREFIX_LIB"
    DOCKER_LOG="$TMP/docker.log"; : > "$DOCKER_LOG"

    # node-config with hysteria2_server + awg_ip present (inputs now available)
    cat > "$PREFIX_ETC/node-config.json" <<EOF
{"node_id":"test-node","hysteria2_server":"hy2.example.com:443","awg_ip":"10.9.0.4"}
EOF
    NODE_CFG="$PREFIX_ETC/node-config.json"

    # hysteria2 config file exists (rendered by enable-hy2 bootstrap)
    touch "$PREFIX_ETC/hysteria2-client.yaml"

    # docker shim: record calls, report container as running
    mkdir -p "$TMP/shims"
    cat > "$TMP/shims/docker" <<DOCKSHIM
#!/usr/bin/env bash
echo "docker \$*" >> "$DOCKER_LOG"
if [[ "\$1" == "inspect" ]]; then echo "true"; exit 0; fi
exit 0
DOCKSHIM
    chmod +x "$TMP/shims/docker"

    # systemctl shim: awg-quick@awg0 is active
    cat > "$TMP/shims/systemctl" <<SYSCTL
#!/usr/bin/env bash
if [[ "\$1" == "is-active" && "\$2" == "awg-quick@awg0" ]]; then
    echo "active"; exit 0
fi
echo "inactive"; exit 3
SYSCTL
    chmod +x "$TMP/shims/systemctl"

    # jq shim: return fields from the real node-config.json.
    # Unquoted heredoc so $NODE_CFG bakes in at write time (matches the
    # docker shim's $DOCKER_LOG pattern above).
    cat > "$TMP/shims/jq" <<JQSHIM
#!/usr/bin/env bash
# Minimal jq: handle the field extractions we need
case "\$*" in
  *hysteria2_server*) python3 -c "import json,sys; print(json.load(open('$NODE_CFG')).get('hysteria2_server',''))" 2>/dev/null || echo "" ;;
  *awg_ip*) python3 -c "import json,sys; print(json.load(open('$NODE_CFG')).get('awg_ip',''))" 2>/dev/null || echo "" ;;
  *) echo "" ;;
esac
JQSHIM
    chmod +x "$TMP/shims/jq"

    # log stub
    log() { :; }
    LOG_FILE="$TMP/refresh.log"
}

teardown_env() {
    rm -rf "$TMP"
}

# Extract the two functions from refresh.sh (they're self-contained once
# PREFIX_LIB/PREFIX_ETC/NODE_CFG/log are set in the environment).
extract_functions() {
    # Extract _channel_restart_if_changed + _rederive_channels_status + the
    # _docker_restart_if_sha_changed call (which we stub out).
    # We use sed to grab from _channel_restart_if_changed to the end of
    # _rederive_channels_status, then add a stub for _docker_restart_if_sha_changed.
    local _out="$TMP/funcs.sh"
    sed -n '/^_channel_restart_if_changed()/,/^}/p' "$REFRESH" > "$_out"
    sed -n '/^_rederive_channels_status()/,/^}/p' "$REFRESH" >> "$_out"
    # Stub: _docker_restart_if_sha_changed — record that it was called
    # (proves the gate did NOT skip), then succeed.
    cat >> "$_out" <<'STUB'
_docker_restart_if_sha_changed() {
    echo "GATE_PASSED: _docker_restart_if_sha_changed called for kind=$1"
}
STUB
    echo "$_out"
}

# ---------------------------------------------------------------------------
# 1. BEFORE: hysteria2=skipped → gate skips (no docker call)
# ---------------------------------------------------------------------------
t_before_skip() {
    setup_env
    # channels-status.env with hysteria2=skipped (install-time decision)
    cat > "$PREFIX_LIB/channels-status.env" <<EOF
xray=active
hysteria2=skipped
naive=skipped
awg=skipped
EOF

    local funcs; funcs=$(extract_functions)
    # shellcheck source=/dev/null
    source "$funcs"

    local out
    out=$(_channel_restart_if_changed hysteria2 \
        "$PREFIX_ETC/hysteria2-client.yaml" \
        "$PREFIX_LIB/hysteria2-config.sha" \
        "$PREFIX_ETC/docker-compose.yml" \
        hysteria2-client restart oxpulse-partner-hysteria2 2>&1)

    # The gate must SKIP — hysteria2=skipped, no GATE_PASSED in output
    if grep -q "GATE_PASSED" <<<"$out"; then
        fail "t_before_skip: gate should have skipped but _docker_restart_if_sha_changed was called"
    else
        pass "t_before_skip: hysteria2=skipped → gate skips (no docker call)"
    fi

    teardown_env
}

# ---------------------------------------------------------------------------
# 2. REDERIVE: inputs present + container running → hysteria2 becomes active
# ---------------------------------------------------------------------------
t_rederive_promotes() {
    setup_env
    cat > "$PREFIX_LIB/channels-status.env" <<EOF
xray=active
hysteria2=skipped
naive=skipped
awg=skipped
EOF

    local funcs; funcs=$(extract_functions)
    # shellcheck source=/dev/null
    source "$funcs"

    PATH="$TMP/shims:$PATH" _rederive_channels_status

    local hy2_status
    hy2_status=$(grep '^hysteria2=' "$PREFIX_LIB/channels-status.env" | cut -d= -f2)

    if [[ "$hy2_status" == "active" ]]; then
        pass "t_rederive_promotes: hysteria2 skipped → active (inputs+container present)"
    else
        fail "t_rederive_promotes: hysteria2 still '$hy2_status' after re-derive (expected active)"
    fi

    # Also check awg promoted (awg_ip present + awg0 active)
    local awg_status
    awg_status=$(grep '^awg=' "$PREFIX_LIB/channels-status.env" | cut -d= -f2)
    if [[ "$awg_status" == "active" ]]; then
        pass "t_rederive_promotes: awg skipped → active (awg_ip+awg0 present)"
    else
        fail "t_rederive_promotes: awg still '$awg_status' after re-derive (expected active)"
    fi

    # xray must remain active (not touched)
    local xray_status
    xray_status=$(grep '^xray=' "$PREFIX_LIB/channels-status.env" | cut -d= -f2)
    if [[ "$xray_status" == "active" ]]; then
        pass "t_rederive_promotes: xray stays active (untouched)"
    else
        fail "t_rederive_promotes: xray changed to '$xray_status' (expected active)"
    fi

    teardown_env
}

# ---------------------------------------------------------------------------
# 3. AFTER: hysteria2=active → gate acts (docker call made)
# ---------------------------------------------------------------------------
t_after_acts() {
    setup_env
    # Post-rederive state: hysteria2=active
    cat > "$PREFIX_LIB/channels-status.env" <<EOF
xray=active
hysteria2=active
naive=skipped
awg=active
EOF

    local funcs; funcs=$(extract_functions)
    # shellcheck source=/dev/null
    source "$funcs"

    local out
    out=$(_channel_restart_if_changed hysteria2 \
        "$PREFIX_ETC/hysteria2-client.yaml" \
        "$PREFIX_LIB/hysteria2-config.sha" \
        "$PREFIX_ETC/docker-compose.yml" \
        hysteria2-client restart oxpulse-partner-hysteria2 2>&1)

    if grep -q "GATE_PASSED" <<<"$out"; then
        pass "t_after_acts: hysteria2=active → gate passes (_docker_restart_if_sha_changed called)"
    else
        fail "t_after_acts: gate skipped even though hysteria2=active"
    fi

    teardown_env
}

# ---------------------------------------------------------------------------
# 4. failed_at_start is NOT promoted (sticky failures)
# ---------------------------------------------------------------------------
t_failed_sticky() {
    setup_env
    cat > "$PREFIX_LIB/channels-status.env" <<EOF
xray=active
hysteria2=failed_at_start
naive=skipped
awg=skipped
EOF

    local funcs; funcs=$(extract_functions)
    # shellcheck source=/dev/null
    source "$funcs"

    PATH="$TMP/shims:$PATH" _rederive_channels_status

    local hy2_status
    hy2_status=$(grep '^hysteria2=' "$PREFIX_LIB/channels-status.env" | cut -d= -f2)

    if [[ "$hy2_status" == "failed_at_start" ]]; then
        pass "t_failed_sticky: hysteria2=failed_at_start stays failed_at_start (not promoted to active)"
    else
        fail "t_failed_sticky: hysteria2 failed_at_start became '$hy2_status' (expected sticky)"
    fi

    teardown_env
}

# ---------------------------------------------------------------------------
# 5. skipped stays skipped when inputs absent (no false promotion)
# ---------------------------------------------------------------------------
t_skipped_stays_when_absent() {
    setup_env
    # node-config WITHOUT hysteria2_server
    cat > "$PREFIX_ETC/node-config.json" <<EOF
{"node_id":"test-node","awg_ip":"10.9.0.4"}
EOF
    NODE_CFG="$PREFIX_ETC/node-config.json"
    # Remove hy2 config file
    rm -f "$PREFIX_ETC/hysteria2-client.yaml"

    cat > "$PREFIX_LIB/channels-status.env" <<EOF
xray=active
hysteria2=skipped
naive=skipped
awg=skipped
EOF

    local funcs; funcs=$(extract_functions)
    # shellcheck source=/dev/null
    source "$funcs"

    PATH="$TMP/shims:$PATH" _rederive_channels_status

    local hy2_status
    hy2_status=$(grep '^hysteria2=' "$PREFIX_LIB/channels-status.env" | cut -d= -f2)

    if [[ "$hy2_status" == "skipped" ]]; then
        pass "t_skipped_stays_when_absent: hysteria2 stays skipped (inputs absent)"
    else
        fail "t_skipped_stays_when_absent: hysteria2 promoted to '$hy2_status' without inputs (false positive)"
    fi

    teardown_env
}

# ---------------------------------------------------------------------------
# 6. No re-derivation when no channels-status.env exists (fresh install)
# ---------------------------------------------------------------------------
t_no_file_noop() {
    setup_env
    # Don't create channels-status.env

    local funcs; funcs=$(extract_functions)
    # shellcheck source=/dev/null
    source "$funcs"

    PATH="$TMP/shims:$PATH" _rederive_channels_status 2>&1

    # Should not create the file, should not error
    if [[ ! -f "$PREFIX_LIB/channels-status.env" ]]; then
        pass "t_no_file_noop: no channels-status.env → noop (file not created)"
    else
        fail "t_no_file_noop: re-derive created channels-status.env (should not)"
    fi

    teardown_env
}

# Run all tests
t_before_skip
t_rederive_promotes
t_after_acts
t_failed_sticky
t_skipped_stays_when_absent
t_no_file_noop

echo ""
echo "=== rederive channels-status: PASS=$PASS FAIL=$FAIL ==="
[[ "$FAIL" -eq 0 ]]
