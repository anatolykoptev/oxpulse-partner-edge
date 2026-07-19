#!/usr/bin/env bash
# Tests for the central-driven fleet self-upgrade (partner-cli-update arc, part 3):
#   L3 upgrade.sh  — _assert_apply_not_downgrade gates the APPLY path on Check 3.
#   L2 refresh.sh  — _maybe_self_upgrade consumes desired_release, guards, applies.
# Mirrors the awk-extract + PATH-stub idiom of tests/test_publicip_*.sh.
set -uo pipefail
# shellcheck disable=SC1090,SC2034  # dynamic source of extracted fns; vars used via dynamic scope
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
UPGRADE="$ROOT/upgrade.sh"
REFRESH="$ROOT/oxpulse-partner-edge-refresh.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== Section A: structural ==="
bash -n "$UPGRADE" && pass "A1: upgrade.sh syntax clean" || { fail "A1: upgrade.sh syntax"; exit 1; }
bash -n "$REFRESH" && pass "A2: refresh.sh syntax clean" || { fail "A2: refresh.sh syntax"; exit 1; }
grep -q '^_assert_apply_not_downgrade() {' "$UPGRADE" \
    && pass "A3: _assert_apply_not_downgrade defined" || { fail "A3: L3 guard missing"; exit 1; }
grep -q '^_maybe_self_upgrade() {' "$REFRESH" \
    && pass "A4: _maybe_self_upgrade defined" || { fail "A4: L2 hook missing"; exit 1; }
# the L3 guard must be CALLED on the apply path (before the self-update reexec)
[ "$(grep -c '^[[:space:]]*_assert_apply_not_downgrade$' "$UPGRADE")" -ge 2 ] \
    && pass "A5: L3 guard wired at both apply reexec sites" || fail "A5: L3 guard not wired (<2 call sites)"

TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT
BIN="$TMPD/bin"; mkdir -p "$BIN"

# ===========================================================================
echo "=== Section B: L3 — apply-path downgrade guard ==="
L3="$TMPD/l3.sh"
{
    echo 'die() { printf "ERR %s\n" "$*" >&2; exit 3; }'
    awk '/^_conflict_check_3\(\)/{f=1} f{print} /^}$/ && f{exit}' "$UPGRADE"
    awk '/^_assert_apply_not_downgrade\(\)/{f=1} f{print} /^}$/ && f{exit}' "$UPGRADE"
} > "$L3"
bash -n "$L3" && pass "B0: extracted L3 functions parse" || { fail "B0: L3 extract syntax"; exit 1; }

# downgrade: CURRENT=v0.16.4, target v0.16.2 → CATASTROPHIC → die(exit 3)
( CURRENT="v0.16.4"; RELEASE_TAG="v0.16.2"; SKIPPED_CHECKS=""; source "$L3"; _assert_apply_not_downgrade ) 2>/dev/null
[ "$?" -eq 3 ] && pass "B1: downgrade (v0.16.4→v0.16.2) DIES on apply" || fail "B1: downgrade not refused on apply"

# upgrade: CURRENT=v0.16.2, target v0.16.4 → PASS → no die
( CURRENT="v0.16.2"; RELEASE_TAG="v0.16.4"; SKIPPED_CHECKS=""; source "$L3"; _assert_apply_not_downgrade ) 2>/dev/null
[ "$?" -eq 0 ] && pass "B2: upgrade (v0.16.2→v0.16.4) proceeds" || fail "B2: upgrade wrongly blocked"

# same version → no die
( CURRENT="v0.16.4"; RELEASE_TAG="v0.16.4"; SKIPPED_CHECKS=""; source "$L3"; _assert_apply_not_downgrade ) 2>/dev/null
[ "$?" -eq 0 ] && pass "B3: same version proceeds" || fail "B3: same version blocked"

# downgrade + --skip-check=3 → skipped → no die
( CURRENT="v0.16.4"; RELEASE_TAG="v0.16.2"; SKIPPED_CHECKS=" 3 "; source "$L3"; _assert_apply_not_downgrade ) 2>/dev/null
[ "$?" -eq 0 ] && pass "B4: --skip-check=3 forces the downgrade" || fail "B4: skip-check=3 not honored"

# ===========================================================================
echo "=== Section C: L2 — refresh self-upgrade hook ==="
L2="$TMPD/l2.sh"
{
    echo 'log() { printf "==> %s\n" "$*" >&2; }'
    echo 'emit_metric() { printf "METRIC %s\n" "$1" >> "$METRICS"; }'
    awk '/^_self_upgrade_is_ge\(\)/{f=1} f{print} /^}$/ && f{exit}' "$REFRESH"
    awk '/^_maybe_self_upgrade\(\)/{f=1} f{print} /^}$/ && f{exit}' "$REFRESH"
} > "$L2"
bash -n "$L2" && pass "C0: extracted L2 functions parse" || { fail "C0: L2 extract syntax"; exit 1; }

# stub the upgrade binary — records its invocation + args
cat > "$BIN/oxpulse-partner-edge-upgrade" <<STUB
#!/usr/bin/env bash
echo "\$@" > "$TMPD/upg_called"
exit 0
STUB
chmod +x "$BIN/oxpulse-partner-edge-upgrade"

PREFIX_LIB="$TMPD/lib"; mkdir -p "$PREFIX_LIB"
printf 'IMAGE_VERSION=v0.16.2\n' > "$PREFIX_LIB/install.env"

run_l2() {  # $1=desired_release (or "" to omit)
    rm -f "$TMPD/upg_called"; METRICS="$TMPD/metrics"; : > "$METRICS"
    local body='{}'; [ -n "$1" ] && body="{\"desired_release\":\"$1\"}"
    ( set -euo pipefail; export PATH="$BIN:$PATH" PREFIX_LIB METRICS; source "$L2"; _maybe_self_upgrade 200 "$body" ) 2>/dev/null
}

run_l2 "0.16.4"   # upgrade
[ "$(cat "$TMPD/upg_called" 2>/dev/null)" = "v0.16.4" ] \
    && pass "C1: desired>installed → invokes upgrade v0.16.4" || fail "C1: upgrade not invoked for a valid upgrade"

run_l2 "0.16.1"   # downgrade
[ ! -f "$TMPD/upg_called" ] && grep -q downgrade_refused "$TMPD/metrics" \
    && pass "C2: desired<installed → REFUSED, no upgrade invoked" || fail "C2: downgrade not refused"

run_l2 "0.16.2"   # converged
[ ! -f "$TMPD/upg_called" ] \
    && pass "C3: desired==installed → no-op (converged)" || fail "C3: converged wrongly invoked upgrade"

run_l2 "latest"   # non-semver
[ ! -f "$TMPD/upg_called" ] && grep -q rejected "$TMPD/metrics" \
    && pass "C4: 'latest' rejected (non-semver), no upgrade" || fail "C4: latest not rejected"

run_l2 ""         # no desired_release (older central) → graceful no-op
[ ! -f "$TMPD/upg_called" ] \
    && pass "C5: absent desired_release → graceful no-op" || fail "C5: absent field wrongly acted"

# non-concrete installed (default IMAGE_VERSION=stable) → fail-closed refuse
printf 'IMAGE_VERSION=stable\n' > "$PREFIX_LIB/install.env"
run_l2 "0.16.4"
[ ! -f "$TMPD/upg_called" ] && grep -q unknown_installed "$TMPD/metrics" \
    && pass "C6: installed=stable → fail-closed refuse (no upgrade)" || fail "C6: stable-installed not refused"
printf 'IMAGE_VERSION=v0.16.2\n' > "$PREFIX_LIB/install.env"   # restore

# missing IMAGE_VERSION= line → fail-soft (no abort) + fail-closed refuse
printf 'SOMETHING=else\n' > "$PREFIX_LIB/install.env"
run_l2 "0.16.4"; _rc_missing=$?
[ "$_rc_missing" -eq 0 ] && [ ! -f "$TMPD/upg_called" ] \
    && pass "C7: missing IMAGE_VERSION → fail-soft (rc 0) + refuse" || fail "C7: missing IMAGE_VERSION aborted/acted"
printf 'IMAGE_VERSION=v0.16.2\n' > "$PREFIX_LIB/install.env"   # restore

# pre-release desired → rejected (not a concrete release target)
run_l2 "0.16.4-rc1"
[ ! -f "$TMPD/upg_called" ] && grep -q rejected "$TMPD/metrics" \
    && pass "C8: pre-release desired (0.16.4-rc1) rejected" || fail "C8: pre-release not rejected"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "PASS: test_fleet_self_upgrade — all checks passed"; exit 0; } \
                  || { echo "FAIL: test_fleet_self_upgrade — $FAIL failed"; exit 1; }
