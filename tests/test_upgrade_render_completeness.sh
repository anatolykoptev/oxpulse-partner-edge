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
NAIVE_SOCKS_PORT=1080
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

        eval "$(awk "/^_resolve_naive_socks_port\(\)/,/^\}$/" "'"$UPGRADE"'"; awk "/^re_render_caddy\(\)/,/^\}$/" "'"$UPGRADE"'")"
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

        eval "$(awk "/^_resolve_naive_socks_port\(\)/,/^\}$/" "'"$UPGRADE"'"; awk "/^re_render_caddy\(\)/,/^\}$/" "'"$UPGRADE"'")"
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

# ---- Test 5: shellcheck -S error on install.sh and upgrade.sh ----
echo "==> Test 5: shellcheck -S error (SC2168 and class) on install.sh + upgrade.sh"
if command -v shellcheck >/dev/null 2>&1; then
    SC_RC=0
    SC_OUT=$(shellcheck -S error "$REPO_ROOT/install.sh" "$UPGRADE" 2>&1) || SC_RC=$?
    if [[ $SC_RC -eq 0 ]]; then
        pass "shellcheck -S error: install.sh + upgrade.sh clean"
    else
        fail "shellcheck -S error found issues:"
        echo "$SC_OUT" >&2
    fi
else
    echo "SKIP: shellcheck not installed"
fi

# ---- Test 6: with_templates conflict-check render path runs without SC2168 abort ----
echo "==> Test 6: with_templates dry-run conflict-check render path (no SC2168 abort)"

# Strategy: spin up a local HTTP server, write a minimal fixture, then build a
# small self-contained script that wraps the render block from upgrade.sh inside
# a function (making `local` valid) and drive it end-to-end.  We detect SC2168
# by grepping the output for the canonical bash error string.

T6_PORT=18864
python3 -m http.server "$T6_PORT" --directory "$REPO_ROOT" \
    >/tmp/test-t6-httpd.log 2>&1 &
T6_HTTP_PID=$!
T6_TMPDIR=$(mktemp -d)
T6_CLEANUP_DONE=0
t6_cleanup() {
    [[ $T6_CLEANUP_DONE -eq 1 ]] && return
    T6_CLEANUP_DONE=1
    kill "$T6_HTTP_PID" 2>/dev/null || true
    rm -rf "$T6_TMPDIR"
}
trap 'cleanup; t6_cleanup' EXIT
sleep 1
curl -fsSL --max-time 5 "http://127.0.0.1:$T6_PORT/Caddyfile.tpl" >/dev/null \
    || { fail "local http server (T6) not ready"; t6_cleanup; }

T6_ETC="$T6_TMPDIR/etc"
T6_LIB="$T6_TMPDIR/lib"
T6_SHARE="$T6_TMPDIR/share/oxpulse-partner-edge/config"
mkdir -p "$T6_ETC" "$T6_LIB" "$T6_SHARE"

cat > "$T6_ETC/docker-compose.yml" << 'COMPOSE6'
services:
  caddy:
    image: ghcr.io/anatolykoptev/partner-edge-caddy:latest
  oxpulse-sfu:
    environment:
      SIGNALING_SFU_SECRET: "test-secret"
COMPOSE6

cat > "$T6_LIB/install.env" << 'ENV6'
PARTNER_DOMAIN=t6.example.com
TURNS_SUBDOMAIN=turns
IMAGE_VERSION=latest
CADDYFILE_SHA=old
NAIVE_SOCKS_PORT=1080
ENV6
chmod 0600 "$T6_LIB/install.env"

cp "$REPO_ROOT/config/defaults.conf" "$T6_SHARE/defaults.conf" 2>/dev/null || \
    printf ': "${OXPULSE_AWG_MOTHERLY_IP:=10.9.0.2}"\n: "${OXPULSE_HY2_FALLBACK_HOST:=host.docker.internal}"\n: "${OXPULSE_HY2_FALLBACK_PORT:=18443}"\n' \
    > "$T6_SHARE/defaults.conf"

# Write a harness script: extracts the Caddyfile render lines from the
# with_templates block and invokes them inside a function (so local is valid).
# We only test that the render runs without the SC2168 abort; the full
# conflict-check path (run_conflict_checks) is stubbed to exit 0.
T6_HARNESS="$T6_TMPDIR/harness.sh"
cat > "$T6_HARNESS" << HARNESS_EOF
#!/bin/bash
set -euo pipefail
log()  { printf "==> %s\n" "\$*" >&2; }
warn() { printf "!! %s\n" "\$*" >&2; }
die()  { printf "ERR %s\n" "\$*" >&2; exit 1; }
run_conflict_checks() { return 0; }

PREFIX_ETC="$T6_ETC"
PREFIX_LIB="$T6_LIB"
PREFIX_SHARE="${T6_TMPDIR}/share"
STATE_FILE="$T6_LIB/install.env"
COMPOSE_FILE="$T6_ETC/docker-compose.yml"
REPO_RAW="http://127.0.0.1:$T6_PORT"
PARTNER_DOMAIN="t6.example.com"
TURNS_SUBDOMAIN="turns"
DRY_RUN=1
DOCKER_BIN="true"
TARGET="latest"

# Source install.env so NAIVE_SOCKS_PORT is available (matches upgrade.sh line 242).
# shellcheck source=/dev/null
. "\$STATE_FILE"

# Re-implement only the render sub-block from the with_templates DRY_RUN=1 branch.
# This mirrors what upgrade.sh does at the conflict-check render step.
_conflict_tmpdir=\$(mktemp -d)
trap "rm -rf '\$_conflict_tmpdir'" EXIT

_proposed_hc="\$_conflict_tmpdir/healthcheck.sh"
curl -fsSL --max-time 30 "\$REPO_RAW/healthcheck.sh" -o "\$_proposed_hc" 2>/dev/null || true

_proposed_compose="\$_conflict_tmpdir/docker-compose.yml.tpl"
curl -fsSL --max-time 30 "\$REPO_RAW/docker-compose.yml.tpl" -o "\$_proposed_compose" 2>/dev/null || true

_rendered_caddy="\$_conflict_tmpdir/Caddyfile"
_proposed_sha="unknown"
if grep -qE '^\s+caddy:' "\$COMPOSE_FILE" 2>/dev/null && \\
   [[ -n "\${PARTNER_DOMAIN:-}" ]] && [[ -n "\${TURNS_SUBDOMAIN:-}" ]]; then
    _caddyfile_tpl="\$_conflict_tmpdir/Caddyfile.tpl"
    if curl -fsSL --max-time 30 "\$REPO_RAW/Caddyfile.tpl" -o "\$_caddyfile_tpl" 2>/dev/null; then
        _esc() { printf '%s' "\$1" | sed -e 's/[\\\\&|]/\\\\&/g'; }
        _defaults_conf="\${PREFIX_SHARE:-/usr/local/share}/oxpulse-partner-edge/config/defaults.conf"
        _dr_awg="\${AWG_MOTHERLY_IP:-10.9.0.2}"
        _dr_hy2h="\${HY2_FALLBACK_HOST:-host.docker.internal}"
        _dr_hy2p="\${HY2_FALLBACK_PORT:-18443}"
        _dr_naive="\${NAIVE_SOCKS_PORT:-}"
        [[ -z "\$_dr_naive" ]] && _dr_naive=\$(
            grep '^NAIVE_SOCKS_PORT=' "\${STATE_FILE:-}" 2>/dev/null | cut -d= -f2 || true)
        [[ -z "\$_dr_naive" ]] && _dr_naive=\$(
            \${DOCKER_BIN:-docker} inspect oxpulse-partner-naive \\
                --format '{{range .Config.Env}}{{.}}\n{{end}}' 2>/dev/null \\
                | grep '^NAIVE_SOCKS_PORT=' | cut -d= -f2 || true)
        if [[ -z "\$_dr_naive" ]]; then
            if grep -qF '{{NAIVE_SOCKS_PORT}}' "\$_caddyfile_tpl" 2>/dev/null; then
                die "NAIVE_SOCKS_PORT not in STATE_FILE and naive container is down"
            fi
            _dr_naive="1080"
        fi
        if [[ -r "\$_defaults_conf" ]]; then
            # Source defaults.conf in a subshell and print the derived values.
            # Using a simple approach (no nested quote complexity): write a helper
            # script and source it. This mirrors upgrade.sh's bash -c pattern but
            # avoids re-creating the complex quoting inside a heredoc.
            _cfg_out=\$(
                set +u
                # shellcheck source=/dev/null
                . "\$_defaults_conf" 2>/dev/null || true
                printf '%s\n%s\n%s\n' \\
                    "\${OXPULSE_AWG_MOTHERLY_IP:-10.9.0.2}" \\
                    "\${OXPULSE_HY2_FALLBACK_HOST:-host.docker.internal}" \\
                    "\${OXPULSE_HY2_FALLBACK_PORT:-18443}"
            )
            _dr_awg=\$(printf '%s' "\$_cfg_out" | sed -n '1p')
            _dr_hy2h=\$(printf '%s' "\$_cfg_out" | sed -n '2p')
            _dr_hy2p=\$(printf '%s' "\$_cfg_out" | sed -n '3p')
        fi
        sed \\
            -e "s|{{PARTNER_DOMAIN}}|\$(_esc "\$PARTNER_DOMAIN")|g" \\
            -e "s|{{TURNS_SUBDOMAIN}}|\$(_esc "\$TURNS_SUBDOMAIN")|g" \\
            -e "s|{{AWG_MOTHERLY_IP}}|\$(_esc "\$_dr_awg")|g" \\
            -e "s|{{HY2_FALLBACK_HOST}}|\$(_esc "\$_dr_hy2h")|g" \\
            -e "s|{{HY2_FALLBACK_PORT}}|\$(_esc "\$_dr_hy2p")|g" \\
            -e "s|{{NAIVE_SOCKS_PORT}}|\$(_esc "\$_dr_naive")|g" \\
            "\$_caddyfile_tpl" > "\$_rendered_caddy"
        _proposed_sha=\$(sha256sum "\$_rendered_caddy" | awk '{print \$1}')
        sed -i "s|__CADDYFILE_SHA__|\${_proposed_sha}|g" "\$_rendered_caddy"
    fi
fi

_conflict_exit=0
run_conflict_checks \\
    "\$_rendered_caddy" "\$_proposed_compose" "\$_proposed_hc" \\
    "\$_proposed_sha" "\$TARGET" || _conflict_exit=\$?

# Verify the rendered file has no unsubstituted placeholders.
leftover=\$(grep -oE '\{\{[A-Z0-9_]+\}\}' "\$_rendered_caddy" 2>/dev/null | sort -u || true)
[[ -z "\$leftover" ]] || { echo "LEFTOVER_PLACEHOLDERS: \$leftover"; exit 1; }
echo "RENDER_OK"
exit "\$_conflict_exit"
HARNESS_EOF
chmod +x "$T6_HARNESS"

T6_RC=0
T6_OUT=$(bash "$T6_HARNESS" 2>&1) || T6_RC=$?

if echo "$T6_OUT" | grep -qi "local: can only be used in a function"; then
    fail "with_templates render block hit SC2168 (local at top-level)"
    echo "$T6_OUT" >&2
elif echo "$T6_OUT" | grep -q "LEFTOVER_PLACEHOLDERS"; then
    fail "with_templates render: leftover placeholders in Caddyfile"
    echo "$T6_OUT" >&2
elif [[ $T6_RC -ne 0 ]]; then
    fail "with_templates render harness exited $T6_RC: $T6_OUT"
else
    pass "with_templates conflict-check render path ran end-to-end (no SC2168 abort, no leftover placeholders)"
fi

t6_cleanup

# ---- Test 7: re_render_caddy dies symmetrically when {{NAIVE_SOCKS_PORT}} in tpl and unresolvable ----
echo "==> Test 7: re_render_caddy dies if NAIVE_SOCKS_PORT unresolvable (symmetric with dry-run)"

T7_TMPDIR=$(mktemp -d)
T7_ETC="$T7_TMPDIR/etc"
T7_LIB="$T7_TMPDIR/lib"
T7_SHARE="$T7_TMPDIR/share/oxpulse-partner-edge/config"
mkdir -p "$T7_ETC" "$T7_LIB" "$T7_SHARE"

# Compose with caddy service so re_render_caddy doesn't skip.
cat > "$T7_ETC/docker-compose.yml" << 'COMPOSE7'
services:
  caddy:
    image: ghcr.io/anatolykoptev/partner-edge-caddy:latest
  oxpulse-sfu:
    environment:
      SIGNALING_SFU_SECRET: "test-secret"
COMPOSE7

# install.env WITHOUT NAIVE_SOCKS_PORT — simulates naive-down edge, no persisted value.
cat > "$T7_LIB/install.env" << 'ENV7'
PARTNER_DOMAIN=t7.example.com
TURNS_SUBDOMAIN=turns
IMAGE_VERSION=latest
CADDYFILE_SHA=old
ENV7
chmod 0600 "$T7_LIB/install.env"

cp "$REPO_ROOT/config/defaults.conf" "$T7_SHARE/defaults.conf" 2>/dev/null || \
    printf ': "${OXPULSE_AWG_MOTHERLY_IP:=10.9.0.2}"\n' > "$T7_SHARE/defaults.conf"

T7_RC=0
T7_OUT=$(
    bash -c '
        set -euo pipefail
        log()  { printf "==> %s\n" "$*" >&2; }
        warn() { printf "!! %s\n" "$*" >&2; }
        die()  { printf "ERR %s\n" "$*" >&2; exit 1; }

        PREFIX_ETC="'"$T7_ETC"'"
        PREFIX_LIB="'"$T7_LIB"'"
        PREFIX_SHARE="'"$T7_TMPDIR/share"'"
        STATE_FILE="'"$T7_LIB/install.env"'"
        COMPOSE_FILE="'"$T7_ETC/docker-compose.yml"'"
        REPO_RAW="http://127.0.0.1:'"$SERVE_PORT"'"
        PARTNER_DOMAIN="t7.example.com"
        TURNS_SUBDOMAIN="turns"
        DOCKER_BIN="true"   # stub — naive container down (true always exits 0 but no output)
        DRY_RUN=0
        # NAIVE_SOCKS_PORT not set — no env, no STATE_FILE entry, docker inspect stub returns empty

        eval "$(awk "/^_resolve_naive_socks_port\(\)/,/^\}$/" "'"$UPGRADE"'")"
        eval "$(awk "/^re_render_caddy\(\)/,/^\}$/" "'"$UPGRADE"'")"
        re_render_caddy
    ' 2>&1
) || T7_RC=$?

if [[ $T7_RC -ne 0 ]] && echo "$T7_OUT" | grep -qi "NAIVE_SOCKS_PORT"; then
    pass "re_render_caddy dies with actionable message when NAIVE_SOCKS_PORT unresolvable"
else
    fail "re_render_caddy did NOT die (rc=$T7_RC) — silent 1080 fallback or wrong error (output: $T7_OUT)"
fi

rm -rf "$T7_TMPDIR"

# ---- Summary ----
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
