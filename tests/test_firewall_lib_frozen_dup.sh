#!/usr/bin/env bats
# tests/test_firewall_lib_frozen_dup.sh — CI guard: lib/install-firewall.sh (the
# frozen Phase-6 back-compat duplicate) stays byte-identical to lib/firewall-lib.sh
# past each file's own header.
#
# lib/install-firewall.sh is kept as a byte-for-byte duplicate of lib/firewall-lib.sh
# for one release cycle so curl|bash / tier-3-4 fetch paths still wired to the OLD
# literal filename keep working (see lib/install-firewall.sh's own header). Nothing
# else enforces the two stay in sync: shellcheck passes both independently, the
# release.yml Phase-6 grep-guard only checks *sourcing refs* in OTHER lib/*.sh files
# (it explicitly skips lib/install-firewall.sh itself), and lib/lib-checksums.txt
# hashes install-firewall.sh against its own prior committed hash — no cross-file
# equality. A commit that edits firewall_apply()/_firewall_apply_ufw in only ONE file
# would pass CI clean while curl|bash installs (still pinned to the old name) apply
# STALE firewall rules relative to reconcile-hosts sourcing the new name.
#
# This test fails the PR the moment the two clones diverge past their headers.
#
# Bats <1.5 compat: no bats_require_minimum_version, no 'run !'

setup() {
	REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	NEW="$REPO_ROOT/lib/firewall-lib.sh"
	OLD="$REPO_ROOT/lib/install-firewall.sh"
	# Shared anchor line: the first line of the ORIGINAL (pre-rename) header comment
	# that both files still carry verbatim. Anchoring on content (not a hardcoded line
	# number) survives either file's own rename-notice header growing/shrinking.
	ANCHOR='^# Closes the 2026-05-21 audit finding'
}

# ---------------------------------------------------------------------------
# Both files present
# ---------------------------------------------------------------------------
@test "lib/firewall-lib.sh and lib/install-firewall.sh both exist" {
	[ -f "$NEW" ]
	[ -f "$OLD" ]
}

# ---------------------------------------------------------------------------
# Body parity: content from the shared anchor line onward must be byte-identical.
# The anchor line itself must resolve in both files, else the header was rewritten
# and this test needs an update, not a silent skip.
# ---------------------------------------------------------------------------
@test "firewall-lib.sh and install-firewall.sh bodies are byte-identical past their headers" {
	[ -f "$NEW" ] && [ -f "$OLD" ] || skip "one or both files missing"

	local new_start old_start
	new_start=$(grep -n "$ANCHOR" "$NEW" | head -1 | cut -d: -f1)
	old_start=$(grep -n "$ANCHOR" "$OLD" | head -1 | cut -d: -f1)
	if [ -z "$new_start" ] || [ -z "$old_start" ]; then
		echo "shared anchor line missing in one or both files — header rewritten? update ANCHOR in this test"
		false
		return
	fi

	run diff <(tail -n +"$new_start" "$NEW") <(tail -n +"$old_start" "$OLD")
	[ "$status" -eq 0 ] || {
		echo "lib/firewall-lib.sh and lib/install-firewall.sh have DIVERGED past their headers."
		echo "install-firewall.sh is a FROZEN back-compat duplicate — it must be kept"
		echo "byte-for-byte in sync with firewall-lib.sh (see its own header)."
		echo "$output"
		false
	}
}
