#!/bin/bash
# tests/test_pipefail_early_exit_guard.sh
#
# Regression guard: no new early-exit pipelines may appear in tests/ files
# that set `set -o pipefail` / `set -euo pipefail`.
#
# Under pipefail, a pipe into an early-exiting consumer (grep -q, head -N)
# can propagate the producer's SIGPIPE (141) as the pipeline's exit status,
# turning a passing assertion into a flaky failure.  This guard prevents the
# class from regrowing after the sweep in PR #503.
#
# Three checks:
#
#   1. grep -q (any flag cluster containing q): ZERO allowed.  Any piped
#      `| grep -q...` in a pipefail test file is a hard failure.  The fix
#      is `| grep ... >/dev/null` (grep drains stdin fully, no SIGPIPE).
#
#   2. head -N (early-exiting consumer, same SIGPIPE class): a known
#      baseline of 94 existing sites is allowed (they predate the guard
#      and sweeping them is out of scope for this PR).  The baseline is
#      read from tests/pipefail_early_exit_baseline.txt — a plain file
#      with `file_path count` per line.  The guard fails when a file's
#      actual count EXCEEDS its baseline count (a new site appeared) or
#      when a file has sites but no baseline entry at all.
#
#      Per-file counts (not line numbers) are used.  What this actually
#      guarantees: a NET increase in any one file is caught.  What it does
#      NOT catch: a substitution within a file (remove a benign
#      `echo x | head -1`, add a flake-capable `ip route show | head -1`
#      — same count, passes), or a move into a file that has slack under
#      its baseline.  Per-file counts are precisely the mechanism that
#      lets an in-file swap consume the budget; do not read this check as
#      stronger than that.
#
#   3. Floor on pipefail files scanned: if REPO_ROOT or the tests/test_*.sh
#      glob ever drifts so the scan set is empty (or near-empty), checks 1
#      and 2 trivially pass and every defect in this guard becomes
#      undiagnosable.  The floor hard-fails below a count well under the
#      current 127 pipefail files but far above zero.
#
# Exclusions:
#   - Comment lines (leading #) are skipped — they describe idioms, not
#     execute them.
#   - Lines containing CMD-SHELL are skipped — the `| grep -q` inside
#     `test: ["CMD-SHELL", "ss -ltn | grep -q ':3080' || exit 1"]` is a
#     string literal inside a YAML heredoc, not a real shell pipe.
#   - `||` (logical OR) is not a pipe: the pattern requires a single `|`
#     preceded by a non-`|` character.
#   - healthcheck.sh is not in tests/ and is not scanned; its piped
#     grep -q run inside `bash -c '...'` children that do not inherit
#     pipefail, so it is immune by construction.
#
# This file is picked up automatically by ci.yml's `installer-bash-tests`
# job (it iterates tests/test_*.sh with `bash "$f"`).

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BASELINE="tests/pipefail_early_exit_baseline.txt"

# Work from REPO_ROOT so file paths match the baseline's relative paths.
cd "$REPO_ROOT"

FAIL=0

# Counters for computed summary output (never print literals — a number in
# guard output that cannot change is worse than no number).
PIPEFAIL_FILES_SCANNED=0
GREPQ_SITES_TOTAL=0
HEAD_SITES_TOTAL=0

# Floor on pipefail files scanned.  127 of 173 tests/test_*.sh set pipefail
# today; floor of 80 tolerates ~37% legitimate removal while catching a
# REPO_ROOT/glob drift that scans ~0 — the exact failure class this guard
# exists to prevent, reproduced inside the guard itself if REPO_ROOT ever
# points at an empty tree.  Without this floor the guard reports clean
# forever and every other defect in it becomes undiagnosable.
PIPEFAIL_FILES_FLOOR=80

# ---------------------------------------------------------------------------
# Helper: count real piped early-exit consumers in a file.
#
# $1 = file path
# $2 = consumer regex (matched after the pipe, e.g. 'grep -[A-Za-z]*q' or 'head')
#
# Excludes comment lines and CMD-SHELL string literals.  Matches a single
# pipe `|` (not `||`) preceded by a non-`|` character.
# ---------------------------------------------------------------------------
count_piped_consumers() {
    local file="$1"
    local consumer_re="$2"
    # [^|] ensures we match a single pipe, not || (logical OR).
    # The consumer regex is anchored right after `|` + optional whitespace.
    # || true masks pipefail's non-zero propagation when grep -nE finds no
    # matches (exit 1) — wc -l still emits the correct count on stdout.
    grep -nE "[^|]\\| *${consumer_re}" "$file" 2>/dev/null \
        | grep -vE '^[[:space:]]*[0-9]+:[[:space:]]*#' \
        | grep -v 'CMD-SHELL' \
        | wc -l \
        || true
}

# ---------------------------------------------------------------------------
# Check 1: piped grep -q (q anywhere in the flag cluster) — zero allowed.
# ---------------------------------------------------------------------------
echo "==> Check 1: no piped grep -q in pipefail test files"
GREPQ_VIOLATIONS=""
for f in tests/test_*.sh; do
    # Only scan files that set pipefail.
    grep -qE '(^|;)[[:space:]]*set[[:space:]].*pipefail' "$f" 2>/dev/null || continue
    PIPEFAIL_FILES_SCANNED=$((PIPEFAIL_FILES_SCANNED + 1))
    n=$(count_piped_consumers "$f" 'grep -[A-Za-z]*q[A-Za-z]*')
    GREPQ_SITES_TOTAL=$((GREPQ_SITES_TOTAL + n))
    if [ "$n" -gt 0 ]; then
        GREPQ_VIOLATIONS="${GREPQ_VIOLATIONS}$(printf '%s\n' "$f ($n):")"
        grep -nE "[^|]\\| *grep -[A-Za-z]*q[A-Za-z]*" "$f" 2>/dev/null \
            | grep -vE '^[[:space:]]*[0-9]+:[[:space:]]*#' \
            | grep -v 'CMD-SHELL' \
            | sed "s|^|    $f:|" >> /tmp/grepq_violations.txt
        FAIL=1
    fi
done
if [ "$FAIL" -ne 0 ]; then
    echo "FAIL: ${GREPQ_SITES_TOTAL} piped grep -q sites found in pipefail test files:" >&2
    cat /tmp/grepq_violations.txt >&2 2>/dev/null || true
    rm -f /tmp/grepq_violations.txt
else
    echo "OK: ${GREPQ_SITES_TOTAL} piped grep -q sites in ${PIPEFAIL_FILES_SCANNED} pipefail test files"
fi
rm -f /tmp/grepq_violations.txt

# ---------------------------------------------------------------------------
# Check 2: piped head — must not exceed baseline counts.
# ---------------------------------------------------------------------------
echo "==> Check 2: piped head count does not exceed baseline"
if [ ! -f "$BASELINE" ]; then
    echo "FAIL: baseline file not found: $BASELINE" >&2
    exit 1
fi

# Build associative array of baseline counts.
declare -A BASELINE_COUNTS
while IFS=' ' read -r path count; do
    [ -n "$path" ] || continue
    BASELINE_COUNTS["$path"]="$count"
done < "$BASELINE"

HEAD_FAIL=0
for f in tests/test_*.sh; do
    grep -qE '(^|;)[[:space:]]*set[[:space:]].*pipefail' "$f" 2>/dev/null || continue
    n=$(count_piped_consumers "$f" 'head')
    HEAD_SITES_TOTAL=$((HEAD_SITES_TOTAL + n))
    if [ "$n" -eq 0 ]; then
        continue
    fi
    base="${BASELINE_COUNTS["$f"]:-0}"
    if [ "$n" -gt "$base" ]; then
        echo "FAIL: $f has $n piped head sites (baseline: $base) — new early-exit pipeline introduced" >&2
        grep -nE "[^|]\\| *head" "$f" 2>/dev/null \
            | grep -vE '^[[:space:]]*[0-9]+:[[:space:]]*#' \
            | grep -v 'CMD-SHELL' \
            | sed 's/^/    /' >&2
        HEAD_FAIL=1
    fi
done

if [ "$HEAD_FAIL" -ne 0 ]; then
    FAIL=1
else
    echo "OK: piped head counts within baseline (${HEAD_SITES_TOTAL} sites across ${#BASELINE_COUNTS[@]} baseline files)"
fi

# ---------------------------------------------------------------------------
# Check 3: floor on pipefail files scanned — guards against REPO_ROOT/glob
# drift producing an empty scan set (the guard would otherwise report clean
# forever, masking every other defect in it).
# ---------------------------------------------------------------------------
echo "==> Check 3: pipefail files scanned >= floor (${PIPEFAIL_FILES_FLOOR})"
if [ "$PIPEFAIL_FILES_SCANNED" -lt "$PIPEFAIL_FILES_FLOOR" ]; then
    echo "FAIL: scanned ${PIPEFAIL_FILES_SCANNED} pipefail test files, floor is ${PIPEFAIL_FILES_FLOOR} — REPO_ROOT or tests/test_*.sh glob likely drifted; guard would report clean on an empty scan set" >&2
    FAIL=1
else
    echo "OK: scanned ${PIPEFAIL_FILES_SCANNED} pipefail test files (floor ${PIPEFAIL_FILES_FLOOR})"
fi

# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------
if [ "$FAIL" -ne 0 ]; then
    echo "FAIL: pipefail early-exit guard violations detected" >&2
    exit 1
fi
echo "PASS: pipefail early-exit guard clean"



