#!/usr/bin/env bash
# Bug M regression test: install.sh early-loader must fetch lib/render-channel-lib.sh
# from REPO_RAW when all three local paths are absent (curl|bash flow, no checkout).
#
# Test strategy:
#   - Grep the exact early-loader block from install.sh (lines _rl_local to unset)
#   - Run it in a controlled env where all 3 local paths are absent + fake curl present
#   - Case 3 is the authoritative assertion: runs install.sh's own block in isolated env;
#     fails against current code (inline stubs used), passes after Bug M fix
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

pass() { echo "OK: $*"; }
fail() { echo "FAIL: $*"; exit 1; }

# Stub render-channel-lib.sh that fake curl will return
STUB_LIB=$(mktemp)
trap 'rm -f "$STUB_LIB"' EXIT
cat > "$STUB_LIB" << 'STUBEOF'
CHANNELS_FAILED=()
_in_array() { local needle=$1; shift; local el; for el in "$@"; do [[ "$el" == "$needle" ]] && return 0; done; return 1; }
render_channel_soft() { return 0; }
compose_strip_failed_channels() { return 0; }
STUBEOF

# Extract the early-loader block from the ACTUAL install.sh
LOADER_BLOCK=$(sed -n '/^_rl_local=/,/^unset _rl_local/p' "$REPO_ROOT/install.sh")

# ---------------------------------------------------------------------------
# Case 1: confirm current (unfixed) install.sh uses inline stubs when all paths absent
# ---------------------------------------------------------------------------
WDIR1=$(mktemp -d)
trap 'rm -rf "$WDIR1"' EXIT

# Fake curl
mkdir -p "$WDIR1/bin"
cat > "$WDIR1/bin/curl" << CURLEOF
#!/usr/bin/env bash
dest=""; url=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in -o) dest="\$2"; shift 2;; http*|https*) url="\$1"; shift;; *) shift;; esac
done
[[ "\$url" == *"render-channel-lib.sh"* && -n "\$dest" ]] && { cp "$STUB_LIB" "\$dest"; exit 0; }
exit 1
CURLEOF
chmod +x "$WDIR1/bin/curl"

mkdir -p "$WDIR1/empty_sbin" "$WDIR1/install_lib_dir_fresh"

CASE1_SCRIPT="$WDIR1/case1.sh"
cat > "$CASE1_SCRIPT" << CASE1EOF
#!/usr/bin/env bash
set -euo pipefail
export PATH="$WDIR1/bin:\$PATH"
PREFIX_SBIN="$WDIR1/empty_sbin"
INSTALL_LIB_DIR="$WDIR1/install_lib_dir_fresh"
REPO_RAW="https://raw.example.com/fake"
warn() { printf '!!  %s\n' "\$*" >&2; }

$LOADER_BLOCK

warn_out=\$(render_channel_soft xray /tmp/f.tpl /tmp/f.out 2>&1 || true)
if echo "\$warn_out" | grep -q "lib/render-channel-lib.sh not found"; then
  echo "CURRENT_USES_INLINE_STUBS"
else
  echo "CURRENT_FETCHES_LIB"
fi
CASE1EOF
chmod +x "$CASE1_SCRIPT"

case1_out=$(bash "$CASE1_SCRIPT" 2>&1)
echo "  case1_out=[$case1_out]"
if echo "$case1_out" | grep -q "CURRENT_USES_INLINE_STUBS"; then
    pass "case 1 (RED confirmed): current install.sh falls back to inline stubs"
elif echo "$case1_out" | grep -q "CURRENT_FETCHES_LIB"; then
    pass "case 1: install.sh already has fetch fallback (pre-patched)"
else
    fail "case 1: unexpected output: $case1_out"
fi

# ---------------------------------------------------------------------------
# Case 3 (authoritative): install.sh actual loader — FRESH dir, no pre-populated lib
# Fails vs current code (inline stubs used), passes after Bug M fix
# ---------------------------------------------------------------------------
WDIR3=$(mktemp -d)
trap 'rm -rf "$WDIR3"' EXIT

mkdir -p "$WDIR3/bin"
cat > "$WDIR3/bin/curl" << C3CURLEOF
#!/usr/bin/env bash
dest=""; url=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in -o) dest="\$2"; shift 2;; http*|https*) url="\$1"; shift;; *) shift;; esac
done
[[ "\$url" == *"render-channel-lib.sh"* && -n "\$dest" ]] && { cp "$STUB_LIB" "\$dest"; exit 0; }
exit 1
C3CURLEOF
chmod +x "$WDIR3/bin/curl"

mkdir -p "$WDIR3/empty_sbin" "$WDIR3/install_lib_dir_c3"

CASE3_SCRIPT="$WDIR3/case3.sh"
cat > "$CASE3_SCRIPT" << CASE3EOF
#!/usr/bin/env bash
set -euo pipefail
export PATH="$WDIR3/bin:\$PATH"
PREFIX_SBIN="$WDIR3/empty_sbin"
INSTALL_LIB_DIR="$WDIR3/install_lib_dir_c3"
REPO_RAW="https://raw.example.com/fake"
warn() { printf '!!  %s\n' "\$*" >&2; }

$LOADER_BLOCK

declare -f render_channel_soft > /dev/null || { echo "FAIL_UNDEF"; exit 1; }
warn_out=\$(render_channel_soft xray /tmp/f.tpl /tmp/f.out 2>&1 || true)
if echo "\$warn_out" | grep -q "lib/render-channel-lib.sh not found"; then
    echo "INLINE_STUB_USED"
    exit 1
fi
[[ -f "\$INSTALL_LIB_DIR/render-channel-lib.sh" ]] || { echo "NOT_PERSISTED"; exit 1; }
echo "CASE3_PASS"
CASE3EOF
chmod +x "$CASE3_SCRIPT"

case3_out=$(bash "$CASE3_SCRIPT" 2>&1)
echo "  case3_out=[$case3_out]"
if echo "$case3_out" | grep -q "CASE3_PASS"; then
    pass "case 3 (install.sh actual loader): fetched lib used, persisted to INSTALL_LIB_DIR"
elif echo "$case3_out" | grep -q "INLINE_STUB_USED"; then
    fail "case 3: install.sh loader uses inline stubs — Bug M not yet fixed in install.sh"
elif echo "$case3_out" | grep -q "NOT_PERSISTED"; then
    fail "case 3: lib not persisted to INSTALL_LIB_DIR after fetch"
else
    fail "case 3 unexpected: $case3_out"
fi

echo "ALL RENDER_CHANNEL_SOFT FETCH TESTS PASS"
