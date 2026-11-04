#!/usr/bin/env bats
# tests/test_healthcheck_authed_probe.sh
#
# Exercises check 19 ("service-token authed probe → 2xx") from healthcheck.sh.
#
# Strategy: run healthcheck.sh with a minimal CONF_DIR and a PATH-shadowing curl
# stub that returns the desired HTTP code. Checks 1-18 fail in the stub env;
# we only assert on check 19 output and overall exit status.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    HC="$REPO_ROOT/healthcheck.sh"

    TMPD="$(mktemp -d)"
    CONF_DIR="$TMPD/cfg"
    mkdir -p "$CONF_DIR" "$TMPD/state" "$TMPD/bin"

    # Minimal compose file so healthcheck.sh passes the early -r guard.
    cat > "$CONF_DIR/docker-compose.yml" <<'EOF'
services:
  caddy: {}
EOF

    # Stub binaries — docker, ss, openssl, timeout: exit 0.
    for _bin in docker ss openssl timeout; do
        printf '#!/bin/bash\nexit 0\n' > "$TMPD/bin/$_bin"
        chmod +x "$TMPD/bin/$_bin"
    done

    # stat stub always returns 600 (satisfies check 17 token mode).
    printf '#!/bin/bash\necho 600\n' > "$TMPD/bin/stat"
    chmod +x "$TMPD/bin/stat"
}

teardown() {
    rm -rf "$TMPD"
}

# Write a curl stub that emits the given code when the -w flag is present.
# The code is baked into the script at write time using printf (no heredoc
# interpolation surprises).
_stub_curl() {
    local code="$1"
    printf '#!/bin/bash\necho "$*" >> "%s/curl.args"\nfor a; do [[ "$a" == "%%{http_code}" ]] && { printf '"'"'%%s'"'"' "%s"; exit 0; }; done; exit 0\n' \
        "$TMPD" "$code" > "$TMPD/bin/curl"
    chmod +x "$TMPD/bin/curl"
}

_run_hc() {
    run env \
        PATH="$TMPD/bin:$PATH" \
        OXPULSE_EDGE_CONFIG_DIR="$CONF_DIR" \
        OXPULSE_EDGE_STATE_DIR="$TMPD/state" \
        bash "$HC" 2>&1
}

# ── 1. probe_ok_with_valid_token ─────────────────────────────────────────────
@test "probe_ok_with_valid_token: backend returns 200 → check passes" {
    printf 'stkn_valid_test_token' > "$CONF_DIR/token"
    chmod 600 "$CONF_DIR/token"
    _stub_curl 200
    _run_hc

    [[ "$output" == *"service-token authed probe"* ]] || {
        echo "check 19 label not found"; false
    }
    [[ "$output" == *"auth accepted"* ]] || {
        echo "expected 'auth accepted', got: $output"; false
    }
    [[ "$output" != *"FAIL (HTTP 200"* ]] || {
        echo "check 19 incorrectly FAILed on 200"; false
    }
}

# ── 2. probe_skips_on_legacy_node ────────────────────────────────────────────
@test "probe_skips_on_legacy_node: no file + no env → INFO + pass" {
    rm -f "$CONF_DIR/token"
    unset OXPULSE_SERVICE_TOKEN 2>/dev/null || true
    _stub_curl 200
    _run_hc

    [[ "$output" == *"legacy node"* ]] || {
        echo "expected 'legacy node' INFO, got: $output"; false
    }
    [[ "$output" == *"no service token persisted"* ]] || {
        echo "expected skip message, got: $output"; false
    }
}

# ── 3. probe_fails_on_401 ────────────────────────────────────────────────────
@test "probe_fails_on_401: backend returns 401 → FAIL with recovery hint" {
    printf 'stkn_revoked_token' > "$CONF_DIR/token"
    chmod 600 "$CONF_DIR/token"
    _stub_curl 401
    _run_hc

    [[ "$output" == *"FAIL"* ]] || {
        echo "expected FAIL in output: $output"; false
    }
    [[ "$output" == *"rotate-service-token"* ]] || {
        echo "recovery hint missing: $output"; false
    }
    [[ "$output" == *"/etc/oxpulse-partner-edge/token"* ]] || {
        echo "token path missing in recovery hint: $output"; false
    }
    # FAIL counter was incremented → overall exit > 0.
    [ "$status" -ne 0 ] || {
        echo "expected non-zero exit on 401; status=$status"; false
    }
}

# ── 4. probe_rejects_503 ─────────────────────────────────────────────────────
# The probe used to hit /api/partner/hy2-credentials, where 503 meant "auth
# accepted, hysteria2 unconfigured". It now hits /api/partner/node-config (the
# CH3-independent endpoint the edge's own refetch uses), where a 503 is just a
# backend that is not answering: the check is "2xx", so it must FAIL.
@test "probe_rejects_503: node-config returning 503 is not an auth success" {
    printf 'stkn_valid_503_token' > "$CONF_DIR/token"
    chmod 600 "$CONF_DIR/token"
    _stub_curl 503
    _run_hc

    [[ "$output" == *"(HTTP 503 "* ]] && [[ "$output" == *"token rejected or endpoint unreachable"* ]] || {
        echo "expected check 19 to FAIL on 503, got: $output"; false
    }
    [[ "$output" != *"auth accepted"* ]] || {
        echo "503 wrongly reported as auth accepted: $output"; false
    }
}

# ── 5. probe_targets_node_config_not_hy2 ─────────────────────────────────────
@test "probe_targets_node_config_not_hy2: token probe hits /api/partner/node-config only" {
    printf 'stkn_valid_test_token' > "$CONF_DIR/token"
    chmod 600 "$CONF_DIR/token"
    printf '{"node_id":"node-xyz"}' > "$CONF_DIR/node-config.json"
    _stub_curl 200
    _run_hc

    [ -s "$TMPD/curl.args" ] || { echo "curl was never called"; false; }
    grep -q '/api/partner/node-config' "$TMPD/curl.args" || {
        echo "probe did not hit node-config: $(cat "$TMPD/curl.args")"; false
    }
    ! grep -q 'hy2-credentials' "$TMPD/curl.args" || {
        echo "probe still hits the CH3 credentials endpoint: $(cat "$TMPD/curl.args")"; false
    }
    grep -q 'X-Node-Id: node-xyz' "$TMPD/curl.args" || {
        echo "X-Node-Id header not sent: $(cat "$TMPD/curl.args")"; false
    }
}
