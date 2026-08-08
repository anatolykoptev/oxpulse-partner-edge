#!/usr/bin/env bash
# tests/test_shell_test_runner_is_single_source.sh
#
# scripts/run-shell-tests.sh exists so that CI and a developer's machine
# enumerate the SAME shell tests. That property is worth exactly as much as
# whatever keeps it true — and the obvious way to lose it is for someone to
# paste the loop back into ci.yml, or to add a job that enumerates its own set.
# Both look harmless in a diff and both restore the original failure mode:
# green locally, red in CI, discovered 243 seconds later.
#
# So this asserts the wiring, not the runner's internals.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$REPO_ROOT/scripts/run-shell-tests.sh"
CI="$REPO_ROOT/.github/workflows/ci.yml"
MK="$REPO_ROOT/Makefile"
fails=0
_fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }
_ok()   { echo "  ok: $*"; }

# ---------------------------------------------------------------------------
# S1. The runner exists and is executable. Anti-vacuous floor: every later
# assertion refers to it, so if it is missing they would be checking nothing.
# ---------------------------------------------------------------------------
if [[ ! -f "$RUNNER" ]]; then
    _fail "S1: $RUNNER is missing — every assertion below would be vacuous"
    echo "RESULT: $fails failure(s)"; exit 1
fi
[[ -x "$RUNNER" ]] && _ok "S1: runner present and executable" \
                   || _fail "S1: runner is not executable — CI invokes it directly"

# ---------------------------------------------------------------------------
# S2. --list resolves a real, substantial set. A runner that enumerates nothing
# would make check-sh pass instantly and prove nothing, which is the exact
# false-green this file guards.
# ---------------------------------------------------------------------------
listing=$("$RUNNER" --list 2>/dev/null)
plain_n=$(awk '/^plain-bash:/{p=1;next} /^bats:/{p=0} p && /^  [^S]/ {n++} END{print n+0}' <<<"$listing")
bats_n=$(awk  '/^bats:/{p=1;next} p && /^  [^S]/ {n++} END{print n+0}' <<<"$listing")
if (( plain_n < 80 )); then
    _fail "S2: only $plain_n plain-bash tests enumerated (expected >= 80) — the glob is not resolving"
else
    _ok "S2: $plain_n plain-bash + $bats_n bats tests enumerated"
fi

# ---------------------------------------------------------------------------
# S3. CI calls the runner for BOTH halves.
# ---------------------------------------------------------------------------
for flag in --plain --bats; do
    if grep -qF "run-shell-tests.sh $flag" "$CI"; then
        _ok "S3: ci.yml invokes the runner with $flag"
    else
        _fail "S3: ci.yml does not invoke scripts/run-shell-tests.sh $flag"
    fi
done

# ---------------------------------------------------------------------------
# S4. THE ONE THAT MATTERS — no workflow enumerates tests on its own.
#
# A re-inlined `for f in tests/test_*.sh` loop is how this regresses, and it
# reads as a perfectly ordinary CI tweak.
# ---------------------------------------------------------------------------
inliners=""
for wf in "$REPO_ROOT"/.github/workflows/*.yml; do
    if grep -qE 'for [a-z]+ in tests/test_\*\.sh' "$wf"; then
        inliners+=" $(basename "$wf")"
    fi
done
if [[ -n "$inliners" ]]; then
    _fail "S4: workflow(s) enumerate tests inline instead of calling the runner:$inliners"
else
    _ok "S4: no workflow enumerates tests/test_*.sh itself"
fi

# ---------------------------------------------------------------------------
# S5. `make check` actually depends on the shell suite. Without this the
# runner exists, CI uses it, and the documented pre-PR gate still skips it —
# which was the state this change set out to fix.
# ---------------------------------------------------------------------------
check_rule=$(awk '/^check:/ { print; exit }' "$MK")
if [[ -z "$check_rule" ]]; then
    _fail "S5: no 'check:' target in the Makefile"
elif [[ "$check_rule" != *check-sh* ]]; then
    _fail "S5: 'check' does not depend on check-sh — the pre-PR gate still skips 190 shell tests (got: $check_rule)"
else
    _ok "S5: make check depends on check-sh ($check_rule)"
fi

# ---------------------------------------------------------------------------
# S6. A stale skip entry fails the run, behaviourally. An exclusion naming a
# file that no longer exists protects nothing while reading as a known issue.
# ---------------------------------------------------------------------------
tmp_runner="$(mktemp)"
trap 'rm -f "$tmp_runner"' EXIT
sed 's|^PLAIN_SKIP=.*|PLAIN_SKIP="test_this_file_does_not_exist.sh"|' "$RUNNER" > "$tmp_runner"
chmod +x "$tmp_runner"
out=$(bash "$tmp_runner" --list 2>&1); rc=$?
if (( rc == 0 )); then
    _fail "S6: a skip entry naming a nonexistent file was accepted (rc=0)"
elif [[ "$out" != *"does not exist"* ]]; then
    _fail "S6: rejected but without naming the stale entry (got: $out)"
else
    _ok "S6: a stale skip entry fails the run and is named"
fi

# ---------------------------------------------------------------------------
# S7. Every real skip entry names a file that exists — checked against the
# runner as shipped, not the mutated copy above.
# ---------------------------------------------------------------------------
if "$RUNNER" --list >/dev/null 2>&1; then
    _ok "S7: shipped skip lists reference only existing files"
else
    _fail "S7: the shipped runner rejects its own skip lists"
fi

echo
if (( fails == 0 )); then echo "RESULT: all checks passed"; exit 0; fi
echo "RESULT: $fails failure(s)"; exit 1
