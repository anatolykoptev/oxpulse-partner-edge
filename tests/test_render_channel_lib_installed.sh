#!/usr/bin/env bats
# tests/test_render_channel_lib_installed.sh — Bug 17 regression test.
#
# Bug 17: after uninstall+reinstall from tarball (no local src_dir), install.sh
# sources render-channel-lib.sh at top-of-file. It checks three paths:
#   1. $(dirname install.sh)/lib/render-channel-lib.sh    (source tree)
#   2. ${INSTALL_LIB_DIR:-/usr/local/lib/partner-edge}/render-channel-lib.sh
#   3. ${PREFIX_SBIN:-/usr/local/sbin}/render-channel-lib.sh
#
# lib/install-systemd.sh installs to $PREFIX_SBIN (tier-3) but uninstall.sh
# removes PREFIX_SBIN/render-channel-lib.sh. Fix: also install to PREFIX_LIBDIR
# (tier-2) so staged operator dirs and re-installs find it at the expected path.
#
# This test verifies _systemd_install_lib_scripts() installs render-channel-lib.sh
# to PREFIX_LIBDIR (not only PREFIX_SBIN).

setup() {
	REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	TMP="$(mktemp -d)"

	FAKE_SBIN="$TMP/sbin"
	FAKE_LIBDIR="$TMP/lib/partner-edge"
	FAKE_SRC="$TMP/src"
	mkdir -p "$FAKE_SBIN" "$FAKE_LIBDIR" "$FAKE_SRC/lib"
	mkdir -p "$TMP/shims"

	# Plant render-channel-lib.sh in a fake src_dir so curl is not needed
	echo "# render-channel-lib stub" > "$FAKE_SRC/lib/render-channel-lib.sh"
	# Plant other required lib scripts
	touch "$FAKE_SRC/channel-render-lib.sh"
	touch "$FAKE_SRC/ghcr-auth-lib.sh"
	touch "$FAKE_SRC/oxpulse-token-lib.sh"
	mkdir -p "$FAKE_SRC/config"
	touch "$FAKE_SRC/config/defaults.conf"

	# `install` shim: actually copies src→dest so [ -f dest ] assertions work.
	# Also creates parent directories as needed.
	cat > "$TMP/shims/install" <<'STUB'
#!/usr/bin/env bash
# Parse mode (-m 0644) and -d flags; then perform the actual copy or mkdir.
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
# Last arg is dest, second-to-last is src
n=${#args[@]}
src="${args[$((n-2))]}"
dst="${args[$((n-1))]}"
mkdir -p "$(dirname "$dst")"
cp "$src" "$dst"
[[ -n "$mode" ]] && chmod "$mode" "$dst"
exit 0
STUB
	chmod +x "$TMP/shims/install"
}

teardown() {
	rm -rf "$TMP"
}

# ---------------------------------------------------------------------------
# Bug 17: render-channel-lib.sh must be installed to PREFIX_LIBDIR
# ---------------------------------------------------------------------------
@test "install-systemd: _systemd_install_lib_scripts installs render-channel-lib.sh to PREFIX_LIBDIR" {
	run env PATH="${TMP}/shims:/usr/bin:/bin" bash -c "
		DRY_RUN=0
		src_dir='${FAKE_SRC}'
		REPO_RAW='http://127.0.0.1:1/does-not-exist'
		PREFIX_SBIN='${FAKE_SBIN}'
		PREFIX_LIBDIR='${FAKE_LIBDIR}'
		SYSTEMD_DIR='${TMP}/systemd'
		BAKE_MODE=0
		TURNS_SUBDOMAIN=api-test01
		DOMAIN=example.net
		_chan_lib_tmp=''
		log()  { echo \"log: \$*\"; }
		warn() { echo \"warn: \$*\"; }
		die()  { echo \"die: \$*\" >&2; exit 1; }
		source '${REPO_ROOT}/lib/install-systemd.sh'
		_systemd_install_lib_scripts
	"
	[ "$status" -eq 0 ]
	# render-channel-lib.sh must exist in PREFIX_LIBDIR (tier-2 path install.sh checks)
	[ -f "${FAKE_LIBDIR}/render-channel-lib.sh" ]
}

@test "install-systemd: render-channel-lib.sh at PREFIX_LIBDIR has mode 0644" {
	run env PATH="${TMP}/shims:/usr/bin:/bin" bash -c "
		DRY_RUN=0
		src_dir='${FAKE_SRC}'
		REPO_RAW='http://127.0.0.1:1/does-not-exist'
		PREFIX_SBIN='${FAKE_SBIN}'
		PREFIX_LIBDIR='${FAKE_LIBDIR}'
		SYSTEMD_DIR='${TMP}/systemd'
		BAKE_MODE=0
		TURNS_SUBDOMAIN=api-test01
		DOMAIN=example.net
		_chan_lib_tmp=''
		log()  { echo \"log: \$*\"; }
		warn() { echo \"warn: \$*\"; }
		die()  { echo \"die: \$*\" >&2; exit 1; }
		source '${REPO_ROOT}/lib/install-systemd.sh'
		_systemd_install_lib_scripts
	"
	[ "$status" -eq 0 ]
	perms="$(stat -c '%a' "${FAKE_LIBDIR}/render-channel-lib.sh" 2>/dev/null || echo MISSING)"
	[ "$perms" = "644" ]
}
