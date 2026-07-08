#!/usr/bin/env bats
# tests/test_lib_checksums_committed.sh — CI guard: lib/lib-checksums.txt stays in sync.
#
# The release pipeline (release.yml) regenerates lib/lib-checksums.txt at release
# time from a fixed ordered list of lib/*.sh files. If a developer modifies any
# of those files without regenerating, tier-4 curl-pipe installs fail with:
#   "tier-4 fetch checksum mismatch for <name> — refusing to source untrusted code"
#
# This test fails the PR before that can happen.
#
# Covers:
#   1. lib/lib-checksums.txt committed and readable
#   2. Exact file set matches release pipeline (no missing, no extra)
#   3. File ordering matches release pipeline (stable for tooling)
#   4. Every hash in committed file matches current lib/*.sh on disk
#   5. No entry in committed file references a non-existent lib/*.sh
#   6. Makefile target 'lib-checksums' exists (operator regen UX)
#
# bats <1.5 compat: no bats_require_minimum_version, no 'run !'

setup() {
	REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	CHECKSUMS="$REPO_ROOT/lib/lib-checksums.txt"
	# Release pipeline order (must match release.yml sha256sum block exactly)
	RELEASE_FILES=(
		install-args.sh
		install-awg.sh
		install-awg-params-agent.sh
		install-deps.sh
		install-firewall.sh
		install-healthcheck.sh
		install-network.sh
		install-preflight.sh
		install-split-routing.sh
		install-systemd.sh
		render-channel-lib.sh
		reconcile.sh
		telegram-alert-lib.sh
		compose-lib.sh
		healthcheck-lib.sh
		host-scripts-lib.sh
		peer-ip-guard-lib.sh
		channel-health-lib.sh
	)
}

# ---------------------------------------------------------------------------
# 1. Committed file exists
# ---------------------------------------------------------------------------
@test "lib/lib-checksums.txt is committed to the repo" {
	[ -f "$CHECKSUMS" ]
}

# ---------------------------------------------------------------------------
# 2. Exact file set matches release pipeline
# ---------------------------------------------------------------------------
@test "lib/lib-checksums.txt covers exactly the release-pipeline file set" {
	[ -f "$CHECKSUMS" ] || skip "lib-checksums.txt missing"

	# Build set from committed file
	local committed_files
	committed_files=$(awk '{print $2}' "$CHECKSUMS" | sort)

	# Build expected set from RELEASE_FILES
	local expected_files
	expected_files=$(printf '%s\n' "${RELEASE_FILES[@]}" | sort)

	if [ "$committed_files" != "$expected_files" ]; then
		echo "Mismatch between committed entries and release pipeline file set"
		echo "Committed: $committed_files"
		echo "Expected:  $expected_files"
		false
	fi
}

# ---------------------------------------------------------------------------
# 3. File ordering matches release pipeline
# ---------------------------------------------------------------------------
@test "lib/lib-checksums.txt entries are in release-pipeline order" {
	[ -f "$CHECKSUMS" ] || skip "lib-checksums.txt missing"

	local i=0
	while IFS= read -r line; do
		# Skip blank lines and comments
		[[ "$line" =~ ^[[:space:]]*$ ]] && continue
		[[ "$line" =~ ^# ]] && continue

		local fname
		fname=$(echo "$line" | awk '{print $2}')
		local expected="${RELEASE_FILES[$i]}"

		if [ "$fname" != "$expected" ]; then
			echo "Line $((i+1)): expected '$expected', got '$fname'"
			echo "lib/lib-checksums.txt must follow release pipeline order exactly."
			echo "Run: make lib-checksums"
			false
			return
		fi
		i=$((i+1))
	done < "$CHECKSUMS"

	# Verify we consumed exactly the expected number of entries
	if [ "$i" -ne "${#RELEASE_FILES[@]}" ]; then
		echo "Expected ${#RELEASE_FILES[@]} entries, found $i"
		false
	fi
}

# ---------------------------------------------------------------------------
# 4. Every hash matches current disk content
# ---------------------------------------------------------------------------
@test "lib/lib-checksums.txt hashes match current lib/*.sh on disk" {
	[ -f "$CHECKSUMS" ] || skip "lib-checksums.txt missing"
	(cd "$REPO_ROOT/lib" && sha256sum --check "$CHECKSUMS")
}

# ---------------------------------------------------------------------------
# 5. No entry references a non-existent file
# ---------------------------------------------------------------------------
@test "lib/lib-checksums.txt has no entries for missing lib/*.sh files" {
	[ -f "$CHECKSUMS" ] || skip "lib-checksums.txt missing"
	local failed=0
	while IFS= read -r line; do
		[[ "$line" =~ ^[[:space:]]*$ ]] && continue
		[[ "$line" =~ ^# ]] && continue
		local fname
		fname=$(echo "$line" | awk '{print $2}')
		if [ ! -f "$REPO_ROOT/lib/$fname" ]; then
			echo "Entry '$fname' in lib-checksums.txt but file does not exist in lib/"
			failed=1
		fi
	done < "$CHECKSUMS"
	[ "$failed" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 6. Makefile has 'lib-checksums' target for operator regen UX
# ---------------------------------------------------------------------------
@test "Makefile has lib-checksums target" {
	grep -q '^lib-checksums' "$REPO_ROOT/Makefile"
}
