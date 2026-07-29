#!/usr/bin/env bash
# tests/test_reconcile_firewall_unsupported.sh — t14 finding regression test.
#
# Bug (config_drift / medium / likely, bug-hunt t14): on a host with neither
# ufw nor firewalld, lib/install-firewall.sh:167-173 (none|* branch) used to
# `return 0` even though it applied nothing, so
# lib/reconcile.sh:1351-1369's `firewall_apply || warn ...` never fired the
# warn — the converge cycle logged green with
# _RECONCILE_FIREWALL_APPLIED=1 while SFU (:9317) + coturn relay (:8912)
# mesh-only ports and the public whitelist stayed unenforced.
#
# Fix under test:
#   1. firewall_apply returns a DISTINCT non-zero (2) on the unsupported-tool
#      branch instead of 0 (lib/install-firewall.sh).
#   2. reconcile_firewall_surface propagates that failure: it does NOT set
#      _RECONCILE_FIREWALL_APPLIED=1, and escalates via the existing
#      dozor AM-webhook notify primitive (lib/telegram-alert-lib.sh tg_alert)
#      with a critical-classified message instead of a buried warn
#      (lib/reconcile.sh).
#
# Falsification: reverting either fix collapses this test back to failing —
#   - revert (1) only: firewall_apply returns 0 → the `if firewall_apply` in
#     reconcile_firewall_surface takes the success branch → APPLIED stays 1
#     and tg_alert (spy) is never called → T2/T3 fail.
#   - revert (2) only (restore `firewall_apply || warn ...`; drop escalate +
#     APPLIED gating): APPLIED gets set to 1 unconditionally and tg_alert
#     (spy) is never called → T2/T3 fail, even though firewall_apply itself
#     already returns 2 (T1 alone would still pass).
#
# REAL-CODE MANDATE: this test sources the real lib/reconcile.sh and the real
# lib/install-firewall.sh (unmodified, no hand-copied function bodies) and
# calls the real reconcile_firewall_surface(). Only the *leaf* dependencies —
# _firewall_detect_tool (so no ufw/firewalld is required in the test sandbox)
# and tg_alert (so no real network POST fires) — are substituted via the
# declare-f injection seam the production code already provides (the same
# seam tests/test_caddy_reload_fail_loud.sh and tests/test_converge_idempotent.sh
# use to stub firewall_apply itself).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
FW_LIB="$REPO_ROOT/lib/install-firewall.sh"
RECONCILE_LIB="$REPO_ROOT/lib/reconcile.sh"
TG_LIB="$REPO_ROOT/lib/telegram-alert-lib.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

echo ""
echo "=== t14: firewall reconcile unsupported-tool escalation ==="

[[ -f "$FW_LIB" ]]        || { fail "P0: lib/install-firewall.sh not found"; exit 1; }
[[ -f "$RECONCILE_LIB" ]] || { fail "P0: lib/reconcile.sh not found"; exit 1; }
[[ -f "$TG_LIB" ]]        || { fail "P0: lib/telegram-alert-lib.sh not found"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

log()  { printf '[log] %s\n' "$*" >>"$TMP/calls.log"; }
warn() { printf '[warn] %s\n' "$*" >>"$TMP/calls.log"; }
die()  { printf '[die] %s\n' "$*" >>"$TMP/calls.log"; exit 1; }

# Source the REAL libs. install-firewall.sh first so reconcile.sh's
# `declare -f firewall_apply` lazy-source check short-circuits (matches the
# established stubbing pattern in tests/test_caddy_reload_fail_loud.sh).
# shellcheck source=lib/install-firewall.sh
. "$FW_LIB"
# shellcheck source=lib/reconcile.sh
. "$RECONCILE_LIB"

# Force the "no supported firewall tool" branch without needing ufw/firewalld
# installed in the test sandbox (mirrors tests/test_install_firewall_module.sh
# Test 3). Defined AFTER sourcing so it overrides the real detector by name
# lookup at call time (bash resolves function calls dynamically).
_firewall_detect_tool() { printf 'none'; }

# Avoid the (unrelated) AWG-port-unresolvable skip branch so the test
# actually reaches the unsupported-tool branch under test.
export AWG_LISTEN_PORT=44399

# ── T1: firewall_apply itself returns non-zero on the unsupported branch ────
_t1_rc=0
firewall_apply >/dev/null 2>&1 || _t1_rc=$?
if [[ "$_t1_rc" -ne 0 ]]; then
	pass "T1: firewall_apply returns non-zero (rc=$_t1_rc) when no fw tool present"
else
	fail "T1: firewall_apply returned 0 with no fw tool present (silent no-op)"
fi

# ── T2/T3: reconcile_firewall_surface propagates + escalates (spy) ─────────
: >"$TMP/tg_alert.log"
# Spy tg_alert BEFORE calling reconcile_firewall_surface: declare -f tg_alert
# will be true, so reconcile_firewall_surface's lazy-source of the real
# lib/telegram-alert-lib.sh is skipped and THIS spy is invoked in its place
# (same injection seam as firewall_apply above) — no real webhook POST fires.
tg_alert() { printf '%s\t%s\n' "$1" "${2:-}" >>"$TMP/tg_alert.log"; }

_RECONCILE_FIREWALL_APPLIED=0
reconcile_firewall_surface

if [[ "$_RECONCILE_FIREWALL_APPLIED" -eq 0 ]]; then
	pass "T2: _RECONCILE_FIREWALL_APPLIED stays 0 when firewall_apply failed (not silently marked applied)"
else
	fail "T2: _RECONCILE_FIREWALL_APPLIED=$_RECONCILE_FIREWALL_APPLIED — silently marked applied despite unsupported tool"
fi

if [[ -s "$TMP/tg_alert.log" ]]; then
	_tg_call=$(cat "$TMP/tg_alert.log")
	# Severity vocab = critical|warning|info ONLY (CLAUDE.md). The message text
	# must classify as critical under dozor's classifyMonitorMessage lexical
	# match (see lib/telegram-alert-lib.sh header) — assert a critical token
	# is present, not just that *some* alert fired.
	if echo "$_tg_call" | grep -iE 'critical|failed|unreachable|blocked' >/dev/null; then
		pass "T3a: tg_alert (AM-webhook notify path) called with a critical-classified message"
	else
		fail "T3a: tg_alert called but message has no critical-severity token: $_tg_call"
	fi
	# force bypasses the 600s rate-limit floor — an unenforced firewall must
	# alert every converge cycle, not just the first.
	if echo "$_tg_call" | grep -E $'\t''(force|1)$' >/dev/null; then
		pass "T3b: tg_alert called with force (bypasses rate-limit floor)"
	else
		fail "T3b: tg_alert not forced — rate-limit could swallow a real incident: $_tg_call"
	fi
else
	fail "T3: tg_alert was NOT called — firewall-unmanaged failure swallowed silently (buried warn only)"
fi

# ── T4: supported tools unaffected (acceptance: no regression on ufw path) ──
: >"$TMP/tg_alert.log"
_firewall_detect_tool() { printf 'ufw'; }
# Stub the tool-specific appliers so no real ufw/firewall-cmd is required.
_firewall_apply_ufw() { :; }
AWG_LISTEN_PORT=44400
_RECONCILE_FIREWALL_APPLIED=0
reconcile_firewall_surface
if [[ "$_RECONCILE_FIREWALL_APPLIED" -eq 1 ]]; then
	pass "T4a: _RECONCILE_FIREWALL_APPLIED=1 on the supported-tool (ufw) path — unaffected"
else
	fail "T4a: _RECONCILE_FIREWALL_APPLIED=$_RECONCILE_FIREWALL_APPLIED on supported-tool path — regression"
fi
if [[ ! -s "$TMP/tg_alert.log" ]]; then
	pass "T4b: tg_alert NOT called on the supported-tool (success) path — no false-positive alert"
else
	fail "T4b: tg_alert called on success path: $(cat "$TMP/tg_alert.log")"
fi

echo ""
echo "=== t14 firewall-unsupported tests: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
