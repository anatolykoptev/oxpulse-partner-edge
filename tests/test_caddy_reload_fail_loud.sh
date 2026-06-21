#!/bin/bash
# tests/test_caddy_reload_fail_loud.sh — Fix 1: apply_caddy_reloads fails loud on double-failure.
#
# Asserts:
#   RF1: apply_caddy_reloads returns non-zero when BOTH hot-reload AND force-recreate fail.
#   RF2: apply_caddy_reloads returns 0 when hot-reload succeeds (single-path success).
#   RF3: apply_caddy_reloads returns 0 when only force-recreate succeeds (fallback path).
#   RF4: reconcile_all returns non-zero (via die) when caddy double-failure occurs.
#   RF5: reconcile_all logs the failure (not silent).
#
# Falsification (anti-vacuous):
#   RF1: if `return 1` is removed from the double-failure path, RF1 FAILS (rc=0 from silent warn).
#   RF4: if reconcile_all does not capture apply_caddy_reloads rc, RF4 FAILS (exit 0 on double-fail).
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LIB="$REPO_ROOT/lib/reconcile.sh"
MANIFEST="$REPO_ROOT/manifest.yaml"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

echo ""
echo "=== caddy reload fail-loud tests ==="

[[ -f "$LIB" ]] || { fail "RF0: lib/reconcile.sh not found"; exit 1; }
[[ -f "$MANIFEST" ]] || { fail "RF0: manifest.yaml not found"; exit 1; }
pass "RF0: prerequisites present"

# Static checks first (fast, no subshell).

# RF1s: return 1 statement present in apply_caddy_reloads double-failure path.
_reload_fn=$(awk '/^apply_caddy_reloads\(\)/,/^\}/' "$LIB" 2>/dev/null || true)
if echo "$_reload_fn" | grep -q 'return 1'; then
    pass "RF1s: apply_caddy_reloads has return 1 on double-failure path"
else
    fail "RF1s: apply_caddy_reloads missing return 1 — double-failure is silent"
fi

# RF4s: reconcile_all captures apply_caddy_reloads rc.
_reconcile_fn=$(awk '/^reconcile_all\(\)/,/^\}/' "$LIB" 2>/dev/null || true)
if echo "$_reconcile_fn" | grep -qE '_caddy_reload_rc|apply_caddy_reloads \|\|'; then
    pass "RF4s: reconcile_all captures apply_caddy_reloads return code"
else
    fail "RF4s: reconcile_all does not capture apply_caddy_reloads rc — double-failure propagation broken"
fi

_tmpdir=$(mktemp -d)
# shellcheck disable=SC2064
trap "rm -rf '$_tmpdir'" EXIT

# Helper: minimal sandbox for functional tests.
_make_sandbox() {
    local _dir="$_tmpdir/$1"
    local _etc="$_dir/etc/oxpulse-partner-edge"
    mkdir -p "$_etc"
    printf '# OLD\n' > "$_etc/Caddyfile"
    printf 'services:\n  caddy:\n    image: test\n' > "$_etc/docker-compose.yml"
    cat > "$_dir/install.env" << 'STATE'
PARTNER_DOMAIN=test.example.com
TURNS_SUBDOMAIN=turns.test.example.com
SCHEMA_VERSION=1
NAIVE_SOCKS_PORT=1080
AWG_MOTHERLY_IP=10.9.0.2
HY2_FALLBACK_HOST=host.docker.internal
HY2_FALLBACK_PORT=18443
CADDYFILE_SHA=sentinel_old
TURN_SECRET=test-secret-rf
STATE
    cp "$MANIFEST" "$_dir/manifest.yaml"
    echo "$_dir"
}

# RF1: apply_caddy_reloads returns non-zero when BOTH paths fail.
_rf1_rc=0
_rf1_out=$( (
    log()  { echo "[L] $*" >&2; }
    warn() { echo "[W] $*" >&2; }
    die()  { echo "[D] $*" >&2; exit 1; }
    # shellcheck disable=SC1090
    . "$LIB"

    # Both docker paths fail.
    export DOCKER_BIN="false"
    COMPOSE_FILE="/dev/null"
    _RECONCILE_CADDY_RELOAD=1

    apply_caddy_reloads
    echo "RC:$?"
) 2>/dev/null || true )

if echo "$_rf1_out" | grep -q "RC:0"; then
    fail "RF1: apply_caddy_reloads returned 0 on double-failure (should be non-zero)"
elif echo "$_rf1_out" | grep -qE "RC:[1-9]"; then
    pass "RF1: apply_caddy_reloads returns non-zero on double-failure"
else
    # rc non-zero via exit (e.g. die call) — that's also acceptable loud failure.
    pass "RF1: apply_caddy_reloads exits non-zero on double-failure"
fi

# RF2: returns 0 when hot-reload succeeds.
_rf2_out=$( (
    log()  { :; }
    warn() { :; }
    die()  { echo "[D] $*" >&2; exit 1; }
    # shellcheck disable=SC1090
    . "$LIB"

    # Override docker to succeed on exec (hot-reload path).
    docker() {
        if [[ "${*}" == *"exec"* ]]; then return 0; fi
        return 1
    }
    export -f docker
    DOCKER_BIN="docker"
    COMPOSE_FILE="/dev/null"
    _RECONCILE_CADDY_RELOAD=1

    apply_caddy_reloads
    echo "RC:$?"
) 2>/dev/null || true )

if echo "$_rf2_out" | grep -q "RC:0"; then
    pass "RF2: apply_caddy_reloads returns 0 when hot-reload succeeds"
else
    fail "RF2: apply_caddy_reloads returned non-zero even though hot-reload succeeded"
fi

# RF3: returns 0 when only force-recreate succeeds (hot-reload fails, fallback succeeds).
_rf3_out=$( (
    log()  { :; }
    warn() { :; }
    die()  { echo "[D] $*" >&2; exit 1; }
    # shellcheck disable=SC1090
    . "$LIB"

    _exec_call=0
    docker() {
        if [[ "${*}" == *"exec"* ]]; then return 1; fi   # hot-reload fails
        if [[ "${*}" == *"force-recreate"* ]]; then return 0; fi  # fallback succeeds
        return 1
    }
    export -f docker
    DOCKER_BIN="docker"
    COMPOSE_FILE="/dev/null"
    _RECONCILE_CADDY_RELOAD=1

    apply_caddy_reloads
    echo "RC:$?"
) 2>/dev/null || true )

if echo "$_rf3_out" | grep -q "RC:0"; then
    pass "RF3: apply_caddy_reloads returns 0 when fallback (force-recreate) succeeds"
else
    fail "RF3: apply_caddy_reloads returned non-zero even though fallback succeeded"
fi

# RF4: reconcile_all returns non-zero (die) when caddy double-failure occurs.
_rf4_dir=$(_make_sandbox rf4)
_rf4_result=$( (
    set +e
    log()  { echo "[L] $*" >&2; }
    warn() { echo "[W] $*" >&2; }
    # die() triggers a non-zero exit — capture it.
    die()  { echo "DIE: $*" >&2; exit 1; }

    opec() {
        if [[ "${1:-}" == "render" ]]; then
            [[ "${3:-}" == "--help" ]] && return 0
            local _kind="${2:-}" _out="" _nxt=0
            for _i in "$@"; do [[ "$_nxt" -eq 1 ]] && _out="$_i" && _nxt=0; [[ "$_i" == "--out" ]] && _nxt=1; done
            if [[ -n "$_out" ]]; then
                case "$_kind" in
                    caddy) printf '# NEW (triggers change)\n' > "$_out" ;;
                    coturn) printf '# mock coturn\nstatic-auth-secret=test-secret\n' > "$_out" ;;
                    xray) printf '{"log":{"loglevel":"warning"}}\n' > "$_out" ;;
                    *) printf '# mock\n' > "$_out" ;;
                esac
            fi
        fi
        return 0
    }
    export -f opec

    export PREFIX_ETC="$_rf4_dir/etc/oxpulse-partner-edge"
    export STATE_FILE="$_rf4_dir/install.env"
    export COMPOSE_FILE="$PREFIX_ETC/docker-compose.yml"
    export REPO_DIR="$REPO_ROOT"
    export DRY_RUN=0

    # shellcheck disable=SC1090
    . "$STATE_FILE"
    # shellcheck disable=SC1090
    . "$LIB"

    # Phase 4b: stub firewall_apply so reconcile_firewall_surface works without ufw/firewalld.
    export FIREWALL_LIB="$REPO_ROOT/lib/install-firewall.sh"
    firewall_apply() { return 0; }
    export -f firewall_apply

    # Both docker paths fail.
    export DOCKER_BIN="false"

    reconcile_all "$_rf4_dir/manifest.yaml"
    echo "RECONCILE_RC:0"   # only reached if reconcile_all returns 0
) 2>&1 || true )

_rf4_rc_zero=$(echo "$_rf4_result" | grep -c "RECONCILE_RC:0" || true)
_rf4_die=$(echo "$_rf4_result" | grep -c "DIE:" || true)

if [[ "$_rf4_rc_zero" -gt 0 ]]; then
    fail "RF4: reconcile_all returned 0 on caddy double-failure — silent success bug still present"
elif [[ "$_rf4_die" -gt 0 ]]; then
    pass "RF4: reconcile_all dies (non-zero) on caddy double-failure"
else
    pass "RF4: reconcile_all exits non-zero on caddy double-failure (no silent success)"
fi

# RF5: reconcile_all logs the failure (warn/die message visible).
if echo "$_rf4_result" | grep -qiE "DIE:.*caddy|double.failure|NOT live"; then
    pass "RF5: reconcile_all emits a meaningful caddy-reload-failure message"
else
    fail "RF5: reconcile_all did not emit a clear caddy-reload-failure message"
fi

echo ""
echo "=== caddy reload fail-loud: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
