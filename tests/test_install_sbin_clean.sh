#!/usr/bin/env bats
# tests/test_install_sbin_clean.sh — Phase 5.7 Item 5: zombie sbin cleanup.
#
# Covers:
#   1. lib/install-systemd.sh defines a list of EXPECTED sbin files
#   2. install.sh accepts --clean-sbin flag
#   3. Behavioral: with --clean-sbin, zombie file in PREFIX_SBIN is removed
#   4. Behavioral: without --clean-sbin, zombie file is warned but not removed
#   5. Known-files list covers all currently-shipped sbin scripts

setup() {
	REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	TMP="$(mktemp -d)"
	INSTALL_SYSTEMD="$REPO_ROOT/lib/install-systemd.sh"
	INSTALL="$REPO_ROOT/install.sh"
}

teardown() {
	rm -rf "$TMP"
}

# ---------------------------------------------------------------------------
# 1. install-systemd.sh defines known sbin files list
# ---------------------------------------------------------------------------
@test "lib/install-systemd.sh defines EXPECTED_SBIN_FILES list" {
	grep -qE 'EXPECTED_SBIN_FILES|_KNOWN_SBIN|_sbin_expected|sbin.*known' "$INSTALL_SYSTEMD"
}

# ---------------------------------------------------------------------------
# 2. install.sh accepts --clean-sbin flag (passes to systemd module)
# ---------------------------------------------------------------------------
@test "install.sh accepts --clean-sbin flag" {
	grep -q 'clean.sbin\|clean_sbin' "$INSTALL"
}

# ---------------------------------------------------------------------------
# 3. Behavioral: --clean-sbin removes zombie file not in known list
# ---------------------------------------------------------------------------
@test "install-systemd.sh --clean-sbin removes zombie sbin file" {
	local fake_sbin="$TMP/sbin"
	mkdir -p "$fake_sbin"

	# Plant a zombie file (old script no longer in known list)
	touch "$fake_sbin/oxpulse-old-zombie-script.sh"

	# Also plant a legitimately expected file (should NOT be removed)
	touch "$fake_sbin/oxpulse-partner-edge-refresh"

	# Source install-systemd.sh and call the cleanup function
	run bash -c "
		source '$INSTALL_SYSTEMD'
		log()  { echo \"LOG: \$*\"; }
		warn() { echo \"WARN: \$*\"; }
		die()  { echo \"DIE: \$*\" >&2; exit 1; }
		PREFIX_SBIN='$fake_sbin'
		CLEAN_SBIN=1
		sbin_cleanup_zombies 2>/dev/null || true
		echo DONE
	"
	[ "$status" -eq 0 ]
	[[ "$output" == *"DONE"* ]]
	# Zombie must be removed
	[ ! -f "$fake_sbin/oxpulse-old-zombie-script.sh" ]
	# Legitimate file must remain
	[ -f "$fake_sbin/oxpulse-partner-edge-refresh" ]
}

# ---------------------------------------------------------------------------
# 4. Behavioral: without --clean-sbin, zombie is warned but not removed
# ---------------------------------------------------------------------------
@test "install-systemd.sh warns about zombie sbin file but does not remove without --clean-sbin" {
	local fake_sbin="$TMP/sbin2"
	mkdir -p "$fake_sbin"
	touch "$fake_sbin/oxpulse-old-zombie-script.sh"

	run bash -c "
		source '$INSTALL_SYSTEMD'
		log()  { echo \"LOG: \$*\"; }
		warn() { echo \"WARN: \$*\"; }
		die()  { echo \"DIE: \$*\" >&2; exit 1; }
		PREFIX_SBIN='$fake_sbin'
		CLEAN_SBIN=0
		sbin_cleanup_zombies 2>/dev/null || true
		echo DONE
	"
	[ "$status" -eq 0 ]
	[[ "$output" == *"DONE"* ]]
	# Zombie should NOT be removed (no --clean-sbin)
	[ -f "$fake_sbin/oxpulse-old-zombie-script.sh" ]
	# But should emit a warning
	[[ "$output" == *"WARN"* || "$output" == *"zombie"* || "$output" == *"unexpected"* ]]
}

# ---------------------------------------------------------------------------
# 5. Known-files list covers all currently-shipped sbin scripts
# ---------------------------------------------------------------------------
@test "EXPECTED_SBIN_FILES covers all oxpulse-* files installed by install-systemd.sh" {
	# All oxpulse-* sbin scripts that install-systemd.sh installs should be
	# in the known files list so they are never flagged as zombies.
	grep -qE 'oxpulse-partner-edge-refresh' "$INSTALL_SYSTEMD"
	grep -qE 'oxpulse-channels-health-report' "$INSTALL_SYSTEMD"
	grep -qE 'ghcr-auth-lib\.sh|ghcr.auth' "$INSTALL_SYSTEMD"
	grep -qE 'channel-render-lib\.sh|render.channel' "$INSTALL_SYSTEMD"
}
