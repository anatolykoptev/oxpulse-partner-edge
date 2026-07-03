#!/bin/bash
# tests/test_upgrade_stages_firewall_lib.sh
#
# BUG 1 (CRITICAL) regression test — the transitive-fetch firewall-abort.
#
# Root cause: on a curl|bash edge, upgrade.sh's _source_lib fetches reconcile.sh
# into a /tmp tmpdir and sources it from there WITHOUT co-locating its transitive
# deps. reconcile_firewall_surface then resolves install-firewall.sh relative to
# reconcile.sh's OWN dir — ${FIREWALL_LIB:-${LIB_DIR:-$(dirname BASH_SOURCE)}/install-firewall.sh}
# = /tmp/install-firewall.sh, which does not exist → die() → the ENTIRE upgrade
# aborts before any image pull, fleet-wide.
#
# Fix under test (architecture-council P1): upgrade.sh PRE-STAGES reconcile.sh's
# transitive deps (install-firewall.sh, telegram-alert-lib.sh) into a stable dir
# via _stage_lib and exports LIB_DIR (+ FIREWALL_LIB) so reconcile_firewall_surface's
# [[ -f ]] check passes. t14's fail-loud firewall contract is preserved — the die
# on a genuinely-missing file AFTER staging is still correct; only the missing
# co-location on the fetch path is fixed.
#
# Falsification: the FIX subtest sources reconcile.sh from a /tmp dir (BASH_SOURCE
# resolves to /tmp — the curl|bash shape) and shows the firewall surface die()s
# with NO LIB_DIR and survives WITH LIB_DIR pointing at a staging dir. Remove the
# LIB_DIR export in upgrade.sh → the structural checks S3/S4 go RED; the die is
# the pre-fix behaviour.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
UPGRADE="$REPO_ROOT/upgrade.sh"
RECONCILE_LIB="$REPO_ROOT/lib/reconcile.sh"
FW_LIB="$REPO_ROOT/lib/install-firewall.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

echo ""
echo "=== BUG1: upgrade.sh stages reconcile's transitive libs + exports LIB_DIR ==="

[[ -f "$UPGRADE" ]]       || { fail "P0: upgrade.sh not found"; exit 1; }
[[ -f "$RECONCILE_LIB" ]] || { fail "P0: lib/reconcile.sh not found"; exit 1; }
[[ -f "$FW_LIB" ]]        || { fail "P0: lib/install-firewall.sh not found"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Structural: upgrade.sh must define + use a staging primitive and export LIB_DIR.
# ---------------------------------------------------------------------------
bash -n "$UPGRADE" && pass "S0: upgrade.sh passes bash -n" || { fail "S0: upgrade.sh syntax error"; exit 1; }

grep -qE '^_stage_lib\(\)' "$UPGRADE" \
    && pass "S1: _stage_lib() staging primitive defined in upgrade.sh" \
    || fail "S1: _stage_lib() not defined in upgrade.sh"

if grep -qE '_stage_lib "install-firewall.sh"' "$UPGRADE" \
   && grep -qE '_stage_lib "telegram-alert-lib.sh"' "$UPGRADE"; then
    pass "S2: install-firewall.sh + telegram-alert-lib.sh both staged"
else
    fail "S2: not both transitive deps staged (install-firewall.sh / telegram-alert-lib.sh)"
fi

if grep -qE 'export LIB_DIR=' "$UPGRADE" && grep -qE 'export FIREWALL_LIB=' "$UPGRADE"; then
    pass "S3: LIB_DIR and FIREWALL_LIB exported"
else
    fail "S3: LIB_DIR/FIREWALL_LIB not both exported"
fi

# S4: the LIB_DIR export must precede the reconcile_all call (staged before use).
_libdir_line=$(grep -nE 'export LIB_DIR=' "$UPGRADE" | head -1 | cut -d: -f1 || true)
_reconcile_line=$(grep -nE 'reconcile_all "' "$UPGRADE" | head -1 | cut -d: -f1 || true)
if [[ -n "$_libdir_line" && -n "$_reconcile_line" && "$_libdir_line" -lt "$_reconcile_line" ]]; then
    pass "S4: LIB_DIR exported (line $_libdir_line) before reconcile_all (line $_reconcile_line)"
else
    fail "S4: LIB_DIR export not before reconcile_all (libdir=$_libdir_line reconcile=$_reconcile_line)"
fi

# ---------------------------------------------------------------------------
# _stage_lib functional: it must resolve a local lib and COPY it to a dest dir.
# ---------------------------------------------------------------------------
STAGE_FN="$TMP/stage_fn.sh"
{
    echo 'log()  { :; }'
    echo 'warn() { :; }'
    echo 'die()  { echo "DIED: $*" >&2; exit 1; }'
    awk '/^_stage_lib\(\)/{f=1} f{print} /^}$/ && f{exit}' "$UPGRADE"
} > "$STAGE_FN"
bash -n "$STAGE_FN" && pass "SF0: extracted _stage_lib parses" || { fail "SF0: _stage_lib syntax error"; }

STAGE_DEST="$TMP/stage"
mkdir -p "$STAGE_DEST"
SF_OUT=$(bash -c "
set -uo pipefail
# shellcheck source=/dev/null
source '$STAGE_FN'
_stage_lib 'install-firewall.sh' '$FW_LIB' '/nonexistent/installed/install-firewall.sh' 'http://127.0.0.1:0/nope' '$STAGE_DEST'
echo STAGED
" 2>&1) || true
if echo "$SF_OUT" | grep -q STAGED && [[ -f "$STAGE_DEST/install-firewall.sh" ]] \
   && grep -q 'firewall_apply' "$STAGE_DEST/install-firewall.sh"; then
    pass "SF1: _stage_lib copies a local lib into the staging dir (real content)"
else
    fail "SF1: _stage_lib did not stage the local lib (out: $SF_OUT)"
fi

# ---------------------------------------------------------------------------
# curl|bash simulation: reconcile.sh sourced from a /tmp dir with NO adjacent
# install-firewall.sh. This reproduces the die() and proves LIB_DIR cures it.
# ---------------------------------------------------------------------------
FETCHED_DIR="$TMP/fetched"        # simulates upgrade.sh's /tmp fetch tmpdir
mkdir -p "$FETCHED_DIR"
cp "$RECONCILE_LIB" "$FETCHED_DIR/reconcile.sh"   # NO lib/install-firewall.sh here

# Bug repro: NO LIB_DIR/FIREWALL_LIB → resolves to $FETCHED_DIR/install-firewall.sh
# (absent) → die.
BUG_OUT=$(bash -c "
set -uo pipefail
log()  { :; }
warn() { :; }
die()  { echo \"DIED: \$*\" >&2; exit 1; }
firewall_apply() { return 0; }   # stub so the ONLY failure path is the missing-file die
unset LIB_DIR FIREWALL_LIB
# shellcheck source=/dev/null
source '$FETCHED_DIR/reconcile.sh'
_RECONCILE_FIREWALL_APPLIED=0
reconcile_firewall_surface
echo SURVIVED
" 2>&1) && BUG_RC=0 || BUG_RC=$?
if [[ "$BUG_RC" -ne 0 ]] && echo "$BUG_OUT" | grep -qi 'install-firewall.sh not found'; then
    pass "BUG: curl|bash tmpdir + no LIB_DIR => reconcile_firewall_surface die()s (repro confirmed)"
else
    fail "BUG: expected die on missing install-firewall.sh; rc=$BUG_RC out: $BUG_OUT"
fi

# Fix: LIB_DIR points at a staging dir that HAS install-firewall.sh → no die.
FIX_STAGE="$TMP/fix_stage"
mkdir -p "$FIX_STAGE"
cp "$FW_LIB" "$FIX_STAGE/install-firewall.sh"
FIX_OUT=$(bash -c "
set -uo pipefail
log()  { :; }
warn() { :; }
die()  { echo \"DIED: \$*\" >&2; exit 1; }
firewall_apply() { return 0; }   # stub (real apply needs ufw/firewalld)
export LIB_DIR='$FIX_STAGE'
# shellcheck source=/dev/null
source '$FETCHED_DIR/reconcile.sh'
_RECONCILE_FIREWALL_APPLIED=0
reconcile_firewall_surface
echo \"SURVIVED APPLIED=\$_RECONCILE_FIREWALL_APPLIED\"
" 2>&1) && FIX_RC=0 || FIX_RC=$?
if [[ "$FIX_RC" -eq 0 ]] && echo "$FIX_OUT" | grep -q 'SURVIVED'; then
    pass "FIX: LIB_DIR→staging dir with install-firewall.sh => no die, firewall surface proceeds"
else
    fail "FIX: staging dir did not cure the die; rc=$FIX_RC out: $FIX_OUT"
fi

# FIX2: FIREWALL_LIB override (explicit path) also cures it, independent of dirname.
FIX2_OUT=$(bash -c "
set -uo pipefail
log()  { :; }
warn() { :; }
die()  { echo \"DIED: \$*\" >&2; exit 1; }
firewall_apply() { return 0; }
unset LIB_DIR
export FIREWALL_LIB='$FIX_STAGE/install-firewall.sh'
# shellcheck source=/dev/null
source '$FETCHED_DIR/reconcile.sh'
_RECONCILE_FIREWALL_APPLIED=0
reconcile_firewall_surface
echo SURVIVED
" 2>&1) && FIX2_RC=0 || FIX2_RC=$?
if [[ "$FIX2_RC" -eq 0 ]] && echo "$FIX2_OUT" | grep -q 'SURVIVED'; then
    pass "FIX2: FIREWALL_LIB explicit override also cures the die"
else
    fail "FIX2: FIREWALL_LIB override did not cure the die; rc=$FIX2_RC out: $FIX2_OUT"
fi

# ---------------------------------------------------------------------------
# Tier-3 (REPO_RAW curl) hardening (review HIGH): the root-run fetch that BUG1
# now routes libs through MORE often must be TLS-pinned and checksum-verified.
# ---------------------------------------------------------------------------
FW_FIXTURE="$TMP/fw_fixture.sh"
printf '#!/usr/bin/env bash\nfirewall_apply() { return 0; }\n' > "$FW_FIXTURE"
FW_HASH=$(sha256sum "$FW_FIXTURE" | awk '{print $1}')
CURL_LOG="$TMP/curl.log"

CK_MATCH="$TMP/ck_match.txt";    printf '%s  install-firewall.sh\n' "$FW_HASH" > "$CK_MATCH"
CK_BAD="$TMP/ck_bad.txt";        printf '%s  install-firewall.sh\n' "0000000000000000000000000000000000000000000000000000000000000000" > "$CK_BAD"
CK_NOENTRY="$TMP/ck_noentry.txt"; printf '%s  some-other-lib.sh\n' "$FW_HASH" > "$CK_NOENTRY"

# Harness: extract self-contained _stage_lib, mock curl (writes the fixture lib,
# and the checksums file only if CKFILE is a real file), drive the tier-3 path.
HARNESS="$TMP/stage3_harness.sh"
cat > "$HARNESS" << 'HEOF'
#!/usr/bin/env bash
set -uo pipefail
log()  { :; }
warn() { :; }
die()  { echo "DIED: $*" >&2; exit 7; }
curl() {
    echo "$*" >> "$CURL_LOG"
    local _o="" _n="" a
    for a in "$@"; do [[ "$_n" == o ]] && { _o="$a"; _n=""; }; [[ "$a" == "-o" ]] && _n=o; done
    case "$*" in
        *lib-checksums.txt*) { [[ -n "${CKFILE:-}" && -f "${CKFILE:-}" ]] && cp "$CKFILE" "$_o"; } || return 1 ;;
        *) cp "$FW_FIXTURE" "$_o" ;;
    esac
    return 0
}
# shellcheck source=/dev/null
source "$STAGE_FN"
if _stage_lib "install-firewall.sh" "/nonexistent/local" "/nonexistent/installed" \
       "$REPO_RAW/lib/install-firewall.sh" "$DEST"; then
    [[ -f "$DEST/install-firewall.sh" ]] && echo "STAGED" || echo "NOFILE"
else
    echo "FAILED"
fi
HEOF

_stage3() {  # CKFILE(""=none) NI(0/1) -> RESULT text
    local _dest; _dest=$(mktemp -d)
    : > "$CURL_LOG"
    env STAGE_FN="$STAGE_FN" FW_FIXTURE="$FW_FIXTURE" CURL_LOG="$CURL_LOG" \
        REPO_RAW="https://raw.example.test/oxpulse-partner-edge/main" \
        INSTALL_LIB_DIR="$TMP/nonexistent-installdir" \
        CKFILE="$1" OXPULSE_UPGRADE_NO_INTEGRITY="$2" DEST="$_dest" \
        bash "$HARNESS" 2>&1 || true   # die() exits non-zero by design; assert on RESULT text
}

# T3-TLS: the tier-3 curl must be TLS-pinned (--proto =https --tlsv1.2).
_out=$(_stage3 "$CK_MATCH" 0)
if grep -q -- '--proto =https' "$CURL_LOG" && grep -q -- '--tlsv1.2' "$CURL_LOG"; then
    pass "T3-TLS: tier-3 fetch is TLS-pinned (--proto =https --tlsv1.2)"
else
    fail "T3-TLS: tier-3 curl missing TLS pin; log: $(cat "$CURL_LOG")"
fi

# T3-MATCH: correct checksum → stages.
if echo "$_out" | grep -q 'STAGED'; then
    pass "T3-MATCH: checksum match => lib staged"
else
    fail "T3-MATCH: expected STAGED with matching checksum; got: $_out"
fi

# T3-MISMATCH: tampered checksum → die (refuses to stage untrusted code).
_out=$(_stage3 "$CK_BAD" 0)
if echo "$_out" | grep -qi 'checksum mismatch'; then
    pass "T3-MISMATCH: checksum mismatch => die (tamper refused, no stage)"
else
    fail "T3-MISMATCH: expected checksum-mismatch die; got: $_out"
fi

# T3-NOENTRY: manifest resolved but OMITS this file + no override → fail-closed die.
# Deliberately stricter than install.sh (which fails OPEN here); must MATCH _source_lib's
# no-entry contract (review HIGH — the two tier-3 resolvers must not diverge). A truncated
# / captive-portal / stale manifest must never silently stage a root-sourced lib.
_out=$(_stage3 "$CK_NOENTRY" 0)
if echo "$_out" | grep -qi 'without a verified checksum is unsafe'; then
    pass "T3-NOENTRY: manifest omits entry + no override => fail-closed die (matches _source_lib)"
else
    fail "T3-NOENTRY: expected fail-closed die for unlisted lib; got: $_out"
fi

# T3-NOENTRY-OVERRIDE: manifest omits entry + OXPULSE_UPGRADE_NO_INTEGRITY=1 → stages (risk accepted).
_out=$(_stage3 "$CK_NOENTRY" 1)
if echo "$_out" | grep -q 'STAGED'; then
    pass "T3-NOENTRY-OVERRIDE: OXPULSE_UPGRADE_NO_INTEGRITY=1 stages an unlisted lib (escape hatch)"
else
    fail "T3-NOENTRY-OVERRIDE: expected STAGED with override; got: $_out"
fi

# T3-NOCK-FAILCLOSED: no checksums anywhere + no override → fail-closed die.
_out=$(_stage3 "" 0)
if echo "$_out" | grep -qi 'without a lib-checksums.txt is unsafe'; then
    pass "T3-NOCK-FAILCLOSED: no checksums + no override => fail-closed die"
else
    fail "T3-NOCK-FAILCLOSED: expected fail-closed die; got: $_out"
fi

# T3-NOCK-OVERRIDE: no checksums + OXPULSE_UPGRADE_NO_INTEGRITY=1 → stages (risk accepted).
_out=$(_stage3 "" 1)
if echo "$_out" | grep -q 'STAGED'; then
    pass "T3-NOCK-OVERRIDE: OXPULSE_UPGRADE_NO_INTEGRITY=1 bypasses verify (escape hatch)"
else
    fail "T3-NOCK-OVERRIDE: expected STAGED with override; got: $_out"
fi

echo ""
echo "=== BUG1 transitive-stage tests: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
