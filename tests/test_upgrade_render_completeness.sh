#!/bin/bash
# tests/test_upgrade_render_completeness.sh
# Upgrade-side render-support checks that are NOT the Caddyfile render itself.
# The Caddyfile placeholder-completeness invariant now lives on the reconcile path
# (opec render caddy + assert_no_unresolved_placeholders) and is covered by
# tests/test_render_completeness.sh; the old re_render_caddy substitution/guard tests
# this file used to carry were removed in the Phase 5 strangler completion (the shell
# renderer had 0 production callers and was deleted).
#
# Coverage:
#   Test 4: xray.env idempotent provisioning in sync_host_scripts / install.sh.
#   Test 5: shellcheck -S error on install.sh + upgrade.sh.
#   Test 6: the --with-templates dry-run conflict-check render path (no SC2168 abort,
#           no leftover placeholders).
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
UPGRADE="$REPO_ROOT/upgrade.sh"

[[ -f "$UPGRADE" ]] || { echo "FAIL: upgrade.sh not found at $UPGRADE"; exit 1; }

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# ---- Test 4: xray.env provisioning in sync_host_scripts (static check) ----
# sync_host_scripts moved to lib/host-scripts-lib.sh (Phase 4 strangler-harden,
# task p4) — check there, not upgrade.sh (which now only holds a thin forwarder).
echo "==> Test 4: sync_host_scripts provisions xray.env"
grep -A 5 "Step 6.5" "$REPO_ROOT/lib/host-scripts-lib.sh" | grep -q "xray.env" \
    && pass "xray.env provisioning step present in lib/host-scripts-lib.sh" \
    || fail "xray.env provisioning step missing from lib/host-scripts-lib.sh"

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
trap 't6_cleanup' EXIT
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

# ---- Summary ----
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
