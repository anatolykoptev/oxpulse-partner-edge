#!/bin/bash
# tests/test_setup_caddy_render_env_naive_die.sh
#
# Guards the NAIVE_SOCKS_PORT tier-4 die in lib/reconcile.sh's _setup_caddy_render_env.
#
# Why this test exists (restored coverage): the P5 strangler completion deleted the
# shell renderer re_render_caddy (upgrade.sh) and its inline "Test 7" die-guard test.
# The equivalent guard now lives in _setup_caddy_render_env (lib/reconcile.sh) and is
# the SINGLE source of truth for BOTH apply paths — reconcile_caddy_surface AND the
# upgrade.sh --with-templates dry-run render — so it is MORE safety-critical than
# before, yet no surviving test exercised its die branch (every other test that
# touches _setup_caddy_render_env resolves NAIVE via tier-1/tier-2 to dodge the die).
#
# The bug the guard prevents: when a Caddyfile template uses {{NAIVE_SOCKS_PORT}} and
# NONE of tiers 1-3 (env / STATE_FILE / live `docker inspect`) resolve it, the renderer
# must DIE with an actionable message — NEVER silently fall back to 1080 and bake a
# wrong upstream (127.0.0.1:1080) into the live Caddyfile. A silent 1080 fallback is
# invisible until the naive proxy on the real port stops answering at the edge.
#
# This test sources the REAL lib/reconcile.sh (no hand-copied logic) and drives the
# REAL _setup_caddy_render_env in an isolated subshell per scenario. FALSIFICATION:
#   * delete the tier-4 die (or move the _port=1080 fallback above the die check) →
#     Scenario A no longer dies → this test FAILS.
#   * make the die unconditional (fire regardless of the placeholder or tier-2/3
#     resolution) → Scenario B or C dies unexpectedly → this test FAILS.
# No opec/docker/net required (docker stubbed via DOCKER_BIN=false) → runs anywhere.
set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LIB="$REPO_ROOT/lib/reconcile.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

echo ""
echo "=== _setup_caddy_render_env NAIVE_SOCKS_PORT tier-4 die-guard ==="

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
# Runner (subshell): sandbox + REAL lib source + sourcer-provided die/log/warn.
#   $1 = repo root
#   $2 = sandbox dir
#   $3 = template mode: "PLACEHOLDER" (tpl carries {{NAIVE_SOCKS_PORT}}) | "PLAIN"
#   $4 = STATE mode:    "NO_NAIVE" (STATE has no NAIVE_SOCKS_PORT) | "WITH_NAIVE"
# Prints on stdout: RESULT=DIE|OK  [NAIVE=<value> on OK]
# On DIE, the die() message is echoed to stdout too (so the caller can assert on it).
# ---------------------------------------------------------------------------
cat > "$_tmp/run.sh" << 'RUNNER'
#!/bin/bash
set -uo pipefail
REPO_ROOT="$1"; TMP="$2"; TPL_MODE="$3"; STATE_MODE="$4"
LIB="$REPO_ROOT/lib/reconcile.sh"
mkdir -p "$TMP"

# Sourcer-provided helpers. die() prints an assertable line to STDOUT then exits.
log()  { echo "[LOG] $*"  >&2; }
warn() { echo "[WARN] $*" >&2; }
die()  { echo "RESULT=DIE"; echo "DIE_MSG: $*"; exit 7; }

# Minimal env so _setup_caddy_render_env reaches the NAIVE tier ladder (PARTNER_DOMAIN
# and TURNS_SUBDOMAIN are validated first; missing → an unrelated early die).
export PARTNER_DOMAIN="test.example.com"
export TURNS_SUBDOMAIN="turns.test.example.com"
export PREFIX_SHARE="$TMP/noshare"   # no defaults.conf → AWG/HY2 hardcoded fallbacks
export DOCKER_BIN="false"            # tier-3 `docker inspect` → empty (never resolves)
unset NAIVE_SOCKS_PORT               # tier-1 unset

# STATE_FILE: present, but with/without a NAIVE_SOCKS_PORT line per STATE_MODE.
export STATE_FILE="$TMP/install.env"
{
    echo "PARTNER_DOMAIN=test.example.com"
    echo "TURNS_SUBDOMAIN=turns.test.example.com"
    [[ "$STATE_MODE" == "WITH_NAIVE" ]] && echo "NAIVE_SOCKS_PORT=18892"
} > "$STATE_FILE"

# Template: carries the placeholder (die-eligible) or not (fallback-eligible).
TPL="$TMP/Caddyfile.tpl"
if [[ "$TPL_MODE" == "PLACEHOLDER" ]]; then
    printf 'reverse_proxy 127.0.0.1:{{NAIVE_SOCKS_PORT}}\n' > "$TPL"
else
    printf 'reverse_proxy 127.0.0.1:8080\n' > "$TPL"
fi

# shellcheck disable=SC1090
. "$LIB"

_setup_caddy_render_env "$TPL"
# Reached only when the function did NOT die.
echo "RESULT=OK"
echo "NAIVE=${NAIVE_SOCKS_PORT:-<unset>}"
RUNNER
chmod +x "$_tmp/run.sh"

# ---- Scenario A: placeholder present + all 3 resolution tiers exhausted → MUST die.
OUT_A=$(bash "$_tmp/run.sh" "$REPO_ROOT" "$_tmp/A" "PLACEHOLDER" "NO_NAIVE" 2>/dev/null)
a_result=$(echo "$OUT_A" | sed -n 's/^RESULT=//p')
a_msg=$(echo "$OUT_A" | sed -n 's/^DIE_MSG: //p')

if [[ "$a_result" == "DIE" ]]; then
    pass "A: unresolvable NAIVE_SOCKS_PORT + {{NAIVE_SOCKS_PORT}} in tpl → die (no silent 1080 fallback)"
else
    fail "A: expected die, got RESULT='${a_result:-?}' — tier-4 guard missing (silent-1080 regression: a wrong 127.0.0.1:1080 upstream would be baked into the live Caddyfile)"
fi
if echo "$a_msg" | grep -q 'not in STATE_FILE and naive container is down' \
   && echo "$a_msg" | grep -q 'cannot render Caddyfile safely'; then
    pass "A: die message is the actionable NAIVE_SOCKS_PORT message"
else
    fail "A: die fired but message not the expected actionable one — got: '${a_msg:-<none>}'"
fi

# ---- Scenario B (control): tpl has NO placeholder → die must NOT fire; NAIVE→1080. ----
#      Guards against an over-eager unconditional die that would break every render
#      whose template legitimately does not use {{NAIVE_SOCKS_PORT}}.
OUT_B=$(bash "$_tmp/run.sh" "$REPO_ROOT" "$_tmp/B" "PLAIN" "NO_NAIVE" 2>/dev/null)
b_result=$(echo "$OUT_B" | sed -n 's/^RESULT=//p')
b_naive=$(echo "$OUT_B" | sed -n 's/^NAIVE=//p')

if [[ "$b_result" == "OK" ]]; then
    pass "B: no placeholder in tpl → no die (1080 fallback is legal when unused)"
else
    fail "B: expected OK, got RESULT='${b_result:-?}' — die is unconditional (breaks placeholder-free renders)"
fi
if [[ "$b_naive" == "1080" ]]; then
    pass "B: NAIVE_SOCKS_PORT fell back to 1080 (only when the placeholder is absent)"
else
    fail "B: expected NAIVE=1080 fallback, got '${b_naive:-?}'"
fi

# ---- Scenario C (control): placeholder present BUT tier-2 (STATE_FILE) resolves → ----
#      die must NOT fire; NAIVE takes the STATE value, never 1080. Guards against a die
#      that fires merely because the placeholder is present, ignoring a valid resolution.
OUT_C=$(bash "$_tmp/run.sh" "$REPO_ROOT" "$_tmp/C" "PLACEHOLDER" "WITH_NAIVE" 2>/dev/null)
c_result=$(echo "$OUT_C" | sed -n 's/^RESULT=//p')
c_naive=$(echo "$OUT_C" | sed -n 's/^NAIVE=//p')

if [[ "$c_result" == "OK" ]]; then
    pass "C: placeholder present but tier-2 (STATE_FILE) resolves → no die"
else
    fail "C: expected OK, got RESULT='${c_result:-?}' — die fired despite a valid tier-2 resolution"
fi
if [[ "$c_naive" == "18892" ]]; then
    pass "C: NAIVE_SOCKS_PORT resolved from STATE_FILE (18892), not the 1080 fallback"
else
    fail "C: expected NAIVE=18892 from STATE_FILE, got '${c_naive:-?}'"
fi

echo ""
echo "=== _setup_caddy_render_env NAIVE die-guard: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
