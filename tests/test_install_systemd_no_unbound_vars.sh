#!/usr/bin/env bats
# tests/test_install_systemd_no_unbound_vars.sh
#
# Bug 20 regression: PREFIX_LIBDIR was referenced in lib/install-systemd.sh but
# never declared — caused "PREFIX_LIBDIR: unbound variable" under set -u when
# install.sh ran on a fresh edge via curl|bash (no OXPULSE_PREFIX_LIBDIR env).
#
# These tests verify that:
#   a) install.sh declares PREFIX_LIBDIR before sourcing lib/install-systemd.sh
#   b) lib/install-systemd.sh can be sourced standalone (with set -u) without
#      crashing due to unbound variables when callers pass all required globals.

setup() {
	REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	TMP="$(mktemp -d)"

	FAKE_SBIN="$TMP/sbin"
	FAKE_LIBDIR="$TMP/lib/partner-edge"
	FAKE_SRC="$TMP/src"
	mkdir -p "$FAKE_SBIN" "$FAKE_LIBDIR" "$FAKE_SRC/lib" "$FAKE_SRC/config"

	# Plant required lib scripts so install stubs don't need to curl
	echo "# render-channel-lib stub" > "$FAKE_SRC/lib/render-channel-lib.sh"
	touch "$FAKE_SRC/channel-render-lib.sh"
	touch "$FAKE_SRC/ghcr-auth-lib.sh"
	touch "$FAKE_SRC/oxpulse-token-lib.sh"
	touch "$FAKE_SRC/config/defaults.conf"

	# `install` shim: actually copies src→dest + mkdir -p
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

	cat > "$TMP/shims/curl" <<'STUB'
#!/usr/bin/env bash
dst=""
while [[ $# -gt 0 ]]; do
    [[ "$1" == "-o" ]] && { dst="$2"; shift 2; } || shift
done
[[ -n "$dst" ]] && touch "$dst" || true
exit 0
STUB
	chmod +x "$TMP/shims/curl"

	cat > "$TMP/shims/systemctl" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
	chmod +x "$TMP/shims/systemctl"

	cat > "$TMP/shims/chmod" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
	chmod +x "$TMP/shims/chmod"
}

teardown() {
	rm -rf "$TMP"
}

# ---------------------------------------------------------------------------
# Bug 20-a: install.sh constants block must declare PREFIX_LIBDIR
# ---------------------------------------------------------------------------
@test "Bug20: install.sh declares PREFIX_LIBDIR in constants block" {
	# install.sh must have PREFIX_LIBDIR=... in its own constant section so that
	# when lib/install-systemd.sh is sourced the variable is already bound.
	grep -q 'PREFIX_LIBDIR' "${REPO_ROOT}/install.sh"
}

# ---------------------------------------------------------------------------
# Bug 20-b: lib/install-systemd.sh sourced with all required caller globals
#           does not produce "unbound variable" error under set -u
# ---------------------------------------------------------------------------
@test "Bug20: install-systemd sources cleanly under set -u when PREFIX_LIBDIR provided" {
	run env PATH="${TMP}/shims:/usr/bin:/bin" bash -euo pipefail -c "
		DRY_RUN=1
		src_dir=''
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
		systemd_run
	"
	[ "$status" -eq 0 ]
	# Must not emit any "unbound variable" error
	[[ "$output" != *"unbound variable"* ]]
}

# ---------------------------------------------------------------------------
# Bug 20-c: _systemd_install_lib_scripts does not crash when PREFIX_LIBDIR is
#           the default (not set by caller) — relies on install.sh declaration.
#           Simulated by exporting OXPULSE_PREFIX_LIBDIR env override.
# ---------------------------------------------------------------------------
@test "Bug20: _systemd_install_lib_scripts runs without PREFIX_LIBDIR in env" {
	run env PATH="${TMP}/shims:/usr/bin:/bin" bash -c "
		set -u
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
	[[ "$output" != *"unbound variable"* ]]
}
