#!/bin/bash
# Golden-file test for Caddyfile.tpl rendering.
# Renders the template with fixed test inputs, runs both renders through
# `caddy adapt --pretty` to produce canonical JSON, and diffs against the
# stored golden JSON. Passes only when JSON output is byte-identical.
#
# Invariant: pure refactor (Phase 2 snippet extraction) must NOT alter the
# adapted JSON at all. Any future change that intentionally alters rendered
# output MUST regenerate the golden files (see regenerate block below).
#
# Regenerate:
#   REGEN=1 bash tests/test_caddyfile_golden.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$REPO_ROOT/tests/fixtures"
GOLDEN_JSON="$FIXTURES/caddyfile-golden-v0.13.0.json"
IMAGE="${CADDY_IMAGE:-ghcr.io/anatolykoptev/partner-edge-caddy:latest}"

PARTNER_DOMAIN="test.example"
TURNS_SUBDOMAIN="api-abc.test.example"

if ! docker info >/dev/null 2>&1; then
  echo "SKIP: docker daemon unreachable" >&2
  exit 0
fi

TMP_RENDERED=$(mktemp)
TMP_JSON=$(mktemp)
trap 'rm -f "$TMP_RENDERED" "$TMP_JSON"' EXIT

# Render template with test values (use infrastructure defaults for new vars)
AWG_MOTHERLY_IP_TEST="${AWG_MOTHERLY_IP_TEST:-10.9.0.2}"
BACKEND_PORT_TEST="${BACKEND_PORT_TEST:-8907}"
HY2_FALLBACK_HOST_TEST="${HY2_FALLBACK_HOST_TEST:-host.docker.internal}"
HY2_FALLBACK_PORT_TEST="${HY2_FALLBACK_PORT_TEST:-18443}"
sed \
  -e "s|{{PARTNER_DOMAIN}}|${PARTNER_DOMAIN}|g" \
  -e "s|{{TURNS_SUBDOMAIN}}|${TURNS_SUBDOMAIN}|g" \
  -e "s|{{AWG_MOTHERLY_IP}}|${AWG_MOTHERLY_IP_TEST}|g" \
  -e "s|{{BACKEND_PORT}}|${BACKEND_PORT_TEST}|g" \
  -e "s|{{HY2_FALLBACK_HOST}}|${HY2_FALLBACK_HOST_TEST}|g" \
  -e "s|{{HY2_FALLBACK_PORT}}|${HY2_FALLBACK_PORT_TEST}|g" \
  "$REPO_ROOT/Caddyfile.tpl" > "$TMP_RENDERED"

# Produce canonical JSON via caddy adapt
docker run --rm \
  -v "$TMP_RENDERED:/etc/caddy/Caddyfile:ro" \
  "$IMAGE" \
  caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile --pretty \
  2>/dev/null > "$TMP_JSON"

if [[ "${REGEN:-0}" == "1" ]]; then
  cp "$TMP_JSON" "$GOLDEN_JSON"
  echo "REGEN: golden JSON updated at $GOLDEN_JSON"
  exit 0
fi

if ! diff -u "$GOLDEN_JSON" "$TMP_JSON"; then
  echo "FAIL: rendered Caddyfile JSON differs from golden $GOLDEN_JSON" >&2
  echo "      Run: REGEN=1 bash tests/test_caddyfile_golden.sh  to update golden if change is intentional." >&2
  exit 1
fi

echo "PASS: Caddyfile.tpl renders to byte-identical JSON vs golden $GOLDEN_JSON"
