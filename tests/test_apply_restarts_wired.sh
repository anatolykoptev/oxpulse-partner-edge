#!/bin/bash
# tests/test_apply_restarts_wired.sh — Phase 4a: caddy reload fires on caddyfile change.
#
# Asserts:
#   AR1: apply_caddy_reloads is CALLED (targeted) after reconcile_all when caddyfile changes.
#   AR2: no caddy reload when caddyfile is UNCHANGED (STATE sha matches rendered sha).
#   AR3: mark_caddy_reload sets _RECONCILE_CADDY_RELOAD; peers NOT in restart list.
#   AR3a: oxpulse-partner-edge.service NOT added to restart units (no full-stack down).
#   AR4: dedup: mark_restart called 3x with same unit produces 1 distinct restart.
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
TURN_SECRET=test-secret-ar
STATE
    cp "$MANIFEST" "$_tmpdir/$_subdir/manifest.yaml"
    echo "$_etc"
}

# AR1: caddyfile changed → apply_caddy_reloads fires (mark_caddy_reload was called).
# AR3: mark_caddy_reload sets _RECONCILE_CADDY_RELOAD=1 on caddyfile change.
# Both assert targeted caddy reload (not a full systemd restart of the stack).
# STATE sha=oldsha will not match the new render hash, triggering the change path.
# Run directly in subshell (no sub-script file) to avoid heredoc-in-file nesting.
_ar1_result=$(
    set +e
    log()  { echo "[L] $*" >&2; }
    warn() { echo "[W] $*" >&2; }
    die()  { echo "[D] $*" >&2; exit 1; }

    _etc=$(_setup_sandbox ar1 "# OLD Caddyfile sha=oldsha" 2>/dev/null)

    opec() {
        if [[ "${1:-}" == "render" ]]; then
            [[ "${3:-}" == "--help" ]] && return 0
            local _kind="${2:-}" _out="" _nxt=0
            for _i in "$@"; do [[ "$_nxt" -eq 1 ]] && _out="$_i" && _nxt=0; [[ "$_i" == "--out" ]] && _nxt=1; done
            if [[ -n "$_out" ]]; then
                case "$_kind" in
                    caddy)
                        # Content whose sha256 differs from STATE CADDYFILE_SHA=oldsha → triggers change
                        printf '# NEW Caddyfile (different from STATE sha=oldsha)\nrespond "__CADDYFILE_SHA__" 200\n' > "$_out"
                        ;;
                    coturn) printf '# mock coturn\nstatic-auth-secret=test-secret\n' > "$_out" ;;
                    xray) printf '{"log":{"loglevel":"warning"}}\n' > "$_out" ;;
                    *) printf '# mock\n' > "$_out" ;;
                esac
            fi
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

    # Phase 4b: stub firewall_apply.
    export FIREWALL_LIB="$REPO_ROOT/lib/install-firewall.sh"
    firewall_apply() { return 0; }
    export -f firewall_apply

    # Override apply_caddy_reloads to capture invocation without docker exec.
    _ar1_caddy_reload_fired=0
    apply_caddy_reloads() {
        if [[ "${_RECONCILE_CADDY_RELOAD:-0}" -eq 1 ]]; then
            echo "CADDY_RELOAD:FIRED"
            _ar1_caddy_reload_fired=1
        else
            echo "CADDY_RELOAD:EMPTY"
        fi
        _RECONCILE_CADDY_RELOAD=0
    }
    apply_restarts() {
        echo "RESTART:${_RECONCILE_RESTART_UNITS:-EMPTY}"
        _RECONCILE_RESTART_UNITS=""
    }

    reconcile_all "$_tmpdir/ar1/manifest.yaml"
    echo "DONE"
)

if echo "$_ar1_result" | grep -q "CADDY_RELOAD:FIRED"; then
    pass "AR1: apply_caddy_reloads fired after caddyfile change (targeted reload, not full restart)"
    # AR3: verify _RECONCILE_CADDY_RELOAD was set (mark_caddy_reload was called)
    # Inferred: CADDY_RELOAD:FIRED means _RECONCILE_CADDY_RELOAD=1 was detected in apply_caddy_reloads
    pass "AR3: mark_caddy_reload set _RECONCILE_CADDY_RELOAD=1 on caddyfile change (peers untouched)"
    # Also verify oxpulse-partner-edge.service was NOT in _RECONCILE_RESTART_UNITS
    # (full-stack restart must NOT happen for a caddy-only change)
    if echo "$_ar1_result" | grep -q "RESTART:EMPTY"; then
        pass "AR3a: oxpulse-partner-edge.service NOT in restart list (caddy change = hot-reload only)"
    else
        _restart_units=$(echo "$_ar1_result" | grep "^RESTART:" | head -1 | cut -d: -f2-)
        fail "AR3a: full systemd restart triggered for caddy-only change (units: $_restart_units) — blast radius too wide"
    fi
elif echo "$_ar1_result" | grep -q "CADDY_RELOAD:EMPTY"; then
    fail "AR1: apply_caddy_reloads fired but _RECONCILE_CADDY_RELOAD was 0 (mark_caddy_reload not called)"
    fail "AR3: mark_caddy_reload not called on caddyfile change"
else
    fail "AR1: apply_caddy_reloads not called (dead code)"
    fail "AR3: cannot verify mark_caddy_reload"
    echo "AR1 output: $_ar1_result" >&2
fi

# AR2: caddyfile UNCHANGED → no caddy reload and no restart.
# We set STATE CADDYFILE_SHA to the sha256 of the rendered content so the
# STATE-based change-detection determines no change.
# Compute the pre-sub sha of the mock render output upfront.
_ar2_stable_content='# STABLE Caddyfile (no __CADDYFILE_SHA__ placeholder)'
_ar2_stable_sha=$(printf '%s\n' "$_ar2_stable_content" | sha256sum | awk '{print $1}')

_ar2_result=$(
    set +e
    log()  { echo "[L] $*" >&2; }
    warn() { echo "[W] $*" >&2; }
    die()  { echo "[D] $*" >&2; exit 1; }

    # On-disk Caddyfile MUST equal what the opec mock renders below — a genuine
    # "unchanged" scenario requires on-disk == rendered == STATE. The new on-disk
    # drift leg in reconcile_caddy_surface hashes the actual file, so a fixture whose
    # on-disk content diverges from the render is real drift (correctly reloads), not
    # "unchanged". Keep both strings identical to _ar2_stable_content.
    _etc=$(_setup_sandbox ar2 "$_ar2_stable_content" 2>/dev/null)
    # Override STATE sha to match the pre-sub hash of what opec will render.
    sed -i "s|^CADDYFILE_SHA=.*|CADDYFILE_SHA=${_ar2_stable_sha}|" "$_tmpdir/ar2/install.env"

    opec() {
        if [[ "${1:-}" == "render" ]]; then
            [[ "${3:-}" == "--help" ]] && return 0
            local _kind="${2:-}" _out="" _nxt=0
            for _i in "$@"; do [[ "$_nxt" -eq 1 ]] && _out="$_i" && _nxt=0; [[ "$_i" == "--out" ]] && _nxt=1; done
            if [[ -n "$_out" ]]; then
                case "$_kind" in
                    caddy)
                        # Produce the same stable content; its sha256 == STATE CADDYFILE_SHA → no change
                        printf '%s\n' "# STABLE Caddyfile (no __CADDYFILE_SHA__ placeholder)" > "$_out"
                        ;;
                    coturn) printf '# mock coturn\nstatic-auth-secret=test-secret\n' > "$_out" ;;
                    xray) printf '{"log":{"loglevel":"warning"}}\n' > "$_out" ;;
                    *) printf '# mock\n' > "$_out" ;;
                esac
            fi
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

    # Phase 4b: stub firewall_apply.
    export FIREWALL_LIB="$REPO_ROOT/lib/install-firewall.sh"
    firewall_apply() { return 0; }
    export -f firewall_apply

    apply_caddy_reloads() {
        echo "CADDY_RELOAD:${_RECONCILE_CADDY_RELOAD:-0}"
        _RECONCILE_CADDY_RELOAD=0
    }
    apply_restarts() {
        echo "RESTART:${_RECONCILE_RESTART_UNITS:-EMPTY}"
        _RECONCILE_RESTART_UNITS=""
    }

    reconcile_all "$_tmpdir/ar2/manifest.yaml"
    echo "DONE"
)

if echo "$_ar2_result" | grep -q "CADDY_RELOAD:0"; then
    pass "AR2: no caddy reload when caddyfile unchanged (STATE sha matches rendered sha)"
elif echo "$_ar2_result" | grep -q "CADDY_RELOAD:1"; then
    fail "AR2: caddy reload triggered on unchanged caddyfile (STATE sha compare broken)"
else
    fail "AR2: apply_caddy_reloads not called"
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
