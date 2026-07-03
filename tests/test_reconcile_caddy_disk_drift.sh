#!/bin/bash
# tests/test_reconcile_caddy_disk_drift.sh
#
# v0.14.1 canary regression guard: reconcile_caddy_surface must detect ON-DISK
# Caddyfile drift and converge the file to the template EVEN WHEN the STATE-recorded
# CADDYFILE_SHA already matches the freshly-rendered candidate.
#
# The bug class this guards (silent-skip): reconcile compared the rendered candidate
# only against STATE CADDYFILE_SHA and skipped the atomic_swap on a match. But the
# on-disk Caddyfile can DRIFT from STATE (operator hand-edit, or a stale pre-#273
# Caddyfile carrying the illegal `reverse_proxy xray-client:3080/health` upstream that
# Caddy v2.11.2 rejects). A STATE-only skip left that broken file live forever and the
# #273 fix (afe18ff) never reached the edge → check_13 canary/tunnel 502.
#
# This test sources the REAL lib/reconcile.sh (no hand-copied logic) and drives
# reconcile_caddy_surface directly. FALSIFICATION: revert the on-disk drift guard so
# reconcile skips on a STATE match alone → Scenario A yields 0 swaps + drift gauge 0,
# and this test FAILS. No opec/docker required (stubbed) → runs anywhere.
set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LIB="$REPO_ROOT/lib/reconcile.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

echo ""
echo "=== reconcile_caddy on-disk drift convergence (v0.14.1 canary) ==="

if [[ ! -f "$LIB" ]]; then
    fail "lib/reconcile.sh not found at $LIB"
    echo "FAIL: 0/$((PASS+FAIL)) tests passed"
    exit 1
fi
pass "lib/reconcile.sh exists"

_tmp=$(mktemp -d)
# shellcheck disable=SC2064
trap "rm -rf '${_tmp}'" EXIT

# ---------------------------------------------------------------------------
# Runner (subshell): sandbox + REAL lib source + stubbed opec/atomic_swap.
#   $1 = per-scenario sandbox dir
#   $2 = repo root
#   $3 = on-disk seed: a file path whose content becomes the initial /etc Caddyfile,
#        OR the literal "__CLEAN__" (runner writes the correct rendered+substituted
#        file, i.e. the no-drift control — guaranteed byte-identical to a fresh swap).
# Prints: SWAPS=<n>  GAUGE=<0|1|NONE>  CONVERGED=<yes|no>
# ---------------------------------------------------------------------------
cat > "$_tmp/run.sh" << 'RUNNER'
#!/bin/bash
set -uo pipefail
TMP="$1"; REPO_ROOT="$2"; ONDISK_SRC="$3"
LIB="$REPO_ROOT/lib/reconcile.sh"
mkdir -p "$TMP"

_SWAPS=0
log()  { echo "[LOG] $*"  >&2; }
warn() { echo "[WARN] $*" >&2; }
die()  { echo "[DIE] $*"  >&2; exit 7; }

ETC="$TMP/etc"; mkdir -p "$ETC"
export PREFIX_ETC="$ETC"
export STATE_FILE="$TMP/install.env"
export COMPOSE_FILE="$ETC/docker-compose.yml"
export DOCKER_BIN="false"          # never run docker
export DRY_RUN=0
export PARTNER_DOMAIN="test.example.com"
export TURNS_SUBDOMAIN="turns.test.example.com"
export NAIVE_SOCKS_PORT="1080"     # tier-1 resolution → no docker inspect
export PARTNER_EDGE_TEXTFILE_DIR="$TMP/textfile"

# caddy service present → defeats the piter/SFU-only skip guard.
cat > "$COMPOSE_FILE" << 'COMPOSE'
services:
  caddy:
    image: ghcr.io/anatolykoptev/partner-edge-caddy:v0.14.1
COMPOSE

# Deterministic rendered candidate (pre-sub: __CADDYFILE_SHA__ still literal).
MOCK="$TMP/mock_render.caddy"
printf '# mock Caddyfile (disk-drift test)\nrespond "__CADDYFILE_SHA__" 200\n' > "$MOCK"
RENDERED_SHA=$(sha256sum "$MOCK" | awk '{print $1}')

# STATE records EXACTLY the rendered pre-sub sha → STATE "matches" the render, so the
# only thing that can legitimately force a swap is on-disk drift detection.
cat > "$STATE_FILE" << STATE
PARTNER_DOMAIN=test.example.com
TURNS_SUBDOMAIN=turns.test.example.com
NAIVE_SOCKS_PORT=1080
CADDYFILE_SHA=$RENDERED_SHA
STATE

# Seed the on-disk Caddyfile.
if [[ "$ONDISK_SRC" == "__CLEAN__" ]]; then
    # No-drift control: the correct rendered file with the self-hash substituted —
    # byte-identical to what a fresh swap would install.
    sed "s|__CADDYFILE_SHA__|$RENDERED_SHA|g" "$MOCK" > "$ETC/Caddyfile"
else
    cp "$ONDISK_SRC" "$ETC/Caddyfile"
fi

# Dummy template (opec stub ignores content; file must exist for the -f checks and
# the NAIVE die-guard grep — it carries no {{NAIVE_SOCKS_PORT}}).
TPL="$TMP/Caddyfile.tpl"
printf '# tpl\nrespond "__CADDYFILE_SHA__" 200\n' > "$TPL"

# shellcheck disable=SC1090
. "$LIB"

# opec stub: emit the deterministic candidate (byte-identical to MOCK) to --out.
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

# Count swaps; actually install so the converged-content assertion is real.
atomic_swap() {
    _SWAPS=$((_SWAPS + 1))
    local _dst="$1" _src="$2"
    cp "$_src" "$_dst" 2>/dev/null || true
    rm -f "$_src"
}

CAND="$TMP/cand"; mkdir -p "$CAND"
reconcile_caddy_surface "$CAND" "$TPL" || echo "RECONCILE_RC=$?" >&2

echo "SWAPS=$_SWAPS"
_prom="$PARTNER_EDGE_TEXTFILE_DIR/partner_edge_caddy.prom"
if [[ -f "$_prom" ]]; then
    echo "GAUGE=$(grep '^partner_edge_caddy_disk_drift ' "$_prom" | awk '{print $2}')"
else
    echo "GAUGE=NONE"
fi
if grep -q 'xray-client:3080/health' "$ETC/Caddyfile"; then
    echo "CONVERGED=no"
else
    echo "CONVERGED=yes"
fi
RUNNER
chmod +x "$_tmp/run.sh"

# ---- Scenario A: STATE matches render, but on-disk carries the stale pre-#273
#      illegal `reverse_proxy xray-client:3080/health` upstream (the canary drift). ----
HEX="$(printf 'a%.0s' $(seq 1 64))"
DRIFT_SRC="$_tmp/drift.caddy"
{
    printf '# STALE pre-#273 Caddyfile (illegal upstream path — Caddy v2.11.2 rejects)\n'
    printf 'handle /health {\n    reverse_proxy xray-client:3080/health\n}\n'
    printf 'handle /canary/config-hash {\n    respond "%s" 200\n}\n' "$HEX"
} > "$DRIFT_SRC"

OUT_A=$(bash "$_tmp/run.sh" "$_tmp/A" "$REPO_ROOT" "$DRIFT_SRC" 2>/dev/null)
a_swaps=$(echo "$OUT_A" | sed -n 's/^SWAPS=//p')
a_gauge=$(echo "$OUT_A" | sed -n 's/^GAUGE=//p')
a_conv=$(echo "$OUT_A"  | sed -n 's/^CONVERGED=//p')

if [[ "$a_swaps" == "1" ]]; then
    pass "A: on-disk drift (STATE-clean) forced exactly 1 atomic_swap"
else
    fail "A: expected 1 swap on on-disk drift, got '${a_swaps:-?}' — STATE-only skip regressed (drift guard missing)"
fi
if [[ "$a_conv" == "yes" ]]; then
    pass "A: on-disk Caddyfile converged — illegal xray-client:3080/health upstream removed (#273 fix reached disk)"
else
    fail "A: on-disk Caddyfile still carries illegal xray-client:3080/health after converge"
fi
if [[ "$a_gauge" == "1" ]]; then
    pass "A: partner_edge_caddy_disk_drift gauge = 1 (standing drift signal wired)"
else
    fail "A: expected drift gauge 1, got '${a_gauge:-?}'"
fi

# ---- Scenario B (control): STATE matches render AND on-disk is already correct →
#      no drift → must be a pure no-op (0 swaps, gauge 0). Guards against an
#      over-eager fix that swaps every run. ----
OUT_B=$(bash "$_tmp/run.sh" "$_tmp/B" "$REPO_ROOT" "__CLEAN__" 2>/dev/null)
b_swaps=$(echo "$OUT_B" | sed -n 's/^SWAPS=//p')
b_gauge=$(echo "$OUT_B" | sed -n 's/^GAUGE=//p')

if [[ "$b_swaps" == "0" ]]; then
    pass "B: clean on-disk (no drift) → 0 swaps (idempotent; no false-positive)"
else
    fail "B: expected 0 swaps on clean converge, got '${b_swaps:-?}' — over-eager swap"
fi
if [[ "$b_gauge" == "0" ]]; then
    pass "B: drift gauge = 0 on clean converge (self-clearing signal)"
else
    fail "B: expected drift gauge 0 on clean converge, got '${b_gauge:-?}'"
fi

echo ""
echo "=== reconcile_caddy disk-drift: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
