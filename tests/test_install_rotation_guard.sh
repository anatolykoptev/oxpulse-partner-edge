#!/usr/bin/env bash
# install.sh --rotate-identity / --force-keygen / --rotate-awg-key:
#   1. refused on an installed node (install.env present) — registration is skipped
#      there, so the flag could not reach the hub and would lock ch1 out;
#   2. Reality identity rotation no longer rotates the AWG keypair as a side effect.
# Plain-bash idiom of tests/test_fleet_self_upgrade.sh (extract + stub).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
ARGS="$ROOT/lib/install-args.sh"
INSTALL="$ROOT/install.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT
mkdir -p "$TMPD/installed" "$TMPD/fresh"
: > "$TMPD/installed/install.env"

# Run args_assert_rotation_supported in a subshell. $1=PREFIX_LIB dir, rest = VAR=val.
guard() {
    local lib="$1"; shift
    (
        die() { printf 'die: %s\n' "$*" >&2; exit 7; }
        # shellcheck disable=SC1090
        source "$ARGS"
        PREFIX_LIB="$lib"; FORCE_KEYGEN=0; FORCE_AWG_KEYGEN=0
        for kv in "$@"; do eval "$kv"; done
        args_assert_rotation_supported
    ) 2>"$TMPD/err"
}

guard "$TMPD/installed" FORCE_KEYGEN=1
[ $? -eq 7 ] && pass "G1: --rotate-identity on an installed node is refused" || fail "G1: not refused"
grep -q "rotate-reality-uuid" "$TMPD/err" \
    && pass "G2: the refusal names the supported path" || fail "G2: refusal does not point at partner-cli rotate-reality-uuid"

guard "$TMPD/installed" FORCE_AWG_KEYGEN=1
[ $? -eq 7 ] && pass "G3: --rotate-awg-key on an installed node is refused" || fail "G3: not refused"

guard "$TMPD/fresh" FORCE_KEYGEN=1
[ $? -eq 0 ] && pass "G4: --rotate-identity on a fresh node (no install.env) is allowed" || fail "G4: fresh install wrongly refused"

guard "$TMPD/installed"
[ $? -eq 0 ] && pass "G5: no rotation flag on an installed node is untouched" || fail "G5: plain re-run wrongly refused"

# --- flag plumbing: --rotate-identity must not turn on AWG rotation ---------
parse() {
    ( die() { echo "die: $*" >&2; exit 1; }; warn() { :; }; log() { :; }
      PREFIX_ETC=/x PREFIX_LIB=/x BACKEND_API=https://x
      OXPULSE_PARTNER_TOKEN='' OXPULSE_IMAGE_VERSION='' TURNS_SUBDOMAIN='' SFU_UDP_PORT='' \
      SFU_METRICS_PORT='' SFU_EDGE_ID='' REGION='' HEALTHCHECK_TIMEOUT='' BRANDING_CONFIG='' \
      OXPULSE_GHCR_TOKEN='' OXPULSE_NONINTERACTIVE=1
      # shellcheck disable=SC1090
      source "$ARGS"
      args_parse --dry-run --domain=a.example --partner-id=abc --token=t "$@"
      echo "FORCE_KEYGEN=$FORCE_KEYGEN FORCE_AWG_KEYGEN=$FORCE_AWG_KEYGEN" ) 2>&1
}
[ "$(parse --rotate-identity)" = "FORCE_KEYGEN=1 FORCE_AWG_KEYGEN=0" ] \
    && pass "P1: --rotate-identity sets Reality rotation only" || fail "P1: --rotate-identity leaks into AWG rotation"
[ "$(parse --force-keygen --rotate-awg-key)" = "FORCE_KEYGEN=1 FORCE_AWG_KEYGEN=1" ] \
    && pass "P2: --rotate-awg-key is the explicit AWG switch" || fail "P2: --rotate-awg-key not honoured"

# --- the installer actually uses the split + calls the guard ----------------
awk '/Reality x25519 keypair \+ UUID/{f=1} /AmneziaWG keypair — generated locally/{f=0} f' "$INSTALL" > "$TMPD/reality.txt"
awk '/AmneziaWG keypair — generated locally/{f=1} /if \[\[ -n "\$MANUAL_CONFIG" \]\]; then/{f=0} f' "$INSTALL" > "$TMPD/awg.txt"
[ -s "$TMPD/reality.txt" ] && [ -s "$TMPD/awg.txt" ] || { fail "S0: could not extract keygen blocks"; exit 1; }
grep -q 'FORCE_KEYGEN.*--rotate' "$TMPD/reality.txt" \
    && pass "S1: Reality keygen block rotates on FORCE_KEYGEN" || fail "S1: Reality block lost its --rotate wiring"
grep -q 'FORCE_AWG_KEYGEN.*--rotate' "$TMPD/awg.txt" \
    && pass "S2: AWG keygen block rotates on FORCE_AWG_KEYGEN" || fail "S2: AWG block not on its own switch"
grep -q 'FORCE_KEYGEN' "$TMPD/awg.txt" \
    && fail "S3: AWG block still reads FORCE_KEYGEN (side-effect rotation)" || pass "S3: AWG block does not read FORCE_KEYGEN"
guard_line=$(grep -n '^args_assert_rotation_supported$' "$INSTALL" | cut -d: -f1)
parse_line=$(grep -n '^args_parse "\$@"$' "$INSTALL" | cut -d: -f1)
if [ -n "$guard_line" ] && [ -n "$parse_line" ] && [ "$guard_line" -gt "$parse_line" ]; then
    pass "S4a: the guard runs right after args_parse"
else
    fail "S4a: guard not wired after args_parse (guard=$guard_line parse=$parse_line)"
fi
# ... and BEFORE every host side effect: a refused rotation must not have installed
# packages, touched the network config or written anything.
for side in preflight_run deps_install network_run; do
    l=$(grep -n "^${side}$" "$INSTALL" | cut -d: -f1)
    if [ -n "$l" ] && [ -n "$guard_line" ] && [ "$guard_line" -lt "$l" ]; then
        pass "S4b: guard precedes $side"
    else
        fail "S4b: guard does not precede $side (guard=$guard_line $side=$l)"
    fi
done

# install.sh must not print the node's uuid in clear (fingerprint only)
clear_logs=$(grep -nE '(log|warn|echo|printf)[^#]*\$\{?REALITY_UUID\}?([^_A-Za-z]|$)' "$INSTALL" | grep -v sha256sum || true)
if [ -n "$clear_logs" ]; then
    fail "S5: install.sh still logs REALITY_UUID in clear: $clear_logs"
else
    pass "S5: no log line prints REALITY_UUID in clear"
fi

echo "--- $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
