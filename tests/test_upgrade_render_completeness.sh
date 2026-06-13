#!/bin/bash
# tests/test_upgrade_render_completeness.sh
# Validates that re_render_caddy() in upgrade.sh substitutes ALL Caddyfile.tpl
# placeholders and that the render-completeness guard fires on unknown ones.
#
# Coverage:
#   Test 1: static — all {{PLACEHOLDER}} tokens in Caddyfile.tpl have a -e
#            substitution line in upgrade.sh re_render_caddy.
#   Test 2: functional — rendered Caddyfile contains no remaining {{...}} tokens.
#   Test 3: render-completeness guard fires if a placeholder survives.
#   Test 4: xray.env idempotent provisioning in sync_host_scripts.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
UPGRADE="$REPO_ROOT/upgrade.sh"
TPL="$REPO_ROOT/Caddyfile.tpl"

[[ -f "$UPGRADE" ]] || { echo "FAIL: upgrade.sh not found at $UPGRADE"; exit 1; }
[[ -f "$TPL"     ]] || { echo "FAIL: Caddyfile.tpl not found at $TPL"; exit 1; }

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# ---- Test 1: static — every {{PLACEHOLDER}} in Caddyfile.tpl has a sed -e substitution ----
echo "==> Test 1: all Caddyfile.tpl placeholders wired in re_render_caddy"
mapfile -t PLACEHOLDERS < <(grep -oE '\{\{[A-Z0-9_]+\}\}' "$TPL" | sort -u)
missing=()
for ph in "${PLACEHOLDERS[@]}"; do
    bare="${ph//\{/}"; bare="${bare//\}/}"
    # Check for substitution in the re_render_caddy function block.
    found_in_func=0
    func_body=$(grep -A 300 "^re_render_caddy()" "$UPGRADE" 2>/dev/null || true)
    echo "$func_body" | grep -qF "{{${bare}}}" 2>/dev/null && found_in_func=1 || true
    if [[ $found_in_func -eq 0 ]]; then
        missing+=("$ph")
    fi
done
if [[ "${#missing[@]}" -eq 0 ]]; then
    pass "all ${#PLACEHOLDERS[@]} placeholder(s) covered in re_render_caddy: ${PLACEHOLDERS[*]}"
else
    fail "re_render_caddy missing substitutions for: ${missing[*]}"
fi

# ---- Test 2: functional — rendered Caddyfile has no remaining {{...}} tokens ----
echo "==> Test 2: rendered Caddyfile leaves no unsubstituted placeholders"

SERVE_PORT=18862
python3 -m http.server "$SERVE_PORT" --directory "$REPO_ROOT" \
    >/tmp/test-render-httpd.log 2>&1 &
HTTP_PID=$!
TMPDIR_ROOT=$(mktemp -d)
cleanup() { kill "$HTTP_PID" 2>/dev/null || true; rm -rf "$TMPDIR_ROOT"; }
trap cleanup EXIT
sleep 1
curl -fsSL --max-time 5 "http://127.0.0.1:$SERVE_PORT/Caddyfile.tpl" >/dev/null \
    || { echo "FAIL: local http server not ready"; exit 1; }

T_ETC="$TMPDIR_ROOT/etc"
T_LIB="$TMPDIR_ROOT/lib"
T_SHARE="$TMPDIR_ROOT/share/oxpulse-partner-edge/config"
mkdir -p "$T_ETC" "$T_LIB" "$T_SHARE"

# Minimal compose with caddy service.
cat > "$T_ETC/docker-compose.yml" << 'COMPOSE'
services:
  caddy:
    image: ghcr.io/anatolykoptev/partner-edge-caddy:latest
  oxpulse-sfu:
    environment:
      SIGNALING_SFU_SECRET: "test-secret"
COMPOSE

cat > "$T_LIB/install.env" << 'ENVEOF'
PARTNER_DOMAIN=test.example.com
TURNS_SUBDOMAIN=turns
IMAGE_VERSION=latest
CADDYFILE_SHA=old
ENVEOF
chmod 0600 "$T_LIB/install.env"

# Provide a defaults.conf so the function can load fleet defaults.
cp "$REPO_ROOT/config/defaults.conf" "$T_SHARE/defaults.conf" 2>/dev/null || \
    printf ': "${OXPULSE_AWG_MOTHERLY_IP:=10.9.0.2}"\n: "${OXPULSE_HY2_FALLBACK_HOST:=host.docker.internal}"\n: "${OXPULSE_HY2_FALLBACK_PORT:=18443}"\n' > "$T_SHARE/defaults.conf"

RENDER_RC=0
RENDER_OUT=$(
    bash -c '
        set -euo pipefail
        log()  { printf "==> %s\n" "$*" >&2; }
        warn() { printf "!! %s\n" "$*" >&2; }
        die()  { printf "ERR %s\n" "$*" >&2; exit 1; }

        PREFIX_ETC="'"$T_ETC"'"
        PREFIX_LIB="'"$T_LIB"'"
        PREFIX_SHARE="'"${TMPDIR_ROOT}/share"'"
        STATE_FILE="'"$T_LIB"'/install.env"
        COMPOSE_FILE="'"$T_ETC"'/docker-compose.yml"
        REPO_RAW="http://127.0.0.1:'"$SERVE_PORT"'"
        PARTNER_DOMAIN="test.example.com"
        TURNS_SUBDOMAIN="turns"
        DOCKER_BIN="true"   # stub — naive container not running
        DRY_RUN=0

        eval "$(awk "/^re_render_caddy\(\)/,/^\}$/" "'"$UPGRADE"'")"
        re_render_caddy
    ' 2>&1
) || RENDER_RC=$?

if [[ $RENDER_RC -ne 0 ]]; then
    fail "re_render_caddy returned non-zero ($RENDER_RC)"
    echo "$RENDER_OUT" >&2
else
    LEFTOVER=$(grep -oE '\{\{[A-Z_]+\}\}' "$T_ETC/Caddyfile" 2>/dev/null | sort -u || true)
    if [[ -n "$LEFTOVER" ]]; then
        fail "rendered Caddyfile still has placeholders: $LEFTOVER"
    else
        pass "rendered Caddyfile has no unsubstituted placeholders"
    fi
    # Verify known values are present.
    grep -q "test.example.com" "$T_ETC/Caddyfile" \
        && pass "PARTNER_DOMAIN substituted" \
        || fail "PARTNER_DOMAIN missing from rendered Caddyfile"
    grep -qF "10.9.0.2" "$T_ETC/Caddyfile" \
        && pass "AWG_MOTHERLY_IP substituted (10.9.0.2)" \
        || fail "AWG_MOTHERLY_IP missing from rendered Caddyfile"
    grep -qF "18443" "$T_ETC/Caddyfile" \
        && pass "HY2_FALLBACK_PORT substituted (18443)" \
        || fail "HY2_FALLBACK_PORT missing from rendered Caddyfile"
fi

# ---- Test 3: render-completeness guard fires on unknown placeholder ----
echo "==> Test 3: render-completeness guard fires on unknown placeholder"

# Inject a fake placeholder into a temp copy of Caddyfile.tpl.
T_FAKE_TPL="$TMPDIR_ROOT/fake_Caddyfile.tpl"
cat "$TPL" > "$T_FAKE_TPL"
printf '\n# test injection\n{{UNKNOWN_PLACEHOLDER_XYZ}}\n' >> "$T_FAKE_TPL"

T2_ETC="$TMPDIR_ROOT/etc2"
mkdir -p "$T2_ETC"
cp "$T_ETC/docker-compose.yml" "$T2_ETC/"

GUARD_RC=0
GUARD_OUT=$(
    bash -c '
        set -euo pipefail
        log()  { printf "==> %s\n" "$*" >&2; }
        warn() { printf "!! %s\n" "$*" >&2; }
        die()  { printf "ERR %s\n" "$*" >&2; exit 1; }

        PREFIX_ETC="'"$T2_ETC"'"
        PREFIX_LIB="'"$T_LIB"'"
        PREFIX_SHARE="'"${TMPDIR_ROOT}/share"'"
        STATE_FILE="'"$T_LIB"'/install.env"
        COMPOSE_FILE="'"$T2_ETC"'/docker-compose.yml"
        # Serve the modified template via the same HTTP server by overriding path.
        # We need to fake REPO_RAW to serve our modified template — use a temp dir.
        _SERVE_ROOT="'"$TMPDIR_ROOT"'/serve"
        mkdir -p "$_SERVE_ROOT"
        cp "'"$T_FAKE_TPL"'" "$_SERVE_ROOT/Caddyfile.tpl"
        REPO_RAW="file://$_SERVE_ROOT"
        # Switch to file:// fetch via curl
        PARTNER_DOMAIN="test.example.com"
        TURNS_SUBDOMAIN="turns"
        DOCKER_BIN="true"
        DRY_RUN=0

        eval "$(awk "/^re_render_caddy\(\)/,/^\}$/" "'"$UPGRADE"'")"
        # Override the curl inside re_render_caddy to copy the local file.
        # We do this by shimming curl in the env.
        curl() {
            # Parse: curl -fsSL --max-time 30 <url> -o <dest>
            local _url="" _out=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    -o) _out="$2"; shift 2 ;;
                    http*|file*) _url="$1"; shift ;;
                    *) shift ;;
                esac
            done
            if [[ "$_url" == *"Caddyfile.tpl"* ]]; then
                cp "'"$T_FAKE_TPL"'" "$_out"
            fi
        }
        export -f curl
        re_render_caddy
    ' 2>&1
) || GUARD_RC=$?

if [[ $GUARD_RC -ne 0 ]] && echo "$GUARD_OUT" | grep -q "UNKNOWN_PLACEHOLDER_XYZ"; then
    pass "render-completeness guard fires on unknown placeholder"
else
    fail "render-completeness guard did NOT fire (rc=$GUARD_RC output: $GUARD_OUT)"
fi

# ---- Test 4: xray.env provisioning in sync_host_scripts (static check) ----
echo "==> Test 4: upgrade.sh sync_host_scripts provisions xray.env"
grep -A 5 "Step 6.5" "$UPGRADE" | grep -q "xray.env" \
    && pass "xray.env provisioning step present in upgrade.sh" \
    || fail "xray.env provisioning step missing from upgrade.sh"

# Verify install.sh also provisions xray.env.
grep -q "xray.env" "$REPO_ROOT/install.sh" \
    && pass "install.sh provisions xray.env" \
    || fail "install.sh does not provision xray.env"

# ---- Summary ----
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
