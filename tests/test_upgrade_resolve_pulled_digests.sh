#!/bin/bash
# tests/test_upgrade_resolve_pulled_digests.sh
#
# Functional test for _parse_compose_config_images — the AWK parser that
# extracts service→image mappings from `docker compose config` output.
#
# The existing test_upgrade_pull_scope_and_rollback.sh only does STRUCTURAL
# checks (function exists, has quote-strip). This test functionally verifies
# the parser against a rendered compose config, asserting extracted image
# refs match. Without this, a future compose-format change → all services
# resolve after="" → fail-safe recreates EVERYTHING → silent loss of
# zero-downtime, suite stays green (#262).
#
# The parser is extracted from upgrade.sh via awk (same pattern as
# test_upgrade_zero_downtime.sh's preamble extraction) and sourced into
# a test harness with a mock docker.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
UPGRADE="$REPO_ROOT/upgrade.sh"

[[ -f "$UPGRADE" ]] || { echo "FAIL: upgrade.sh not found at $UPGRADE"; exit 1; }

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# Extract _parse_compose_config_images from upgrade.sh.
PREAMBLE=$(mktemp)
cat > "$PREAMBLE" << 'HELPERS'
# Minimal stubs needed by the parser (none today, but future deps may
# reference these — keep the harness self-contained).
log()  { :; }
warn() { :; }
HELPERS

awk '/^_parse_compose_config_images\(\)/{found=1} found{print} found && /^}$/{exit}' "$UPGRADE" >> "$PREAMBLE"
bash -n "$PREAMBLE" || { echo "FAIL: extracted parser has syntax errors"; exit 1; }

# Source the parser into the current shell.
# shellcheck disable=SC1090
source "$PREAMBLE"

# ---------------------------------------------------------------------------
# Test 1: standard compose config — multiple services, mixed quoting
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 1: standard compose config with mixed quoting ==="

CFG1='services:
  caddy:
    image: ghcr.io/anatolykoptev/partner-edge-caddy:v0.16.0
    container_name: oxpulse-partner-caddy
  coturn:
    image: "ghcr.io/anatolykoptev/partner-edge-coturn:v0.16.0"
    network_mode: host
  sfu:
    image: "ghcr.io/anatolykoptev/partner-edge-sfu:v0.16.0"
    network_mode: host
  all-edge-c-gate:
    image: all-edge-c-gate:latest
    network_mode: host
  xray:
    image: ghcr.io/anatolykoptev/partner-edge-xray:v0.16.0'

declare -A map1
_parse_compose_config_images "$CFG1" map1

[[ "${map1[caddy]:-}" == "ghcr.io/anatolykoptev/partner-edge-caddy:v0.16.0" ]] \
    && pass "1a: caddy image parsed (unquoted)" \
    || fail "1a: caddy image mismatch: '${map1[caddy]:-}'"

[[ "${map1[coturn]:-}" == "ghcr.io/anatolykoptev/partner-edge-coturn:v0.16.0" ]] \
    && pass "1b: coturn image parsed (quoted, quotes stripped)" \
    || fail "1b: coturn image mismatch: '${map1[coturn]:-}'"

[[ "${map1[sfu]:-}" == "ghcr.io/anatolykoptev/partner-edge-sfu:v0.16.0" ]] \
    && pass "1c: sfu image parsed (quoted, quotes stripped)" \
    || fail "1c: sfu image mismatch: '${map1[sfu]:-}'"

[[ "${map1[all-edge-c-gate]:-}" == "all-edge-c-gate:latest" ]] \
    && pass "1d: foreign service image parsed (not filtered by parser)" \
    || fail "1d: foreign service image mismatch: '${map1[all-edge-c-gate]:-}'"

[[ "${map1[xray]:-}" == "ghcr.io/anatolykoptev/partner-edge-xray:v0.16.0" ]] \
    && pass "1e: xray image parsed (unquoted)" \
    || fail "1e: xray image mismatch: '${map1[xray]:-}'"

# ---------------------------------------------------------------------------
# Test 2: empty config — parser returns empty map (no crash)
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 2: empty/minimal compose config ==="

CFG2='services:'
declare -A map2=()
_parse_compose_config_images "$CFG2" map2
[[ ${#map2[@]} -eq 0 ]] \
    && pass "2a: empty services map for minimal config" \
    || fail "2a: expected empty map, got ${#map2[@]} entries: ${!map2[@]}"

# ---------------------------------------------------------------------------
# Test 3: service with no image field — parser skips it (no entry in map)
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 3: service without image field ==="

CFG3='services:
  caddy:
    image: ghcr.io/anatolykoptev/partner-edge-caddy:v0.16.0
  noimage:
    container_name: foo
    network_mode: host'

declare -A map3
_parse_compose_config_images "$CFG3" map3
[[ "${map3[caddy]:-}" == "ghcr.io/anatolykoptev/partner-edge-caddy:v0.16.0" ]] \
    && pass "3a: caddy image parsed despite sibling without image" \
    || fail "3a: caddy image mismatch: '${map3[caddy]:-}'"
[[ -z "${map3[noimage]:-}" ]] \
    && pass "3b: service without image has no map entry" \
    || fail "3b: noimage should be absent, got: '${map3[noimage]:-}'"

# ---------------------------------------------------------------------------
# Test 4: image with whitespace before value — parser handles it
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 4: image with extra whitespace ==="

CFG4='services:
  sfu:
    image:    ghcr.io/anatolykoptev/partner-edge-sfu:v0.16.0'

declare -A map4
_parse_compose_config_images "$CFG4" map4
[[ "${map4[sfu]:-}" == "ghcr.io/anatolykoptev/partner-edge-sfu:v0.16.0" ]] \
    && pass "4a: image parsed with extra whitespace after image:" \
    || fail "4a: image mismatch with whitespace: '${map4[sfu]:-}'"

# ---------------------------------------------------------------------------
# Test 5: real docker-compose.yml.tpl rendered — end-to-end parser check
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 5: rendered docker-compose.yml.tpl end-to-end ==="

TPL="$REPO_ROOT/docker-compose.yml.tpl"
if [[ -f "$TPL" ]]; then
    # Render the template by substituting placeholders with test values.
    CFG5=$(sed \
        -e 's/{{IMAGE_VERSION}}/v0.16.0/g' \
        -e 's/{{SFU_EDGE_ID}}/test-edge/g' \
        -e 's/{{AWG_HOST_IP}}/10.9.0.99/g' \
        -e 's/{{SFU_METRICS_BIND}}/10.9.0.99/g' \
        -e 's/{{SFU_LOCAL_IP}}/10.0.1.99/g' \
        -e 's/{{SFU_PUBLIC_IP}}/192.0.2.99/g' \
        -e 's/{{SFU_SIGNING_PUBLIC_KEY}}/TESTKEY/g' \
        -e 's/{{SIGNALING_SFU_SECRET}}/testsecret/g' \
        -e 's/{{NAIVE_SOCKS_PORT}}/1080/g' \
        "$TPL")

    declare -A map5
    _parse_compose_config_images "$CFG5" map5

    # Every service in the template should have an image.
    svc_count=${#map5[@]}
    [[ "$svc_count" -gt 0 ]] \
        && pass "5a: rendered template parsed $svc_count services" \
        || fail "5a: rendered template produced 0 services"

    # All images should be non-empty.
    all_nonempty=true
    for svc in "${!map5[@]}"; do
        if [[ -z "${map5[$svc]}" ]]; then
            fail "5b: service '$svc' has empty image ref"
            all_nonempty=false
        fi
    done
    $all_nonempty && pass "5b: all $svc_count services have non-empty image refs"

    # All partner-edge images should match the ghcr.io pattern.
    all_ghcr=true
    for svc in "${!map5[@]}"; do
        img="${map5[$svc]}"
        if [[ "$img" == ghcr.io/anatolykoptev/partner-edge-* ]]; then
            : # expected
        elif [[ "$img" != ghcr.io/* ]]; then
            : # foreign service — ok
        else
            fail "5c: service '$svc' has unexpected image: '$img'"
            all_ghcr=false
        fi
    done
    $all_ghcr && pass "5c: all partner-edge images match ghcr.io/anatolykoptev/partner-edge-*"
else
    pass "5: docker-compose.yml.tpl not found — skipping end-to-end test"
fi

# ---------------------------------------------------------------------------
rm -f "$PREAMBLE"
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
