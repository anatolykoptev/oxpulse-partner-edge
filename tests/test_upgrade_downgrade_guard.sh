#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# _assert_apply_not_downgrade — the guard that refuses a derived upgrade
# against an unversioned current state (#612 / PR #614).
# ---------------------------------------------------------------------------
# Why this file exists: the guard shipped ungated.  Deleting its five lines
# outright left every other suite in the repo green, so nothing detected the
# difference between "refuses a silent downgrade" and "does not exist".
#
# Two failure directions, and BOTH must be covered — they pull opposite ways:
#
#   too permissive — CURRENT unversioned (`stable`, the installer default at
#     lib/install-args.sh:130, or `latest`/`unknown`) means _conflict_check_3
#     cannot rank the two sides and records only WARNING, so a DERIVED target
#     taken from this script's baked tag can silently move the edge BACKWARDS.
#
#   too strict — refusing an EXPLICIT tag bricks the fleet.  Both writers that
#     make CURRENT comparable (upgrade.sh:3742, :3995) run downstream of this
#     guard, so the explicit-tag run is the only thing that can record a
#     version.  Refuse it and there is no exit from the unversioned state, on
#     either apply path.  That is the bootstrap refresh.sh:363-366 prescribes.
#
# The real functions are awk-extracted from upgrade.sh and sourced — a replica
# of their logic defined here would drift silently and assert nothing.
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UPGRADE="$REPO_ROOT/upgrade.sh"

FAIL=0
_MARK=0
pass() {
    if [[ $FAIL -ne $_MARK ]]; then _MARK=$FAIL; return 0; fi
    echo "OK: $*"
}
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
fail_exit() { echo "FAIL: $*" >&2; exit 1; }

_dir=$(mktemp -d)
trap 'rm -rf "$_dir"' EXIT
_stub="$_dir/guard.sh"

{
    echo 'die() { echo "REFUSED: $*"; exit 9; }'
    awk '/^_conflict_check_3\(\)/{f=1} f{print} /^}$/ && f{exit}' "$UPGRADE"
    awk '/^_assert_apply_not_downgrade\(\)/{f=1} f{print} /^}$/ && f{exit}' "$UPGRADE"
} > "$_stub"

grep -q '^_assert_apply_not_downgrade()' "$_stub" \
    || fail_exit "extraction missing _assert_apply_not_downgrade — the awk pattern no longer matches upgrade.sh"
grep -q '^_conflict_check_3()' "$_stub" \
    || fail_exit "extraction missing _conflict_check_3"
# The stub must NOT carry its own SKIPPED_CHECKS assignment: one did, and it
# shadowed the caller's value, making the escape hatch look broken.
grep -q '^SKIPPED_CHECKS=' "$_stub" \
    && fail_exit "extraction picked up a SKIPPED_CHECKS assignment — it would shadow the caller"
bash -n "$_stub" || fail_exit "extracted stub is not valid bash"

# run <explicit> <current> <tag> [skipped] -> prints PROCEEDS or REFUSED
run() {
    TARGET_EXPLICIT="$1" CURRENT="$2" RELEASE_TAG="$3" SKIPPED_CHECKS="${4:-}" \
        bash -c "set -uo pipefail; source '$_stub'; _assert_apply_not_downgrade && echo PROCEEDS" 2>&1
}

expect() {
    local want="$1" explicit="$2" cur="$3" tag="$4" skip="${5:-}" label="$6" got
    local raw
    raw=$(run "$explicit" "$cur" "$tag" "$skip")
    # First line via parameter expansion, never a piped early-exit reader:
    # under pipefail it SIGPIPEs the producer and the status flips on success.
    got="${raw%%$'\n'*}"
    case "$got" in
        "$want"*) ;;
        *) fail "$label — expected $want, got: $got" ;;
    esac
}

echo "--- G1: a DERIVED target against an unversioned CURRENT is refused ---"
# The installer default is `stable`; `latest` and `unknown` reach here too.
for cur in stable latest unknown; do
    expect REFUSED 0 "$cur" v0.16.24 "" "G1: derived v0.16.24 vs CURRENT=$cur must refuse"
done
pass "G1: derived target refused against stable/latest/unknown"

echo "--- G2: an EXPLICIT tag is NOT refused — this is the bootstrap ---"
# Regression guard for the blocker: gating on comparability alone (rather than
# provenance) refused this too, leaving the fleet no way to record a version.
for cur in stable latest unknown; do
    expect PROCEEDS 1 "$cur" v0.16.24 "" "G2: explicit v0.16.24 vs CURRENT=$cur must proceed (bootstrap)"
done
pass "G2: explicit tag proceeds against stable/latest/unknown"

echo "--- G3: a real downgrade between comparable versions is still refused ---"
expect REFUSED 1 v0.16.24 v0.15.0 "" "G3: explicit downgrade must still refuse"
expect REFUSED 0 v0.16.24 v0.15.0 "" "G3: derived downgrade must still refuse"
pass "G3: comparable downgrade refused regardless of provenance"

echo "--- G4: a genuine upgrade proceeds ---"
expect PROCEEDS 1 v0.16.24 v0.17.0 "" "G4: explicit upgrade must proceed"
expect PROCEEDS 0 v0.16.24 v0.17.0 "" "G4: derived upgrade must proceed"
pass "G4: comparable upgrade proceeds regardless of provenance"

echo "--- G5: explicit 'latest' is unaffected in both directions ---"
expect PROCEEDS 1 latest    latest "" "G5: latest vs latest must proceed"
expect PROCEEDS 1 v0.16.24  latest "" "G5: latest vs a pinned CURRENT must proceed"
pass "G5: explicit latest proceeds"

echo "--- G6: --skip-check=3 forces, other skips do not ---"
expect PROCEEDS 0 stable v0.16.24 " 3 "   "G6: skip-check=3 must force"
expect PROCEEDS 0 stable v0.16.24 " 1 3 " "G6: skip-check=1,3 must force"
expect REFUSED  0 stable v0.16.24 " 2 "   "G6: skip-check=2 must NOT bypass check 3"
pass "G6: escape hatch is scoped to check 3"

echo "--- G7: the function does not require its caller to define TARGET_EXPLICIT ---"
# A sibling suite extracts this function into a stub that never sets the flag.
# Under `set -u` a bare reference kills it before any case runs; the default
# must hold, and must default to the STRICTER (derived) branch.
_g7_raw=$( CURRENT=stable RELEASE_TAG=v0.16.24 SKIPPED_CHECKS="" \
    bash -c "set -uo pipefail; source '$_stub'; _assert_apply_not_downgrade && echo PROCEEDS" 2>&1 )
_g7="${_g7_raw%%$'\n'*}"
case "$_g7" in
    REFUSED*)  ;;
    *unbound*) fail "G7: TARGET_EXPLICIT unset kills the function under set -u — $_g7" ;;
    *)         fail "G7: TARGET_EXPLICIT unset did not default to the strict branch — $_g7" ;;
esac
pass "G7: TARGET_EXPLICIT unset defaults to derived (strict), function survives set -u"

if [[ $FAIL -ne 0 ]]; then
    echo "FAIL: downgrade guard — one or more checks failed" >&2
    exit 1
fi
echo "All downgrade guard tests passed."
