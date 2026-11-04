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

# systemd-run stub: records argv, does NOT run the command (the real one hands it
# to systemd and returns at once). systemctl stub: ActiveState from $SELFUP_STATE.
cat > "$BIN/systemd-run" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMPD/sdrun_called"
exit "\${SDRUN_RC:-0}"
STUB
cat > "$BIN/systemctl" <<STUB
#!/usr/bin/env bash
[ "\$1" = show ] && echo "\${SELFUP_STATE:-inactive}"
exit 0
STUB
chmod +x "$BIN/systemd-run" "$BIN/systemctl"
PREFIX_LIB="$TMPD/lib"; mkdir -p "$PREFIX_LIB"
printf 'IMAGE_VERSION=v0.16.2\n' > "$PREFIX_LIB/install.env"

run_l2() {  # $1=desired_release (or "" to omit)
    rm -f "$TMPD/upg_called" "$TMPD/sdrun_called"; METRICS="$TMPD/metrics"; : > "$METRICS"
    local body='{}'; [ -n "$1" ] && body="{\"desired_release\":\"$1\"}"
    ( set -euo pipefail; export PATH="$BIN:$PATH" PREFIX_LIB METRICS; source "$L2"; _maybe_self_upgrade 200 "$body" ) 2>/dev/null
}

run_l2 "0.16.4"   # upgrade
# C1: the upgrade is handed to systemd-run as its own detached unit and is NEVER run
# synchronously inside the refresh unit (TimeoutStartSec=120 SIGTERMed it, 2026-10-31).
grep -q -- '--unit=oxpulse-partner-edge-self-upgrade' "$TMPD/sdrun_called" 2>/dev/null \
    && grep -q -- '--no-block' "$TMPD/sdrun_called" \
    && grep -q -- 'TimeoutStartSec=1000' "$TMPD/sdrun_called" \
    && grep -Eq 'oxpulse-partner-edge-upgrade v0.16.4$' "$TMPD/sdrun_called" \
    && [ ! -f "$TMPD/upg_called" ] \
    && pass "C1: desired>installed → detached systemd-run unit for v0.16.4, no inline upgrade" \
    || fail "C1: upgrade not handed to a detached unit (or ran inline)"

SELFUP_STATE=activating run_l2 "0.16.4"
[ ! -f "$TMPD/sdrun_called" ] && [ ! -f "$TMPD/upg_called" ] \
    && pass "C1b: self-upgrade unit already activating → no second upgrade started" || fail "C1b: second concurrent upgrade started"

SDRUN_RC=1 run_l2 "0.16.4"; _rc_sd=$?
[ "$_rc_sd" -eq 0 ] && grep -q self_upgrade_failure "$TMPD/metrics" \
    && pass "C1c: systemd-run failure → fail-soft (rc 0) + failure metric" || fail "C1c: systemd-run failure aborted refresh or went unmetered"

run_l2 "0.16.1"   # downgrade
[ ! -f "$TMPD/upg_called" ] && [ ! -f "$TMPD/sdrun_called" ] && grep -q downgrade_refused "$TMPD/metrics" \
    && pass "C2: desired<installed → REFUSED, no upgrade invoked" || fail "C2: downgrade not refused"

run_l2 "0.16.2"   # converged
[ ! -f "$TMPD/upg_called" ] && [ ! -f "$TMPD/sdrun_called" ] \
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

# ===========================================================================
echo "=== Section D: upgrade.sh re-runs detached when started inside the refresh unit ==="
# Nodes whose refresh predates the detached runner still run upgrade.sh inside
# oxpulse-partner-edge-refresh.service (killed at 120 s). The (post-self-update)
# upgrade.sh must move itself out of that cgroup.
DT="$TMPD/d.sh"
{
    echo 'log() { printf "==> %s\n" "$*" >&2; }; warn() { printf "!! %s\n" "$*" >&2; }'
    awk '/^_SELF_UPGRADE_UNIT=/{print}' "$UPGRADE"
    awk '/^_maybe_detach_from_refresh_unit\(\)/{f=1} f{print} /^}$/ && f{exit}' "$UPGRADE"
} > "$DT"
bash -n "$DT" && pass "D0: extracted detach function parses" || { fail "D0: detach extract syntax"; exit 1; }
printf '0::/system.slice/oxpulse-partner-edge-refresh.service\n' > "$TMPD/cg_refresh"
printf '0::/system.slice/oxpulse-partner-edge-self-upgrade.service\n' > "$TMPD/cg_detached"
printf '0::/user.slice/user-0.slice/session-3.scope\n' > "$TMPD/cg_ssh"
mkdir -p "$TMPD/sbin"; printf '#!/bin/sh\n' > "$TMPD/sbin/oxpulse-partner-edge-upgrade"; chmod +x "$TMPD/sbin/oxpulse-partner-edge-upgrade"
run_d() {  # $1=cgroup file; $_drc = exit status of the subshell; "after" marks fall-through
    rm -f "$TMPD/sdrun_called" "$TMPD/after"
    ( export PATH="$BIN:$PATH" OXPULSE_UPGRADE_CGROUP_FILE="$1" PREFIX_SBIN="$TMPD/sbin" PREFIX_LIB="$TMPD/lib"
      source "$DT"; _maybe_detach_from_refresh_unit --check-x v0.16.4; touch "$TMPD/after" ) 2>/dev/null
    _drc=$?
}
run_d "$TMPD/cg_refresh"
[ "$_drc" -eq 0 ] && [ ! -f "$TMPD/after" ] \
    && grep -q -- '--unit=oxpulse-partner-edge-self-upgrade' "$TMPD/sdrun_called" \
    && grep -q -- '--setenv=_OXPULSE_UPGRADE_DETACHED=1' "$TMPD/sdrun_called" \
    && grep -Fq "$TMPD/sbin/oxpulse-partner-edge-upgrade --check-x v0.16.4" "$TMPD/sdrun_called" \
    && pass "D1: inside refresh cgroup → re-exec detached with original args, parent exits 0" \
    || fail "D1: not detached from the refresh unit (rc=$_drc)"
run_d "$TMPD/cg_ssh"
[ "$_drc" -eq 0 ] && [ -f "$TMPD/after" ] && [ ! -f "$TMPD/sdrun_called" ] \
    && pass "D2: outside the refresh cgroup (operator ssh) → runs inline" || fail "D2: detached when it should not"
run_d "$TMPD/cg_detached"
[ -f "$TMPD/after" ] && [ ! -f "$TMPD/sdrun_called" ] \
    && pass "D3: already in the self-upgrade unit → runs inline" || fail "D3: re-detach loop risk"
_OXPULSE_UPGRADE_DETACHED=1 run_d "$TMPD/cg_refresh"
[ -f "$TMPD/after" ] && [ ! -f "$TMPD/sdrun_called" ] \
    && pass "D4: _OXPULSE_UPGRADE_DETACHED=1 sentinel → no second detach" || fail "D4: sentinel ignored"
SELFUP_STATE=active run_d "$TMPD/cg_refresh"
[ "$_drc" -eq 0 ] && [ ! -f "$TMPD/after" ] && [ ! -f "$TMPD/sdrun_called" ] \
    && pass "D5: self-upgrade unit already active → skip, no second upgrade" || fail "D5: concurrent upgrade started"
SDRUN_RC=1 run_d "$TMPD/cg_refresh"
[ -f "$TMPD/after" ] \
    && pass "D6: systemd-run failure → falls back to inline (legacy behaviour)" || fail "D6: no fallback when systemd-run fails"
# wiring: the call sits BEFORE the flock (the transient unit does not inherit fd 9)
_dl=$(grep -n '^	_maybe_detach_from_refresh_unit "\$@"' "$UPGRADE" -m1 | cut -d: -f1)
_ll=$(grep -n '^	exec 9>"\$LOCK_FILE"' "$UPGRADE" -m1 | cut -d: -f1)
[ -n "$_dl" ] && [ -n "$_ll" ] && [ "$_dl" -lt "$_ll" ] \
    && pass "D7: detach is wired before the upgrade.lock flock" || fail "D7: detach missing or after the flock"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "PASS: test_fleet_self_upgrade — all checks passed"; exit 0; } \
                  || { echo "FAIL: test_fleet_self_upgrade — $FAIL failed"; exit 1; }
