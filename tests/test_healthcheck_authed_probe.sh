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
    printf '#!/bin/bash\nfor a; do [[ "$a" == "%%{http_code}" ]] && { printf '"'"'%s'"'"' "%s"; exit 0; }; done; exit 0\n' \
        "$code" > "$TMPD/bin/curl"
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

# ── 4. probe_accepts_503_as_auth_ok ──────────────────────────────────────────
@test "probe_accepts_503_as_auth_ok: backend returns 503 → OK (auth ok, unconfigured)" {
    printf 'stkn_valid_503_token' > "$CONF_DIR/token"
    chmod 600 "$CONF_DIR/token"
    _stub_curl 503
    _run_hc

    [[ "$output" == *"service-token authed probe"* ]] || {
        echo "check 19 label not found"; false
    }
    [[ "$output" == *"auth accepted"* ]] || {
        echo "expected 'auth accepted' for 503, got: $output"; false
    }
    [[ "$output" != *"FAIL (HTTP 503"* ]] || {
        echo "check 19 incorrectly FAILed on 503"; false
    }
}
