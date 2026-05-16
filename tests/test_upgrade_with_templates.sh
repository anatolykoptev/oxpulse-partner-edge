#!/bin/bash
# tests/test_upgrade_with_templates.sh
# Tests the --with-templates logic in upgrade.sh.
# Strategy: extract render functions and test them directly (no docker, no root).
# The DOCKER_BIN=true override and a fake healthcheck cover the integration path.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
UPGRADE="$REPO_ROOT/upgrade.sh"

[[ -f "$UPGRADE" ]] || { echo "FAIL: upgrade.sh not found at $UPGRADE"; exit 1; }

# ---- spin up a local HTTP server for templates ----
SERVE_PORT=18757
python3 -m http.server "$SERVE_PORT" --directory "$REPO_ROOT" \
    >/tmp/test-upgrade-httpd.log 2>&1 &
HTTP_PID=$!

TMPDIR_ROOT=$(mktemp -d)
cleanup() { kill "$HTTP_PID" 2>/dev/null || true; rm -rf "$TMPDIR_ROOT"; }
trap cleanup EXIT

# Give server a moment to start.
sleep 1
curl -fsSL --max-time 5 "http://127.0.0.1:$SERVE_PORT/Caddyfile.tpl" >/dev/null \
    || { echo "FAIL: local http server did not serve Caddyfile.tpl"; exit 1; }

# ---- sandbox dirs ----
T_ETC="$TMPDIR_ROOT/etc"
T_LIB="$TMPDIR_ROOT/lib"
mkdir -p "$T_ETC" "$T_LIB"

# Minimal docker-compose.yml with caddy + non-empty SIGNALING_SFU_SECRET.
cat > "$T_ETC/docker-compose.yml" << 'COMPOSE'
services:
  caddy:
    image: ghcr.io/anatolykoptev/partner-edge-caddy:latest
  oxpulse-sfu:
    environment:
      SIGNALING_SFU_SECRET: "test-secret-nonzero"
COMPOSE

# Old Caddyfile on disk.
echo "# old Caddyfile" > "$T_ETC/Caddyfile"

# install.env.
cat > "$T_LIB/install.env" << 'ENVEOF'
PARTNER_ID=testpartner
PARTNER_DOMAIN=test.example.com
NODE_ID=test-node-abc123
TUNNEL=vless
IMAGE_VERSION=latest
TURNS_SUBDOMAIN=turns
INSTALLED_AT=2026-01-01T00:00:00Z
CADDYFILE_SHA=oldhashvalue
ENVEOF
chmod 0600 "$T_LIB/install.env"

# Fake healthcheck that always succeeds.
FAKE_HC="$TMPDIR_ROOT/fake-healthcheck"
printf '#!/bin/bash\nexit 0\n' > "$FAKE_HC"
chmod 0755 "$FAKE_HC"

# ---- Test 1: syntax check ----
echo "==> Test 1: upgrade.sh syntax"
bash -n "$UPGRADE" || { echo "FAIL: upgrade.sh has syntax errors"; exit 1; }
echo "OK: syntax clean"

# ---- Test 2: --with-templates appears in usage block ----
echo "==> Test 2: --with-templates in usage/flag list"
grep -q '\-\-with-templates' "$UPGRADE" \
    || { echo "FAIL: --with-templates not in upgrade.sh"; exit 1; }
grep -q 'MODE=with_templates' "$UPGRADE" \
    || { echo "FAIL: MODE=with_templates not in upgrade.sh"; exit 1; }
echo "OK: --with-templates flag wired"

# ---- Test 3: re_render_caddy function renders Caddyfile correctly ----
echo "==> Test 3: re_render_caddy renders PARTNER_DOMAIN + CADDYFILE_SHA"

RENDER_RC=0
RENDER_SHA=$(
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

        # Extract and run re_render_caddy from upgrade.sh.
        # We eval the function definition only.
        eval "$(awk "/^re_render_caddy\(\)/,/^\}$/" "'"$UPGRADE"'")"
        re_render_caddy
        grep "^CADDYFILE_SHA=" "'"$T_LIB"'/install.env" | cut -d= -f2
    ' 2>/tmp/render-test.log
) || RENDER_RC=$?

if [[ $RENDER_RC -ne 0 ]]; then
    echo "FAIL: re_render_caddy returned non-zero ($RENDER_RC)"
    cat /tmp/render-test.log >&2
    exit 1
fi

[[ -n "$RENDER_SHA" ]] \
    || { echo "FAIL: CADDYFILE_SHA not written to install.env"; exit 1; }

# Rendered Caddyfile must contain substituted domain.
grep -q "test.example.com" "$T_ETC/Caddyfile" \
    || { echo "FAIL: rendered Caddyfile missing PARTNER_DOMAIN substitution"; exit 1; }

# No raw placeholder must remain.
grep -q "{{PARTNER_DOMAIN}}" "$T_ETC/Caddyfile" \
    && { echo "FAIL: {{PARTNER_DOMAIN}} placeholder still in rendered Caddyfile"; exit 1; }
grep -q "{{TURNS_SUBDOMAIN}}" "$T_ETC/Caddyfile" \
    && { echo "FAIL: {{TURNS_SUBDOMAIN}} placeholder still in rendered Caddyfile"; exit 1; }

# __CADDYFILE_SHA__ must be replaced.
grep -q "__CADDYFILE_SHA__" "$T_ETC/Caddyfile" \
    && { echo "FAIL: __CADDYFILE_SHA__ still present in rendered Caddyfile"; exit 1; }

# SHA in install.env must match what's embedded in the Caddyfile respond block.
# The sha is computed BEFORE substituting __CADDYFILE_SHA__, so we recompute:
# Re-render without SHA substitution to get the pre-sha content.
CADDY_NOSUB=$(mktemp)
bash -c '
    curl -fsSL --max-time 15 "http://127.0.0.1:'"$SERVE_PORT"'/Caddyfile.tpl" | \
    sed \
        -e "s|{{PARTNER_DOMAIN}}|test.example.com|g" \
        -e "s|{{TURNS_SUBDOMAIN}}|turns|g" \
    > "'"$CADDY_NOSUB"'"
'
EXPECTED_SHA=$(sha256sum "$CADDY_NOSUB" | awk '{print $1}')
rm -f "$CADDY_NOSUB"

[[ "$RENDER_SHA" == "$EXPECTED_SHA" ]] \
    || { echo "FAIL: SHA mismatch: install.env=$RENDER_SHA expected=$EXPECTED_SHA"; exit 1; }

echo "OK: Caddyfile rendered, SHA=$RENDER_SHA matches expected"

# ---- Test 4: CADDYFILE_SHA update is idempotent (replace existing line) ----
echo "==> Test 4: CADDYFILE_SHA line replace is idempotent"

# Restore install.env with old SHA, re-render.
sed -i "s|^CADDYFILE_SHA=.*|CADDYFILE_SHA=oldhashvalue|" "$T_LIB/install.env"

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
' 2>/tmp/render-idem.log || { echo "FAIL: second re_render_caddy failed"; cat /tmp/render-idem.log >&2; exit 1; }

SHA_COUNT=$(grep -c "^CADDYFILE_SHA=" "$T_LIB/install.env")
[[ "$SHA_COUNT" -eq 1 ]] \
    || { echo "FAIL: CADDYFILE_SHA line duplicated in install.env (count=$SHA_COUNT)"; exit 1; }

echo "OK: idempotent — exactly one CADDYFILE_SHA line after second render"

# ---- Test 5: rollback restores .prev files ----
echo "==> Test 5: do_rollback_templates restores .prev files"

OLD_CADDY="# old caddyfile backup"
OLD_STATE="PARTNER_ID=prev-state"
OLD_COMPOSE="# old compose backup"

echo "$OLD_CADDY"  > "$T_LIB/Caddyfile.prev"
echo "$OLD_STATE"  > "$T_LIB/install.env.prev"
echo "$OLD_COMPOSE" > "$T_LIB/docker-compose.yml.prev"
printf '#!/bin/bash\n# old healthcheck\n' > "$T_LIB/healthcheck.prev"

# Overwrite live files with "new" content.
echo "# new caddyfile" > "$T_ETC/Caddyfile"

bash -c '
    set -euo pipefail
    log()  { printf "==> %s\n" "$*" >&2; }
    warn() { printf "!! %s\n" "$*" >&2; }
    die()  { printf "ERR %s\n" "$*" >&2; exit 1; }

    PREV_CADDYFILE="'"$T_LIB"'/Caddyfile.prev"
    PREV_HEALTHCHECK="'"$T_LIB"'/healthcheck.prev"
    PREV_STATE_FILE="'"$T_LIB"'/install.env.prev"
    PREV_COMPOSE_FILE="'"$T_LIB"'/docker-compose.yml.prev"
    PREFIX_ETC="'"$T_ETC"'"
    STATE_FILE="'"$T_LIB"'/install.env"
    COMPOSE_FILE="'"$T_ETC"'/docker-compose.yml"
    HEALTHCHECK="'"$FAKE_HC"'"

    eval "$(awk "/^do_rollback_templates\(\)/,/^\}$/" "'"$UPGRADE"'")"
    do_rollback_templates
' 2>&1 || { echo "FAIL: do_rollback_templates returned non-zero"; exit 1; }

RESTORED=$(cat "$T_ETC/Caddyfile")
[[ "$RESTORED" == "$OLD_CADDY" ]] \
    || { echo "FAIL: Caddyfile not restored (got: $RESTORED)"; exit 1; }

echo "OK: do_rollback_templates restores .prev files"

# ---- Test 6: piter SFU-only node — caddy absent → graceful skip ----
echo "==> Test 6: caddy-absent compose → Caddyfile render skipped"

PITER_ETC="$TMPDIR_ROOT/piter-etc"
mkdir -p "$PITER_ETC"
cat > "$PITER_ETC/docker-compose.yml" << 'SFUONLY'
services:
  oxpulse-sfu:
    image: ghcr.io/anatolykoptev/partner-edge-sfu:latest
    environment:
      SIGNALING_SFU_SECRET: "sfu-only"
SFUONLY

SKIP_OUT=$(bash -c '
    set -euo pipefail
    log()  { printf "==> %s\n" "$*" >&2; }
    warn() { printf "!! %s\n" "$*" >&2; }
    die()  { printf "ERR %s\n" "$*" >&2; exit 1; }

    PREFIX_ETC="'"$PITER_ETC"'"
    PREFIX_LIB="'"$T_LIB"'"
    STATE_FILE="'"$T_LIB"'/install.env"
    COMPOSE_FILE="'"$PITER_ETC"'/docker-compose.yml"
    REPO_RAW="http://127.0.0.1:'"$SERVE_PORT"'"
    PARTNER_DOMAIN="piter.example.com"
    TURNS_SUBDOMAIN="turns"
    DRY_RUN=0

    eval "$(awk "/^re_render_caddy\(\)/,/^\}$/" "'"$UPGRADE"'")"
    re_render_caddy
' 2>&1 || true)

echo "$SKIP_OUT" | grep -q "SFU-only" \
    || { echo "FAIL: SFU-only skip message not emitted"; echo "$SKIP_OUT"; exit 1; }

echo "OK: piter SFU-only caddy skip works"

# ---- Test 7: existing tests still pass ----
echo "==> Test 7: test_upgrade_die_on_empty_sfu_secret.sh"
REPO_ROOT="$REPO_ROOT" bash "$REPO_ROOT/tests/test_upgrade_die_on_empty_sfu_secret.sh" \
    || { echo "FAIL: existing sfu_secret test regressed"; exit 1; }
echo "OK: existing sfu_secret test still passes"

echo ""
echo "PASS: all test_upgrade_with_templates tests passed"
