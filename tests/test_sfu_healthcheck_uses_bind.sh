#!/bin/bash
# Regression guard for Bug #4 (2026-05-28 edge-d fresh install):
# SFU metrics and relay-API listeners bind on the AWG mesh IP (SFU_METRICS_BIND /
# SFU_RELAY_API_BIND), NOT on 0.0.0.0. The docker-compose healthcheck was probing
# 127.0.0.1 for those two planes -> connection refused -> container marked
# unhealthy -> false positive operator alarm.
#
# 2026-07-08 RECONCILIATION (v0.14.5, PR1 of the installer/upgrade robustness
# arc): the Bug #4 fix above substituted the raw {{AWG_ALLOCATED_IP}} template
# placeholder directly into the healthcheck test: line. That placeholder
# INTENTIONALLY keeps its /CIDR suffix (e.g. 10.9.0.7/24 -- needed elsewhere
# for `ip addr add` / awg0.conf), which the environment: block does NOT use
# (it derives the CIDR-stripped {{AWG_HOST_IP}} instead -- see install.sh:744
# and tests/test_sfu_bind_strip_cidr.sh). Substituting the raw CIDR form into
# a wget URL / nc target broke the healthcheck AGAIN, silently, for 6+ days on
# production (edge-d, failingstreak=19471+) -- while this file's former
# Test 2/3/5 LOCKED IN the broken placeholder by grep-REQUIRING it.
#
# Those three assertions are RETIRED (removed below). The template now
# references the container's own ${SFU_METRICS_BIND}/${SFU_RELAY_API_BIND}
# runtime env vars -- the SAME CIDR-stripped source the environment: block
# already sets (see tpl:153-154) -- eliminating the whole class of "two
# independent placeholders that can drift" rather than swapping one drifted
# value for a fresher one.
#
# tests/test_sfu_bind_strip_cidr.sh is now the SINGLE owner of the invariant
# "healthcheck and environment: block trace to the same CIDR-stripped bind
# source; never a raw {{AWG_ALLOCATED_IP}}; never literal 127.0.0.1." This
# file keeps only the still-valid, orthogonal Bug #4 assertions: the
# metrics/relay-API probes must not regress to hardcoded 127.0.0.1 (mesh-only
# bind, loopback would always fail-closed), and client_ws must STAY on
# 127.0.0.1 (it binds on 0.0.0.0, unlike the other two planes).
#
# Test 1: compose template has NO bare 127.0.0.1 for the metrics probe.
# Test 4: client_ws probe stays on 127.0.0.1 (SFU_BIND_ADDRESS is 0.0.0.0).
# (Former Test 2, 3, 5 -- grep-required {{AWG_ALLOCATED_IP}} -- retired above.)
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

# Test 4: client_ws probe MUST stay on 127.0.0.1 (SFU_BIND_ADDRESS is 0.0.0.0)
echo "==> Test 4: client_ws probe stays on 127.0.0.1 (SFU_BIND_ADDRESS=0.0.0.0)"
CLIENT_WS_CLAUSE=$(echo "$HC_LINE" | grep -oE 'SIGNALING_SFU_SECRET[^;]+' || true)
if echo "$CLIENT_WS_CLAUSE" | grep -qF '127.0.0.1'; then
    pass "client_ws probe uses 127.0.0.1 (correct: binds on 0.0.0.0)"
else
    fail "client_ws probe no longer uses 127.0.0.1 -- was it accidentally moved to mesh IP?"
fi

# Result
if [[ "$FAIL" -ne 0 ]]; then
    echo "FAIL: SFU healthcheck bind address invariant violated"
    exit 1
fi
echo "PASS: SFU healthcheck client_ws stays loopback; metrics probe is not hardcoded loopback"
