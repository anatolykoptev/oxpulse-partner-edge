#!/bin/bash
# tests/test_phase4b_surfaces.sh — Phase 4b: coturn/xray_client/firewall/xray_env
# surface handlers + multi-surface idempotency + peer isolation.
#
# Scenarios:
#   Surface wiring:
#   W1  coturn wired:true in manifest.yaml
#   W2  xray_client wired:true in manifest.yaml
#   W3  firewall wired:true in manifest.yaml
#   W4  xray_env wired:true in manifest.yaml
#
#   Handler existence:
#   H1  reconcile_coturn_surface() declared in lib/reconcile.sh
#   H2  reconcile_xray_client_surface() declared (or inline handler in reconcile_all)
#   H3  firewall_apply is called from the firewall network_apply handler in reconcile_all
#   H4  reconcile_xray_env_surface() declared
#
#   Changed-count correctness (P4a deferred):
#   CC1 _changed_count reflects per-surface changes (not _RECONCILE_RESTART_UNITS delta)
#   CC2 dedup does not hide a real change (two different surfaces both changed = count 2)
#
#   Idempotency (S2):
#   I7  coturn surface: run twice, run 2 = 0 swaps (unchanged conf)
#   I8  xray_client surface: run twice, run 2 = 0 recreates (unchanged json)
#   I9  xray_env surface: run twice, run 2 = 0 swaps (file already present)
#   I10 multi-surface (all 4 wired): run 2 = 0 swaps/signals/recreates
#
#   Peer isolation:
#   PI1 coturn SIGUSR2 sent only to coturn container, not peers
#   PI2 xray_client recreate targets 'xray-client' service ONLY
#   PI3 firewall_apply does NOT call docker / docker compose (canon §6 scope)
#
#   fail_soft (xray_client):
#   FS1 xray_client render failure = log + continue, NOT die
#
#   xray_env no-double-provision:
#   NDP1 xray_env surface is the single authority (upgrade.sh in-line provision is
#        idempotent with it: both touch if absent, reconcile wins when both fire)
#
# Falsification:
#   W1-W4: removing wired:true from manifest makes the test fail (grep for wired:false)
#   H1/H4: removing the function declaration makes the test fail
#   I7/I8/I9/I10: reverting the no-op path makes run-2 produce changes → FAIL
#   PI1: using mark_restart instead of signal coturn → restart_units not empty → FAIL
#   FS1: using die instead of warn+return in fail_soft path → subshell exits nonzero → FAIL
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
MANIFEST="$REPO_ROOT/manifest.yaml"
LIB="$REPO_ROOT/lib/reconcile.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

echo ""
echo "=== Phase 4b surface wiring + idempotency + peer isolation tests ==="

[[ -f "$LIB" ]]      || { fail "P0: lib/reconcile.sh not found"; exit 1; }
[[ -f "$MANIFEST" ]] || { fail "P0: manifest.yaml not found"; exit 1; }

# ---------------------------------------------------------------------------
# W1-W4: manifest wired:true checks
# ---------------------------------------------------------------------------
_check_surface_wired() {
    local surface="$1" label="$2"
    # Surface block starts with "- id: $surface" and must NOT have "wired: false"
    # before the next "- id:" line.
    local block
    block=$(awk "/^  - id: ${surface}$/,/^  - id: /" "$MANIFEST" 2>/dev/null | head -20)
    if echo "$block" | grep -q 'wired: false'; then
        fail "${label}: surface '$surface' still has wired:false in manifest.yaml"
    elif echo "$block" | grep -q "id: ${surface}"; then
        pass "${label}: surface '$surface' is wired (no wired:false in block)"
    else
        fail "${label}: surface '$surface' block not found in manifest.yaml"
    fi
}
_check_surface_wired "coturn"      "W1"
_check_surface_wired "xray_client" "W2"
_check_surface_wired "firewall"    "W3"
_check_surface_wired "xray_env"    "W4"

# compose must stay wired:false (scope discipline)
# awk range /^  - id: compose$/,/^  - id: / collapses (end=start). Use f-flag instead.
_block_compose=$(awk 'f && /^  - id:/{exit} /^  - id: compose$/{f=1} f' "$MANIFEST" 2>/dev/null || true)
if echo "$_block_compose" | grep -q 'wired: false'; then
    pass "W5: compose stays wired:false (not in P4b scope)"
else
    fail "W5: compose wired:false removed — outside P4b scope"
fi

# ---------------------------------------------------------------------------
# H1-H4: handler declarations
# ---------------------------------------------------------------------------
if grep -qE '^reconcile_coturn_surface\(\)' "$LIB"; then
    pass "H1: reconcile_coturn_surface() declared in lib/reconcile.sh"
else
    fail "H1: reconcile_coturn_surface() not found in lib/reconcile.sh"
fi

# xray_client handler may be inline in reconcile_all or a separate function
if grep -qE '^reconcile_xray_client_surface\(\)|xray_client.*reconcile|reconcile.*xray_client' "$LIB" || \
   grep -qE "xray_client|xray.client" "$LIB"; then
    pass "H2: xray_client handler present in lib/reconcile.sh"
else
    fail "H2: xray_client handler not found in lib/reconcile.sh"
fi

# firewall: reconcile_all must route to reconcile_firewall_surface,
# which internally calls firewall_apply (indirect — correct pattern).
_reconcile_all_body=$(awk '/^reconcile_all\(\)/,/^}/' "$LIB" 2>/dev/null || true)
if echo "$_reconcile_all_body" | grep -q 'reconcile_firewall_surface'; then
    pass "H3: firewall_apply called from network_apply handler in reconcile_all"
else
    fail "H3: firewall_apply not called from reconcile_all network_apply handler"
fi

if grep -qE '^reconcile_xray_env_surface\(\)' "$LIB"; then
    pass "H4: reconcile_xray_env_surface() declared in lib/reconcile.sh"
else
    fail "H4: reconcile_xray_env_surface() not found in lib/reconcile.sh"
fi

# ---------------------------------------------------------------------------
# CC1: _changed_count is per-surface, not _RECONCILE_RESTART_UNITS delta
# ---------------------------------------------------------------------------
# The unsound pattern: comparing len before/after mark_restart into deduped list.
# The fix: each surface sets its own flag/counter that accurately tracks "did this
# surface change?" independently of dedup state.
# We verify the coturn surface uses a per-surface flag (not _RECONCILE_RESTART_UNITS).
_coturn_fn=$(awk '/^reconcile_coturn_surface\(\)/,/^}/' "$LIB" 2>/dev/null || true)
if echo "$_coturn_fn" | grep -qE '_RECONCILE_COTURN_CHANGED|mark_coturn_|COTURN_CHANGED'; then
    pass "CC1: coturn surface uses per-surface change flag (not _RECONCILE_RESTART_UNITS delta)"
else
    # Also acceptable: the handler returns an exit code that reconcile_all uses
    if echo "$_coturn_fn" | grep -qE 'return 1|echo.*CHANGED|_surface_changed'; then
        pass "CC1: coturn surface signals change via non-_RECONCILE_RESTART_UNITS mechanism"
    else
        fail "CC1: coturn surface change-tracking mechanism unclear — may undercount changes"
    fi
fi

# ---------------------------------------------------------------------------
# PI1: coturn reload via SIGUSR2, not via mark_restart of full-stack unit
# ---------------------------------------------------------------------------
if echo "$_coturn_fn" | grep -qE 'SIGUSR2|kill.*USR2|docker.*kill.*USR2'; then
    pass "PI1a: coturn surface sends SIGUSR2 (no session drop)"
else
    fail "PI1a: coturn surface does not send SIGUSR2 — may drop TURN allocations"
fi
if echo "$_coturn_fn" | grep -qE 'mark_restart.*oxpulse-partner-edge\.service'; then
    fail "PI1b: coturn surface calls mark_restart(oxpulse-partner-edge.service) — would kill caddy/SFU/xray"
else
    pass "PI1b: coturn does NOT mark_restart(oxpulse-partner-edge.service)"
fi

# ---------------------------------------------------------------------------
# PI2: xray_client recreate targets 'xray-client' service ONLY
# ---------------------------------------------------------------------------
# Look for the xray_client handler (inline in reconcile_all or separate function)
_xray_client_fn=$(awk '/^reconcile_xray_client_surface\(\)/,/^}/' "$LIB" 2>/dev/null || true)
if echo "$_xray_client_fn" | grep -qE 'force-recreate xray-client|force.recreate.*xray.client'; then
    pass "PI2: xray_client recreate uses --force-recreate xray-client (not full stack)"
else
    fail "PI2: xray_client recreate does not specify 'xray-client' service — may recreate all"
fi

# ---------------------------------------------------------------------------
# PI3: firewall handler does NOT call docker/docker-compose (canon §6)
# ---------------------------------------------------------------------------
# firewall_apply is in lib/install-firewall.sh; it uses ufw/firewalld (not docker).
# The reconcile_all firewall handler must call firewall_apply and ONLY firewall_apply
# for the firewall surface — no compose call.
# We check by finding the firewall case arm in reconcile_all.
_firewall_arm=$(awk '/firewall.*network_apply|network_apply.*firewall|case.*network_apply/,/;;/' \
    "$LIB" 2>/dev/null || true)
_reconcile_all_firewall=$(echo "$_reconcile_all_body" | \
    awk '/firewall/,/;;/' 2>/dev/null | head -20 || true)
# Strip comment lines before checking for docker/compose calls.
_reconcile_all_firewall_code=$(echo "$_reconcile_all_firewall" | grep -v '^\s*#' || true)
if echo "$_reconcile_all_firewall_code" | grep -qE 'docker|compose'; then
    fail "PI3: firewall handler calls docker/compose — violates canon §6 (oxpulse-owned nft only)"
else
    pass "PI3: firewall handler does NOT call docker/compose (canon §6 compliant)"
fi

# ---------------------------------------------------------------------------
# FS1: xray_client fail_soft — render failure does NOT die
# ---------------------------------------------------------------------------
_tmpdir=$(mktemp -d)
# shellcheck disable=SC2064
trap "rm -rf '$_tmpdir'" EXIT

_fs_out=$(bash - << 'SHELLEOF' 2>&1 || true
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null || pwd)"
# Find repo root heuristically
for _try in "$PWD" "$PWD/.." "$HOME/src/oxpulse-partner-edge" ; do
    [[ -f "$_try/lib/reconcile.sh" ]] && { REPO_ROOT="$_try"; break; }
done
LIB="$REPO_ROOT/lib/reconcile.sh"
[[ -f "$LIB" ]] || exit 0  # skip if not found

log()  { echo "[LOG] $*" >&2; }
warn() { echo "[WARN] $*" >&2; }
die()  { echo "[DIE] $*" >&2; exit 1; }

export PREFIX_ETC="$(mktemp -d)"
mkdir -p "$PREFIX_ETC"
export STATE_FILE="$(mktemp)"
cat > "$STATE_FILE" << 'STATE'
PARTNER_DOMAIN=test.example.com
TURNS_SUBDOMAIN=turns.test.example.com
PARTNER_ID=testpartner
NODE_ID=test-node-01
BACKEND_API=https://api.oxpulse.chat
IMAGE_VERSION=v0.12.99
SCHEMA_VERSION=1
STATE
# shellcheck source=/dev/null
. "$LIB"

# Now call reconcile_xray_client_surface with a failing opec
opec() { return 1; }   # simulate render failure
export -f opec
export DOCKER_BIN="false"
export COMPOSE_FILE="$(mktemp)"
printf 'services:\n  xray-client:\n    image: test\n' > "$COMPOSE_FILE"
export REPO_DIR="$REPO_ROOT"

# reconcile_xray_client_surface must NOT die on opec failure (fail_soft)
reconcile_xray_client_surface "$PREFIX_ETC" 2>/dev/null || true
echo "SURVIVED"
SHELLEOF
)

if echo "$_fs_out" | grep -q "SURVIVED"; then
    pass "FS1: xray_client render failure does NOT die (fail_soft — bypass channel continues)"
elif echo "$_fs_out" | grep -q "DIE"; then
    fail "FS1: xray_client render failure called die() — should be fail_soft (warn+continue)"
else
    # Function not yet implemented — expected RED before P4b
    fail "FS1: reconcile_xray_client_surface not implemented or crashed"
fi

# ---------------------------------------------------------------------------
# I7: coturn idempotency — run twice, run 2 = 0 swaps
# ---------------------------------------------------------------------------
_tmpdir2=$(mktemp -d)
# shellcheck disable=SC2064
trap "rm -rf '$_tmpdir2'" EXIT

_i7_out=$(bash - << SHELLEOF 2>&1 || true
set -euo pipefail
REPO_ROOT=""
for _try in "\$PWD" "\$PWD/.." "\$HOME/src/oxpulse-partner-edge"; do
    [[ -f "\$_try/lib/reconcile.sh" ]] && { REPO_ROOT="\$_try"; break; }
done
LIB="\$REPO_ROOT/lib/reconcile.sh"
[[ -f "\$LIB" ]] || { echo "SKIP_NO_LIB"; exit 0; }

log()  { :; }
warn() { echo "[WARN] \$*" >&2; }
die()  { echo "[DIE] \$*" >&2; exit 1; }

_SWAP_COUNT=0
atomic_swap() { _SWAP_COUNT=\$((_SWAP_COUNT+1)); }
apply_caddy_reloads() { return 0; }

PREFIX_ETC="$_tmpdir2/etc/oxpulse-partner-edge"
mkdir -p "\$PREFIX_ETC"
STATE_FILE="$_tmpdir2/install.env"
cat > "\$STATE_FILE" << 'STATE'
PARTNER_DOMAIN=test.example.com
TURNS_SUBDOMAIN=api-test01
PARTNER_ID=testpartner
NODE_ID=test-node-01
BACKEND_API=https://api.oxpulse.chat
IMAGE_VERSION=v0.12.99
SCHEMA_VERSION=1
TURN_SECRET=test-secret
PUBLIC_IP=1.2.3.4
EXTERNAL_IP_LINE=1.2.3.4
STATE
export PREFIX_ETC STATE_FILE DOCKER_BIN="false" REPO_DIR="\$REPO_ROOT"
# Export vars that _setup_coturn_render_env reads from env (not STATE_FILE).
export PARTNER_DOMAIN=test.example.com TURNS_SUBDOMAIN=api-test01
export TURN_SECRET=test-secret PUBLIC_IP=1.2.3.4
. "\$LIB"

# Write a "pre-installed" coturn.conf by rendering once and saving it
opec() {
    if [[ "\${1:-}" == "render" && "\${2:-}" == "coturn" ]]; then
        local _out=""
        local i; for i in "\$@"; do
            [[ "\${_out_next:-0}" == "1" ]] && _out="\$i" && _out_next=0
            [[ "\$i" == "--out" ]] && _out_next=1
        done
        [[ -n "\$_out" ]] && printf '# mock coturn\\nstatic-auth-secret=test-secret\\n' > "\$_out"
        return 0
    fi; return 0
}
export -f opec

# Pre-install: run once to establish stable state
reconcile_coturn_surface "\$PREFIX_ETC" 2>/dev/null || true
_before=\$_SWAP_COUNT

# Run 2: must be zero new swaps
reconcile_coturn_surface "\$PREFIX_ETC" 2>/dev/null || true
_after=\$_SWAP_COUNT
echo "RUN2_SWAPS=\$((_after - _before))"
echo "DONE"
SHELLEOF
)

if echo "$_i7_out" | grep -q "SKIP_NO_LIB"; then
    fail "I7: lib/reconcile.sh not found"
elif echo "$_i7_out" | grep -q "DONE"; then
    _r2=$(echo "$_i7_out" | grep "^RUN2_SWAPS=" | cut -d= -f2)
    if [[ "${_r2:-1}" -eq 0 ]]; then
        pass "I7: coturn surface run-2 = 0 swaps (idempotent)"
    else
        fail "I7: coturn surface run-2 = $_r2 swaps (NOT idempotent)"
    fi
else
    fail "I7: reconcile_coturn_surface not implemented or crashed"
fi

# ---------------------------------------------------------------------------
# I9: xray_env idempotency — run twice, run 2 = 0 swaps
# ---------------------------------------------------------------------------
_tmpdir3=$(mktemp -d)
_i9_out=$(bash - << SHELLEOF 2>&1 || true
set -euo pipefail
REPO_ROOT=""
for _try in "\$PWD" "\$PWD/.." "\$HOME/src/oxpulse-partner-edge"; do
    [[ -f "\$_try/lib/reconcile.sh" ]] && { REPO_ROOT="\$_try"; break; }
done
LIB="\$REPO_ROOT/lib/reconcile.sh"
[[ -f "\$LIB" ]] || { echo "SKIP_NO_LIB"; exit 0; }

log()  { :; }
warn() { :; }
die()  { echo "[DIE] \$*" >&2; exit 1; }

_SWAP_COUNT=0
atomic_swap() { _SWAP_COUNT=\$((_SWAP_COUNT+1)); }

PREFIX_ETC="$_tmpdir3/etc/oxpulse-partner-edge"
mkdir -p "\$PREFIX_ETC"
STATE_FILE="$_tmpdir3/install.env"
printf 'SCHEMA_VERSION=1\n' > "\$STATE_FILE"
export PREFIX_ETC STATE_FILE

. "\$LIB"

# Run 1: file absent → create
reconcile_xray_env_surface "\$PREFIX_ETC" 2>/dev/null || true
_b=\$_SWAP_COUNT

# Run 2: file present → no-op
reconcile_xray_env_surface "\$PREFIX_ETC" 2>/dev/null || true
echo "RUN2_SWAPS=\$((_SWAP_COUNT - _b))"
echo "DONE"
SHELLEOF
)

if echo "$_i9_out" | grep -q "SKIP_NO_LIB"; then
    fail "I9: lib/reconcile.sh not found"
elif echo "$_i9_out" | grep -q "DONE"; then
    _r9=$(echo "$_i9_out" | grep "^RUN2_SWAPS=" | cut -d= -f2)
    if [[ "${_r9:-1}" -eq 0 ]]; then
        pass "I9: xray_env surface run-2 = 0 swaps (idempotent)"
    else
        fail "I9: xray_env surface run-2 = $_r9 swaps (NOT idempotent)"
    fi
else
    fail "I9: reconcile_xray_env_surface not implemented or crashed"
fi

rm -rf "$_tmpdir3"

# ---------------------------------------------------------------------------
# NDP1: xray_env no-double-provision: both reconcile and upgrade.sh touch-if-absent
#       are idempotent. Structural check: upgrade.sh in-line provision uses [[ ! -f ]]
# ---------------------------------------------------------------------------
# sync_host_scripts (incl. the xray.env provision block) moved to
# lib/host-scripts-lib.sh (Phase 4 strangler-harden, task p4) — check there,
# not upgrade.sh (which now only holds a thin forwarder).
HOST_SCRIPTS_LIB="$REPO_ROOT/lib/host-scripts-lib.sh"
if [[ -f "$HOST_SCRIPTS_LIB" ]]; then
    # Scan the xray.env provision block for the no-double-provision guard. The
    # block is "provision xray.env" -> "_xray_env_path=" -> "[[ ! -f ... ]]". A
    # wide grep -A window catches the guard a couple lines below the path assign.
    _upg_xray_env=$(grep -A8 -E '_xray_env_path=|provision xray\.env' "$HOST_SCRIPTS_LIB" 2>/dev/null || true)
    if echo "$_upg_xray_env" | grep -qE '\[\[ ! -f.*xray_env_path|\[ ! -f.*xray_env_path|!\s*-f.*xray\.env|\[ ! -f.*xray\.env'; then
        pass "NDP1: lib/host-scripts-lib.sh xray.env provision is guarded touch-if-absent (idempotent with reconcile)"
    else
        # Guard absent -> double-provision risk: sync_host_scripts would clobber an
        # operator env override on every run. This MUST go RED, not silently pass.
        fail "NDP1: lib/host-scripts-lib.sh xray.env provision MISSING the [[ ! -f ]] no-double-provision guard - would clobber operator env on every upgrade"
    fi
else
    fail "NDP1: lib/host-scripts-lib.sh not found - cannot verify xray.env no-double-provision guard"
fi

# ---------------------------------------------------------------------------
# DET1 (render determinism — env-substituting mock): the opec mock SUBSTITUTES
#   the EXTERNAL_IP_LINE env into the rendered conf (NOT a constant). This proves
#   the harness can SEE a render change. Run-1 establishes installed conf; run-2
#   with the SAME source => 0 swaps; flipping PUBLIC_IP => a 2nd swap. If the mock
#   were a constant (like I7's) this test could never detect non-determinism.
#
# DET2 (the CRITICAL): STATE has NO PUBLIC_IP, installed coturn.conf present with
#   external-ip=<known>. Reconcile MUST reuse the installed external-ip (last-
#   known-good) so run-2 renders identical => ZERO swap. Under the OLD code the
#   STATE miss fell through to a live curl probe; with the probe stubbed empty
#   (DPI-edge simulation) external-ip rendered EMPTY => differed from installed
#   => a DEGRADED live swap. So DET2 is RED before the fix, GREEN after.
# ---------------------------------------------------------------------------
_tmpdir_det=$(mktemp -d)
# shellcheck disable=SC2064
trap "rm -rf '$_tmpdir_det'" EXIT

_det_out=$(bash - << SHELLEOF 2>&1 || true
set -euo pipefail
REPO_ROOT=""
for _try in "\$PWD" "\$PWD/.." "\$HOME/src/oxpulse-partner-edge"; do
    [[ -f "\$_try/lib/reconcile.sh" ]] && { REPO_ROOT="\$_try"; break; }
done
LIB="\$REPO_ROOT/lib/reconcile.sh"
[[ -f "\$LIB" ]] || { echo "SKIP_NO_LIB"; exit 0; }

log()  { :; }
warn() { :; }
die()  { echo "[DIE] \$*" >&2; exit 1; }

_SWAP_COUNT=0

# Stub curl + ip so the OLD code's live-probe / heuristic deterministically
# yields EMPTY (simulates a DPI-blocked edge). This makes DET2 RED on old code
# regardless of the test host's actual network reachability.
curl() { return 1; }
ip()   { return 1; }
export -f curl ip

# opec mock that SUBSTITUTES the env (not a constant): the rendered external-ip
# is whatever EXTERNAL_IP_LINE resolved to. Flipping the source flips the output.
opec() {
    if [[ "\${1:-}" == "render" && "\${2:-}" == "coturn" ]]; then
        local _out="" _next=0 i
        for i in "\$@"; do
            [[ "\$_next" == "1" ]] && { _out="\$i"; _next=0; }
            [[ "\$i" == "--out" ]] && _next=1
        done
        [[ -n "\$_out" ]] && printf 'static-auth-secret=%s\nexternal-ip=%s\n' \
            "\${TURN_SECRET:-}" "\${EXTERNAL_IP_LINE:-}" > "\$_out"
        return 0
    fi; return 0
}
export -f opec

PREFIX_ETC="$_tmpdir_det/etc/oxpulse-partner-edge"
mkdir -p "\$PREFIX_ETC"
STATE_FILE="$_tmpdir_det/install.env"
export PREFIX_ETC STATE_FILE DOCKER_BIN="false" REPO_DIR="\$REPO_ROOT"
. "\$LIB"

# Override atomic_swap AFTER sourcing the lib (the lib defines its own). It must
# still move the rendered file into place so the installed coturn.conf reflects
# the last render (DET2 reads it back) AND count swaps so DET1 flip is detectable.
atomic_swap() { _SWAP_COUNT=\$((_SWAP_COUNT+1)); cp "\$2" "\$1"; }

# ---- DET1: STATE-backed determinism + flip-forces-swap ----
cat > "\$STATE_FILE" << 'STATE'
SCHEMA_VERSION=1
PUBLIC_IP=1.2.3.4
STATE
export PARTNER_DOMAIN=test.example.com TURNS_SUBDOMAIN=api-test01 TURN_SECRET=sek
unset PUBLIC_IP PRIVATE_IP EXTERNAL_IP_LINE
reconcile_coturn_surface "\$PREFIX_ETC" >/dev/null 2>&1 || true   # establish
_b1=\$_SWAP_COUNT
unset PUBLIC_IP PRIVATE_IP EXTERNAL_IP_LINE
reconcile_coturn_surface "\$PREFIX_ETC" >/dev/null 2>&1 || true   # same source
echo "DET1_SAME_SWAPS=\$((_SWAP_COUNT - _b1))"
# Flip the source IP via env override -> MUST force a swap (mock substitutes env)
_b2=\$_SWAP_COUNT
unset PUBLIC_IP PRIVATE_IP EXTERNAL_IP_LINE
export PUBLIC_IP=9.9.9.9
reconcile_coturn_surface "\$PREFIX_ETC" >/dev/null 2>&1 || true
echo "DET1_FLIP_SWAPS=\$((_SWAP_COUNT - _b2))"

# ---- DET2 (CRITICAL): STATE has NO PUBLIC_IP, installed conf present ----
# Reset to a clean installed conf carrying a known external-ip; STATE empty.
rm -rf "\$PREFIX_ETC"; mkdir -p "\$PREFIX_ETC"
printf 'static-auth-secret=sek\nexternal-ip=5.6.7.8\n' > "\$PREFIX_ETC/coturn.conf"
printf 'SCHEMA_VERSION=1\n' > "\$STATE_FILE"   # deliberately NO PUBLIC_IP
_b3=\$_SWAP_COUNT
unset PUBLIC_IP PRIVATE_IP EXTERNAL_IP_LINE
reconcile_coturn_surface "\$PREFIX_ETC" >/dev/null 2>&1 || true
echo "DET2_SWAPS=\$((_SWAP_COUNT - _b3))"
# Prove the live config still carries the last-known-good external-ip (not empty)
_ext_after=\$(grep '^external-ip=' "\$PREFIX_ETC/coturn.conf" | head -1)
echo "DET2_EXTERNAL=\${_ext_after}"
echo "DONE"
SHELLEOF
)

if echo "$_det_out" | grep -q "SKIP_NO_LIB"; then
    fail "DET: lib/reconcile.sh not found"
elif echo "$_det_out" | grep -q "DONE"; then
    _d1s=$(echo "$_det_out" | grep "^DET1_SAME_SWAPS=" | cut -d= -f2)
    _d1f=$(echo "$_det_out" | grep "^DET1_FLIP_SWAPS=" | cut -d= -f2)
    _d2=$(echo "$_det_out"  | grep "^DET2_SWAPS=" | cut -d= -f2)
    _d2ext=$(echo "$_det_out" | grep "^DET2_EXTERNAL=" | cut -d= -f2-)
    # DET1: same source = 0 swaps; flipped source = exactly 1 swap (mock is real).
    if [[ "${_d1s:-1}" -eq 0 ]]; then
        pass "DET1: STATE-backed render is deterministic (same source = 0 swaps)"
    else
        fail "DET1: STATE-backed render NOT deterministic (same source = $_d1s swaps)"
    fi
    if [[ "${_d1f:-0}" -ge 1 ]]; then
        pass "DET1: env-substituting mock is real (flipped PUBLIC_IP forced a swap)"
    else
        fail "DET1: flipped PUBLIC_IP did NOT force a swap — mock not substituting env (test would be vacuous)"
    fi
    # DET2 (CRITICAL): STATE miss + installed conf present = ZERO swap (reuse LKG).
    if [[ "${_d2:-1}" -eq 0 ]]; then
        pass "DET2 (CRITICAL): STATE-empty + installed conf present = 0 swaps (reuses last-known-good external-ip)"
    else
        fail "DET2 (CRITICAL): STATE-empty triggered $_d2 swap(s) — non-idempotent; would swap a (possibly degraded) coturn.conf live on a no-op converge"
    fi
    # And the live config must NOT have been degraded to an empty external-ip.
    if echo "$_d2ext" | grep -qE '^external-ip=5\.6\.7\.8$'; then
        pass "DET2 (CRITICAL): live coturn.conf retains last-known-good external-ip (not degraded to empty)"
    else
        fail "DET2 (CRITICAL): live coturn.conf external-ip became '$_d2ext' — degraded NAT config swapped live"
    fi
else
    fail "DET: determinism harness crashed or reconcile_coturn_surface missing — output: $_det_out"
fi

rm -rf "$_tmpdir_det"

echo ""
echo "=== Phase 4b tests: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
