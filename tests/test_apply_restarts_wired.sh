#!/bin/bash
# tests/test_apply_restarts_wired.sh — Phase 4a: apply_restarts fires on caddyfile change.
#
# Asserts:
#   AR1: apply_restarts is CALLED after reconcile_all when caddyfile changes.
#   AR2: apply_restarts does NOT fire when caddyfile is unchanged (checksum match).
#   AR3: mark_restart is called with oxpulse-partner-edge.service on caddyfile change.
#   AR4: dedup: calling mark_restart twice with same unit results in one restart.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LIB="$REPO_ROOT/lib/reconcile.sh"
MANIFEST="$REPO_ROOT/manifest.yaml"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

echo ""
echo "=== apply_restarts wiring tests ==="

# AR0: prerequisites
[[ -f "$LIB" ]] || { fail "AR0: lib/reconcile.sh not found"; exit 1; }
[[ -f "$MANIFEST" ]] || { fail "AR0: manifest.yaml not found"; exit 1; }
pass "AR0: prerequisites present"

_tmpdir=$(mktemp -d)
# shellcheck disable=SC2064
trap "rm -rf '$_tmpdir'" EXIT

# ---- Helpers shared by AR1/AR2 ----
_setup_sandbox() {
    local _subdir="$1" _caddyfile_content="$2"
    local _etc="$_tmpdir/$_subdir/etc/oxpulse-partner-edge"
    mkdir -p "$_etc"
    printf '%s\n' "$_caddyfile_content" > "$_etc/Caddyfile"
    printf 'services:\n  caddy:\n    image: test\n' > "$_etc/docker-compose.yml"
    cat > "$_tmpdir/$_subdir/install.env" << 'STATE'
PARTNER_DOMAIN=test.example.com
TURNS_SUBDOMAIN=turns.test.example.com
SCHEMA_VERSION=1
NAIVE_SOCKS_PORT=1080
AWG_MOTHERLY_IP=10.9.0.2
HY2_FALLBACK_HOST=host.docker.internal
HY2_FALLBACK_PORT=18443
CADDYFILE_SHA=oldsha
STATE
    cp "$MANIFEST" "$_tmpdir/$_subdir/manifest.yaml"
    echo "$_etc"
}

# AR1 + AR3: caddyfile changed → apply_restarts fires with oxpulse-partner-edge.service.
# Run directly in subshell (no sub-script file) to avoid heredoc-in-file nesting.
_ar1_result=$(
    set +e
    log()  { echo "[L] $*" >&2; }
    warn() { echo "[W] $*" >&2; }
    die()  { echo "[D] $*" >&2; exit 1; }

    _etc=$(_setup_sandbox ar1 "# OLD Caddyfile sha=oldsha" 2>/dev/null)

    opec() {
        if [[ "${1:-}" == "render" && "${2:-}" == "caddy" ]]; then
            [[ "${3:-}" == "--help" ]] && return 0
            local _out="" _nxt=0
            for _i in "$@"; do [[ "$_nxt" -eq 1 ]] && _out="$_i" && _nxt=0; [[ "$_i" == "--out" ]] && _nxt=1; done
            [[ -n "$_out" ]] && printf '# NEW Caddyfile sha=newsha\n' > "$_out"
        fi
        return 0
    }
    export -f opec

    export PREFIX_ETC="$_tmpdir/ar1/etc/oxpulse-partner-edge"
    export STATE_FILE="$_tmpdir/ar1/install.env"
    export COMPOSE_FILE="$PREFIX_ETC/docker-compose.yml"
    export REPO_DIR="$REPO_ROOT"
    export DRY_RUN=0

    # shellcheck disable=SC1090
    . "$STATE_FILE"
    # shellcheck disable=SC1090
    . "$LIB"

    _ar1_fired=0
    _ar1_units=""
    apply_restarts() {
        _ar1_units="${_RECONCILE_RESTART_UNITS:-}"
        [[ -n "$_ar1_units" ]] && _ar1_fired=1
        echo "FIRED:${_RECONCILE_RESTART_UNITS:-EMPTY}"
        _RECONCILE_RESTART_UNITS=""
    }

    reconcile_all "$_tmpdir/ar1/manifest.yaml"
    echo "DONE"
)

if echo "$_ar1_result" | grep -q "^FIRED:oxpulse"; then
    _units=$(echo "$_ar1_result" | grep "^FIRED:" | head -1 | cut -d: -f2-)
    pass "AR1: apply_restarts fired after caddyfile change"
    if echo "$_units" | grep -q "oxpulse-partner-edge.service"; then
        pass "AR3: oxpulse-partner-edge.service in restart list"
    else
        fail "AR3: oxpulse-partner-edge.service not in restart list (got: $_units)"
    fi
elif echo "$_ar1_result" | grep -q "^FIRED:EMPTY"; then
    fail "AR1: apply_restarts fired with empty units (mark_restart not called)"
    fail "AR3: oxpulse-partner-edge.service not marked for restart"
else
    fail "AR1: apply_restarts not called (dead code)"
    fail "AR3: cannot verify mark_restart"
    echo "AR1 output: $_ar1_result" >&2
fi

# AR2: caddyfile UNCHANGED → apply_restarts fires with empty units (no restart).
_ar2_result=$(
    set +e
    log()  { echo "[L] $*" >&2; }
    warn() { echo "[W] $*" >&2; }
    die()  { echo "[D] $*" >&2; exit 1; }

    _etc=$(_setup_sandbox ar2 "# STABLE Caddyfile sha=stable" 2>/dev/null)

    opec() {
        if [[ "${1:-}" == "render" && "${2:-}" == "caddy" ]]; then
            [[ "${3:-}" == "--help" ]] && return 0
            local _out="" _nxt=0
            for _i in "$@"; do [[ "$_nxt" -eq 1 ]] && _out="$_i" && _nxt=0; [[ "$_i" == "--out" ]] && _nxt=1; done
            # Produce SAME content as installed
            [[ -n "$_out" ]] && printf '# STABLE Caddyfile sha=stable\n' > "$_out"
        fi
        return 0
    }
    export -f opec

    export PREFIX_ETC="$_tmpdir/ar2/etc/oxpulse-partner-edge"
    export STATE_FILE="$_tmpdir/ar2/install.env"
    export COMPOSE_FILE="$PREFIX_ETC/docker-compose.yml"
    export REPO_DIR="$REPO_ROOT"
    export DRY_RUN=0

    # shellcheck disable=SC1090
    . "$STATE_FILE"
    # shellcheck disable=SC1090
    . "$LIB"

    apply_restarts() {
        echo "FIRED:${_RECONCILE_RESTART_UNITS:-EMPTY}"
        _RECONCILE_RESTART_UNITS=""
    }

    reconcile_all "$_tmpdir/ar2/manifest.yaml"
    echo "DONE"
)

if echo "$_ar2_result" | grep -q "^FIRED:EMPTY"; then
    pass "AR2: apply_restarts fired with empty units (no restart when unchanged)"
elif echo "$_ar2_result" | grep -q "^FIRED:"; then
    _u=$(echo "$_ar2_result" | grep "^FIRED:" | head -1 | cut -d: -f2-)
    fail "AR2: restart fired when caddyfile was unchanged (units: $_u)"
else
    fail "AR2: apply_restarts not called"
    echo "AR2 output: $_ar2_result" >&2
fi

# AR4: dedup test via mark_restart directly.
_ar4_result=$(
    set +e
    log()  { :; }; warn() { :; }; die() { exit 1; }
    # shellcheck disable=SC1090
    . "$LIB"
    apply_restarts() {
        local _cnt=0
        for _u in $_RECONCILE_RESTART_UNITS; do _cnt=$((_cnt+1)); done
        echo "DISTINCT_UNITS=$_cnt"
        _RECONCILE_RESTART_UNITS=""
    }
    mark_restart "oxpulse-partner-edge.service"
    mark_restart "oxpulse-partner-edge.service"
    mark_restart "oxpulse-partner-edge.service"
    apply_restarts
)

_distinct=$(echo "$_ar4_result" | grep "^DISTINCT_UNITS=" | cut -d= -f2)
if [[ "${_distinct:-0}" -eq 1 ]]; then
    pass "AR4: mark_restart dedup — 3 calls → 1 distinct unit"
else
    fail "AR4: dedup failed — expected 1, got ${_distinct:-?}"
fi

echo ""
echo "=== apply_restarts wiring: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
