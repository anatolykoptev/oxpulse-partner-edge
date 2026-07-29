#!/bin/bash
# tests/test_caddy_peer_isolation.sh — caddy change must NOT recreate peer containers.
#
# Asserts:
#   P1: apply_caddy_reloads is called (not mark_restart on full stack unit).
#   P2: SFU/coturn/xray/naive services are NOT in _RECONCILE_RESTART_UNITS after
#       a caddyfile change.
#   P3: apply_caddy_reloads prefers `docker compose exec caddy caddy reload` (hot-reload).
#   P4: Fallback is `docker compose up -d --force-recreate caddy` (caddy ONLY, not all).
#
# Falsification (anti-vacuous):
#   If mark_caddy_reload is replaced with mark_restart("oxpulse-partner-edge.service"),
#   P2 fails (peer services would be in restart list because the unit brings down all).
#   If apply_caddy_reloads calls `docker compose up -d` (no --force-recreate caddy),
#   P4 fails.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LIB="$REPO_ROOT/lib/reconcile.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

echo ""
echo "=== caddy peer isolation tests ==="

[[ -f "$LIB" ]] || { fail "P0: lib/reconcile.sh not found"; exit 1; }
pass "P0: lib/reconcile.sh present"

# P1: mark_caddy_reload is defined; mark_restart("oxpulse-partner-edge.service") is NOT
# called by reconcile_caddy_surface.
if grep -q 'mark_caddy_reload' "$LIB"; then
    pass "P1: mark_caddy_reload defined in lib/reconcile.sh"
else
    fail "P1: mark_caddy_reload not found — caddy change would trigger full-stack restart"
fi

# P2: reconcile_caddy_surface calls mark_caddy_reload, NOT mark_restart on the edge unit.
_caddy_fn_body=$(awk '/^reconcile_caddy_surface\(\)/,/^\}/' "$LIB" 2>/dev/null || true)
if echo "$_caddy_fn_body" | grep 'mark_caddy_reload' >/dev/null; then
    pass "P2a: reconcile_caddy_surface calls mark_caddy_reload"
else
    fail "P2a: reconcile_caddy_surface does not call mark_caddy_reload"
fi
if echo "$_caddy_fn_body" | grep -E 'mark_restart.*oxpulse-partner-edge' >/dev/null; then
    fail "P2b: reconcile_caddy_surface still calls mark_restart(oxpulse-partner-edge.service) — full-stack restart blast radius"
else
    pass "P2b: reconcile_caddy_surface does NOT call mark_restart(oxpulse-partner-edge.service)"
fi

# P3: apply_caddy_reloads calls `caddy reload` (hot-reload via admin API).
_reload_fn_body=$(awk '/^apply_caddy_reloads\(\)/,/^\}/' "$LIB" 2>/dev/null || true)
if echo "$_reload_fn_body" | grep 'caddy reload' >/dev/null; then
    pass "P3: apply_caddy_reloads uses caddy reload (hot-reload, no container down)"
else
    fail "P3: apply_caddy_reloads does not call caddy reload"
fi

# P4: Fallback uses --force-recreate caddy (not bare `up -d` which would recreate all).
if echo "$_reload_fn_body" | grep 'force-recreate caddy' >/dev/null; then
    pass "P4: apply_caddy_reloads fallback uses --force-recreate caddy (not full stack)"
else
    fail "P4: apply_caddy_reloads fallback missing --force-recreate caddy"
fi

# P5: Functional — after a caddyfile change, _RECONCILE_RESTART_UNITS is empty.
_tmpdir=$(mktemp -d)
# shellcheck disable=SC2064
trap "rm -rf '$_tmpdir'" EXIT

# Compute sha of stable content to set up STATE
_stable_sha=$(printf '# STABLE\n' | sha256sum | awk '{print $1}')

# Set up a sandbox with STATE sha=different → forces change path
mkdir -p "$_tmpdir/etc/oxpulse-partner-edge"
printf '# OLD\n' > "$_tmpdir/etc/oxpulse-partner-edge/Caddyfile"
printf 'services:\n  caddy:\n    image: test\n' > "$_tmpdir/etc/oxpulse-partner-edge/docker-compose.yml"
cat > "$_tmpdir/install.env" << STATE
PARTNER_DOMAIN=test.example.com
TURNS_SUBDOMAIN=turns.test.example.com
SCHEMA_VERSION=1
NAIVE_SOCKS_PORT=1080
AWG_MOTHERLY_IP=10.9.0.2
HY2_FALLBACK_HOST=host.docker.internal
HY2_FALLBACK_PORT=18443
CADDYFILE_SHA=sentinel_old_sha
TURN_SECRET=test-secret-p5
STATE
cp "$REPO_ROOT/manifest.yaml" "$_tmpdir/manifest.yaml"

_p5_result=$(
    set +e
    log()  { :; }
    warn() { :; }
    die()  { echo "DIE: $*" >&2; exit 1; }

    opec() {
        if [[ "${1:-}" == "render" ]]; then
            [[ "${3:-}" == "--help" ]] && return 0
            local _kind="${2:-}" _out="" _nxt=0
            for _i in "$@"; do [[ "$_nxt" -eq 1 ]] && _out="$_i" && _nxt=0; [[ "$_i" == "--out" ]] && _nxt=1; done
            if [[ -n "$_out" ]]; then
                case "$_kind" in
                    caddy) printf '# NEW Caddyfile (triggers change)\n' > "$_out" ;;
                    coturn) printf '# mock coturn\nstatic-auth-secret=test-secret\n' > "$_out" ;;
                    xray) printf '{"log":{"loglevel":"warning"}}\n' > "$_out" ;;
                    *) printf '# mock\n' > "$_out" ;;
                esac
            fi
        fi
        return 0
    }
    export -f opec

    export PREFIX_ETC="$_tmpdir/etc/oxpulse-partner-edge"
    export STATE_FILE="$_tmpdir/install.env"
    export COMPOSE_FILE="$PREFIX_ETC/docker-compose.yml"
    export REPO_DIR="$REPO_ROOT"
    export DRY_RUN=0

    # shellcheck disable=SC1090
    . "$STATE_FILE"
    # shellcheck disable=SC1090
    . "$LIB"

    # Phase 4b: stub firewall_apply.
    export FIREWALL_LIB="$REPO_ROOT/lib/install-firewall.sh"
    firewall_apply() { return 0; }
    export -f firewall_apply

    # Override apply_caddy_reloads (no real docker)
    apply_caddy_reloads() {
        echo "CADDY_RELOAD:${_RECONCILE_CADDY_RELOAD:-0}"
        _RECONCILE_CADDY_RELOAD=0
    }

    reconcile_all "$_tmpdir/manifest.yaml"

    echo "RESTART_UNITS:${_RECONCILE_RESTART_UNITS:-EMPTY}"
    echo "DONE"
)

if echo "$_p5_result" | grep "CADDY_RELOAD:1" >/dev/null; then
    pass "P5: apply_caddy_reloads fired on caddyfile change"
else
    fail "P5: caddy reload not fired on caddyfile change"
fi

if echo "$_p5_result" | grep -E "RESTART_UNITS:EMPTY|RESTART_UNITS:$" >/dev/null; then
    pass "P5a: _RECONCILE_RESTART_UNITS empty after caddyfile change (peers untouched)"
else
    _units=$(echo "$_p5_result" | grep "^RESTART_UNITS:" | cut -d: -f2-)
    fail "P5a: _RECONCILE_RESTART_UNITS non-empty after caddy change: $_units"
fi

echo ""
echo "=== caddy peer isolation: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
