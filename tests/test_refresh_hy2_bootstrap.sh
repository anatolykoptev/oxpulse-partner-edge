#!/usr/bin/env bats
# tests/test_refresh_hy2_bootstrap.sh — CH3 self-bootstrap logic in refresh.sh.
#
# Covers:
#   1. hy2_config_exists: restart path taken, bootstrap NOT invoked
#   2. hy2_config_absent + HYSTERIA2_SERVER set: enable-hy2 invoked with --server
#   3. hy2_config_absent + HYSTERIA2_SERVER empty: both paths skipped (no-op)
#   4. hy2_config_absent + HYSTERIA2_SERVER set + enable-hy2 missing: warn, continue
#
# Bats <1.5 compat: no bats_require_minimum_version, no `run !`.
# Tests extract the hy2 branch logic and exercise it directly.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    REFRESH="$REPO_ROOT/oxpulse-partner-edge-refresh.sh"
    TMP="$(mktemp -d)"

    PREFIX_ETC="$TMP/etc"
    PREFIX_LIB="$TMP/lib"
    PREFIX_SBIN="$TMP/sbin"
    mkdir -p "$PREFIX_ETC" "$PREFIX_LIB" "$PREFIX_SBIN"

    # Minimal node-config.json — hysteria2_server populated
    printf '{"node_id":"test-node","hysteria2_server":"test-server:443"}\n' \
        > "$PREFIX_ETC/node-config.json"

    # Sentinel paths — hardcoded into the stub at setup time
    ENABLE_HY2_CALLED="$TMP/enable_hy2_called"
    ENABLE_HY2_ARGS="$TMP/enable_hy2_args"

    # Stub enable-hy2: writes sentinel with hardcoded path (not env-dependent)
    cat > "$PREFIX_SBIN/oxpulse-partner-edge-enable-hy2" <<STUB
#!/usr/bin/env bash
touch "${ENABLE_HY2_CALLED}"
printf '%s\n' "\$*" > "${ENABLE_HY2_ARGS}"
exit 0
STUB
    chmod +x "$PREFIX_SBIN/oxpulse-partner-edge-enable-hy2"

    # Stub compose file
    touch "$PREFIX_ETC/docker-compose.yml"

    # Log file
    LOG_FILE="$TMP/refresh.log"
}

teardown() {
    rm -rf "$TMP"
}

# ── Structural gate: refresh.sh contains the bootstrap elif branch ─────────
@test "refresh.sh contains hy2 bootstrap elif branch" {
    grep -q 'elif.*_hy2_server' "$REFRESH"
}

@test "refresh.sh reads hysteria2_server from NODE_CFG via jq" {
    grep -q 'hysteria2_server.*NODE_CFG\|NODE_CFG.*hysteria2_server\|jq.*hysteria2_server' "$REFRESH"
}

@test "refresh.sh bootstrap path references oxpulse-partner-edge-enable-hy2 and --server" {
    # Script name and --server are on adjacent lines; check both exist in the bootstrap block
    local block
    block=$(awk '/elif.*_hy2_server/,/unset _hy2_server/' "$REFRESH")
    printf '%s\n' "$block" | grep -q 'oxpulse-partner-edge-enable-hy2'
    printf '%s\n' "$block" | grep -q -- '--server'
}

@test "refresh.sh bootstrap failure is non-fatal (WARNING, not die)" {
    # The bootstrap failure path must log WARNING, NOT call die
    local block
    block=$(awk '/elif.*_hy2_server/,/unset _hy2_server/' "$REFRESH")
    printf '%s\n' "$block" | grep -q 'WARNING'
    # Verify die() is not called in bootstrap path
    local die_calls
    die_calls=$(printf '%s\n' "$block" | grep -c '^\s*die ' 2>/dev/null || true)
    [ "$die_calls" -eq 0 ]
}

# ── Test helper ─────────────────────────────────────────────────────────────
# _run_hy2_block: exercises the hy2 branch logic in a controlled subshell.
# Arguments:
#   $1 — "exists" | "absent"   (whether hysteria2-client.yaml exists)
#   $2 — server value or ""    (content for node-config hysteria2_server)
#   $3 — "present" | "missing" (whether enable-hy2 stub is executable)
_run_hy2_block() {
    local yaml_state="$1" server_val="$2" enable_state="$3"

    # Write node-config with or without hysteria2_server
    if [[ -n "$server_val" ]]; then
        printf '{"node_id":"test-node","hysteria2_server":"%s"}\n' "$server_val" \
            > "$PREFIX_ETC/node-config.json"
    else
        printf '{"node_id":"test-node"}\n' > "$PREFIX_ETC/node-config.json"
    fi

    # Create or remove the yaml config file
    if [[ "$yaml_state" == "exists" ]]; then
        touch "$PREFIX_ETC/hysteria2-client.yaml"
    else
        rm -f "$PREFIX_ETC/hysteria2-client.yaml"
    fi

    # Make enable-hy2 present or absent
    if [[ "$enable_state" == "missing" ]]; then
        rm -f "$PREFIX_SBIN/oxpulse-partner-edge-enable-hy2"
    fi

    # Reproduce the hy2 block verbatim.
    # All paths are embedded via shell expansion at call time.
    bash -c "
        set -euo pipefail
        PREFIX_ETC='$PREFIX_ETC'
        PREFIX_LIB='$PREFIX_LIB'
        PREFIX_SBIN='$PREFIX_SBIN'
        NODE_CFG='$PREFIX_ETC/node-config.json'
        LOG_FILE='$LOG_FILE'

        log()  { printf '%s %s\n' \"\$(date -Iseconds)\" \"\$*\" | tee -a \"\$LOG_FILE\"; }

        # Stub _restart_if_changed: writes a sentinel
        _restart_if_changed() {
            touch '$TMP/restart_called'
            log '  [surgical] hysteria2 restart path'
        }

        _hy2_server=\$(jq -r '.hysteria2_server // empty' \"\$NODE_CFG\" 2>/dev/null || true)
        if [[ -f \"\${PREFIX_ETC}/hysteria2-client.yaml\" ]]; then
            _restart_if_changed hysteria2 \\
                \"\${PREFIX_ETC}/hysteria2-client.yaml\" \\
                \"\${PREFIX_LIB}/hysteria2-config.sha\" \\
                '$PREFIX_ETC/docker-compose.yml' \\
                oxpulse-partner-hysteria2
        elif [[ -n \"\${_hy2_server:-}\" ]]; then
            log \"  hy2 channel: bootstrap (node-config has hysteria2_server=\${_hy2_server}; local config absent)\"
            if [[ -x \"\${PREFIX_SBIN:-/usr/local/sbin}/oxpulse-partner-edge-enable-hy2\" ]]; then
                \"\${PREFIX_SBIN:-/usr/local/sbin}/oxpulse-partner-edge-enable-hy2\" \\
                    --server \"\$_hy2_server\" \\
                    2>&1 | sed 's/^/    [enable-hy2] /' || \\
                    log 'WARNING: hy2 bootstrap failed (non-fatal); next channels_version tick will retry'
            else
                log 'WARNING: hy2 bootstrap requested but enable-hy2 not installed at \${PREFIX_SBIN:-/usr/local/sbin}/oxpulse-partner-edge-enable-hy2 — run upgrade.sh --host-scripts-only'
            fi
        fi
        unset _hy2_server
    " 2>&1
}

# ── Test 1: config exists → restart path, bootstrap NOT called ─────────────
@test "hy2_config_exists__refresh_restart_if_changed_path" {
    _run_hy2_block "exists" "test-server:443" "present"

    # Restart sentinel must exist
    [ -f "$TMP/restart_called" ]
    # Bootstrap sentinel must NOT exist
    run ls "$ENABLE_HY2_CALLED" 2>/dev/null
    [ "$status" -ne 0 ]
}

# ── Test 2: config absent + server set → bootstrap invoked with --server ───
@test "hy2_config_absent_hysteria2_server_set__bootstrap_invoked" {
    _run_hy2_block "absent" "test:443" "present"

    # enable-hy2 sentinel must exist
    [ -f "$ENABLE_HY2_CALLED" ]

    # enable-hy2 must have been called with --server test:443
    run cat "$ENABLE_HY2_ARGS"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -q -- '--server test:443'

    # Restart path must NOT have been taken
    run ls "$TMP/restart_called" 2>/dev/null
    [ "$status" -ne 0 ]
}

# ── Test 3: config absent + server empty → no-op ───────────────────────────
@test "hy2_config_absent_hysteria2_server_empty__skip" {
    _run_hy2_block "absent" "" "present"

    # Neither bootstrap nor restart path taken
    run ls "$ENABLE_HY2_CALLED" 2>/dev/null
    [ "$status" -ne 0 ]

    run ls "$TMP/restart_called" 2>/dev/null
    [ "$status" -ne 0 ]
}

# ── Test 4: config absent + server set + enable-hy2 missing → warn, continue
@test "hy2_config_absent_enable_hy2_missing__warn_continue" {
    local output
    output=$(_run_hy2_block "absent" "test:443" "missing")
    local exit_code=$?

    # refresh must continue (exit 0)
    [ "$exit_code" -eq 0 ]

    # Must log the upgrade.sh hint
    printf '%s\n' "$output" | grep -q 'upgrade.sh'

    # enable-hy2 sentinel must NOT exist (it was never called)
    run ls "$ENABLE_HY2_CALLED" 2>/dev/null
    [ "$status" -ne 0 ]
}
