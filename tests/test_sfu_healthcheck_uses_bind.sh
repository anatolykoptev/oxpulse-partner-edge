#!/bin/bash
# Regression guard for Bug #4 (2026-05-28 ruoxp fresh install):
# SFU metrics and relay-API listeners bind on the AWG mesh IP (SFU_METRICS_BIND /
# SFU_RELAY_API_BIND = AWG_ALLOCATED_IP), NOT on 0.0.0.0. The docker-compose
# healthcheck was probing 127.0.0.1 for those two planes -> connection refused ->
# container marked unhealthy -> false positive operator alarm.
#
# Test 1: compose template has NO bare 127.0.0.1 for the metrics probe.
# Test 2: compose template metrics probe uses {{AWG_ALLOCATED_IP}} placeholder.
# Test 3: compose template relay-API probe uses {{AWG_ALLOCATED_IP}} placeholder.
# Test 4: client_ws probe stays on 127.0.0.1 (SFU_BIND_ADDRESS is 0.0.0.0).
# Test 5: rendered compose (sed substitution) probes the literal mesh IP, not 127.0.0.1.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TPL="$REPO_ROOT/docker-compose.yml.tpl"

FAIL=0
pass() { echo "OK: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }

# Isolate the SFU healthcheck test: line from the template.
HC_LINE=$(grep -A1 'healthcheck:' "$TPL" \
    | awk '/wget.*metrics/{found=1} found{print; exit}')

if [[ -z "$HC_LINE" ]]; then
    fail "SFU healthcheck test: line not found in $TPL"
    exit 1
fi

# Test 1: metrics probe must NOT use bare 127.0.0.1:port for /metrics
echo "==> Test 1: metrics probe does not hardcode 127.0.0.1 for /metrics"
if echo "$HC_LINE" | grep -qF '127.0.0.1:{{SFU_METRICS_PORT}}'; then
    fail "metrics probe still hardcodes 127.0.0.1:{{SFU_METRICS_PORT}} -- fix not applied"
else
    pass "metrics probe does not contain 127.0.0.1:{{SFU_METRICS_PORT}}"
fi

# Test 2: metrics probe must use {{AWG_ALLOCATED_IP}} placeholder
echo "==> Test 2: metrics probe uses {{AWG_ALLOCATED_IP}} placeholder"
if echo "$HC_LINE" | grep -qF '{{AWG_ALLOCATED_IP}}:{{SFU_METRICS_PORT}}'; then
    pass "metrics probe uses {{AWG_ALLOCATED_IP}}:{{SFU_METRICS_PORT}}"
else
    fail "metrics probe does not use {{AWG_ALLOCATED_IP}}:{{SFU_METRICS_PORT}}"
fi

# Test 3: relay-API probe must use {{AWG_ALLOCATED_IP}} (not 127.0.0.1).
# Pattern: extract the relay-API nc segment specifically (after RELAY_JWT_SECRET gate).
# Use grep -oE to capture just the relay nc clause to avoid false match on client_ws.
echo "==> Test 3: relay-API probe uses {{AWG_ALLOCATED_IP}} (not 127.0.0.1)"
RELAY_CLAUSE=$(echo "$HC_LINE" | grep -oE 'RELAY_JWT_SECRET[^;]+' || true)
if echo "$RELAY_CLAUSE" | grep -qF '127.0.0.1'; then
    fail "relay-API probe still hardcodes 127.0.0.1 -- fix not applied"
elif echo "$RELAY_CLAUSE" | grep -qF '{{AWG_ALLOCATED_IP}}'; then
    pass "relay-API probe uses {{AWG_ALLOCATED_IP}}"
else
    fail "relay-API probe: neither 127.0.0.1 nor {{AWG_ALLOCATED_IP}} found -- unexpected format"
fi

# Test 4: client_ws probe MUST stay on 127.0.0.1 (SFU_BIND_ADDRESS is 0.0.0.0)
echo "==> Test 4: client_ws probe stays on 127.0.0.1 (SFU_BIND_ADDRESS=0.0.0.0)"
CLIENT_WS_CLAUSE=$(echo "$HC_LINE" | grep -oE 'SIGNALING_SFU_SECRET[^;]+' || true)
if echo "$CLIENT_WS_CLAUSE" | grep -qF '127.0.0.1'; then
    pass "client_ws probe uses 127.0.0.1 (correct: binds on 0.0.0.0)"
else
    fail "client_ws probe no longer uses 127.0.0.1 -- was it accidentally moved to mesh IP?"
fi

# Test 5: rendered compose substitutes literal IP (simulated via sed)
echo "==> Test 5: rendered compose has literal mesh IP in healthcheck"
RENDERED=$(sed \
    -e 's|{{AWG_ALLOCATED_IP}}|10.9.0.7|g' \
    -e 's|{{SFU_METRICS_PORT}}|9317|g' \
    "$TPL")
HC_RENDERED=$(echo "$RENDERED" | grep -A1 'healthcheck:' \
    | awk '/wget.*metrics/{found=1} found{print; exit}')

if echo "$HC_RENDERED" | grep -qF 'http://10.9.0.7:9317/metrics'; then
    pass "rendered metrics probe = http://10.9.0.7:9317/metrics"
else
    fail "rendered metrics probe does not contain http://10.9.0.7:9317/metrics"
fi
if echo "$HC_RENDERED" | grep -qF 'nc -z 10.9.0.7'; then
    pass "rendered relay-API probe = nc -z 10.9.0.7"
else
    fail "rendered relay-API probe does not contain literal 10.9.0.7"
fi
if echo "$HC_RENDERED" | grep -qF '127.0.0.1:9317'; then
    fail "rendered output still has 127.0.0.1:9317 -- metrics fix not applied"
fi

# Result
if [[ "$FAIL" -ne 0 ]]; then
    echo "FAIL: SFU healthcheck bind address fix not fully applied"
    exit 1
fi
echo "PASS: SFU healthcheck probes mesh IP (AWG_ALLOCATED_IP) for metrics and relay-API"
