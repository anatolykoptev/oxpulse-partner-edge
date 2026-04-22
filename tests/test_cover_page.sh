#!/bin/bash
# Structural test for Task 3.1 cover-page + @probe matcher.
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-/home/krolik/src/oxpulse-partner-edge}"
CF="$REPO_ROOT/deploy/partner-edge/Caddyfile.tpl"
CV="$REPO_ROOT/deploy/partner-edge/cover/cover.html"
CP="$REPO_ROOT/deploy/partner-edge/docker-compose.yml.tpl"

[ -f "$CV" ] || { echo "FAIL: cover.html missing"; exit 1; }
grep -q '<title>Site under construction' "$CV" || { echo "FAIL: cover.html content wrong"; exit 1; }

grep -q '@probe' "$CF" || { echo "FAIL: @probe matcher missing"; exit 1; }
grep -q 'oxpulse_session' "$CF" || { echo "FAIL: session cookie check missing in @probe"; exit 1; }
grep -q '/srv/cover' "$CF" || { echo "FAIL: cover root missing"; exit 1; }
grep -q 'handle @probe' "$CF" || { echo "FAIL: handle @probe block missing"; exit 1; }

grep -q './cover:/srv/cover:ro' "$CP" || { echo "FAIL: cover volume mount missing"; exit 1; }

# Render + validate
sed -e 's/{{PARTNER_DOMAIN}}/example.test/g' -e 's/{{TURNS_SUBDOMAIN}}/turns/g' \
    "$CF" > /tmp/Caddyfile.cover.check
docker run --rm -v /tmp/Caddyfile.cover.check:/etc/caddy/Caddyfile:ro \
    oxpulse-partner-edge-caddy:test caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1 \
    | grep -q 'Valid configuration' \
    || { echo "FAIL: rendered Caddyfile doesn't validate"; exit 1; }

echo "PASS: cover page + @probe matcher structurally valid"
