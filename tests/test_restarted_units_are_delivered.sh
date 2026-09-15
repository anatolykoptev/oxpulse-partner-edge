#!/bin/bash
# tests/test_restarted_units_are_delivered.sh
#
# Every binary a shipped systemd unit executes must reach a node by a KNOWN
# mechanism, and upgrade must refresh it.
#
# The measurement this exists for, taken across all five production edges
# 2026-08-07: FOUR distinct sha256 of /usr/local/bin/oxpulse-awg-params-agent,
# while all 27 managed host SCRIPTS were byte-identical. Its unit is in
# _HOST_SCRIPT_RESTART_UNITS, so every upgrade restarts it — and nothing ever
# updated it. Each node ran the build it was provisioned with, and the four
# hashes lined up with the four provisioning dates.
#
# FIXED: sync_host_scripts' asset step (Step 5d in lib/host-scripts-lib.sh)
# now delivers release-asset binaries — arch-mapped, tag-pinned, verified
# against the tag's SHA256SUMS, atomically installed, restart fired via
# _any_changed. This test's job is to keep that wiring honest: the declared
# asset set (_HOST_SCRIPT_ASSET_FILES) must equal the set of unit-executed
# asset-class binaries, each declared asset's install dir must match its
# unit's ExecStart, and its unit must be in _HOST_SCRIPT_RESTART_UNITS —
# otherwise bytes would land without ever taking effect.
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
#   D5  add a new asset-class binary without wiring it into
#       _HOST_SCRIPT_ASSET_FILES                                 → RED
set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
UPGRADE="$REPO_ROOT/upgrade.sh"
INSTALL_SYSTEMD="$REPO_ROOT/lib/install-systemd.sh"
HOST_SCRIPTS_LIB="$REPO_ROOT/lib/host-scripts-lib.sh"
UNIT_DIR="$REPO_ROOT/systemd"

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

for f in "$UPGRADE" "$INSTALL_SYSTEMD" "$HOST_SCRIPTS_LIB"; do
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
ASSET_DELIVERED=$(arr "$HOST_SCRIPTS_LIB" _HOST_SCRIPT_ASSET_FILES)
RESTART_UNITS=$(arr "$UPGRADE" _HOST_SCRIPT_RESTART_UNITS)

# The real routing functions, not reimplementations of them.
# Consumed by the eval'd functions, which shellcheck cannot see
# into — hence the disables rather than a rewrite.
# shellcheck disable=SC2034
PREFIX_BIN=/usr/local/bin
# shellcheck disable=SC2034
PREFIX_SBIN=/usr/local/sbin
eval "$(awk '/^_host_script_install_dir\(\)/{f=1} f{print} f&&/^}/{exit}' "$UPGRADE")"
eval "$(awk '/^_host_script_asset_install_dir\(\)/{f=1} f{print} f&&/^}/{exit}' "$HOST_SCRIPTS_LIB")"

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
		# lib naming it plus a slot in the asset delivery array is the declared
		# mechanism; anything else has no delivery path at all and is a unit
		# pointing at nothing.
		if grep -rqlF "$base" "$REPO_ROOT"/lib/install-*.sh 2>/dev/null; then
			seen_assets="$seen_assets $base"
			# Asset-class binaries get their own routing fn (their home is
			# PREFIX_BIN, not the script class's sbin default); it must agree
			# with the unit's ExecStart or the refresh lands where nothing
			# executes it.
			got=$(_host_script_asset_install_dir "$base")
			[[ "$got" == "$want" ]] || wrongdir="$wrongdir ${base}(unit:${want} asset-install:${got})"
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

# --- D5: asset-class binaries are all delivered by the asset step ----------
# Both directions. A new asset-class binary must not appear silently, and a
# _HOST_SCRIPT_ASSET_FILES entry that no unit executes must not linger as a
# stale declaration (the old KNOWN_UNREFRESHED_ASSETS registry was deleted
# when delivery landed — it would now be a stale lie this test cannot see).
for a in $seen_assets; do
	grep -qw "$a" <<<"$ASSET_DELIVERED" || undeclared_asset="$undeclared_asset $a"
done
stale=""
for k in $ASSET_DELIVERED; do
	grep -qw "$k" <<<"$seen_assets" || stale="$stale $k"
done

if [[ -z "${undeclared_asset// /}" && -z "${stale// /}" ]]; then
	pass "D5: asset-class unit binaries match the delivered set ($ASSET_DELIVERED)"
else
	[[ -n "${undeclared_asset// /}" ]] &&
		fail "D5: unit binaries not wired into _HOST_SCRIPT_ASSET_FILES:$undeclared_asset"
	[[ -n "${stale// /}" ]] &&
		fail "D5: declared asset no longer executed by any unit (stale entry):$stale"
fi

# --- D5b: delivery is only real if the bytes take effect --------------------
# The asset step flips _any_changed, which drives Step 7's restart loop over
# _HOST_SCRIPT_RESTART_UNITS. A delivered asset whose unit is NOT in that list
# would land new bytes that never run — the binary equivalent of "delivered to
# the wrong directory".
unrestarted=""
for a in $seen_assets; do
	grep -qw "${a}.service" <<<"$RESTART_UNITS" || unrestarted="$unrestarted $a"
done
if [[ -z "${unrestarted// /}" ]]; then
	pass "D5b: every delivered asset's unit is in _HOST_SCRIPT_RESTART_UNITS"
else
	fail "D5b: assets delivered but never restarted:$unrestarted"
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
