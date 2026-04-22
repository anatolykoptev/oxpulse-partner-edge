#!/bin/bash
# Validates Caddyfile.tpl renders + parses with the partner-edge Caddy image.
# Runs caddy validate via the xcaddy-built image (has caddy-l4).
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-/home/krolik/src/oxpulse-partner-edge}"
IMAGE="${1:-partner-edge-caddy:test}"
TPL="$REPO_ROOT/deploy/partner-edge/Caddyfile.tpl"

if ! docker info >/dev/null 2>&1; then
  echo "FAIL: docker daemon unreachable" >&2
  exit 2
fi

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "FAIL: image $IMAGE not found — run Task 2A.1 test first" >&2
  exit 1
fi

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

# Substitute placeholders with deterministic test values
sed -e 's/{{PARTNER_DOMAIN}}/example.test/g' \
    -e 's/{{TURNS_SUBDOMAIN}}/turns/g' \
    "$TPL" > "$TMP"

# Validate via the partner-edge image (has caddy-l4 plugin)
if ! docker run --rm -v "$TMP:/etc/caddy/Caddyfile:ro" "$IMAGE" \
       caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1 \
     | tee /tmp/caddyfile-validate.log \
     | grep -q 'Valid configuration'; then
  echo "FAIL: caddy validate rejected rendered Caddyfile.tpl" >&2
  tail -20 /tmp/caddyfile-validate.log >&2
  exit 1
fi

# Verify l4 demux block is present structurally (defensive against accidental revert)
grep -q 'listener_wrappers' "$TPL" || { echo "FAIL: listener_wrappers directive missing"; exit 1; }
grep -q 'layer4' "$TPL" || { echo "FAIL: layer4 directive missing"; exit 1; }
grep -qE 'tls sni \{\{TURNS_SUBDOMAIN\}\}\.\{\{PARTNER_DOMAIN\}\}' "$TPL" || { echo "FAIL: @turns SNI matcher wrong"; exit 1; }
grep -qF 'proxy tcp/127.0.0.1:5349' "$TPL" || { echo "FAIL: proxy target wrong"; exit 1; }
grep -q 'disable_tlsalpn_challenge' "$TPL" || { echo "FAIL: disable_tlsalpn_challenge missing in TURNS stub"; exit 1; }
# Trailing 'tls' fallback inside listener_wrappers — load-bearing for
# non-TURNS traffic; silent drop would break all HTTPS for PARTNER_DOMAIN.
awk '/listener_wrappers \{/,/^    \}$/' "$TPL" | grep -qxE '[[:space:]]+tls' \
  || { echo "FAIL: fallback 'tls' directive missing inside listener_wrappers"; exit 1; }

echo "PASS: Caddyfile.tpl validates + has required l4 demux structure"
