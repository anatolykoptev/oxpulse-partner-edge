#!/bin/bash
# Validates Caddyfile.tpl renders + parses with the partner-edge Caddy image.
# Runs caddy validate via the xcaddy-built image (has caddy-l4).
#
# Phase 2 fixes (vs original):
#   - REPO_ROOT derived from script location (was hardcoded to wrong path)
#   - TPL path corrected to Caddyfile.tpl at repo root (was deploy/partner-edge/)
#   - IMAGE defaults to prod ghcr.io image instead of local partner-edge-caddy:test
#   - proxy target corrected to host.docker.internal:5349 (not 127.0.0.1:5349)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${CADDY_IMAGE:-ghcr.io/anatolykoptev/partner-edge-caddy:latest}"
TPL="$REPO_ROOT/Caddyfile.tpl"

if ! docker info >/dev/null 2>&1; then
  echo "SKIP: docker daemon unreachable" >&2
  exit 0
fi

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

# Substitute placeholders with deterministic test values
sed -e 's/{{PARTNER_DOMAIN}}/example.test/g' \
    -e 's/{{TURNS_SUBDOMAIN}}/turns/g' \
    "$TPL" > "$TMP"

# Validate via the partner-edge image (has caddy-l4 plugin)
VALIDATE_OUT=$(docker run --rm -v "$TMP:/etc/caddy/Caddyfile:ro" "$IMAGE" \
       caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1)
if ! echo "$VALIDATE_OUT" | grep -q 'Valid configuration'; then
  echo "FAIL: caddy validate rejected rendered Caddyfile.tpl" >&2
  echo "$VALIDATE_OUT" >&2
  exit 1
fi

# Verify l4 demux block is present structurally (defensive against accidental revert)
grep -q 'listener_wrappers' "$TPL" || { echo "FAIL: listener_wrappers directive missing"; exit 1; }
grep -q 'layer4' "$TPL" || { echo "FAIL: layer4 directive missing"; exit 1; }
grep -qE 'tls sni \{\{TURNS_SUBDOMAIN\}\}\.\{\{PARTNER_DOMAIN\}\}' "$TPL" || { echo "FAIL: @turns SNI matcher wrong"; exit 1; }
grep -qF 'proxy tcp/host.docker.internal:5349' "$TPL" || { echo "FAIL: proxy target wrong (expected host.docker.internal:5349)"; exit 1; }
grep -q 'disable_tlsalpn_challenge' "$TPL" || { echo "FAIL: disable_tlsalpn_challenge missing in TURNS stub"; exit 1; }
# Trailing 'tls' fallback inside listener_wrappers
awk '/listener_wrappers \{/,/^    \}$/' "$TPL" | grep -qxE '[[:space:]]+tls' \
  || { echo "FAIL: fallback 'tls' directive missing inside listener_wrappers"; exit 1; }

# Phase 1 canary site checks
grep -qF "http://127.0.0.1:9080" "$TPL" \
  || { echo "FAIL: canary site block missing (http://127.0.0.1:9080)"; exit 1; }
grep -q "/canary/tunnel" "$TPL" \
  || { echo "FAIL: /canary/tunnel endpoint missing"; exit 1; }
grep -q "/canary/upstream" "$TPL" \
  || { echo "FAIL: /canary/upstream endpoint missing"; exit 1; }
grep -q "/canary/config-hash" "$TPL" \
  || { echo "FAIL: /canary/config-hash endpoint missing"; exit 1; }
grep -q "/canary/route-table" "$TPL" \
  || { echo "FAIL: /canary/route-table endpoint missing"; exit 1; }
# Phase 1 JSON log checks
grep -q "format json" "$TPL" \
  || { echo "FAIL: log format json directive missing in global block"; exit 1; }
grep -q "level INFO" "$TPL" \
  || { echo "FAIL: log level INFO directive missing in global block"; exit 1; }
# Phase 2 snippet checks
grep -q '(tunnel_upstream)' "$TPL" \
  || { echo "FAIL: tunnel_upstream snippet definition missing"; exit 1; }
grep -q '(tunnel_upstream_default)' "$TPL" \
  || { echo "FAIL: tunnel_upstream_default snippet definition missing"; exit 1; }
grep -qE 'import tunnel_upstream /api/\*' "$TPL" \
  || { echo "FAIL: import tunnel_upstream /api/* missing"; exit 1; }
grep -qE 'import tunnel_upstream /ws/\*' "$TPL" \
  || { echo "FAIL: import tunnel_upstream /ws/* missing"; exit 1; }
grep -qE 'import tunnel_upstream /events/\*' "$TPL" \
  || { echo "FAIL: import tunnel_upstream /events/* missing"; exit 1; }
grep -q 'import tunnel_upstream_default' "$TPL" \
  || { echo "FAIL: import tunnel_upstream_default missing"; exit 1; }

# Confirm canary site is NOT on :443 (must never be public)
python3 - "$TPL" <<'PYCHECK'
import sys, re
with open(sys.argv[1]) as f:
    t = f.read()
m = re.search(r'http://127\.0\.0\.1:9080\s*\{(.+?)\n\}', t, re.DOTALL)
if not m:
    print("FAIL: canary site block not parseable"); sys.exit(1)
if ":443" in m.group(0):
    print("FAIL: canary block references :443 -- must be 127.0.0.1:9080 only"); sys.exit(1)
print("OK: canary block bound to 127.0.0.1:9080 only")
PYCHECK

echo "PASS: Caddyfile.tpl validates + has required l4 demux structure + Phase 1 canary + JSON logs + Phase 2 snippets"
