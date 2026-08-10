#!/bin/bash
# tests/test_upgrade_enable_set_matches_installer.sh
#
# The upgrade path's enable-set MUST equal the installer's, and every unit in
# it MUST be delivered by the upgrade path.
#
# Why this test exists (fleet fingerprint, 2026-08-07 — 5 of 5 nodes, 86 axes):
# a fresh install enables seven units; nothing on any upgrade path ever ran
# `systemctl enable` at all. The two oldest nodes (rvpn-seed,
# zvonilka-cc7cf842800b) therefore sat with oxpulse-partner-edge.service
# DISABLED — no container comes back after a reboot — plus the xray-update and
# geoip-refresh timers off, and NO cert-watch units at all, so a renewed TURNS
# certificate never signalled coturn. Every one of those was reachable only
# from a fresh install, and no upgrade could ever repair it.
#
# The fix put an enable-set in upgrade.sh. That immediately creates the defect
# this file guards: a THIRD hand-maintained list, free to drift from the
# installer that defines what "installed" means. So the set is derived from
# lib/install-systemd.sh's own BAKE_MODE=0 branch and compared, rather than
# re-typed and trusted.
#
# Asserts:
#   S1: both sets extract non-empty and at or above the anti-vacuous floor.
#   S2: upgrade.sh's _HOST_SCRIPT_ENABLE_UNITS == the installer's BAKE_MODE=0 set.
#   S3: the bake-only hydrate oneshot is NOT in the set (extraction sanity: a
#       naive "whole function" grab would silently pull the else-branch in).
#   S4: every unit in the enable-set has a file in systemd/.
#   S5: every unit in the enable-set is DELIVERED by an upgrade — present in
#       _HOST_SCRIPT_SYSTEMD_FILES or _HOST_SCRIPT_SYSTEMD_TEMPLATED_FILES.
#       This is the assertion that would have caught the original cert-watch
#       gap: enabling a unit the upgrade path never ships is a guaranteed warn
#       on every run and a permanently unconverged node.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
UPGRADE="$REPO_ROOT/upgrade.sh"
INSTALLER="$REPO_ROOT/lib/install-systemd.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

for f in "$UPGRADE" "$INSTALLER"; do
    [[ -f "$f" ]] || { echo "FAIL: $f not found"; exit 1; }
done

# Anti-vacuous floor. The installer enables 7 units as of v0.16.13; a drop
# below that means the extraction broke, not that the fleet shrank. Raise it
# deliberately when units are added — never lower it to make a run green.
FLOOR=7

# ---------------------------------------------------------------------------
# Extract the installer's live-install enable-set.
#
# The BAKE_MODE=0 branch ONLY. The else-branch is bake mode (pre-snapshot),
# which enables oxpulse-partner-edge-hydrate.service instead of the main
# service and deliberately does not start anything — grabbing the whole
# function would merge the two and silently produce the wrong desired state.
# ---------------------------------------------------------------------------
installer_units=$(awk '
    /^_systemd_enable_units\(\)/                 { infn=1 }
    infn && /BAKE_MODE/ && /"0"/                 { inbranch=1; next }
    inbranch && /^[[:space:]]*else[[:space:]]*$/ { exit }
    inbranch && /systemctl enable/               { print $NF }
' "$INSTALLER" | sort -u)

# ---------------------------------------------------------------------------
# Extract upgrade.sh's declared enable-set.
# ---------------------------------------------------------------------------
_extract_array() {
    awk -v name="$1" '
        $0 ~ "^" name "=\\(" { inarr=1; next }
        inarr && /^\)/       { exit }
        inarr {
            sub(/#.*/, "")
            gsub(/[[:space:]]/, "")
            if (length($0)) print
        }
    ' "$UPGRADE" | sort -u
}

upgrade_units=$(_extract_array _HOST_SCRIPT_ENABLE_UNITS)
delivered_plain=$(_extract_array _HOST_SCRIPT_SYSTEMD_FILES)
delivered_tpl=$(_extract_array _HOST_SCRIPT_SYSTEMD_TEMPLATED_FILES)
delivered_all=$(printf '%s\n%s\n' "$delivered_plain" "$delivered_tpl" | sort -u)

echo ""
echo "=== Enable-set parity: upgrade.sh vs lib/install-systemd.sh ==="

# ---------------------------------------------------------------------------
# S1: anti-vacuous floor on BOTH sides.
#
# Without this, a broken awk yields two empty sets, they compare equal, and
# the whole file passes having asserted nothing.
# ---------------------------------------------------------------------------
inst_n=$(printf '%s\n' "$installer_units" | grep -c . || true)
upg_n=$(printf '%s\n' "$upgrade_units" | grep -c . || true)

if [[ "$inst_n" -ge "$FLOOR" ]]; then
    pass "S1a: installer enable-set extracted ($inst_n units, floor $FLOOR)"
else
    fail "S1a: installer enable-set has $inst_n units, below the floor of $FLOOR — extraction is broken, or _systemd_enable_units changed shape"
fi

if [[ "$upg_n" -ge "$FLOOR" ]]; then
    pass "S1b: upgrade enable-set extracted ($upg_n units, floor $FLOOR)"
else
    fail "S1b: _HOST_SCRIPT_ENABLE_UNITS has $upg_n units, below the floor of $FLOOR"
fi

# ---------------------------------------------------------------------------
# S2: set equality.
# ---------------------------------------------------------------------------
if [[ "$installer_units" == "$upgrade_units" ]]; then
    pass "S2: enable-sets are identical ($upg_n units)"
else
    fail "S2: enable-sets DIVERGED — a fresh install and an upgrade would leave a node in different states"
    echo "--- only in lib/install-systemd.sh (installed but never enabled on upgrade):"
    comm -23 <(printf '%s\n' "$installer_units") <(printf '%s\n' "$upgrade_units") | sed 's/^/    /'
    echo "--- only in upgrade.sh (enabled on upgrade but not by a fresh install):"
    comm -13 <(printf '%s\n' "$installer_units") <(printf '%s\n' "$upgrade_units") | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
# S3: extraction sanity — the bake-only oneshot must not appear.
# ---------------------------------------------------------------------------
if grep -qx 'oxpulse-partner-edge-hydrate.service' <<< "$upgrade_units"; then
    fail "S3: oxpulse-partner-edge-hydrate.service is in the enable-set — that is the BAKE_MODE=1 first-boot oneshot, wrong on a live node"
else
    pass "S3: bake-only hydrate oneshot correctly absent from the enable-set"
fi

# ---------------------------------------------------------------------------
# S4: every enabled unit has a unit file in the repo.
# ---------------------------------------------------------------------------
missing_file=""
while IFS= read -r u; do
    [[ -n "$u" ]] || continue
    [[ -f "$REPO_ROOT/systemd/$u" ]] || missing_file="$missing_file $u"
done <<< "$upgrade_units"

if [[ -z "$missing_file" ]]; then
    pass "S4: every enable-set unit has a file in systemd/"
else
    fail "S4: enable-set names units with no file in systemd/:$missing_file"
fi

# ---------------------------------------------------------------------------
# S5: every enabled unit is DELIVERED by an upgrade.
#
# The load-bearing assertion. `systemctl enable X` on a node that never
# receives X's unit file cannot succeed — it warns into a log nobody reads and
# the node stays unconverged forever. That is exactly what happened to
# oxpulse-partner-cert-watch.path: it carries {{TURNS_SUBDOMAIN}} placeholders,
# so it was excluded from the verbatim copy loop and delivered ONLY by a fresh
# install. Two nodes have gone without it since they were built.
# ---------------------------------------------------------------------------
undelivered=""
while IFS= read -r u; do
    [[ -n "$u" ]] || continue
    grep -qx -- "$u" <<< "$delivered_all" || undelivered="$undelivered $u"
done <<< "$upgrade_units"

if [[ -z "$undelivered" ]]; then
    pass "S5: every enable-set unit is delivered on the upgrade path"
else
    fail "S5: enable-set units NOT delivered by any upgrade path:$undelivered
      Add them to _HOST_SCRIPT_SYSTEMD_FILES (verbatim copy) or to
      _HOST_SCRIPT_SYSTEMD_TEMPLATED_FILES (rendered from STATE) in upgrade.sh.
      Enabling an undelivered unit is a permanent warn and an unconverged node."
fi

# ---------------------------------------------------------------------------
# S6: the SELF-HEALER's enable-set is the same set, minus its own timer.
#
# oxpulse-partner-edge-selfheal.sh re-enables any declared unit it finds
# disabled — the drift this whole file exists to prevent, but continuously
# rather than only when an upgrade happens to run. That makes its ENABLE_UNITS
# a FOURTH copy of the same list, free to drift exactly like the third one did.
# So it is asserted here rather than trusted, and the healer parses nothing at
# runtime.
#
# The one deliberate difference: the healer's OWN timer is excluded. Disabling
# that timer is how an operator stops the healer, and a healer that re-enables
# itself cannot be switched off by the person it is fighting.
# ---------------------------------------------------------------------------
SELFHEAL="$REPO_ROOT/oxpulse-partner-edge-selfheal.sh"
if [[ ! -f "$SELFHEAL" ]]; then
    fail "S6: $SELFHEAL not found — the healer's enable-set cannot be checked"
else
    healer_units=$(awk '/^ENABLE_UNITS=\(/{f=1;next} f&&/^\)/{exit} f' "$SELFHEAL" \
                   | sed 's/#.*//' | tr -d '\t ' | grep . | sort)
    expected=$(printf '%s\n' "$upgrade_units" \
               | grep -vx 'oxpulse-partner-edge-selfheal.timer' | sort)
    if [[ "$healer_units" == "$expected" ]]; then
        pass "S6: the self-healer's enable-set matches (minus its own timer)"
    else
        fail "S6: the self-healer's ENABLE_UNITS DIVERGED from the enable-set"
        echo "--- in the declared set but the healer would never repair it:"
        comm -23 <(printf '%s\n' "$expected") <(printf '%s\n' "$healer_units") | sed 's/^/    /'
        echo "--- the healer would enable, but nothing declares it (a unit switched on by nobody's decision):"
        comm -13 <(printf '%s\n' "$expected") <(printf '%s\n' "$healer_units") | sed 's/^/    /'
    fi
    if grep -qx 'oxpulse-partner-edge-selfheal.timer' <<< "$healer_units"; then
        fail "S6b: the healer's own timer is in its enable-set — switching the healer off would not stick"
    else
        pass "S6b: the healer never re-enables its own timer"
    fi
fi

echo ""
if [[ "$FAIL" -eq 0 ]]; then
    echo "PASS: all $PASS enable-set parity checks passed"
    exit 0
else
    echo "FAIL: $FAIL of $((PASS+FAIL)) enable-set parity checks failed"
    exit 1
fi
