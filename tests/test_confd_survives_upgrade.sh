#!/bin/bash
# tests/test_confd_survives_upgrade.sh
# Verifies that upgrade.sh --with-templates preserves conf.d/ content.
# Strategy: pre-populate conf.d/ with a sentinel file, run re_render_caddy
# (extracted from upgrade.sh), assert sentinel unchanged (sha256 match).
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
UPGRADE="$REPO_ROOT/upgrade.sh"

[[ -f "$UPGRADE" ]] || { echo "FAIL: upgrade.sh not found"; exit 1; }
bash -n "$UPGRADE" || { echo "FAIL: upgrade.sh syntax errors"; exit 1; }
echo "OK: syntax clean"

SERVE_PORT=18758
python3 -m http.server "$SERVE_PORT" --directory "$REPO_ROOT" \
    >/tmp/test-confd-httpd.log 2>&1 &
HTTP_PID=$!

TMPDIR_ROOT=$(mktemp -d)
cleanup() { kill "$HTTP_PID" 2>/dev/null || true; rm -rf "$TMPDIR_ROOT"; }
trap cleanup EXIT

sleep 1
curl -fsSL --max-time 5 "http://127.0.0.1:$SERVE_PORT/Caddyfile.tpl" >/dev/null \
    || { echo "FAIL: http server not serving Caddyfile.tpl"; exit 1; }

T_ETC="$TMPDIR_ROOT/etc"
T_LIB="$TMPDIR_ROOT/lib"
T_CONFD="$T_ETC/conf.d"
mkdir -p "$T_ETC" "$T_LIB" "$T_CONFD"

# Pre-populate conf.d/ with sentinel file
SENTINEL_CONTENT='cheburator.bot { respond "sentinel" }'
SENTINEL_PATH="$T_CONFD/cheburator-vhosts.caddy"
printf '%s\n' "$SENTINEL_CONTENT" > "$SENTINEL_PATH"
SENTINEL_SHA=$(sha256sum "$SENTINEL_PATH" | awk '{print $1}')

# Compose (minimal — re_render_caddy checks for caddy service)
cat > "$T_ETC/docker-compose.yml" << 'COMPOSE'
services:
  caddy:
    image: ghcr.io/anatolykoptev/partner-edge-caddy:latest
  oxpulse-sfu:
    environment:
      SIGNALING_SFU_SECRET: "test-secret-nonzero"
COMPOSE
echo "# old Caddyfile" > "$T_ETC/Caddyfile"

# install.env
cat > "$T_LIB/install.env" << 'ENVEOF'
PARTNER_ID=testpartner
PARTNER_DOMAIN=test.example.com
NODE_ID=test-node
TUNNEL=vless
IMAGE_VERSION=latest
TURNS_SUBDOMAIN=turns
INSTALLED_AT=2026-01-01T00:00:00Z
CADDYFILE_SHA=oldhash
ENVEOF
chmod 0600 "$T_LIB/install.env"

echo "==> Test 1: re_render_caddy does not touch conf.d/"
bash -c '
    set -euo pipefail
    log()  { printf "==> %s\n" "$*" >&2; }
    warn() { printf "!! %s\n" "$*" >&2; }
    die()  { printf "ERR %s\n" "$*" >&2; exit 1; }

    PREFIX_ETC="'"$T_ETC"'"
    PREFIX_LIB="'"$T_LIB"'"
    STATE_FILE="'"$T_LIB"'/install.env"
    COMPOSE_FILE="'"$T_ETC"'/docker-compose.yml"
    REPO_RAW="http://127.0.0.1:'"$SERVE_PORT"'"
    PARTNER_DOMAIN="test.example.com"
    TURNS_SUBDOMAIN="turns"
    DRY_RUN=0

    eval "$(awk "/^re_render_caddy\(\)/,/^\}$/" "'"$UPGRADE"'")"
    re_render_caddy
' 2>/tmp/confd-upgrade-test.log || { echo "FAIL: re_render_caddy returned non-zero"; cat /tmp/confd-upgrade-test.log >&2; exit 1; }

# Verify sentinel still exists and unchanged
[[ -f "$SENTINEL_PATH" ]] || { echo "FAIL: sentinel file deleted by re_render_caddy"; exit 1; }
POST_SHA=$(sha256sum "$SENTINEL_PATH" | awk '{print $1}')
[[ "$POST_SHA" == "$SENTINEL_SHA" ]] \
    || { echo "FAIL: sentinel sha256 changed: before=$SENTINEL_SHA after=$POST_SHA"; exit 1; }
echo "OK: conf.d/cheburator-vhosts.caddy unchanged after re_render_caddy (sha=$POST_SHA)"

# Verify Caddyfile was re-rendered (it changed from "# old Caddyfile")
grep -q "test.example.com" "$T_ETC/Caddyfile" \
    || { echo "FAIL: Caddyfile not re-rendered"; exit 1; }
echo "OK: Caddyfile was re-rendered"

echo ""
echo "PASS: conf.d/ survives upgrade --with-templates (re_render_caddy)"
