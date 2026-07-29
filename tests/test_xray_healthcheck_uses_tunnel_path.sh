#!/bin/bash
# tests/test_xray_healthcheck_uses_tunnel_path.sh
#
# Direct assertion against the SHIPPED template (docker-compose.yml.tpl) that
# the xray-client healthcheck probes the real tunnel path, not a bound port.
#
# Why a direct assertion against the shipped template is needed:
#   tests/fixtures/install-render/compose.tpl is a FROZEN COPY of an older
#   template, used by test_hydrate_render_identical.sh and
#   crates/opec/tests/render_compose.rs to verify the RENDER ALGORITHM
#   (render_template / opec render compose) produces byte-identical output
#   to a frozen baseline — NOT to verify the template's content. That copy
#   has already drifted (missing the 14-line rationale block, env_file,
#   SFU_LOCAL_IP, the naive service, etc.). Both render-identity tests
#   render that copy, so deleting the entire docker-compose.yml.tpl hunk
#   would leave every render-identity test green. This test closes that gap
#   by asserting directly against $REPO_ROOT/docker-compose.yml.tpl.
#
# Why a fixture-sync check is NOT worth it:
#   The fixture is a deliberately frozen snapshot for render-identity testing.
#   A sync check (diff docker-compose.yml.tpl tests/fixtures/install-render/compose.tpl)
#   would fail immediately — the fixture is ~100 lines behind the shipped
#   template by design (it freezes the render algorithm's input, not the
#   template's evolution). Adding a sync check would conflate two different
#   test concerns (render algorithm stability vs. template content) and break
#   on every template evolution, providing no useful signal. The direct
#   assertion against the shipped template (this file) is the right guard for
#   template content; the render-identity tests remain the right guard for
#   render algorithm stability.
#
# Pattern: same as tests/test_sfu_healthcheck_uses_bind.sh:39-40 — grep
# directly against $REPO_ROOT/docker-compose.yml.tpl. Nine existing tests
# already use this pattern (test_sfu_bind_strip_cidr.sh, test_sfu_compose.sh,
# test_compose_profiles_gating.sh, test_compose_volumes.sh, etc.).
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TPL="$REPO_ROOT/docker-compose.yml.tpl"

FAIL=0
pass() { echo "OK: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }

[[ -f "$TPL" ]] || { echo "FAIL: docker-compose.yml.tpl not found at $TPL"; exit 1; }

# Isolate the xray-client healthcheck test: line from the template.
# The xray healthcheck is the one that references :3080 (the dokodemo-door).
HC_LINE=$(grep -A1 'healthcheck:' "$TPL" \
    | awk '/3080/{found=1} found{print; exit}')

if [[ -z "$HC_LINE" ]]; then
    fail "xray healthcheck test: line not found in $TPL"
    exit 1
fi

# Test 1: xray healthcheck must probe /api/health/live through :3080.
echo "==> Test 1: xray healthcheck probes /api/health/live through :3080"
if echo "$HC_LINE" | grep -F 'http://127.0.0.1:3080/api/health/live' >/dev/null; then
    pass "xray healthcheck probes http://127.0.0.1:3080/api/health/live"
else
    fail "xray healthcheck does not probe /api/health/live through :3080: $HC_LINE"
fi

# Test 2: xray healthcheck must NOT use ss -ltn (the old bound-port probe).
echo "==> Test 2: xray healthcheck does not use ss -ltn (bound-port probe)"
if echo "$HC_LINE" | grep -F 'ss -ltn' >/dev/null; then
    fail "xray healthcheck still uses ss -ltn (bound-port probe, not tunnel path): $HC_LINE"
else
    pass "xray healthcheck does not contain ss -ltn"
fi

# Test 3: the healthcheck test: line must use wget (the real probe), not
# ss/grep (the old bound-port check). Comments may mention ss -ltn in prose
# (explaining why it was replaced) — this test scopes to the test: line only.
echo "==> Test 3: xray healthcheck test: line uses wget, not ss/grep"
if echo "$HC_LINE" | grep -F 'wget' >/dev/null; then
    pass "xray healthcheck test: line uses wget"
else
    fail "xray healthcheck test: line does not use wget: $HC_LINE"
fi

# Result
if [[ "$FAIL" -ne 0 ]]; then
    echo "FAIL: xray healthcheck tunnel-path invariant violated"
    exit 1
fi
echo "PASS: xray healthcheck probes the tunnel path (/api/health/live through :3080), not a bound port"
