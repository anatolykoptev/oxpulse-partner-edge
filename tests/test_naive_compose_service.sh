#!/usr/bin/env bash
# Phase 5.10 Task 7 — verify naive compose service:
#   1. RENDERED when NAIVE_SERVER set
#   2. STRIPPED when NAIVE_SERVER unset (via compose_strip_failed_channels)
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

pass() { echo "OK: $*"; }
fail() { echo "FAIL: $*"; exit 1; }

# Require python3 + yaml (needed by compose_strip_failed_channels).
python3 -c "import yaml" 2>/dev/null \
    || fail "python3 yaml module not available — install python3-yaml"

# Render {{VAR}} placeholders via sed (mirrors opec substitution in tests).
_render_tpl() {
    local tpl=$1 out=$2
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
        "$tpl" > "$out"
}

# ---------------------------------------------------------------------------
# Case 1: NAIVE_SERVER set → naive service block present in rendered template
# ---------------------------------------------------------------------------
TMP1=$(mktemp /tmp/compose-naive-XXXXXX.yml)
TMP2=$(mktemp /tmp/compose-naive-strip-XXXXXX.yml)
trap 'rm -f "$TMP1" "$TMP2"' EXIT

_render_tpl "$REPO_ROOT/docker-compose.yml.tpl" "$TMP1"

grep -qE '^[[:space:]]{2}naive:' "$TMP1" \
    || fail "case 1: 'naive:' service key missing when NAIVE_SERVER set"
pass "case 1: 'naive:' service key present"

grep -qE 'container_name:[[:space:]]*oxpulse-partner-naive' "$TMP1" \
    || fail "case 1: container_name missing"
pass "case 1: container_name: oxpulse-partner-naive"

grep -qE 'ghcr\.io/anatolykoptev/partner-edge-naive:' "$TMP1" \
    || fail "case 1: image ref missing"
pass "case 1: image ref present"

grep -qE '127\.0\.0\.1:1080:1080' "$TMP1" \
    || fail "case 1: SOCKS port not bound to 127.0.0.1"
pass "case 1: SOCKS port bound to 127.0.0.1:1080:1080"

grep -qE '/etc/oxpulse-partner-edge/naive-client\.json:/etc/naive/config\.json' "$TMP1" \
    || fail "case 1: config volume mount missing"
pass "case 1: config volume mount present"

# ---------------------------------------------------------------------------
# Case 2: NAIVE_SERVER unset → compose_strip_failed_channels removes 'naive' block
# ---------------------------------------------------------------------------
cp "$TMP1" "$TMP2"

# Source the lib and invoke strip with empty NAIVE_SERVER.
NAIVE_SERVER="" bash --noprofile --norc -c '
    set -euo pipefail
    source "'"$REPO_ROOT"'/lib/render-channel-lib.sh"
    # With no extra failed channels; function must auto-add "naive" when NAIVE_SERVER unset
    compose_strip_failed_channels "'"$TMP2"'"
'

if grep -qE '^[[:space:]]{2}naive:' "$TMP2"; then
    fail "case 2: naive service still present after strip (NAIVE_SERVER unset)"
fi
pass "case 2: naive service stripped when NAIVE_SERVER unset"

echo "ALL NAIVE COMPOSE TESTS PASS"
