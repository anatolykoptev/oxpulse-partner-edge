#!/bin/bash
# tests/test_converge_idempotent.sh — Phase 4a: reconcile_all idempotency (S2).
#
# Runs reconcile_all twice in a sandbox (no opec, no real caddy path) and asserts
# that run 2 makes zero changes — no atomic_swap calls, no restarts.
#
# Strategy:
#   - Source lib/reconcile.sh with mocked die/log/warn.
#   - Override reconcile_caddy_surface with a version that counts calls and
#     checks whether it would swap (tracks checksum state in a temp dir).
#   - Source a minimal manifest reader via manifest_surfaces().
#   - Assert run 1 may or may not swap (state == desired from the start in sandbox).
#   - Assert run 2 has zero atomic_swap calls (idempotency).
#
# SKIP if opec not available (CI parity: opec absent = skip opec-dependent tests).
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
MANIFEST="$REPO_ROOT/manifest.yaml"
LIB="$REPO_ROOT/lib/reconcile.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

echo ""
echo "=== Converge idempotency tests ==="

# I1: reconcile.sh exists
if [[ ! -f "$LIB" ]]; then
    fail "I1: lib/reconcile.sh not found — cannot test"
    echo "FAIL: 0/$((PASS+FAIL)) tests passed"
    exit 1
fi
pass "I1: lib/reconcile.sh exists"

# I2: manifest.yaml exists
if [[ ! -f "$MANIFEST" ]]; then
    fail "I2: manifest.yaml not found — cannot test"
    echo "FAIL: $PASS passed, $FAIL failed"
    exit 1
fi
pass "I2: manifest.yaml exists"

# I3: reconcile_all function is declared in lib/reconcile.sh
if grep -qE '^reconcile_all\(\)' "$LIB"; then
    pass "I3: reconcile_all() declared in lib/reconcile.sh"
else
    fail "I3: reconcile_all() not found in lib/reconcile.sh"
fi

# I4: manifest_surfaces function is declared in lib/reconcile.sh
if grep -qE '^manifest_surfaces\(\)|^manifest_field\(\)' "$LIB"; then
    pass "I4: manifest reader (manifest_surfaces/manifest_field) declared in lib/reconcile.sh"
else
    fail "I4: manifest reader not found in lib/reconcile.sh"
fi

# I5: apply_restarts is called inside reconcile_all (not dead code)
_reconcile_all_body=$(awk '/^reconcile_all\(\)/,/^}/' "$LIB" 2>/dev/null || true)
if echo "$_reconcile_all_body" | grep -q 'apply_restarts'; then
    pass "I5: apply_restarts() is called inside reconcile_all()"
else
    fail "I5: apply_restarts() NOT called inside reconcile_all() — it is dead code"
fi

# I6: Functional idempotency with __CADDYFILE_SHA__ placeholder.
# The mock renderer emits 'respond "__CADDYFILE_SHA__" 200' (mirrors Caddyfile.tpl:361)
# so the substitution path is exercised and the broken pre-sub-vs-post-sub comparison
# (BLOCKER-1) would have caused run-2 to also swap (false-GREEN without this placeholder).
# Asserts: run-1 swaps (STATE sha=abc123 != rendered pre-sub hash), run-2 is NO-OP.
# Falsification: reverting BLOCKER-1 fix makes run-2 produce 1 swap => FAIL.
# We use a subshell with mocked primitives.
_tmpdir=$(mktemp -d)
# shellcheck disable=SC2064
trap "rm -rf '${_tmpdir}'" EXIT

# Create a mock "installed" Caddyfile (content doesn't matter for STATE-based compare).
# The STATE CADDYFILE_SHA='abc123' will NOT match the real pre-sub hash of the mock
# render output, so run-1 will detect a change and swap. After run-1, STATE is updated
# to the actual pre-sub hash. Run-2 renders the same content => same hash => no swap.
# The mock renderer emits respond \"__CADDYFILE_SHA__\" 200 to exercise the substitution path.
_etc_dir="$_tmpdir/etc/oxpulse-partner-edge"
mkdir -p "$_etc_dir"
# Write an initial installed Caddyfile (placeholder value; will be replaced on run-1).
echo "# initial installed Caddyfile" > "$_etc_dir/Caddyfile"

# Write a minimal state file.
# CADDYFILE_SHA=abc123 is a sentinel that deliberately does NOT match the pre-sub hash
# of the mock render output, ensuring run-1 triggers a change (and exercises the swap +
# STATE-update path). After run-1 updates STATE, run-2 must be a no-op.
_state_file="$_tmpdir/install.env"
cat > "$_state_file" << 'STATE'
PARTNER_DOMAIN=test.example.com
TURNS_SUBDOMAIN=turns.test.example.com
PARTNER_ID=testpartner
NODE_ID=test-node-01
BACKEND_API=https://api.oxpulse.chat
IMAGE_VERSION=v0.12.99
SCHEMA_VERSION=1
NAIVE_SOCKS_PORT=1080
AWG_MOTHERLY_IP=10.9.0.2
HY2_FALLBACK_HOST=host.docker.internal
HY2_FALLBACK_PORT=18443
CADDYFILE_SHA=abc123
STATE

# Create a fake docker-compose.yml (caddy service present for non-SFU-only guard)
mkdir -p "$_etc_dir"
cat > "$_etc_dir/docker-compose.yml" << 'COMPOSE'
services:
  caddy:
    image: ghcr.io/anatolykoptev/partner-edge-caddy:v0.12.99
COMPOSE

# Write the manifest to the temp sandbox (copy from repo)
cp "$MANIFEST" "$_tmpdir/manifest.yaml"

# Write a test runner script to subshell
cat > "$_tmpdir/run_idempotency.sh" << 'SHELLEOF'
#!/bin/bash
set -euo pipefail
TMPDIR_HERE="$1"
REPO_ROOT="$2"
LIB="$REPO_ROOT/lib/reconcile.sh"

# Swap counters
_ATOMIC_SWAP_COUNT=0
_RESTART_COUNT=0

# Minimal stubs expected by lib/reconcile.sh (must be defined before sourcing).
log()  { echo "[LOG] $*" >&2; }
warn() { echo "[WARN] $*" >&2; }
die()  { echo "[DIE] $*" >&2; exit 1; }

# Env setup (before source so REPO_DIR is available to reconcile_all).
export PREFIX_ETC="$TMPDIR_HERE/etc/oxpulse-partner-edge"
export STATE_FILE="$TMPDIR_HERE/install.env"
export COMPOSE_FILE="$TMPDIR_HERE/etc/oxpulse-partner-edge/docker-compose.yml"
export DOCKER_BIN="false"   # never actually run docker in tests
export DRY_RUN=0
# REPO_DIR: reconcile_all fetches Caddyfile.tpl from here when REPO_RAW is unset.
export REPO_DIR="$REPO_ROOT"

# Source state
# shellcheck disable=SC1090
. "$STATE_FILE"

# Source lib (defines atomic_swap, opec etc — we override AFTER sourcing).
# shellcheck disable=SC1090
. "$LIB"

# Override atomic_swap AFTER sourcing lib to count calls without writing.
atomic_swap() {
    _ATOMIC_SWAP_COUNT=$((_ATOMIC_SWAP_COUNT + 1))
    log "atomic_swap: would swap $1 <- $2 (count=$_ATOMIC_SWAP_COUNT)"
}

# Override apply_caddy_reloads: idempotency test measures atomic_swap counts,
# not reload behavior (reload tested by test_caddy_reload_fail_loud.sh).
# Without this stub, DOCKER_BIN="false" causes both reload paths to fail and
# reconcile_all die()s (Fix 1 behavior), collapsing the run1/run2 comparison.
apply_caddy_reloads() {
    log "apply_caddy_reloads: stubbed (idempotency test — reload behavior tested separately)"
    _RECONCILE_CADDY_RELOAD=0
    return 0
}

# Override opec: produce a file matching the installed SHA so run 1 is idempotent.
# Handles: render caddy --tpl TPL --out OUT, and render caddy --help (capability probe).
opec() {
    local _subcmd="${1:-}" _kind="${2:-}"
    if [[ "$_subcmd" == "render" && "$_kind" == "caddy" ]]; then
        if [[ "${3:-}" == "--help" ]]; then return 0; fi
        local _out="" _out_next=0
        local i
        for i in "$@"; do
            [[ "$_out_next" -eq 1 ]] && _out="$i" && _out_next=0
            [[ "$i" == "--out" ]] && _out_next=1
        done
        # Produce deterministic content with the self-referential __CADDYFILE_SHA__
        # placeholder (mirrors Caddyfile.tpl:361 'respond \"__CADDYFILE_SHA__\" 200').
        # This exercises the substitution path so the pre-sub hash comparison is tested.
        # BLOCKER-2 fix: WITHOUT this placeholder, pre-sub == post-sub and the broken
        # comparison was accidentally stable, masking BLOCKER-1.
        if [[ -n "$_out" ]]; then
            printf '# mock Caddyfile (Phase 4a idempotency test)\n' > "$_out"
            printf 'respond "__CADDYFILE_SHA__" 200\n' >> "$_out"
        fi
        return 0
    fi
    return 0
}
export -f opec

# Run reconcile_all twice
MANIFEST_PATH="$TMPDIR_HERE/manifest.yaml"

log "=== RUN 1 ==="
_before_run1_swaps=$_ATOMIC_SWAP_COUNT
reconcile_all "$MANIFEST_PATH" || { echo "RUN1_FAILED"; exit 0; }
_run1_swaps=$((_ATOMIC_SWAP_COUNT - _before_run1_swaps))
echo "RUN1_SWAPS=$_run1_swaps"

log "=== RUN 2 ==="
_before_run2_swaps=$_ATOMIC_SWAP_COUNT
reconcile_all "$MANIFEST_PATH" || { echo "RUN2_FAILED"; exit 0; }
_run2_swaps=$((_ATOMIC_SWAP_COUNT - _before_run2_swaps))
echo "RUN2_SWAPS=$_run2_swaps"

echo "DONE"
SHELLEOF
chmod +x "$_tmpdir/run_idempotency.sh"

_idem_out=$(bash "$_tmpdir/run_idempotency.sh" "$_tmpdir" "$REPO_ROOT" 2>/dev/null || true)

if echo "$_idem_out" | grep -q "RUN1_FAILED"; then
    fail "I6: reconcile_all run1 failed (function may not be implemented yet)"
elif echo "$_idem_out" | grep -q "RUN2_FAILED"; then
    fail "I6: reconcile_all run2 failed (non-idempotent crash)"
elif echo "$_idem_out" | grep -q "DONE"; then
    _run1_swaps=$(echo "$_idem_out" | grep "^RUN1_SWAPS=" | cut -d= -f2)
    _run2_swaps=$(echo "$_idem_out" | grep "^RUN2_SWAPS=" | cut -d= -f2)
    # Run-1 must detect a change (STATE sha=abc123 != rendered pre-sub sha).
    if [[ "${_run1_swaps:-0}" -eq 0 ]]; then
        fail "I6: reconcile_all run1 produced zero swaps — expected 1 (STATE sha mismatch should trigger change)"
    # Run-2 must be a no-op (STATE sha now matches rendered pre-sub sha).
    elif [[ "${_run2_swaps:-1}" -eq 0 ]]; then
        pass "I6: reconcile_all run2 produces zero atomic_swap calls (idempotent with __CADDYFILE_SHA__ placeholder exercised)"
    else
        fail "I6: reconcile_all run2 had $_run2_swaps swap(s) — NOT idempotent (BLOCKER-1 not fixed?)"
    fi
else
    fail "I6: reconcile_all did not complete (function not implemented or crashed)"
    echo "Output: $_idem_out" >&2
fi

echo ""
echo "=== Converge idempotency: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
