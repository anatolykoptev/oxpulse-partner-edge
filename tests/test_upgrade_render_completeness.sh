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
#   Test 6: drives the REAL upgrade.sh --with-templates --dry-run Caddyfile render
#           sub-block. The block is awk-extracted verbatim from upgrade.sh (no
#           hand-copied logic) and run against the REAL lib/reconcile.sh
#           _setup_caddy_render_env, with opec + curl stubbed. Asserts opec is
#           invoked with the exact --tpl/--out flags the block passes, that
#           _setup_caddy_render_env exports every Caddyfile.tpl placeholder var
#           (no {{VAR}} survives an opec that reads only the process env), and that
#           the __CADDYFILE_SHA__ self-hash substitution runs. FALSIFICATION: break
#           the --tpl/--out flags in upgrade.sh, or drop an export from
#           _setup_caddy_render_env, and this test goes RED.
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

# ---- Test 6: REAL --with-templates --dry-run opec render sub-block ----
# Strategy (mirrors tests/test_reconcile_caddy_disk_drift.sh + the awk-extract
# pattern in tests/test_upgrade_with_templates.sh): awk-extract the dry-run render
# sub-block verbatim from upgrade.sh, source the REAL lib/reconcile.sh so the real
# _setup_caddy_render_env runs, stub opec + curl, then assert the block wires the
# real render authority correctly. No network, no docker, no opec binary required.
echo "==> Test 6: real --with-templates --dry-run opec render sub-block (extracted from upgrade.sh)"

T6_TMPDIR=$(mktemp -d)
T6_RUN="$T6_TMPDIR/run.sh"
t6_cleanup() { rm -rf "$T6_TMPDIR"; }
trap 't6_cleanup' EXIT

# The runner uses a quoted heredoc (no interpolation); repo root + sandbox come
# in as positional args so the extracted block and stubs stay byte-faithful.
cat > "$T6_RUN" << 'RUNNER'
#!/bin/bash
set -uo pipefail
REPO_ROOT="$1"; SANDBOX="$2"
UPGRADE="$REPO_ROOT/upgrade.sh"
RECONCILE_LIB="$REPO_ROOT/lib/reconcile.sh"
CADDY_TPL_SRC="$REPO_ROOT/Caddyfile.tpl"

mkdir -p "$SANDBOX"
OPEC_ARGS_LOG="$SANDBOX/opec.args"
: > "$OPEC_ARGS_LOG"

log()  { echo "[LOG] $*"  >&2; }
warn() { echo "[WARN] $*" >&2; }
die()  { echo "[DIE] $*"  >&2; exit 7; }

# --- sandbox env the extracted block references ---
_conflict_tmpdir="$SANDBOX/conflict"; mkdir -p "$_conflict_tmpdir"
REPO_RAW="stub://repo"                 # curl is stubbed; the value is irrelevant
COMPOSE_FILE="$SANDBOX/docker-compose.yml"
STATE_FILE="$SANDBOX/install.env"
PREFIX_SHARE="$SANDBOX/share"          # no defaults.conf → _setup uses hardcoded fallbacks
DOCKER_BIN="false"                     # NAIVE tier-3 docker inspect never fires
TARGET="latest"
PARTNER_DOMAIN="t6.example.com"
TURNS_SUBDOMAIN="turns"
export PARTNER_DOMAIN TURNS_SUBDOMAIN  # block guards on ${PARTNER_DOMAIN:-} / ${TURNS_SUBDOMAIN:-}

# caddy service present → defeats the relay-x/SFU-only skip guard in the block.
cat > "$COMPOSE_FILE" << 'COMPOSE'
services:
  caddy:
    image: ghcr.io/anatolykoptev/partner-edge-caddy:latest
COMPOSE

# NAIVE_SOCKS_PORT resolves via tier-2 (STATE_FILE) → no docker, no die.
cat > "$STATE_FILE" << 'STATE'
PARTNER_DOMAIN=t6.example.com
TURNS_SUBDOMAIN=turns
NAIVE_SOCKS_PORT=1080
STATE

# --- REAL lib: the real _setup_caddy_render_env is the dependency under test ---
# shellcheck source=/dev/null
. "$RECONCILE_LIB"

# --- curl stub: serve the REAL Caddyfile.tpl to the -o target (hermetic, no net) ---
curl() {
    local _out="" _prev="" _a
    for _a in "$@"; do
        [[ "$_prev" == "-o" ]] && _out="$_a"
        _prev="$_a"
    done
    case " $* " in
        *Caddyfile.tpl*) [[ -n "$_out" ]] && cp "$CADDY_TPL_SRC" "$_out"; return 0 ;;
        *)               [[ -n "$_out" ]] && : > "$_out"; return 0 ;;
    esac
}

# --- opec stub: record args + render like the real binary. It substitutes ONLY
#     vars present in the PROCESS ENVIRONMENT (printenv), exactly like a separate
#     opec binary — a placeholder var that _setup_caddy_render_env sets as a shell
#     global but forgets to `export` stays unsubstituted (→ {{VAR}} leftover). ---
opec() {
    [[ "${1:-}" == "render" && "${2:-}" == "caddy" && "${3:-}" == "--help" ]] && return 0
    printf '%s\n' "$*" >> "$OPEC_ARGS_LOG"
    local _tpl="" _out="" _prev="" _a
    for _a in "$@"; do
        [[ "$_prev" == "--tpl" ]] && _tpl="$_a"
        [[ "$_prev" == "--out" ]] && _out="$_a"
        _prev="$_a"
    done
    [[ -n "$_tpl" && -n "$_out" ]] || return 3    # missing/renamed flags → no render
    cp "$_tpl" "$_out"
    local _v _val
    for _v in PARTNER_DOMAIN TURNS_SUBDOMAIN AWG_MOTHERLY_IP HY2_FALLBACK_HOST HY2_FALLBACK_PORT NAIVE_SOCKS_PORT; do
        _val="$(printenv "$_v" 2>/dev/null || true)"
        [[ -n "$_val" ]] && sed -i "s|{{${_v}}}|${_val}|g" "$_out"
    done
    return 0
}

# --- extract + run the REAL dry-run render sub-block from upgrade.sh verbatim ---
_BLOCK=$(awk '/_rendered_caddy="\$_conflict_tmpdir\/Caddyfile"/{f=1} /# Run all conflict checks/{f=0} f{print}' "$UPGRADE")
[[ -n "$_BLOCK" ]] || die "could not extract dry-run render sub-block from upgrade.sh"
eval "$_BLOCK"

# --- report (parsed by the harness caller) ---
echo "OPEC_INVOCATIONS=$(wc -l < "$OPEC_ARGS_LOG" | tr -d ' ')"
echo "TPL_PATH=${_caddyfile_tpl:-}"
echo "OUT_PATH=${_rendered_caddy:-}"
echo "RENDERED_EXISTS=$([[ -f "${_rendered_caddy:-/nonexistent}" ]] && echo yes || echo no)"
if [[ -f "${_rendered_caddy:-/nonexistent}" ]]; then
    _leftover=$(grep -oE '\{\{[A-Z0-9_]+\}\}' "$_rendered_caddy" | sort -u | tr '\n' ' ')
    echo "LEFTOVER=${_leftover}"
    if grep -q '__CADDYFILE_SHA__' "$_rendered_caddy"; then echo "SHA_SUBBED=no"; else echo "SHA_SUBBED=yes"; fi
fi
echo "OPEC_ARGS_BEGIN"
cat "$OPEC_ARGS_LOG"
echo "OPEC_ARGS_END"
RUNNER
chmod +x "$T6_RUN"

T6_RC=0
T6_OUT=$(bash "$T6_RUN" "$REPO_ROOT" "$T6_TMPDIR/sbox" 2>/dev/null) || T6_RC=$?

t6_get() { echo "$T6_OUT" | sed -n "s/^$1=//p" | head -1; }
T6_INVOCATIONS=$(t6_get OPEC_INVOCATIONS)
T6_TPL=$(t6_get TPL_PATH)
T6_OUTPATH=$(t6_get OUT_PATH)
T6_RENDERED=$(t6_get RENDERED_EXISTS)
T6_LEFTOVER=$(t6_get LEFTOVER)
T6_SHA=$(t6_get SHA_SUBBED)
T6_ARGS=$(echo "$T6_OUT" | awk '/^OPEC_ARGS_BEGIN$/{f=1;next} /^OPEC_ARGS_END$/{f=0} f')

# 6a: opec was actually invoked by the real block (proves the block reached render).
if [[ "${T6_INVOCATIONS:-0}" -ge 1 ]]; then
    pass "6a: dry-run block invoked opec render caddy ($T6_INVOCATIONS call)"
else
    fail "6a: dry-run block did NOT invoke opec (rc=$T6_RC) — render authority not reached; out: $T6_OUT"
fi

# 6b: opec got the EXACT --tpl/--out flags the block passes (falsifies a flag typo).
if echo "$T6_ARGS" | grep -qF -- "--tpl $T6_TPL --out $T6_OUTPATH" && [[ -n "$T6_TPL" && -n "$T6_OUTPATH" ]]; then
    pass "6b: opec invoked with correct --tpl/--out flags"
else
    fail "6b: opec --tpl/--out flags wrong or missing — args='$T6_ARGS' tpl='$T6_TPL' out='$T6_OUTPATH'"
fi

# 6c: no {{VAR}} survived — _setup_caddy_render_env exported EVERY placeholder var
#     (falsifies dropping any export from _setup_caddy_render_env).
if [[ "$T6_RENDERED" == "yes" && -z "${T6_LEFTOVER// /}" ]]; then
    pass "6c: rendered Caddyfile has no {{VAR}} leftover (all 6 placeholder vars exported)"
else
    fail "6c: rendered=$T6_RENDERED, leftover placeholders='$T6_LEFTOVER' — _setup_caddy_render_env missing an export"
fi

# 6d: the __CADDYFILE_SHA__ self-hash substitution step ran on the real output.
if [[ "$T6_SHA" == "yes" ]]; then
    pass "6d: __CADDYFILE_SHA__ self-hash substituted in rendered Caddyfile"
else
    fail "6d: __CADDYFILE_SHA__ not substituted (SHA_SUBBED=$T6_SHA) — sha step did not run"
fi

t6_cleanup
trap - EXIT

# ---- Summary ----
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
