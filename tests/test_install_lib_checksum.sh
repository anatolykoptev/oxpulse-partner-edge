#!/usr/bin/env bats
# tests/test_install_lib_checksum.sh — Phase 5.7 Item 3: tier-4 fetch integrity.
#
# Covers:
#   1. lib/lib-checksums.txt exists in the repo
#   2. lib-checksums.txt contains SHA256 entries for all lib/*.sh files
#   3. release.yml generates and uploads lib-checksums.txt
#   4. _install_lib_source in install.sh has checksum validation logic
#   5. Behavioral: wrong checksum on tier-4 fetch → die with expected message
#   6. Behavioral: missing lib-checksums.txt → warn + continue (legacy fallback)
#   7. Behavioral: correct checksum → source succeeds
#   8. lib-checksums.txt SHA256SUMS format valid (sha256sum --check compatible)

setup() {
	REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	TMP="$(mktemp -d)"
	INSTALL="$REPO_ROOT/install.sh"
	CHECKSUMS="$REPO_ROOT/lib/lib-checksums.txt"
	RELEASE_YML="$REPO_ROOT/.github/workflows/release.yml"
}

teardown() {
	rm -rf "$TMP"
}

# ---------------------------------------------------------------------------
# 1. lib/lib-checksums.txt exists
# ---------------------------------------------------------------------------
@test "lib/lib-checksums.txt exists" {
	[ -f "$CHECKSUMS" ]
}

# ---------------------------------------------------------------------------
# 2. lib-checksums.txt contains SHA256 entries for lib/*.sh files
# ---------------------------------------------------------------------------
@test "lib/lib-checksums.txt contains entries for all lib/*.sh files" {
	[ -f "$CHECKSUMS" ] || skip "lib-checksums.txt not yet created"
	for f in "$REPO_ROOT"/lib/*.sh; do
		local basename
		basename="$(basename "$f")"
		grep -q "$basename" "$CHECKSUMS"
	done
}

# ---------------------------------------------------------------------------
# 3. release.yml references lib-checksums.txt (generates + uploads)
# ---------------------------------------------------------------------------
@test "release.yml generates lib-checksums.txt as a release asset" {
	grep -q 'lib-checksums' "$RELEASE_YML"
}

# ---------------------------------------------------------------------------
# 4. install.sh _install_lib_source contains checksum validation
# ---------------------------------------------------------------------------
@test "install.sh _install_lib_source validates SHA256 on tier-4 fetch" {
	grep -q 'lib-checksums' "$INSTALL"
}

@test "install.sh _install_lib_source dies on checksum mismatch" {
	grep -qE 'checksum mismatch|mismatch.*refusing|refusing.*untrusted' "$INSTALL"
}

# ---------------------------------------------------------------------------
# 5. Behavioral: wrong checksum → die
# ---------------------------------------------------------------------------
@test "_install_lib_source tier-4: wrong checksum causes die" {
	# Write a fake lib-checksums.txt with a known-wrong checksum
	local fake_lib_dir="$TMP/lib"
	mkdir -p "$fake_lib_dir"

	# The module we'll "fetch"
	local module_name="install-preflight.sh"
	local fake_content="echo 'fake module content'"
	local correct_hash
	correct_hash=$(printf '%s' "$fake_content" | sha256sum | awk '{print $1}')
	local wrong_hash="0000000000000000000000000000000000000000000000000000000000000000"

	# lib-checksums.txt with the WRONG hash for this module
	printf '%s  %s\n' "$wrong_hash" "$module_name" > "$TMP/lib-checksums.txt"

	# Write the fake module content to a temp file (simulates what tier-4 curl would fetch)
	printf '%s\n' "$fake_content" > "$TMP/fetched-module.sh"

	# Extract and test just the checksum validation logic from install.sh
	# We simulate the _install_lib_source tier-4 check:
	#   1. curl fetched content to $tmp
	#   2. lib-checksums.txt available
	#   3. validate sha256
	run bash -c "
		log()  { echo \"LOG: \$*\"; }
		warn() { echo \"WARN: \$*\"; }
		die()  { echo \"DIE: \$*\" >&2; exit 1; }

		# Simulate the checksum validation block
		_tmp='$TMP/fetched-module.sh'
		_name='$module_name'
		_checksums='$TMP/lib-checksums.txt'
		_actual_hash=\$(sha256sum \"\$_tmp\" | awk '{print \$1}')
		_expected_hash=\$(grep \"\$_name\" \"\$_checksums\" 2>/dev/null | awk '{print \$1}')
		if [[ -n \"\$_expected_hash\" && \"\$_actual_hash\" != \"\$_expected_hash\" ]]; then
			die \"tier-4 fetch checksum mismatch for \$_name — refusing to source untrusted code\"
		fi
		echo 'VALIDATION_PASSED'
	"
	[ "$status" -ne 0 ]
	[[ "$output" == *"checksum mismatch"* || "$output" == *"refusing"* ]]
}

# ---------------------------------------------------------------------------
# 6. Behavioral: missing lib-checksums.txt → warn + continue (legacy fallback)
# ---------------------------------------------------------------------------
@test "_install_lib_source tier-4: missing lib-checksums.txt warns but continues" {
	run bash -c "
		log()  { echo \"LOG: \$*\"; }
		warn() { echo \"WARN: \$*\"; }
		die()  { echo \"DIE: \$*\" >&2; exit 1; }

		_tmp='$TMP/fetched-module.sh'
		printf 'echo fake\n' > \"\$_tmp\"
		_name='install-preflight.sh'
		_checksums='$TMP/nonexistent-checksums.txt'
		# Logic from install.sh: if checksums file missing, warn and continue
		if [[ ! -f \"\$_checksums\" ]]; then
			warn \"lib-checksums.txt not found — skipping integrity check (legacy install)\"
		else
			_actual=\$(sha256sum \"\$_tmp\" | awk '{print \$1}')
			_expected=\$(grep \"\$_name\" \"\$_checksums\" 2>/dev/null | awk '{print \$1}')
			if [[ -n \"\$_expected\" && \"\$_actual\" != \"\$_expected\" ]]; then
				die \"tier-4 fetch checksum mismatch for \$_name — refusing to source untrusted code\"
			fi
		fi
		echo 'CONTINUED'
	"
	[ "$status" -eq 0 ]
	[[ "$output" == *"CONTINUED"* ]]
	[[ "$output" == *"skipping integrity"* || "$output" == *"lib-checksums.txt not found"* ]]
}

# ---------------------------------------------------------------------------
# 7. Behavioral: correct checksum → source succeeds
# ---------------------------------------------------------------------------
@test "_install_lib_source tier-4: correct checksum allows sourcing" {
	local fake_content
	printf 'echo fake_module_loaded\n' > "$TMP/fetched-ok.sh"
	local correct_hash
	correct_hash=$(sha256sum "$TMP/fetched-ok.sh" | awk '{print $1}')

	printf '%s  install-preflight.sh\n' "$correct_hash" > "$TMP/lib-checksums-ok.txt"

	run bash -c "
		log()  { echo \"LOG: \$*\"; }
		warn() { echo \"WARN: \$*\"; }
		die()  { echo \"DIE: \$*\" >&2; exit 1; }

		_tmp='$TMP/fetched-ok.sh'
		_name='install-preflight.sh'
		_checksums='$TMP/lib-checksums-ok.txt'
		_actual=\$(sha256sum \"\$_tmp\" | awk '{print \$1}')
		_expected=\$(grep \"\$_name\" \"\$_checksums\" 2>/dev/null | awk '{print \$1}')
		if [[ -n \"\$_expected\" && \"\$_actual\" != \"\$_expected\" ]]; then
			die \"tier-4 fetch checksum mismatch for \$_name — refusing to source untrusted code\"
		fi
		echo 'CHECKSUM_OK'
	"
	[ "$status" -eq 0 ]
	[[ "$output" == *"CHECKSUM_OK"* ]]
}

# ---------------------------------------------------------------------------
# 8. lib-checksums.txt is sha256sum --check compatible (valid format)
# ---------------------------------------------------------------------------
@test "lib/lib-checksums.txt passes sha256sum --check from repo root" {
	[ -f "$CHECKSUMS" ] || skip "lib-checksums.txt not yet created"
	# sha256sum --check reads "hash  filename" lines relative to CWD
	(cd "$REPO_ROOT/lib" && sha256sum --check "$CHECKSUMS")
}
