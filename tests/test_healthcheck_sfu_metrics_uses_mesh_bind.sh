#!/usr/bin/env bats
# tests/test_healthcheck_sfu_metrics_uses_mesh_bind.sh
#
# Regression guard for Bug #7 (2026-05-28 ruoxp fresh install v0.12.71):
# healthcheck.sh check #12 ("SFU /metrics → 200") probed 127.0.0.1:9317
# instead of SFU_METRICS_BIND from compose file. On post-#288 edges the SFU
# metrics socket is mesh-only (10.9.0.x), so 127.0.0.1 → connection refused.
#
# Tests:
#   1. Compose file has SFU_METRICS_BIND: "10.9.0.7"
#      → check #12 probes http://10.9.0.7:9317/metrics (not 127.0.0.1)
#   2. Compose file has no SFU_METRICS_BIND entry
#      → check #12 falls back to http://127.0.0.1:9317/metrics
#   3. Compose file has SFU_METRICS_BIND: "10.9.0.7/24" (CIDR)
#      → check #12 strips mask, probes http://10.9.0.7:9317/metrics
#
# Bats <1.5 compat: no bats_require_minimum_version, no `run !`.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    HC="$REPO_ROOT/healthcheck.sh"

    TMPD="$(mktemp -d)"
    CONF_DIR="$TMPD/cfg"
    mkdir -p "$CONF_DIR" "$TMPD/state" "$TMPD/bin"

    CURL_LOG="$TMPD/curl.log"

    # Stub binaries — docker, ss, openssl, timeout, stat: exit 0.
    for _bin in docker ss openssl timeout; do
        printf '#!/bin/bash\nexit 0\n' > "$TMPD/bin/$_bin"
        chmod +x "$TMPD/bin/$_bin"
    done
    # stat stub: always returns 600 (satisfies check 17 token mode).
    printf '#!/bin/bash\necho 600\n' > "$TMPD/bin/stat"
    chmod +x "$TMPD/bin/stat"
}

teardown() {
    rm -rf "$TMPD"
}

# Write a compose file with an optional SFU_METRICS_BIND line.
_write_compose() {
    local bind_line="$1"  # pass empty string to omit
    {
        echo 'services:'
        echo '  sfu:'
        echo '    environment:'
        if [[ -n "$bind_line" ]]; then
            echo "      $bind_line"
        fi
        echo '      SFU_METRICS_PORT: "9317"'
    } > "$CONF_DIR/docker-compose.yml"
}

# Write a curl stub that:
#   - logs its positional args (joined by space) to $CURL_LOG
#   - emits "200" if called with %{http_code} format arg, else exits 0.
_stub_curl_recording() {
    cat > "$TMPD/bin/curl" << 'EOF'
#!/bin/bash
echo "$*" >> "$CURL_LOG"
for a; do
    [[ "$a" == "%{http_code}" ]] && { printf '200'; exit 0; }
done
exit 0
EOF
    # Inject CURL_LOG path from outer scope via env var baked into stub.
    sed -i "s|\"\$CURL_LOG\"|\"${CURL_LOG}\"|g" "$TMPD/bin/curl"
    chmod +x "$TMPD/bin/curl"
}

_run_hc() {
    run env \
        PATH="$TMPD/bin:$PATH" \
        OXPULSE_EDGE_CONFIG_DIR="$CONF_DIR" \
        OXPULSE_EDGE_STATE_DIR="$TMPD/state" \
        bash "$HC" 2>&1
}

# ── 1. mesh_bind_from_compose ─────────────────────────────────────────────────
@test "mesh_bind_from_compose: SFU_METRICS_BIND=10.9.0.7 → probe uses mesh IP" {
    _write_compose 'SFU_METRICS_BIND: "10.9.0.7"'
    _stub_curl_recording
    _run_hc

    # grep the curl log for the metrics call
    grep -q 'http://10.9.0.7:9317/metrics' "$CURL_LOG" || {
        echo "Expected curl to probe http://10.9.0.7:9317/metrics"
        echo "curl log: $(cat "$CURL_LOG" 2>/dev/null || echo '<empty>')"
        false
    }
    # Must NOT probe 127.0.0.1 for /metrics
    grep -v 'canary' "$CURL_LOG" | grep -v 'api/' | grep -q '127.0.0.1:9317/metrics' && {
        echo "curl probed 127.0.0.1:9317/metrics — fallback kicked in unexpectedly"
        echo "curl log: $(cat "$CURL_LOG")"
        false
    } || true
    # Check #12 must be OK in output
    [[ "$output" == *"SFU /metrics"*"OK"* ]] || {
        echo "check #12 did not show OK; output: $output"; false
    }
}

# ── 2. fallback_when_bind_missing ────────────────────────────────────────────
@test "fallback_when_bind_missing: no SFU_METRICS_BIND → probe falls back to 127.0.0.1" {
    _write_compose ''  # no SFU_METRICS_BIND
    _stub_curl_recording
    _run_hc

    grep -q 'http://127.0.0.1:9317/metrics' "$CURL_LOG" || {
        echo "Expected fallback probe to http://127.0.0.1:9317/metrics"
        echo "curl log: $(cat "$CURL_LOG" 2>/dev/null || echo '<empty>')"
        false
    }
}

# ── 3. cidr_stripped ─────────────────────────────────────────────────────────
@test "cidr_stripped: SFU_METRICS_BIND=10.9.0.7/24 → mask stripped, probe uses 10.9.0.7" {
    _write_compose 'SFU_METRICS_BIND: "10.9.0.7/24"'
    _stub_curl_recording
    _run_hc

    grep -q 'http://10.9.0.7:9317/metrics' "$CURL_LOG" || {
        echo "Expected curl to probe http://10.9.0.7:9317/metrics (CIDR stripped)"
        echo "curl log: $(cat "$CURL_LOG" 2>/dev/null || echo '<empty>')"
        false
    }
    # Must NOT contain the raw CIDR in URL
    grep -q 'http://10.9.0.7/24:9317' "$CURL_LOG" && {
        echo "CIDR was not stripped from probe URL"
        false
    } || true
}
