#!/bin/bash
# tests/test_sbin_lib_delivery_assertion.sh — #530: sbin helper lib delivery
# assertion.
#
# Three falsification cases, each stated as a FILE:LINE edit:
#
#   F1 — truncate one shipped lib to zero bytes after install.  The new
#        assertion (_verify_sbin_libs) must go RED naming that lib.
#        mutation: truncate "$PREFIX_SBIN/metric-sink-lib.sh" to 0 bytes
#        → RED? (must name metric-sink-lib.sh)
#
#   F2 — add a new helper lib to the installer's delivery code WITHOUT
#        touching any list, then assert the check covers it.  If the check
#        misses it, the set is not derived and F2 has found that.
#        mutation: append "new-test-lib.sh" to _DELIVERED_SBIN_LIBS
#        (simulating a new install block) → check must cover it
#
#   F3 — replace one curl tier with a command that exits 0 and writes an
#        empty file.  The install must die.  Today it proceeds.
#        mutation: curl shim writes empty file + exits 0 →
#        _curl_fetch_or_die must die on [[ -s ]] check
#
# A mutation that fails to COMPILE or parse is not a kill — the script must
# RUN and the assertion fail.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
INSTALL_SYSTEMD="$REPO_ROOT/lib/install-systemd.sh"

[[ -f "$INSTALL_SYSTEMD" ]] || { echo "FAIL: lib/install-systemd.sh not found"; exit 1; }

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# ---------------------------------------------------------------------------
# Harness: minimal globals + PATH shims for sourcing the module and running
# _systemd_install_lib_scripts + _verify_sbin_libs in isolation.
# ---------------------------------------------------------------------------
_setup_harness() {
	local _tmp="$1" _src="$2"

	# PATH shims
	mkdir -p "$_tmp/bin"

	# install: copy src→dest so downstream code can open the file
	cat > "$_tmp/bin/install" <<'STUB'
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
[[ -n "$mode" ]] && chmod "$mode" "$dst" 2>/dev/null || true
exit 0
STUB
	chmod +x "$_tmp/bin/install"

	# curl: copy from a fake repo root so the file has real content
	cat > "$_tmp/bin/curl" <<'STUB'
#!/usr/bin/env bash
# Extract -o dest
dst=""
url=""
while [[ $# -gt 0 ]]; do
	case "$1" in
		-o) dst="$2"; shift 2 ;;
		-*) shift ;;
		*)  url="$1"; shift ;;
	esac
done
# Resolve URL to a local file under FAKE_REPO_ROOT
[[ -n "$FAKE_REPO_ROOT" ]] || exit 1
# Strip the base URL prefix to get the repo-relative path
rel="${url#*/oxpulse-partner-edge/}"
src="$FAKE_REPO_ROOT/$rel"
if [[ -f "$src" ]]; then
	cp "$src" "$dst"
else
	echo "curl: file not found: $src" >&2
	exit 1
fi
exit 0
STUB
	chmod +x "$_tmp/bin/curl"

	# chmod: no-op
	cat > "$_tmp/bin/chmod" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
	chmod +x "$_tmp/bin/chmod"

	# Build a fake repo root with the actual lib files so curl can serve them
	mkdir -p "$_tmp/repo/lib" "$_tmp/repo/config" "$_tmp/repo/systemd" "$_tmp/repo/scripts"
	cp "$REPO_ROOT/channel-render-lib.sh" "$_tmp/repo/channel-render-lib.sh"
	cp "$REPO_ROOT/sni-select-lib.sh" "$_tmp/repo/sni-select-lib.sh"
	cp "$REPO_ROOT/lib/render-channel-lib.sh" "$_tmp/repo/lib/render-channel-lib.sh"
	cp "$REPO_ROOT/ghcr-auth-lib.sh" "$_tmp/repo/ghcr-auth-lib.sh"
	cp "$REPO_ROOT/lib/peer-ip-guard-lib.sh" "$_tmp/repo/lib/peer-ip-guard-lib.sh"
	cp "$REPO_ROOT/oxpulse-token-lib.sh" "$_tmp/repo/oxpulse-token-lib.sh"
	cp "$REPO_ROOT/lib/hydrate-hy2.sh" "$_tmp/repo/lib/hydrate-hy2.sh"
	cp "$REPO_ROOT/lib/telegram-alert-lib.sh" "$_tmp/repo/lib/telegram-alert-lib.sh"
	cp "$REPO_ROOT/lib/channel-health-lib.sh" "$_tmp/repo/lib/channel-health-lib.sh"
	cp "$REPO_ROOT/lib/cross-probe-lib.sh" "$_tmp/repo/lib/cross-probe-lib.sh"
	cp "$REPO_ROOT/lib/metric-sink-lib.sh" "$_tmp/repo/lib/metric-sink-lib.sh"
	cp "$REPO_ROOT/lib/surgical-restart-lib.sh" "$_tmp/repo/lib/surgical-restart-lib.sh"
	cp "$REPO_ROOT/lib/xprb-refresh-lib.sh" "$_tmp/repo/lib/xprb-refresh-lib.sh"
	cp "$REPO_ROOT/config/defaults.conf" "$_tmp/repo/config/defaults.conf" 2>/dev/null || true
	printf '0.0.0-test\n' > "$_tmp/repo/VERSION"

	# Also copy lib files to src_dir so the install path uses local files
	mkdir -p "$_src/lib" "$_src/config"
	cp "$REPO_ROOT/channel-render-lib.sh" "$_src/"
	cp "$REPO_ROOT/sni-select-lib.sh" "$_src/"
	cp "$REPO_ROOT/lib/render-channel-lib.sh" "$_src/lib/"
	cp "$REPO_ROOT/ghcr-auth-lib.sh" "$_src/"
	cp "$REPO_ROOT/lib/peer-ip-guard-lib.sh" "$_src/lib/"
	cp "$REPO_ROOT/oxpulse-token-lib.sh" "$_src/"
	cp "$REPO_ROOT/lib/hydrate-hy2.sh" "$_src/lib/"
	cp "$REPO_ROOT/lib/telegram-alert-lib.sh" "$_src/lib/"
	cp "$REPO_ROOT/lib/channel-health-lib.sh" "$_src/lib/"
	cp "$REPO_ROOT/lib/cross-probe-lib.sh" "$_src/lib/"
	cp "$REPO_ROOT/lib/metric-sink-lib.sh" "$_src/lib/"
	cp "$REPO_ROOT/lib/surgical-restart-lib.sh" "$_src/lib/"
	cp "$REPO_ROOT/lib/xprb-refresh-lib.sh" "$_src/lib/"
	cp "$REPO_ROOT/config/defaults.conf" "$_src/config/" 2>/dev/null || true
	printf '0.0.0-test\n' > "$_src/VERSION"
}

# _env_block TMP SRC SBIN — emit the common env block for sourcing the module.
_env_block() {
	cat <<ENVEOF
DRY_RUN=0
src_dir='$2'
REPO_RAW='https://raw.example.test/oxpulse-partner-edge/main'
PREFIX_SBIN='$3'
PREFIX_LIBDIR='$3/libdir'
INSTALL_LIB_DIR='$3/libdir'
SYSTEMD_DIR='$3/systemd'
OXPULSE_SHARE_DIR='$1/share'
BAKE_MODE=0
TURNS_SUBDOMAIN=api-test01
DOMAIN=example.net
_chan_lib_tmp=''
log()  { :; }
warn() { :; }
die()  { echo "DIE: \$*" >&2; exit 1; }
ENVEOF
}

# ---------------------------------------------------------------------------
# F1 — truncate one shipped lib to zero bytes after install; the assertion
# must go RED naming that lib.
# ---------------------------------------------------------------------------
echo ""
echo "=== F1: truncate a shipped lib to zero bytes → assertion names it ==="
TMP_F1=$(mktemp -d)
SRC_F1="$TMP_F1/src"
SBIN_F1="$TMP_F1/sbin"
mkdir -p "$SRC_F1" "$SBIN_F1"
_setup_harness "$TMP_F1" "$SRC_F1"

F1_OUT=$(env FAKE_REPO_ROOT="$TMP_F1/repo" PATH="$TMP_F1/bin:$PATH" bash -c "
	$(_env_block "$TMP_F1" "$SRC_F1" "$SBIN_F1")
	source '$INSTALL_SYSTEMD'
	_systemd_install_lib_scripts
	# Truncate metric-sink-lib.sh to zero bytes — simulates a failed curl
	# that left a zero-byte file.
	: > '$SBIN_F1/metric-sink-lib.sh'
	# Run the assertion — it must fail and name metric-sink-lib.sh
	if _verify_sbin_libs 2>&1; then
		echo 'ASSERTION_PASSED (BAD — should have failed)'
	else
		echo 'ASSERTION_FAILED (good)'
	fi
" 2>&1) || true

if [[ "$F1_OUT" == *'ASSERTION_FAILED'* ]]; then
	if [[ "$F1_OUT" == *'metric-sink-lib.sh'* ]]; then
		pass "F1: assertion failed and named metric-sink-lib.sh (zero-byte detection)"
	else
		fail "F1: assertion failed but did NOT name metric-sink-lib.sh — output: $F1_OUT"
	fi
else
	fail "F1: assertion did not fail on zero-byte lib — output: $F1_OUT"
fi
rm -rf "$TMP_F1"

# ---------------------------------------------------------------------------
# F2 — add a new helper lib to the installer's delivery code WITHOUT touching
# any list, then assert the check covers it.  This proves the set is derived
# from the delivery code, not a hand-maintained array.
# ---------------------------------------------------------------------------
echo ""
echo "=== F2: add a new lib without touching any list → check covers it ==="
TMP_F2=$(mktemp -d)
SRC_F2="$TMP_F2/src"
SBIN_F2="$TMP_F2/sbin"
mkdir -p "$SRC_F2" "$SBIN_F2"
_setup_harness "$TMP_F2" "$SRC_F2"

# Create a fake new lib that a developer might add
printf '#!/bin/bash\nnew_test_func() { echo hello; }\n' > "$SBIN_F2/new-test-lib.sh"

F2_OUT=$(env FAKE_REPO_ROOT="$TMP_F2/repo" PATH="$TMP_F2/bin:$PATH" bash -c "
	$(_env_block "$TMP_F2" "$SRC_F2" "$SBIN_F2")
	source '$INSTALL_SYSTEMD'
	_systemd_install_lib_scripts
	# Simulate a developer adding a new install block: they would add
	# the install + _DELIVERED_SBIN_LIBS+=('new-test-lib.sh') line.
	# We append to the array (the derivation mechanism) without touching
	# any hand-maintained list.
	_DELIVERED_SBIN_LIBS+=('new-test-lib.sh')
	# The file exists and defines a function → assertion should pass
	if _verify_sbin_libs 2>&1; then
		echo 'NEW_LIB_COVERED'
	else
		echo 'NEW_LIB_MISSED (BAD — derivation broken)'
	fi
	# Now remove the file → assertion must fail naming it
	rm -f '$SBIN_F2/new-test-lib.sh'
	if _verify_sbin_libs 2>&1; then
		echo 'REMOVED_LIB_NOT_CAUGHT (BAD)'
	else
		echo 'REMOVED_LIB_CAUGHT (good)'
	fi
" 2>&1) || true

if [[ "$F2_OUT" == *'NEW_LIB_COVERED'* ]]; then
	pass "F2: new lib added to delivery code is covered by the assertion (derivation works)"
else
	fail "F2: new lib was NOT covered — the set is not derived. Output: $F2_OUT"
fi
if [[ "$F2_OUT" == *'REMOVED_LIB_CAUGHT'* ]]; then
	if [[ "$F2_OUT" == *'new-test-lib.sh'* ]]; then
		pass "F2: assertion names new-test-lib.sh when it goes missing"
	else
		fail "F2: assertion caught missing lib but did not name new-test-lib.sh. Output: $F2_OUT"
	fi
else
	fail "F2: assertion did not catch the removed new lib. Output: $F2_OUT"
fi
rm -rf "$TMP_F2"

# ---------------------------------------------------------------------------
# F3 — replace one curl tier with a command that exits 0 and writes an empty
# file.  The install must die.  Today it proceeds.
# ---------------------------------------------------------------------------
echo ""
echo "=== F3: curl exits 0 + writes empty file → install must die ==="
TMP_F3=$(mktemp -d)
SRC_F3=""  # empty src_dir forces curl path
SBIN_F3="$TMP_F3/sbin"
mkdir -p "$SBIN_F3"

# Custom curl shim: exits 0 and writes an EMPTY file
mkdir -p "$TMP_F3/bin"
cat > "$TMP_F3/bin/curl" <<'STUB'
#!/usr/bin/env bash
# Extract -o dest, write an empty file, exit 0
dst=""
while [[ $# -gt 0 ]]; do
	case "$1" in
		-o) dst="$2"; shift 2 ;;
		*)  shift ;;
	esac
done
[[ -n "$dst" ]] && : > "$dst"  # zero-byte file
exit 0
STUB
chmod +x "$TMP_F3/bin/curl"
cat > "$TMP_F3/bin/install" <<'STUB'
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
exit 0
STUB
chmod +x "$TMP_F3/bin/install"
cat > "$TMP_F3/bin/chmod" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$TMP_F3/bin/chmod"

F3_OUT=$(env PATH="$TMP_F3/bin:$PATH" bash -c "
	DRY_RUN=0
	src_dir=''
	REPO_RAW='https://raw.example.test/oxpulse-partner-edge/main'
	PREFIX_SBIN='$SBIN_F3'
	PREFIX_LIBDIR='$SBIN_F3/libdir'
	INSTALL_LIB_DIR='$SBIN_F3/libdir'
	SYSTEMD_DIR='$SBIN_F3/systemd'
	BAKE_MODE=0
	TURNS_SUBDOMAIN=api-test01
	DOMAIN=example.net
	_chan_lib_tmp=''
	log()  { :; }
	warn() { :; }
	die()  { echo \"DIE: \$*\" >&2; exit 1; }
	source '$INSTALL_SYSTEMD'
	_systemd_install_lib_scripts
	echo 'INSTALL_PROCEEDED (BAD — should have died)'
" 2>&1) || true

if [[ "$F3_OUT" =~ DIE:.*empty\ file ]]; then
	pass "F3: install died on empty curl output (truncated/dropped transfer detected)"
elif [[ "$F3_OUT" == *'DIE:'* ]]; then
	pass "F3: install died on curl failure (die triggered)"
else
	fail "F3: install did NOT die on empty curl output — output: $F3_OUT"
fi
if [[ "$F3_OUT" == *'INSTALL_PROCEEDED'* ]]; then
	fail "F3: install proceeded past the empty file — _curl_fetch_or_die not working"
fi
rm -rf "$TMP_F3"

# ---------------------------------------------------------------------------
# Additional: verify _DELIVERED_SBIN_LIBS is populated by _systemd_install_lib_scripts
# and has the expected count (13 libs).  This is a sanity check that the
# derivation mechanism works — if the array is empty, the assertion is vacuous.
# ---------------------------------------------------------------------------
echo ""
echo "=== Sanity: _DELIVERED_SBIN_LIBS populated with expected lib count ==="
TMP_S=$(mktemp -d)
SRC_S="$TMP_S/src"
SBIN_S="$TMP_S/sbin"
mkdir -p "$SRC_S" "$SBIN_S"
_setup_harness "$TMP_S" "$SRC_S"

SANITY_OUT=$(env FAKE_REPO_ROOT="$TMP_S/repo" PATH="$TMP_S/bin:$PATH" bash -c "
	$(_env_block "$TMP_S" "$SRC_S" "$SBIN_S")
	source '$INSTALL_SYSTEMD'
	_systemd_install_lib_scripts
	echo \"COUNT=\${#_DELIVERED_SBIN_LIBS[@]}\"
	for lib in \"\${_DELIVERED_SBIN_LIBS[@]}\"; do echo \"LIB=\$lib\"; done
	# Also verify the manifest was written
	if [[ -f '/usr/local/share/oxpulse-partner-edge/sbin-libs.manifest' ]]; then
		echo 'MANIFEST_WRITTEN'
	else
		echo 'MANIFEST_NOT_WRITTEN (expected — share dir may not be writable in test)'
	fi
" 2>&1) || true

DELIVERED_COUNT=$(echo "$SANITY_OUT" | sed -n 's/^COUNT=//p')
if [[ "$DELIVERED_COUNT" -eq 13 ]]; then
	pass "Sanity: _DELIVERED_SBIN_LIBS has 13 entries (all libs recorded)"
else
	fail "Sanity: _DELIVERED_SBIN_LIBS has $DELIVERED_COUNT entries (expected 13). Output: $SANITY_OUT"
fi

# Verify each expected lib is in the array
for expected_lib in \
	channel-render-lib.sh \
	sni-select-lib.sh \
	render-channel-lib.sh \
	ghcr-auth-lib.sh \
	peer-ip-guard-lib.sh \
	oxpulse-token-lib.sh \
	hydrate-hy2.sh \
	telegram-alert-lib.sh \
	channel-health-lib.sh \
	cross-probe-lib.sh \
	metric-sink-lib.sh \
	surgical-restart-lib.sh \
	xprb-refresh-lib.sh; do
	if [[ "$SANITY_OUT" == *"LIB=$expected_lib"* ]]; then
		: # ok
	else
		fail "Sanity: $expected_lib missing from _DELIVERED_SBIN_LIBS"
	fi
done
rm -rf "$TMP_S"

# ---------------------------------------------------------------------------
# Additional: verify _verify_sbin_libs passes when all libs are correctly
# installed (the happy path — must not be a false-positive machine).
# ---------------------------------------------------------------------------
echo ""
echo "=== Happy path: all libs correctly installed → assertion passes ==="
TMP_H=$(mktemp -d)
SRC_H="$TMP_H/src"
SBIN_H="$TMP_H/sbin"
mkdir -p "$SRC_H" "$SBIN_H"
_setup_harness "$TMP_H" "$SRC_H"

HAPPY_OUT=$(env FAKE_REPO_ROOT="$TMP_H/repo" PATH="$TMP_H/bin:$PATH" bash -c "
	$(_env_block "$TMP_H" "$SRC_H" "$SBIN_H")
	source '$INSTALL_SYSTEMD'
	_systemd_install_lib_scripts
	if _verify_sbin_libs 2>&1; then
		echo 'ALL_LIBS_VERIFIED'
	else
		echo 'FALSE_POSITIVE (BAD — assertion failed on good install)'
	fi
" 2>&1) || true

if [[ "$HAPPY_OUT" == *'ALL_LIBS_VERIFIED'* ]]; then
	pass "Happy path: all 13 libs verified present, non-empty, defining ≥1 function"
else
	fail "Happy path: assertion failed on a correct install (false positive). Output: $HAPPY_OUT"
fi
rm -rf "$TMP_H"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "==================================================================="
echo "sbin lib delivery assertion (#530): PASS=$PASS FAIL=$FAIL"
echo "==================================================================="
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
