#!/bin/bash
# Validates Caddyfile.tpl renders + parses with the partner-edge Caddy image.
# Runs caddy validate via the xcaddy-built image (has caddy-l4).
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-/home/user/src/oxpulse-partner-edge}"
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
# Confirm canary site is NOT on :443 (must never be public)
python3 - "$TPL" <<'PYEOF'
import sys, re
with open(sys.argv[1]) as f:
    t = f.read()
# Find canary block and assert no :443 binding
m = re.search(r'http://127\.0\.0\.1:9080\s*\{(.+?)\n\}', t, re.DOTALL)
if not m:
    print("FAIL: canary site block not parseable"); sys.exit(1)
if ":443" in m.group(0):
    print("FAIL: canary block references :443 -- must be 127.0.0.1:9080 only"); sys.exit(1)
print("OK: canary block bound to 127.0.0.1:9080 only")
PYEOF

echo "PASS: Caddyfile.tpl validates + has required l4 demux structure + Phase 1 canary + JSON logs"
