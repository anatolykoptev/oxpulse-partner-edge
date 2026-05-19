#!/usr/bin/env bats
# tests/test_install_systemd_render_channel_lib.sh
#
# Bug 19 regression: lib/install-systemd.sh only checked $src_dir/lib/render-channel-lib.sh
# (git-clone subdir layout).  Release tarballs land flat — operator runs install.sh at
# /root/install.sh with assets next to it at /root/render-channel-lib.sh.  The lib/
# subdir does not exist so code fell through to the else branch (curl), which fails
# with -fsSL on a fresh machine that has no reachable REPO_RAW.
#
# Fix: triple-fallback priority:
#   1. $src_dir/lib/render-channel-lib.sh   (git-clone layout)
#   2. $src_dir/render-channel-lib.sh       (release-asset flat layout)
#   3. ${INSTALL_LIB_DIR}/render-channel-lib.sh (operator-staged)
#   else: curl fallback
#
# Tests verify that each local source path is *used* (content is preserved)
# rather than falling through to curl.  The poison-curl shim fails fast so
# a curl invocation = test failure.

setup() {
	REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	TMP="$(mktemp -d)"

	FAKE_SBIN="$TMP/sbin"
	FAKE_LIBDIR="$TMP/lib/partner-edge"
	FAKE_INSTALL_LIB_DIR="$TMP/operator-staged"
	mkdir -p "$FAKE_SBIN" "$FAKE_LIBDIR" "$FAKE_INSTALL_LIB_DIR"

	# `install` shim: copies src→dest
	mkdir -p "$TMP/shims"
	cat > "$TMP/shims/install" <<'STUB'
#!/usr/bin/env bash
mode=""
is_dir=0
args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -m) mode="$2"; shift 2 ;;
        -d) is_dir=1; shift ;;
        *)  args+=("$1"); shift ;;
    esac
done
if [[ $is_dir -eq 1 ]]; then
    mkdir -p "${args[@]}"
    exit 0
fi
n=${#args[@]}
src="${args[$((n-2))]}"
dst="${args[$((n-1))]}"
mkdir -p "$(dirname "$dst")"
cp "$src" "$dst" 2>/dev/null || touch "$dst"
[[ -n "$mode" ]] && chmod "$mode" "$dst"
exit 0
STUB
	chmod +x "$TMP/shims/install"

	# Poison curl: if render-channel-lib is fetched via curl it means local
	# fallback was missed — fail the test with a distinct exit code.
	cat > "$TMP/shims/curl" <<'STUB'
#!/usr/bin/env bash
# Check if this is a render-channel-lib.sh fetch — that should never happen
# when a local file is available.
for arg in "$@"; do
    if [[ "$arg" == *"render-channel-lib.sh" ]]; then
        echo "POISON: curl called for render-channel-lib.sh — local fallback not used" >&2
        exit 77
    fi
done
# All other curl calls (other assets): touch dest and succeed
dst=""
while [[ $# -gt 0 ]]; do
    [[ "$1" == "-o" ]] && { dst="$2"; shift 2; } || shift
done
[[ -n "$dst" ]] && touch "$dst" || true
exit 0
STUB
	chmod +x "$TMP/shims/curl"

	cat > "$TMP/shims/chmod" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
	chmod +x "$TMP/shims/chmod"
}

teardown() {
	rm -rf "$TMP"
}

# Helper: plant the sibling lib files (not render-channel-lib.sh) that
# _systemd_install_lib_scripts also handles, so curl isn't needed for them.
_make_common_src_files() {
	local src_dir="$1"
	touch "$src_dir/channel-render-lib.sh"
	touch "$src_dir/ghcr-auth-lib.sh"
	touch "$src_dir/oxpulse-token-lib.sh"
	mkdir -p "$src_dir/config"
	touch "$src_dir/config/defaults.conf"
}

# Helper: run _systemd_install_lib_scripts with given src_dir + optional INSTALL_LIB_DIR
_run_install_lib_scripts() {
	local src_dir="$1"
	local install_lib_dir="${2:-}"
	run env PATH="${TMP}/shims:/usr/bin:/bin" bash -c "
		set -u
		DRY_RUN=0
		src_dir='${src_dir}'
		REPO_RAW='http://127.0.0.1:1/does-not-exist'
		PREFIX_SBIN='${FAKE_SBIN}'
		PREFIX_LIBDIR='${FAKE_LIBDIR}'
		SYSTEMD_DIR='${TMP}/systemd'
		BAKE_MODE=0
		TURNS_SUBDOMAIN=api-test01
		DOMAIN=example.net
		_chan_lib_tmp=''
		INSTALL_LIB_DIR='${install_lib_dir}'
		log()  { echo \"log: \$*\"; }
		warn() { echo \"warn: \$*\"; }
		die()  { echo \"die: \$*\" >&2; exit 1; }
		source '${REPO_ROOT}/lib/install-systemd.sh'
		_systemd_install_lib_scripts
	"
}

# ---------------------------------------------------------------------------
# Case 1: git-clone layout — $src_dir/lib/render-channel-lib.sh
# ---------------------------------------------------------------------------
@test "Bug19: Case1 git-clone layout installs render-channel-lib.sh to PREFIX_SBIN without curl" {
	local src_dir="$TMP/src_git"
	mkdir -p "$src_dir/lib"
	echo "# MARKER_GIT_CLONE" > "$src_dir/lib/render-channel-lib.sh"
	_make_common_src_files "$src_dir"

	_run_install_lib_scripts "$src_dir" ""
	[ "$status" -eq 0 ]
	[ -f "${FAKE_SBIN}/render-channel-lib.sh" ]
	grep -q "MARKER_GIT_CLONE" "${FAKE_SBIN}/render-channel-lib.sh"
}

@test "Bug19: Case1 git-clone layout installs render-channel-lib.sh to PREFIX_LIBDIR without curl" {
	local src_dir="$TMP/src_git2"
	mkdir -p "$src_dir/lib"
	echo "# MARKER_GIT_CLONE" > "$src_dir/lib/render-channel-lib.sh"
	_make_common_src_files "$src_dir"
	# Reset dirs
	rm -rf "$FAKE_SBIN" "$FAKE_LIBDIR" && mkdir -p "$FAKE_SBIN" "$FAKE_LIBDIR"

	_run_install_lib_scripts "$src_dir" ""
	[ "$status" -eq 0 ]
	[ -f "${FAKE_LIBDIR}/render-channel-lib.sh" ]
	grep -q "MARKER_GIT_CLONE" "${FAKE_LIBDIR}/render-channel-lib.sh"
}

# ---------------------------------------------------------------------------
# Case 2: release-asset flat layout — $src_dir/render-channel-lib.sh (no lib/)
# The poison-curl shim exits 77 if curl is used for render-channel-lib.sh,
# so any fallback to curl here = status 77 = test fail.
# ---------------------------------------------------------------------------
@test "Bug19: Case2 flat-layout installs render-channel-lib.sh to PREFIX_SBIN without curl" {
	local src_dir="$TMP/src_flat"
	mkdir -p "$src_dir"
	# NOTE: NO lib/ subdir — flat release-asset layout
	echo "# MARKER_FLAT_LAYOUT" > "$src_dir/render-channel-lib.sh"
	_make_common_src_files "$src_dir"
	rm -rf "$FAKE_SBIN" "$FAKE_LIBDIR" && mkdir -p "$FAKE_SBIN" "$FAKE_LIBDIR"

	_run_install_lib_scripts "$src_dir" ""
	[ "$status" -eq 0 ]
	[ -f "${FAKE_SBIN}/render-channel-lib.sh" ]
	grep -q "MARKER_FLAT_LAYOUT" "${FAKE_SBIN}/render-channel-lib.sh"
}

@test "Bug19: Case2 flat-layout installs render-channel-lib.sh to PREFIX_LIBDIR without curl" {
	local src_dir="$TMP/src_flat2"
	mkdir -p "$src_dir"
	echo "# MARKER_FLAT_LAYOUT" > "$src_dir/render-channel-lib.sh"
	_make_common_src_files "$src_dir"
	rm -rf "$FAKE_SBIN" "$FAKE_LIBDIR" && mkdir -p "$FAKE_SBIN" "$FAKE_LIBDIR"

	_run_install_lib_scripts "$src_dir" ""
	[ "$status" -eq 0 ]
	[ -f "${FAKE_LIBDIR}/render-channel-lib.sh" ]
	grep -q "MARKER_FLAT_LAYOUT" "${FAKE_LIBDIR}/render-channel-lib.sh"
}

# ---------------------------------------------------------------------------
# Case 3: operator-staged — INSTALL_LIB_DIR has render-channel-lib.sh
#         src_dir has no render-channel-lib.sh (pure curl|bash scenario).
# ---------------------------------------------------------------------------
@test "Bug19: Case3 operator-staged installs render-channel-lib.sh to PREFIX_SBIN without curl" {
	local src_dir="$TMP/src_empty"
	mkdir -p "$src_dir"
	echo "# MARKER_OPERATOR_STAGED" > "$FAKE_INSTALL_LIB_DIR/render-channel-lib.sh"
	_make_common_src_files "$src_dir"
	rm -rf "$FAKE_SBIN" "$FAKE_LIBDIR" && mkdir -p "$FAKE_SBIN" "$FAKE_LIBDIR"

	_run_install_lib_scripts "$src_dir" "$FAKE_INSTALL_LIB_DIR"
	[ "$status" -eq 0 ]
	[ -f "${FAKE_SBIN}/render-channel-lib.sh" ]
	grep -q "MARKER_OPERATOR_STAGED" "${FAKE_SBIN}/render-channel-lib.sh"
}

@test "Bug19: Case3 operator-staged installs render-channel-lib.sh to PREFIX_LIBDIR without curl" {
	local src_dir="$TMP/src_empty2"
	mkdir -p "$src_dir"
	echo "# MARKER_OPERATOR_STAGED" > "$FAKE_INSTALL_LIB_DIR/render-channel-lib.sh"
	_make_common_src_files "$src_dir"
	rm -rf "$FAKE_SBIN" "$FAKE_LIBDIR" && mkdir -p "$FAKE_SBIN" "$FAKE_LIBDIR"

	_run_install_lib_scripts "$src_dir" "$FAKE_INSTALL_LIB_DIR"
	[ "$status" -eq 0 ]
	[ -f "${FAKE_LIBDIR}/render-channel-lib.sh" ]
	grep -q "MARKER_OPERATOR_STAGED" "${FAKE_LIBDIR}/render-channel-lib.sh"
}

# ---------------------------------------------------------------------------
# Case 4: no local source — falls through to curl (non-poison path)
#         asserts install doesn't crash even when curl touches an empty file
# ---------------------------------------------------------------------------
@test "Bug19: Case4 no local source falls through to curl without crash" {
	local src_dir="$TMP/src_none"
	mkdir -p "$src_dir"
	# No render-channel-lib.sh anywhere; INSTALL_LIB_DIR empty
	_make_common_src_files "$src_dir"
	rm -rf "$FAKE_SBIN" "$FAKE_LIBDIR" && mkdir -p "$FAKE_SBIN" "$FAKE_LIBDIR"

	# Use a non-poison curl that just touches for this case
	cat > "$TMP/shims/curl" <<'STUB2'
#!/usr/bin/env bash
dst=""
while [[ $# -gt 0 ]]; do
    [[ "$1" == "-o" ]] && { dst="$2"; shift 2; } || shift
done
[[ -n "$dst" ]] && touch "$dst" || true
exit 0
STUB2
	chmod +x "$TMP/shims/curl"

	_run_install_lib_scripts "$src_dir" ""
	[ "$status" -eq 0 ]
}
