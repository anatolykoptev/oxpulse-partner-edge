#!/bin/bash
# tests/test_install_sh_check_drift.sh
# Tests install.sh --check drift detection mode.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
INSTALL="$REPO_ROOT/install.sh"

[[ -f "$INSTALL" ]] || { echo "FAIL: install.sh not found at $INSTALL"; exit 1; }
bash -n "$INSTALL" || { echo "FAIL: install.sh has syntax errors"; exit 1; }
echo "OK: syntax clean"

SERVE_PORT=18759
python3 -m http.server "$SERVE_PORT" --directory "$REPO_ROOT" \
    >/tmp/test-check-httpd.log 2>&1 &
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

PARTNER_DOMAIN="check-test.example.com"
TURNS_SUBDOMAIN="turns"
PARTNER_ID="checktest"
IMAGE_VERSION="latest"

cat > "$T_LIB/install.env" << ENVEOF
PARTNER_ID=${PARTNER_ID}
PARTNER_DOMAIN=${PARTNER_DOMAIN}
NODE_ID=check-node-abc123
TUNNEL=vless
IMAGE_VERSION=${IMAGE_VERSION}
TURNS_SUBDOMAIN=${TURNS_SUBDOMAIN}
INSTALLED_AT=2026-01-01T00:00:00Z
CADDYFILE_SHA=placeholder
ENVEOF
chmod 0600 "$T_LIB/install.env"

# Pre-render Caddyfile — matches --check render exactly
sed \
    -e "s|{{PARTNER_DOMAIN}}|${PARTNER_DOMAIN}|g" \
    -e "s|{{TURNS_SUBDOMAIN}}|${TURNS_SUBDOMAIN}|g" \
    "$REPO_ROOT/Caddyfile.tpl" > "$T_ETC/Caddyfile.raw"
_sha=$(sha256sum "$T_ETC/Caddyfile.raw" | awk '{print $1}')
sed "s|__CADDYFILE_SHA__|${_sha}|g" "$T_ETC/Caddyfile.raw" > "$T_ETC/Caddyfile"
rm "$T_ETC/Caddyfile.raw"

# Pre-render compose — same 4-substitution as --check
sed \
    -e "s|{{PARTNER_ID}}|${PARTNER_ID}|g" \
    -e "s|{{PARTNER_DOMAIN}}|${PARTNER_DOMAIN}|g" \
    -e "s|{{TURNS_SUBDOMAIN}}|${TURNS_SUBDOMAIN}|g" \
    -e "s|{{IMAGE_VERSION}}|${IMAGE_VERSION}|g" \
    "$REPO_ROOT/docker-compose.yml.tpl" > "$T_ETC/docker-compose.yml"

# Run --check, capture output + exit code without triggering set -e
do_check() {
    local _out _rc=0
    _out=$(OXPULSE_PREFIX_ETC="$T_ETC" OXPULSE_PREFIX_LIB="$T_LIB" \
           OXPULSE_REPO_RAW="http://127.0.0.1:$SERVE_PORT" \
               bash "$INSTALL" --check 2>&1) || _rc=$?
    printf '%s' "$_out"
    return $_rc
}

# ---- Test 1: clean → exit 0 ----
echo "==> Test 1: clean install → exit 0"
OUT=""; RC=0
OUT=$(do_check) || RC=$?
[[ "$RC" -eq 0 ]] || { echo "FAIL: expected exit 0, got $RC"; echo "$OUT"; exit 1; }
echo "$OUT" | grep "\[OK\].*Caddyfile" >/dev/null || { echo "FAIL: [OK] Caddyfile missing"; echo "$OUT"; exit 1; }
echo "$OUT" | grep "\[OK\].*docker-compose" >/dev/null || { echo "FAIL: [OK] compose missing"; echo "$OUT"; exit 1; }
echo "$OUT" | grep "\[conf.d/\]" >/dev/null || { echo "FAIL: [conf.d/] missing"; echo "$OUT"; exit 1; }
echo "OK: exit 0, both [OK] lines"

# ---- Test 2: modify Caddyfile → exit 1 ----
echo "==> Test 2: modified Caddyfile → exit 1"
echo "# operator manual edit" >> "$T_ETC/Caddyfile"
OUT=""; RC=0
OUT=$(do_check) || RC=$?
[[ "$RC" -eq 1 ]] || { echo "FAIL: expected exit 1, got $RC"; echo "$OUT"; exit 1; }
echo "$OUT" | grep "\[DRIFT\].*Caddyfile" >/dev/null || { echo "FAIL: [DRIFT] Caddyfile missing"; echo "$OUT"; exit 1; }
echo "OK: exit 1, [DRIFT] Caddyfile"
sed -i '/# operator manual edit/d' "$T_ETC/Caddyfile"

# ---- Test 3: modify compose → exit 2 (Caddyfile clean) ----
echo "==> Test 3: modified docker-compose.yml → exit 2"
echo "# operator compose edit" >> "$T_ETC/docker-compose.yml"
OUT=""; RC=0
OUT=$(do_check) || RC=$?
[[ "$RC" -eq 2 ]] || { echo "FAIL: expected exit 2, got $RC"; echo "$OUT"; exit 1; }
echo "$OUT" | grep "\[DRIFT\].*docker-compose" >/dev/null || { echo "FAIL: [DRIFT] compose missing"; echo "$OUT"; exit 1; }
echo "OK: exit 2, [DRIFT] docker-compose.yml"
sed -i '/# operator compose edit/d' "$T_ETC/docker-compose.yml"

# ---- Test 4: conf.d/*.caddy → exit 0 ----
echo "==> Test 4: conf.d/test.caddy → --check exits 0"
echo 'test.example.local { respond "hi" }' > "$T_CONFD/test.caddy"
OUT=""; RC=0
OUT=$(do_check) || RC=$?
[[ "$RC" -eq 0 ]] || { echo "FAIL: expected exit 0 with conf.d/test.caddy, got $RC"; echo "$OUT"; exit 1; }
echo "$OUT" | grep "\[conf.d/\] 1" >/dev/null || { echo "FAIL: conf.d count not 1"; echo "$OUT"; exit 1; }
echo "OK: exit 0, conf.d/1 file reported"

echo ""
echo "PASS: all test_install_sh_check_drift tests passed"
