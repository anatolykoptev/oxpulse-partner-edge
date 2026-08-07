#!/bin/bash
# tests/test_restarted_units_are_delivered.sh
#
# Every binary a shipped systemd unit executes must reach a node by a KNOWN
# mechanism, and upgrade must refresh it — or the gap must be declared here.
#
# The measurement this exists for, taken across all five production edges
# 2026-08-07: FOUR distinct sha256 of /usr/local/bin/oxpulse-awg-params-agent,
# while all 27 managed host SCRIPTS were byte-identical. Its unit is in
# _HOST_SCRIPT_RESTART_UNITS, so every upgrade restarts it — and nothing ever
# updates it. Each node still runs the build it was provisioned with, and the
# four hashes line up with the four provisioning dates.
#
# The first version of this test asserted that every unit-executed binary must
# be in _HOST_SCRIPT_SBIN_FILES. That was WRONG and the repo's own
# test_sourced_sibling_delivery caught it: that array delivers shell scripts
# fetched from the repo and verified against SHA256SUMS, while
# oxpulse-awg-params-agent is a compiled Rust binary (crates/awg-params-agent)
# shipped as a per-arch release asset. Adding it to the script array would have
# made upgrade look for a file that does not exist. The classification below is
# the corrected shape: WHICH mechanism a binary belongs to is derivable, and the
# right assertion is that each one has a mechanism at all.
#
# Derived, not listed: upgrade.sh:1009 says the delivery array "mirrors
# EXPECTED_SBIN_FILES in install-systemd.sh and must be kept in sync when scripts
# are added/removed". A ground truth that is a hand-written list cannot detect
# what is missing from it. systemd/*.service is the honest source — the units are
# the reason these binaries have to exist at all.
#
# Falsification (anti-vacuous):
#   D1  drop a script-class binary from the delivery array      → RED
#   D2  route one to a directory its unit does not name          → RED
#   D3  make the ExecStart filter match nothing                  → RED (floor)
#   D4  drop a lib install expects but no unit executes          → RED
#   D5  add a new asset-class binary without declaring the gap   → RED
set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
UPGRADE="$REPO_ROOT/upgrade.sh"
INSTALL_SYSTEMD="$REPO_ROOT/lib/install-systemd.sh"
UNIT_DIR="$REPO_ROOT/systemd"

# Binaries that reach a node as a RELEASE ASSET rather than a repo script, and
# that upgrade does NOT currently refresh. Each entry is a live defect with a
# measurement behind it, not an exemption:
#
#   oxpulse-awg-params-agent — compiled from crates/awg-params-agent, installed
#     once by lib/install-awg-params-agent.sh from
#     releases/latest/download/oxpulse-awg-params-agent-<arch>. Note "latest",
#     not the tag being installed: even a fresh install does not record which
#     build it took. Measured 4 distinct hashes across 5 edges.
#
# Fixing this needs an arch-aware, tag-pinned asset refresh on the upgrade path
# — a different surface kind from the script sync, which is why it is declared
# here rather than bodged into the script array.
KNOWN_UNREFRESHED_ASSETS="oxpulse-awg-params-agent"

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
echo "=== every unit-executed binary has a delivery mechanism ==="

for f in "$UPGRADE" "$INSTALL_SYSTEMD"; do
	[[ -f "$f" ]] || {
		fail "D0: $f not found"
		exit 1
	}
done
[[ -d "$UNIT_DIR" ]] || {
	fail "D0: systemd/ not found"
	exit 1
}

arr() {
	awk -v n="$2" '$0 ~ "^"n"=\\(" {f=1;next} f&&/^\)/{exit} f' "$1" |
		sed 's/#.*//' | tr -d ' \t' | grep -v '^$' | sort -u
}

DELIVERED=$(arr "$UPGRADE" _HOST_SCRIPT_SBIN_FILES)
EXPECTED=$(arr "$INSTALL_SYSTEMD" EXPECTED_SBIN_FILES)

# The real routing function, not a reimplementation of it.
# Consumed by the eval'd _host_script_install_dir, which shellcheck cannot see
# into — hence the disables rather than a rewrite.
# shellcheck disable=SC2034
PREFIX_BIN=/usr/local/bin
# shellcheck disable=SC2034
PREFIX_SBIN=/usr/local/sbin
eval "$(awk '/^_host_script_install_dir\(\)/{f=1} f{print} f&&/^}/{exit}' "$UPGRADE")"

# /usr/local/** only — /usr/bin/docker is the OS's, not ours to deliver.
PAIRS=$(grep -h '^ExecStart=' "$UNIT_DIR"/*.service 2>/dev/null |
	sed 's/^ExecStart=//' | awk '{print $1}' |
	grep '^/usr/local/' | sort -u)

# --- D3: the derivation found something (anti-vacuous floor) ---------------
n_pairs=$(grep -c . <<<"$PAIRS" || true)
if [[ "$n_pairs" -ge 8 ]]; then
	pass "D3: derived $n_pairs unit-executed binaries from systemd/ (floor 8)"
else
	fail "D3: only $n_pairs binaries derived — the glob or the units moved; every assert below is vacuous"
	echo ""
	echo "Results: $PASS passed, $((FAIL + 1)) failed"
	exit 1
fi

# --- classify: a repo file makes it script-class, otherwise asset-class ---
missing="" wrongdir="" undeclared_asset="" seen_assets=""
while IFS= read -r path; do
	[[ -n "$path" ]] || continue
	base=${path##*/}
	want=${path%/*}

	# Classify by the mechanism that actually delivers it, never by guessing a
	# filename. The repo->installed name mapping is not uniform (hydrate.sh ->
	# oxpulse-partner-edge-hydrate, upgrade.sh -> oxpulse-partner-edge-upgrade,
	# while oxpulse-xray-update.sh keeps its suffix), and a filesystem heuristic
	# misclassified delivered scripts twice while this test was being written.
	# Membership of the delivery array IS the script class.
	if grep -qx "$base" <<<"$DELIVERED"; then
		got=$(_host_script_install_dir "$base")
		[[ "$got" == "$want" ]] || wrongdir="$wrongdir ${base}(unit:${want} install:${got})"
	else
		# Not in the script sync, so it must arrive some other way. An installer
		# lib naming it is the only other declared mechanism; anything else has
		# no delivery path at all and is a unit pointing at nothing.
		if grep -rqlF "$base" "$REPO_ROOT"/lib/install-*.sh 2>/dev/null; then
			seen_assets="$seen_assets $base"
		else
			missing="$missing $base"
		fi
	fi
done <<<"$PAIRS"

# --- D1 / D2: script-class binaries -----------------------------------------
if [[ -z "${missing// /}" ]]; then
	pass "D1: every unit-executed binary has a declared delivery mechanism"
else
	fail "D1: units execute binaries that NOTHING delivers:$missing"
fi

if [[ -z "$wrongdir" ]]; then
	pass "D2: _host_script_install_dir agrees with every unit's ExecStart directory"
else
	fail "D2: delivery directory disagrees with the unit:$wrongdir"
	echo "    A binary delivered to the wrong directory is worse than one not"
	echo "    delivered: the unit keeps running the stale copy and upgrade reports success."
fi

# --- D5: asset-class binaries are all accounted for ------------------------
# Both directions. A new asset-class binary must not appear silently, and a
# baseline entry that no longer exists must not linger as a stale exemption.
for a in $seen_assets; do
	grep -qw "$a" <<<"$KNOWN_UNREFRESHED_ASSETS" || undeclared_asset="$undeclared_asset $a"
done
stale=""
for k in $KNOWN_UNREFRESHED_ASSETS; do
	grep -qw "$k" <<<"$seen_assets" || stale="$stale $k"
done

if [[ -z "${undeclared_asset// /}" && -z "${stale// /}" ]]; then
	pass "D5: asset-class unit binaries match the declared set ($KNOWN_UNREFRESHED_ASSETS)"
	echo "    NOTE: those are NOT refreshed by upgrade — a live gap, declared so it"
	echo "    cannot grow silently. Closing it needs an arch-aware, tag-pinned asset"
	echo "    refresh on the upgrade path."
else
	[[ -n "${undeclared_asset// /}" ]] &&
		fail "D5: unit binaries with no declared delivery mechanism:$undeclared_asset"
	[[ -n "${stale// /}" ]] &&
		fail "D5: declared asset no longer executed by any unit (stale exemption):$stale"
fi

# --- D4: the two hand-maintained arrays cannot diverge downward -----------
undelivered=$(comm -23 <(printf '%s\n' "$EXPECTED") <(printf '%s\n' "$DELIVERED") | tr '\n' ' ')
if [[ -z "${undelivered// /}" ]]; then
	pass "D4: everything install expects is in upgrade's delivery set"
else
	fail "D4: install expects files upgrade never delivers: $undelivered"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
