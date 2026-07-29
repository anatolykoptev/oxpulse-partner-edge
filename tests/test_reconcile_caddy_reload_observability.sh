#!/bin/bash
# tests/test_reconcile_caddy_reload_observability.sh
#
# FIX 3(a): apply_caddy_reloads must NOT swallow the caddy reload stderr, and on a
# reload+recreate double-failure it must PERSIST the just-rendered Caddyfile to a
# timestamped file for post-mortem.
#
# Root cause under test:
#   apply_caddy_reloads ran `... caddy reload ... 2>/dev/null` and `... up -d
#   --force-recreate caddy 2>/dev/null` - so when a reload failed, WHY it failed
#   (the caddy adapter/parse error) was discarded, and the un-loadable Caddyfile
#   was gone by the time an operator looked. A RU relay silently kept serving the
#   stale config with no forensic trail.
#
# Fix under test:
#   The stderr of each path is captured (2>&1) and surfaced in a warn; on a double
#   failure the on-disk rendered Caddyfile is copied to
#   $PARTNER_EDGE_LOG_DIR/caddy-reload-fail-<UTC-ts>.caddy (non-fatal).
#
# Falsification (anti-vacuous):
#   P2 injects a distinctive stderr string and asserts it reaches the warn output;
#   restoring `2>/dev/null` drops it (FAIL). P1 asserts the persisted file exists
#   with the Caddyfile's content; removing the persist call drops it (FAIL).
#
# REAL-CODE MANDATE: sources the real lib/reconcile.sh and drives the real
# apply_caddy_reloads / _reconcile_persist_failed_caddyfile. Only docker is stubbed.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LIB="$REPO_ROOT/lib/reconcile.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

echo ""
echo "=== FIX 3(a): caddy reload stderr surfaced + un-loadable Caddyfile persisted ==="

[[ -f "$LIB" ]] || { fail "P0: lib/reconcile.sh not found"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --- P1: _reconcile_persist_failed_caddyfile writes a timestamped copy. ---
P1_ETC="$TMP/p1_etc"; mkdir -p "$P1_ETC"
printf '# CADDYFILE-UNDER-TEST-CONTENT\n:80 { respond "x" }\n' > "$P1_ETC/Caddyfile"
P1_LOG="$TMP/p1_log"
P1_OUT=$(
    log()  { :; }
    warn() { echo "[W] $*"; }
    # shellcheck disable=SC1090
    . "$LIB"
    export PREFIX_ETC="$P1_ETC"
    export PARTNER_EDGE_LOG_DIR="$P1_LOG"
    _reconcile_persist_failed_caddyfile
    echo "RC:$?"
)
_p1_file=$(ls "$P1_LOG"/caddy-reload-fail-*.caddy 2>/dev/null | head -1 || true)
if [[ -n "$_p1_file" ]] && grep -q 'CADDYFILE-UNDER-TEST-CONTENT' "$_p1_file"; then
    pass "P1: rendered Caddyfile persisted to a timestamped post-mortem file with its content"
else
    fail "P1: no timestamped Caddyfile persisted (file='$_p1_file'); out: $P1_OUT"
fi
# Timestamp must come from the system, not a hardcoded literal (UTC ...Z form).
if [[ -n "$_p1_file" ]] && basename "$_p1_file" | grep -E 'caddy-reload-fail-[0-9]{8}T[0-9]{6}Z\.caddy' >/dev/null; then
    pass "P1b: post-mortem filename carries a system UTC timestamp (not hardcoded)"
else
    fail "P1b: persisted filename lacks a UTC timestamp: '$_p1_file'"
fi
# The post-mortem copy must be operator-only (0600): a future template regression that
# inlines a secret must not land it in a world-readable file (Caddyfile.tpl:387 invariant).
if [[ -n "$_p1_file" ]] && [[ "$(stat -c %a "$_p1_file" 2>/dev/null)" == "600" ]]; then
    pass "P1c: persisted Caddyfile is mode 0600 (operator-only, no world-read of a future secret)"
else
    fail "P1c: persisted Caddyfile mode is '$(stat -c %a "$_p1_file" 2>/dev/null)', expected 600"
fi

# --- P2: apply_caddy_reloads surfaces the reload stderr on a double failure and
#         persists the Caddyfile. ---
P2_ETC="$TMP/p2_etc"; mkdir -p "$P2_ETC"
printf '# P2-CADDYFILE\n' > "$P2_ETC/Caddyfile"
printf 'services:\n  caddy:\n    image: test\n' > "$P2_ETC/docker-compose.yml"
P2_LOG="$TMP/p2_log"
P2_OUT=$( (
    log()  { :; }
    warn() { echo "[W] $*"; }
    # shellcheck disable=SC1090
    . "$LIB"
    # docker stub: both paths fail, each emitting a distinctive stderr string.
    docker() {
        if [[ "$*" == *"exec"* ]]; then
            echo "SIMULATED-RELOAD-ADAPTER-ERR" >&2; return 1
        fi
        if [[ "$*" == *"force-recreate"* ]]; then
            echo "SIMULATED-RECREATE-ERR" >&2; return 1
        fi
        return 1
    }
    export -f docker
    export DOCKER_BIN="docker"
    export COMPOSE_FILE="$P2_ETC/docker-compose.yml"
    export PREFIX_ETC="$P2_ETC"
    export PARTNER_EDGE_LOG_DIR="$P2_LOG"
    _RECONCILE_CADDY_RELOAD=1
    apply_caddy_reloads
    echo "RC:$?"
) 2>&1 )

if echo "$P2_OUT" | grep 'SIMULATED-RELOAD-ADAPTER-ERR' >/dev/null; then
    pass "P2: caddy reload stderr is surfaced (no longer swallowed by 2>/dev/null)"
else
    fail "P2: reload stderr NOT surfaced; out: $P2_OUT"
fi
if echo "$P2_OUT" | grep 'SIMULATED-RECREATE-ERR' >/dev/null; then
    pass "P2b: caddy force-recreate stderr is surfaced too"
else
    fail "P2b: force-recreate stderr NOT surfaced; out: $P2_OUT"
fi
if echo "$P2_OUT" | grep -E 'RC:[1-9]' >/dev/null; then
    pass "P2c: apply_caddy_reloads still returns non-zero on double failure (fail-loud preserved)"
else
    fail "P2c: apply_caddy_reloads did not return non-zero; out: $P2_OUT"
fi
_p2_file=$(ls "$P2_LOG"/caddy-reload-fail-*.caddy 2>/dev/null | head -1 || true)
if [[ -n "$_p2_file" ]] && grep -q 'P2-CADDYFILE' "$_p2_file"; then
    pass "P2d: double failure persisted the un-loadable Caddyfile for post-mortem"
else
    fail "P2d: Caddyfile not persisted on double failure (file='$_p2_file')"
fi

# --- P3: persist is non-fatal when there is no rendered Caddyfile. ---
P3_OUT=$(
    log()  { :; }
    warn() { :; }
    # shellcheck disable=SC1090
    . "$LIB"
    export PREFIX_ETC="$TMP/nonexistent_etc"
    export PARTNER_EDGE_LOG_DIR="$TMP/p3_log"
    _reconcile_persist_failed_caddyfile
    echo "RC:$?"
)
if echo "$P3_OUT" | grep 'RC:0' >/dev/null && [[ ! -d "$TMP/p3_log" || -z "$(ls -A "$TMP/p3_log" 2>/dev/null)" ]]; then
    pass "P3: persist is a silent no-op (rc=0, no file) when no Caddyfile is present"
else
    fail "P3: persist mishandled the absent-Caddyfile case; out: $P3_OUT"
fi

echo ""
echo "=== caddy reload observability: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
