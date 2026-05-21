#!/usr/bin/env bats
# tests/test_install_systemd_same_file_guard.sh — Bug 8/10: install -m fails
# with "source and dest are the same file" when PREFIX_LIBDIR is pre-staged
# (operator workaround for Bug R: copies render-channel-lib.sh to
# /usr/local/lib/partner-edge/ before running install.sh). In that case
# _rcl_src resolves to PREFIX_LIBDIR/render-channel-lib.sh which equals
# the destination, and `install -m 0644 "$_rcl_src" "$PREFIX_LIBDIR/..."` errors.
#
# Fix: add a -ef guard in _systemd_install_lib_scripts before the
# `install -m 0644 "$_rcl_src" "$PREFIX_LIBDIR/render-channel-lib.sh"` call.

setup() {
	REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	TMP="$(mktemp -d)"
	FAKE_LIBDIR="$TMP/lib/partner-edge"
	FAKE_SBIN="$TMP/sbin"
	mkdir -p "$FAKE_LIBDIR" "$FAKE_SBIN"
	# Pre-stage the file — operator-staged workaround (case3 source == dest)
	echo "# render-channel-lib stub" > "$FAKE_LIBDIR/render-channel-lib.sh"
}

teardown() {
	rm -rf "$TMP"
}

# ---------------------------------------------------------------------------
# Bug 8/10 structural: -ef guard present near PREFIX_LIBDIR install in install-systemd.sh
# ---------------------------------------------------------------------------
@test "Bug 8/10: install-systemd.sh has -ef same-file guard before install -m into PREFIX_LIBDIR" {
	# _systemd_install_lib_scripts must contain a -ef guard specifically
	# guarding the install -m ... "$PREFIX_LIBDIR/render-channel-lib.sh" line
	grep -q -- '-ef.*PREFIX_LIBDIR\|PREFIX_LIBDIR.*-ef' "$REPO_ROOT/lib/install-systemd.sh"
}

# ---------------------------------------------------------------------------
# Bug 8/10 structural: guard pattern (the fix) works correctly in isolation
# ---------------------------------------------------------------------------
@test "Bug 8/10: -ef guard: same-file source==dest is silent no-op" {
	local src dst
	src="$FAKE_LIBDIR/render-channel-lib.sh"
	dst="$FAKE_LIBDIR/render-channel-lib.sh"
	[ "$src" -ef "$dst" ]  # confirm same inode — precondition

	run bash -c "
		set -euo pipefail
		src='$src'
		dst='$dst'
		if [[ \"\$src\" -ef \"\$dst\" ]]; then
			echo 'same-file: skipped'
		else
			install -m 0644 \"\$src\" \"\$dst\"
		fi
		echo 'ok'
	"
	[ "$status" -eq 0 ]
	[[ "$output" == *"same-file: skipped"* ]]
}

@test "Bug 8/10: operator-staged case3: install _rcl_src to PREFIX_LIBDIR succeeds when src==dst" {
	# Write the rcl block from install-systemd.sh to a temp script file, substitute
	# test paths, then run it. Avoids heredoc quoting issues with ${...} in block.
	local fake_libdir fake_sbin repo_root block_start third_fi_line
	fake_libdir="$FAKE_LIBDIR"
	fake_sbin="$FAKE_SBIN"
	repo_root="$REPO_ROOT"

	# Find lines 88..110 (install -d $PREFIX_LIBDIR through the outer closing fi)
	block_start=$(grep -n 'install -d -m 0755 "\$PREFIX_LIBDIR"' "$repo_root/lib/install-systemd.sh" | head -1 | cut -d: -f1)
	# Need the 3rd fi after block_start (inner: _rcl_src assignment, inner: -ef guard, outer: -n _rcl_src)
	third_fi_line=$(awk "NR>$block_start && /^[[:space:]]*fi$/ { count++; if (count==3) { print NR; exit } }" \
		"$repo_root/lib/install-systemd.sh")

	# Write to a temp script so we avoid heredoc shell expansion issues
	local script_file="$TMP/test_rcl_block.sh"
	{
		echo "set -euo pipefail"
		echo "PREFIX_LIBDIR='$fake_libdir'"
		echo "PREFIX_SBIN='$fake_sbin'"
		echo "INSTALL_LIB_DIR='$fake_libdir'"
		echo "src_dir=''"
		echo "log()  { :; }"
		echo "warn() { :; }"
		echo "die()  { echo \"die: \$*\" >&2; exit 1; }"
		sed -n "${block_start},${third_fi_line}p" "$repo_root/lib/install-systemd.sh"
		echo "echo 'rcl-install-ok'"
	} > "$script_file"

	run bash "$script_file"
	echo "status=$status output=$output"
	[ "$status" -eq 0 ]
	[[ "$output" == *"rcl-install-ok"* ]]
}
