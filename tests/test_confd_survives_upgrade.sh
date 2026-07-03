#!/bin/bash
# tests/test_confd_survives_upgrade.sh
#
# Verifies that a Caddyfile converge preserves conf.d/ content.
#
# The Caddyfile render authority is reconcile_caddy_surface (opec render caddy +
# single-file atomic_swap), driven by upgrade.sh via reconcile_all. The legacy
# re_render_caddy shell renderer this test used to exercise was deleted in the
# Phase 5 strangler completion (0 production callers); this test was retargeted to
# the live path so the conf.d-survival invariant is guarded against the real code.
#
# Strategy: source the REAL lib/reconcile.sh, stub ONLY opec (the Rust binary is
# absent in CI) to emit a deterministic candidate, and use the REAL atomic_swap.
# STATE records a DIFFERENT CADDYFILE_SHA than the render → a real converge (swap)
# fires. Pre-seed conf.d/ with a sentinel and assert it is byte-identical after the
# converge. FALSIFICATION: if reconcile_caddy_surface ever wrote outside the single
# Caddyfile (e.g. rewrote or cleared $PREFIX_ETC), the sentinel sha would change and
# this test would FAIL.
set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LIB="$REPO_ROOT/lib/reconcile.sh"

[[ -f "$LIB" ]] || { echo "FAIL: lib/reconcile.sh not found at $LIB"; exit 1; }
bash -n "$LIB" || { echo "FAIL: lib/reconcile.sh syntax errors"; exit 1; }
echo "OK: syntax clean"

TMP=$(mktemp -d)
# shellcheck disable=SC2064
trap "rm -rf '${TMP}'" EXIT

ETC="$TMP/etc"
CONFD="$ETC/conf.d"
mkdir -p "$CONFD"

# Pre-populate conf.d/ with a sentinel vhost file (mirrors the real
# cheburator-vhosts.caddy on a production edge).
SENTINEL_PATH="$CONFD/cheburator-vhosts.caddy"
printf '%s\n' 'cheburator.bot { respond "sentinel" }' > "$SENTINEL_PATH"
SENTINEL_SHA=$(sha256sum "$SENTINEL_PATH" | awk '{print $1}')

# Old Caddyfile on disk (will be swapped out by the converge).
printf '# old Caddyfile\n' > "$ETC/Caddyfile"

# compose with caddy service present → defeats the piter/SFU-only skip guard.
cat > "$ETC/docker-compose.yml" << 'COMPOSE'
services:
  caddy:
    image: ghcr.io/anatolykoptev/partner-edge-caddy:latest
COMPOSE

# STATE with a CADDYFILE_SHA that does NOT match the render → forces a swap.
cat > "$TMP/install.env" << 'STATE'
PARTNER_DOMAIN=test.example.com
TURNS_SUBDOMAIN=turns.test.example.com
NAIVE_SOCKS_PORT=1080
CADDYFILE_SHA=deadbeef-does-not-match
STATE

# Deterministic rendered candidate the opec stub will emit (pre-sub form).
MOCK="$TMP/mock_render.caddy"
printf '# rendered Caddyfile for test.example.com\nrespond "__CADDYFILE_SHA__" 200\n' > "$MOCK"

# Dummy template (opec stub ignores content; must exist for the -f checks and the
# NAIVE die-guard grep — carries no {{NAIVE_SOCKS_PORT}}).
TPL="$TMP/Caddyfile.tpl"
printf '# tpl\nrespond "__CADDYFILE_SHA__" 200\n' > "$TPL"

echo "==> Test 1: reconcile_caddy_surface converge does not touch conf.d/"
OUT=$(bash -c '
    set -uo pipefail
    ETC="'"$ETC"'"; TMP="'"$TMP"'"; LIB="'"$LIB"'"; MOCK="'"$MOCK"'"; TPL="'"$TPL"'"

    export PREFIX_ETC="$ETC"
    export STATE_FILE="$TMP/install.env"
    export COMPOSE_FILE="$ETC/docker-compose.yml"
    export DOCKER_BIN="false"
    export DRY_RUN=0
    export PARTNER_DOMAIN="test.example.com"
    export TURNS_SUBDOMAIN="turns.test.example.com"
    export NAIVE_SOCKS_PORT="1080"
    export PARTNER_EDGE_TEXTFILE_DIR="$TMP/textfile"

    # shellcheck disable=SC1090
    . "$LIB"

    # opec stub: emit the deterministic candidate to --out (real atomic_swap installs it).
    opec() {
        if [[ "${1:-}" == "render" && "${2:-}" == "caddy" ]]; then
            [[ "${3:-}" == "--help" ]] && return 0
            local _out="" _next=0 _a
            for _a in "$@"; do
                [[ "$_next" -eq 1 ]] && { _out="$_a"; _next=0; }
                [[ "$_a" == "--out" ]] && _next=1
            done
            [[ -n "$_out" ]] && cp "$MOCK" "$_out"
            return 0
        fi
        return 0
    }

    CAND="$TMP/cand"; mkdir -p "$CAND"
    reconcile_caddy_surface "$CAND" "$TPL"
' 2>&1) || { echo "FAIL: reconcile_caddy_surface returned non-zero"; echo "$OUT" >&2; exit 1; }

# The converge must have replaced the Caddyfile (old "# old Caddyfile" → rendered).
grep -q "rendered Caddyfile for test.example.com" "$ETC/Caddyfile" \
    || { echo "FAIL: Caddyfile not re-rendered by converge"; echo "$OUT" >&2; exit 1; }
echo "OK: Caddyfile converged (swap fired)"

# The sentinel conf.d file must be byte-identical (untouched by the converge).
[[ -f "$SENTINEL_PATH" ]] \
    || { echo "FAIL: sentinel conf.d file deleted by converge"; exit 1; }
POST_SHA=$(sha256sum "$SENTINEL_PATH" | awk '{print $1}')
[[ "$POST_SHA" == "$SENTINEL_SHA" ]] \
    || { echo "FAIL: sentinel sha256 changed: before=$SENTINEL_SHA after=$POST_SHA"; exit 1; }
echo "OK: conf.d/cheburator-vhosts.caddy unchanged after converge (sha=$POST_SHA)"

echo ""
echo "PASS: conf.d/ survives a Caddyfile converge (reconcile_caddy_surface)"
