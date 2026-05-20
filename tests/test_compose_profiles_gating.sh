#!/usr/bin/env bash
# Bug O regression test: naive service must have profiles: [ch5] so docker compose
# doesn't start it (and auto-create naive-client.json as a dir) when not configured.
#
# Cases:
#   1. naive service has profiles: [ch5] in docker-compose.yml.tpl
#   2. docker compose config without COMPOSE_PROFILES does NOT include naive service
#   3. docker compose config with COMPOSE_PROFILES=ch5 DOES include naive service
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

pass() { echo "OK: $*"; }
fail() { echo "FAIL: $*"; exit 1; }

# ---------------------------------------------------------------------------
# Case 1: template declares profiles: [ch5] on the naive service
# ---------------------------------------------------------------------------
# Find the naive: service block in the template and check for profiles.
# We look for 'profiles:' within ~10 lines after the 'naive:' service key.
naive_block=$(awk '/^  naive:/{found=1} found{print; if(/^  [a-z]/ && !/^  naive:/) {found=0}}' \
    "$REPO_ROOT/docker-compose.yml.tpl")

if echo "$naive_block" | grep -qE 'profiles:.*\[.*ch5.*\]'; then
    pass "case 1: naive service has profiles: [ch5]"
else
    fail "case 1: naive service missing profiles: [ch5] in docker-compose.yml.tpl"
fi

# ---------------------------------------------------------------------------
# Require docker compose for cases 2 and 3
# ---------------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
    echo "SKIP cases 2-3: docker not available"
    echo "ALL COMPOSE PROFILES TESTS PASS (cases 2-3 skipped)"
    exit 0
fi

# Render the template with all placeholders substituted (mirrors opec substitution).
TPL=$(mktemp /tmp/compose-profiles-XXXXXX.yml)
trap 'rm -f "$TPL"' EXIT

sed \
    -e "s|{{IMAGE_VERSION}}|stable|g" \
    -e "s|{{NAIVE_SOCKS_PORT}}|1080|g" \
    -e "s|{{PARTNER_ID}}|test-partner|g" \
    -e "s|{{PARTNER_DOMAIN}}|test.example.com|g" \
    -e "s|{{BACKEND_ENDPOINT}}|https://api.example.com|g" \
    -e "s|{{TURN_SECRET}}|secret|g" \
    -e "s|{{REALITY_UUID}}|uuid|g" \
    -e "s|{{REALITY_PUBLIC_KEY}}|pubkey|g" \
    -e "s|{{REALITY_SHORT_ID}}|shortid|g" \
    -e "s|{{REALITY_SERVER_NAME}}|reality.example.com|g" \
    -e "s|{{PUBLIC_IP}}|1.2.3.4|g" \
    -e "s|{{PRIVATE_IP}}|10.0.0.1|g" \
    -e "s|{{SFU_UDP_PORT}}|40000|g" \
    -e "s|{{SFU_METRICS_PORT}}|9318|g" \
    -e "s|{{SFU_SIGNING_PUBLIC_KEY}}|sfupubkey|g" \
    -e "s|{{SFU_EDGE_ID}}|edge1|g" \
    -e "s|{{SIGNALING_SFU_SECRET}}|sfusecret|g" \
    -e "s|{{OTEL_EXPORTER_OTLP_ENDPOINT}}||g" \
    -e "s|{{RELAY_JWT_SECRET}}|relayjwt|g" \
    "$REPO_ROOT/docker-compose.yml.tpl" > "$TPL"

# ---------------------------------------------------------------------------
# Case 2: without COMPOSE_PROFILES, naive service must NOT appear in active config
# ---------------------------------------------------------------------------
config_no_profile=$(docker compose -f "$TPL" config 2>/dev/null)
if echo "$config_no_profile" | grep -qE 'container_name.*oxpulse-partner-naive|name.*oxpulse-partner-naive'; then
    fail "case 2: naive service present in docker compose config without COMPOSE_PROFILES — crashloop risk"
else
    pass "case 2: naive service absent from docker compose config without COMPOSE_PROFILES"
fi

# ---------------------------------------------------------------------------
# Case 3: with COMPOSE_PROFILES=ch5, naive service IS in active config
# ---------------------------------------------------------------------------
config_with_ch5=$(COMPOSE_PROFILES=ch5 docker compose -f "$TPL" config 2>/dev/null)
if echo "$config_with_ch5" | grep -qE 'container_name.*oxpulse-partner-naive|name.*oxpulse-partner-naive'; then
    pass "case 3: naive service present in docker compose config with COMPOSE_PROFILES=ch5"
else
    fail "case 3: naive service absent from docker compose config even with COMPOSE_PROFILES=ch5"
fi

echo "ALL COMPOSE PROFILES TESTS PASS"
