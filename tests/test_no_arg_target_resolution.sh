#!/bin/bash
# tests/test_no_arg_target_resolution.sh — issue #612: no-arg target resolution.
#
# Defect: resolve_default_target (upgrade.sh:973-984) is wrong on both branches:
#   • VERSION missing → TARGET=latest.  CURRENT also reads latest, they compare
#     equal, and the run exits "already on latest — nothing to do" having
#     transferred nothing.  Every probed edge (ruoxp, rvpn, zvonilka) has no
#     VERSION file, so this is the normal path, not an edge case.
#   • VERSION present → awk yields bare 0.16.24; normalize_target never adds a
#     v prefix, so the release URL 404s against the real v0.16.24 tag.
#
# The correct value is already in the script: OXPULSE_UPGRADE_TAG (upgrade.sh:143)
# is substituted by release.yml at publish time and carries v0.16.24 on every
# probed edge.  resolve_default_target never consulted it.
#
# This test file covers:
#   F1 — a no-arg invocation on a host with no VERSION file resolves to the tag
#        baked into the script, not to latest.  Asserts DELIVERY (CURRENT !=
#        TARGET), not an exit code — the bug's shape is success that delivers
#        nothing.
#   F2 — a bare X.Y.Z target acquires the v prefix so the release URL does not
#        404.  Asserts the real release tag form (^v[0-9]+\.[0-9]+\.[0-9]+),
#        not a constant.
#   F3 — latest stays reachable when the operator types it explicitly.
#
# The real resolve_default_target and normalize_target are awk-extracted from
# upgrade.sh and sourced — a replica would drift from the original silently and
# assert nothing.  Same extraction pattern as test_upgrade_tag_form.sh and
# test_hy2_server_resolution.sh.
#
# Harness: set -uo pipefail with NO -e (a stray set -e after a capture changes
# behaviour for everything below it).  Inner subshells may use set -euo
# pipefail because they are isolated.
set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
UPGRADE="$REPO_ROOT/upgrade.sh"

[[ -f "$UPGRADE" ]] || { echo "FAIL: upgrade.sh not found at $UPGRADE"; exit 1; }

pass() { echo "OK: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Extract the REAL resolve_default_target + normalize_target + derive_release_tag
# alias from upgrade.sh into a preamble that can be sourced in a subshell.
# Stubs for log/warn/die so the functions can emit their messages without the
# full upgrade.sh environment.  BASH_SOURCE[0] inside the sourced preamble
# points at the temp file, so resolve_default_target's VERSION-file lookup
# searches a temp dir that has no VERSION file — the exact state of every
# probed live edge.
# ---------------------------------------------------------------------------
PREAMBLE=$(mktemp /tmp/no-arg-target-preamble-XXXXXX.sh)
# shellcheck disable=SC2064
trap "rm -f '$PREAMBLE'" EXIT

{
    printf 'log()  { printf "==> %%s\\n" "$*" >&2; }\n'
    printf 'warn() { printf "!! %%s\\n"  "$*" >&2; }\n'
    printf 'die()  { printf "ERR %%s\\n" "$*" >&2; exit 1; }\n'
    awk '/^resolve_default_target\(\)/{found=1} found{print} /^}$/ && found{exit}' "$UPGRADE"
    awk '/^normalize_target\(\)/{found=1} found{print} /^}$/ && found{exit}' "$UPGRADE"
    grep '^derive_release_tag()' "$UPGRADE" || true
} > "$PREAMBLE"
bash -n "$PREAMBLE" || fail "preamble has syntax errors — extraction is wrong"
pass "preamble syntax clean (real functions extracted from upgrade.sh)"

# Couple the test to the real code: the extracted preamble must contain both
# function definitions, not empty stubs.
grep -q '^resolve_default_target()' "$PREAMBLE" \
    || fail "extraction missing resolve_default_target"
grep -q '^normalize_target()' "$PREAMBLE" \
    || fail "extraction missing normalize_target"

# ---------------------------------------------------------------------------
# F1 — no-arg, no VERSION file → resolves to the baked tag, not latest.
# ---------------------------------------------------------------------------
# Mutation target: in upgrade.sh, delete the OXPULSE_UPGRADE_TAG branch from
# resolve_default_target so control falls through to TARGET=latest.  This test
# goes RED because no file was delivered (CURRENT == TARGET == latest → the
# "already on latest — nothing to do" gate fires), NOT because a string differs.
# ---------------------------------------------------------------------------
echo "--- F1: no-arg + no VERSION → baked tag, not latest (delivery assertion) ---"

_f1_result=$(
    _PREAMBLE="$PREAMBLE" bash <<'INNER'
set -uo pipefail
# Simulate a live edge: image pulled as :latest, no CLI arg, baked tag.
CURRENT=latest
TARGET=""
OXPULSE_UPGRADE_TAG=v0.16.24
source "$_PREAMBLE"
resolve_default_target
normalize_target
# The "already on $TARGET — nothing to do" gate (upgrade.sh:3871):
# if CURRENT == TARGET the run exits having delivered nothing.
if [[ "$CURRENT" == "$TARGET" ]]; then
    printf 'NO_DELIVERY|current=%s target=%s' "$CURRENT" "$TARGET"
else
    printf 'DELIVERS|current=%s target=%s release_tag=%s' "$CURRENT" "$TARGET" "$RELEASE_TAG"
fi
INNER
)

if [[ "$_f1_result" == NO_DELIVERY* ]]; then
    fail "F1: no file delivered — $_f1_result (CURRENT==TARGET, run exits 'already on latest — nothing to do')"
fi
# Extract the resolved target from the DELIVERS line and confirm it is the
# baked tag, not latest.
_f1_target=$(echo "$_f1_result" | sed 's/.*target=\([^ ]*\).*/\1/')
if [[ "$_f1_target" == "latest" ]]; then
    fail "F1: TARGET resolved to 'latest' instead of the baked tag — $_f1_result"
fi
if [[ ! "$_f1_target" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    fail "F1: TARGET '$_f1_target' is not a real release tag form (^vX.Y.Z) — $_f1_result"
fi
pass "F1: no-arg + no VERSION → TARGET=$_f1_target (baked tag), CURRENT=latest → delivery happens"

# ---------------------------------------------------------------------------
# F1b — the UNSUBSTITUTED sentinel must not be accepted as a tag.
# ---------------------------------------------------------------------------
# This is the entire justification for testing OXPULSE_UPGRADE_TAG with
# `=~ ^v[0-9]+\.` rather than a string compare, and without this case the
# property is unasserted: broadening the regex to `=~ .` leaves every other
# test in this file and in test_upgrade_tag_form.sh green.
#
# Mutation target: in upgrade.sh, broaden resolve_default_target's
# OXPULSE_UPGRADE_TAG test to `=~ .` → this test goes RED because the raw
# sentinel is adopted as TARGET and the release URL would 404.
# ---------------------------------------------------------------------------
echo "--- F1b: the unsubstituted sentinel is rejected, not adopted ---"

_f1b_target=$(
    _PREAMBLE="$PREAMBLE" bash <<'INNER'
set -uo pipefail
# A source checkout, or an artifact release.yml never sed'd: the placeholder is
# still literal. Note the value is assembled at runtime so this test file cannot
# itself be rewritten by release.yml's global sed.
CURRENT=latest
TARGET=""
OXPULSE_UPGRADE_TAG="@RELEASE_$(printf 'TAG')@"
source "$_PREAMBLE"
resolve_default_target
printf '%s' "$TARGET"
INNER
)

case "$_f1b_target" in
    *RELEASE_TAG*)
        fail "F1b: the unsubstituted sentinel was adopted as TARGET ('$_f1b_target') — a real tag test is missing" ;;
    latest)
        pass "F1b: unsubstituted sentinel rejected → fell through to 'latest' as designed" ;;
    *)
        # A VERSION file next to the extracted preamble would also be legitimate;
        # anything except the sentinel means the guard held.
        pass "F1b: unsubstituted sentinel rejected → TARGET=$_f1b_target" ;;
esac

# ---------------------------------------------------------------------------
# F2 — a bare X.Y.Z target acquires the v prefix.
# ---------------------------------------------------------------------------
# Mutation target: in upgrade.sh, remove the bare-version case from
# normalize_target.  RED must be the resulting tag form: RELEASE_TAG=0.16.24
# (no v) does not match ^v[0-9]+\.[0-9]+\.[0-9]+ and the release URL 404s.
# The assertion compares against the real release tag FORM (the same ^v[0-9]+
# regex upgrade.sh:186/465 uses), not a constant — and confirms the bare
# version is preserved under the prefix.
# ---------------------------------------------------------------------------
echo "--- F2: bare X.Y.Z → v-prefixed release tag form ---"

_bare_input="0.16.24"
_f2_result=$(
    _PREAMBLE="$PREAMBLE" bash <<'INNER'
set -uo pipefail
TARGET=0.16.24
OXPULSE_UPGRADE_TAG="@RELEASE_TAG@"
source "$_PREAMBLE"
normalize_target
printf '%s' "$RELEASE_TAG"
INNER
)

# Must match the real release tag form — same regex as upgrade.sh:186/465.
if [[ ! "$_f2_result" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "   got RELEASE_TAG='$_f2_result' (expected ^v[0-9]+\\.[0-9]+\\.[0-9]+\$)" >&2
    fail "F2: bare $_bare_input did not acquire v prefix — RELEASE_TAG='$_f2_result' is not real release tag form"
fi
# The bare version must be preserved under the prefix (v + bare == RELEASE_TAG).
if [[ "${_f2_result#v}" != "$_bare_input" ]]; then
    fail "F2: v-prefix mangled the version — RELEASE_TAG='$_f2_result', v-stripped='${_f2_result#v}' != input '$_bare_input'"
fi
# Negative: the bare form must NOT survive (that is the 404 path).
if [[ "$_f2_result" == "$_bare_input" ]]; then
    fail "F2: RELEASE_TAG is still bare '$_bare_input' — release URL would 404"
fi
pass "F2: bare $_bare_input → RELEASE_TAG=$_f2_result (real release tag form, v-prefix added)"

# ---------------------------------------------------------------------------
# F3 — latest stays reachable when the operator types it explicitly.
# ---------------------------------------------------------------------------
# Mutation target: (a) remove the [[ -n "$TARGET" ]] guard from
# resolve_default_target so OXPULSE_UPGRADE_TAG overrides an explicit latest,
# OR (b) add a latest→v* conversion in normalize_target.  Either mutation makes
# this test RED: TARGET or RELEASE_TAG would no longer be 'latest'.
# ---------------------------------------------------------------------------
echo "--- F3: explicit 'latest' stays reachable ---"

_f3_result=$(
    _PREAMBLE="$PREAMBLE" bash <<'INNER'
set -uo pipefail
CURRENT=v0.16.24
TARGET=latest
OXPULSE_UPGRADE_TAG=v0.16.24
source "$_PREAMBLE"
resolve_default_target
normalize_target
printf '%s|%s' "$TARGET" "$RELEASE_TAG"
INNER
)
_f3_target="${_f3_result%%|*}"
_f3_rtag="${_f3_result#*|}"

if [[ "$_f3_target" != "latest" ]]; then
    fail "F3: explicit TARGET=latest was overridden to '$_f3_target' by resolve_default_target — the [[ -n \$TARGET ]] guard is missing"
fi
if [[ "$_f3_rtag" != "latest" ]]; then
    fail "F3: RELEASE_TAG='$_f3_rtag' (expected 'latest') — normalize_target mangled the explicit floating tag"
fi
pass "F3: explicit 'latest' stays TARGET=latest, RELEASE_TAG=latest (operator choice reachable)"

echo
echo "All no-arg target resolution tests passed."
