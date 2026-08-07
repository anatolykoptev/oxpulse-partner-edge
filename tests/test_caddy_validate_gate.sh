#!/bin/bash
# tests/test_caddy_validate_gate.sh
#
# _assert_caddyfile_loads must refuse to install a Caddyfile the RUNNING caddy
# binary cannot parse — and must refuse BEFORE the swap, not after.
#
# Root cause under test:
#   upgrade.sh has owned this exact test since conflict check 1 (upgrade.sh:2806),
#   including the correct remedy in its hint. But run_conflict_checks executes
#   only on the --dry-run report path and then exits, so no path that actually
#   APPLIES a template ever ran it. Check 3 had the identical shape and was
#   promoted to the apply path as _assert_apply_not_downgrade — its comment
#   records that a plain upgrade would otherwise silently downgrade. Check 1 was
#   never promoted.
#
# Why the ordering is the whole point: apply_caddy_reloads hot-reloads and, on
# failure, falls back to `up -d --force-recreate caddy`. The recreate reads the
# file that was ALREADY swapped, so an unparseable Caddyfile crashloops caddy and
# :443 on that edge goes dark. A gate placed after atomic_swap would report the
# problem while the outage is already happening.
#
# Falsification (anti-vacuous):
#   T3  remove the `die` → the bad config is accepted (FAIL)
#   T7  move _assert_caddyfile_loads after atomic_swap → ordering assert (FAIL)
#   T1  make the no-running-caddy branch fail closed → first install breaks (FAIL)
#   T5/T6 drop an escape hatch → operator cannot override a known-good directive
#
# REAL-CODE MANDATE: sources the real lib/reconcile.sh and drives the real
# _assert_caddyfile_loads. Only docker is stubbed.
set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LIB="$REPO_ROOT/lib/reconcile.sh"

PASS=0
FAIL=0
pass() {
	echo "PASS: $1"
	PASS=$((PASS + 1))
}
fail() {
	echo "FAIL: $1"
	FAIL=$((FAIL + 1))
}

echo ""
echo "=== caddy config validate gate (fail-closed, pre-swap) ==="

[[ -f "$LIB" ]] || {
	fail "T0: lib/reconcile.sh not found"
	exit 1
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --- docker stub -----------------------------------------------------------
# STUB_CID    : what `compose ps -q caddy` / `ps -q` return ("" = no container)
# STUB_IMAGE  : what `inspect -f {{.Config.Image}}` returns
# STUB_RC     : exit code of `docker run ... caddy validate`
# STUB_CALLS  : appended to, so a test can assert `docker run` never happened
mkdir -p "$TMP/bin"
cat >"$TMP/bin/docker" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "${STUB_CALLS:-/dev/null}"
case "$1" in
  compose) printf '%s\n' "${STUB_CID:-}" ;;
  ps)      printf '%s\n' "${STUB_CID:-}" ;;
  inspect) printf '%s\n' "${STUB_IMAGE:-}" ;;
  run)     printf 'adapting config: unrecognized directive: cache\n'; exit "${STUB_RC:-0}" ;;
  *)       exit 0 ;;
esac
STUB
chmod +x "$TMP/bin/docker"
export PATH="$TMP/bin:$PATH"

CAND="$TMP/candidate.caddy"
printf ':80 { respond "x" }\n' >"$CAND"

# Drive the real function in a subshell with log/warn/die stubbed.
# `die` exits 9 so the caller can distinguish a refusal from any other failure.
drive() {
	(
		log() { echo "[L] $*"; }
		warn() { echo "[W] $*"; }
		die() {
			echo "[DIE] $*"
			exit 9
		}
		# shellcheck disable=SC1090
		. "$LIB"
		_assert_caddyfile_loads "$CAND"
	)
}

# --- T1: no running caddy → skip, and say so ------------------------------
out=$(STUB_CID="" STUB_IMAGE="" STUB_RC=0 drive 2>&1)
rc=$?
if [[ $rc -eq 0 && "$out" == *"no running caddy container"* ]]; then
	pass "T1: no running caddy → skipped (a fresh install renders before the image exists)"
else
	fail "T1: expected a logged skip and rc=0, got rc=$rc: $out"
fi

# --- T2: running caddy, config valid → proceed ----------------------------
out=$(STUB_CID="deadbeef" STUB_IMAGE="ghcr.io/x/caddy:v1" STUB_RC=0 drive 2>&1)
rc=$?
if [[ $rc -eq 0 && "$out" == *"validates against the running image"* ]]; then
	pass "T2: valid config against the running image → proceeds"
else
	fail "T2: expected rc=0 and a validation log, got rc=$rc: $out"
fi

# --- T3: running caddy, config INVALID → refuse (the whole point) ---------
out=$(STUB_CID="deadbeef" STUB_IMAGE="ghcr.io/x/caddy:v1" STUB_RC=1 drive 2>&1)
rc=$?
if [[ $rc -eq 9 && "$out" == *"NOT loadable"* ]]; then
	pass "T3: unparseable config → die BEFORE any swap"
else
	fail "T3: expected die (rc=9), got rc=$rc: $out"
fi

# --- T4: the refusal names the remedy and the untouched state -------------
if [[ "$out" == *"--image-only"* && "$out" == *"previous Caddyfile is untouched"* ]]; then
	pass "T4: refusal names the ordering remedy and states nothing was swapped"
else
	fail "T4: refusal message lacks the remedy or the reassurance: $out"
fi

# --- T5: --skip-check=1 escape hatch --------------------------------------
CALLS="$TMP/calls5"
: >"$CALLS"
out=$(STUB_CALLS="$CALLS" SKIPPED_CHECKS=" 1 " STUB_CID="deadbeef" \
	STUB_IMAGE="ghcr.io/x/caddy:v1" STUB_RC=1 drive 2>&1)
rc=$?
if [[ $rc -eq 0 ]] && ! grep -q '^run ' "$CALLS"; then
	pass "T5: --skip-check=1 skips without even invoking docker run"
else
	fail "T5: expected a no-docker skip, got rc=$rc calls=[$(tr '\n' ';' <"$CALLS")]"
fi

# --- T6: env escape hatch for the install path ----------------------------
out=$(OXPULSE_SKIP_CADDY_VALIDATE=1 STUB_CID="deadbeef" \
	STUB_IMAGE="ghcr.io/x/caddy:v1" STUB_RC=1 drive 2>&1)
rc=$?
if [[ $rc -eq 0 ]]; then
	pass "T6: OXPULSE_SKIP_CADDY_VALIDATE=1 skips"
else
	fail "T6: expected rc=0, got rc=$rc: $out"
fi

# --- T7: STATIC — the gate must sit BEFORE atomic_swap --------------------
# The behavioural tests above cannot see ordering: a gate that dies correctly
# but runs after the swap passes every one of them while the outage happens.
# Comments are blanked (line-for-line, so numbering is preserved) before the
# search. Without that this assert reads prose: reconcile_caddy_surface carries
# the line "causing atomic_swap every run" in a comment 59 lines ABOVE the real
# call, which made this test fail against correctly-ordered code on its first run.
body=$(awk '/^reconcile_caddy_surface\(\)/{f=1} f{print} f&&/^}/{exit}' "$LIB" | sed 's/#.*//')
gate_ln=$(printf '%s\n' "$body" | grep -n '^[[:space:]]*_assert_caddyfile_loads ' | sed '1q' | cut -d: -f1)
swap_ln=$(printf '%s\n' "$body" | grep -n '^[[:space:]]*atomic_swap ' | sed '1q' | cut -d: -f1)
if [[ -n "$gate_ln" && -n "$swap_ln" && "$gate_ln" -lt "$swap_ln" ]]; then
	pass "T7: _assert_caddyfile_loads is called before atomic_swap (gate:$gate_ln swap:$swap_ln)"
else
	fail "T7: gate must precede atomic_swap in reconcile_caddy_surface (gate:${gate_ln:-none} swap:${swap_ln:-none})"
fi

# --- T8: the post-mortem copy is labelled as a VALIDATE failure -----------
# A validate refusal and a reload double-failure are different incidents; one
# label for both would make the log dir unreadable during an actual outage.
if grep -q 'caddy-validate-fail' "$LIB"; then
	pass "T8: refused candidate is persisted under its own label"
else
	fail "T8: expected a distinct caddy-validate-fail label"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
