#!/bin/bash
# tests/test_sourced_sibling_delivery.sh
#
# Class guard: every file a shipped sbin script sources as a SAME-DIR sibling
# must itself be in the delivery list (_HOST_SCRIPT_SBIN_FILES) AND in the
# release asset set (release.yml SHA256SUMS staging + gh release upload).
#
# The invariant catches the bug class, not one instance: a sourced helper that
# resolves via dirname("${BASH_SOURCE[0]}"/"$0")/<name>.sh lands in PREFIX_SBIN
# on a live node. If that helper is not itself synced by sync_host_scripts, the
# source fails on every existing edge after upgrade — the renderer silently
# degrades (warn + fallback) and/or the rotator exit 1s every night. A test
# that only knows about a specific filename does not catch the next extraction.
#
# The sourced-sibling set is DERIVED from the scripts (grep for the dirname-
# relative same-dir .sh source pattern), never hardcoded.
#
# Neighbour style: tests/test_upgrade_syncs_host_scripts.sh (plain bash,
# PASS/FAIL counters, extract helpers from upgrade.sh via awk).
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
UPGRADE="$REPO_ROOT/upgrade.sh"
RELEASE_YML="$REPO_ROOT/.github/workflows/release.yml"

[[ -f "$UPGRADE"   ]] || { echo "FAIL: upgrade.sh not found at $UPGRADE"; exit 1; }
[[ -f "$RELEASE_YML" ]] || { echo "FAIL: release.yml not found at $RELEASE_YML"; exit 1; }

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# ---------------------------------------------------------------------------
# Extract _HOST_SCRIPT_SBIN_FILES (skip comment/blank lines).
# ---------------------------------------------------------------------------
mapfile -t SBIN_FILES < <(
    awk '/^_HOST_SCRIPT_SBIN_FILES=\(/{f=1;next} f&&/^\)$/{exit} f{
        gsub(/#.*/,""); gsub(/^[[:space:]]+/,""); gsub(/[[:space:]]+$/,"");
        if(length($0)>0) print
    }' "$UPGRADE"
)
[[ "${#SBIN_FILES[@]}" -gt 0 ]] \
    && pass "extracted _HOST_SCRIPT_SBIN_FILES (${#SBIN_FILES[@]} entries)" \
    || { fail "_HOST_SCRIPT_SBIN_FILES extracted empty"; exit 1; }

# ---------------------------------------------------------------------------
# Extract _host_script_remote_name from upgrade.sh so we can resolve each
# shipped sbin name to its repo path (the file we actually read for sources).
# ---------------------------------------------------------------------------
REMOTE_NAME_FN="$REPO_ROOT/.remote_name_fn.tmp.$$"
awk '/^_host_script_remote_name\(\)/{f=1} f{print} f&&/^}$/{exit}' "$UPGRADE" > "$REMOTE_NAME_FN"
trap 'rm -f "$REMOTE_NAME_FN"' EXIT
bash -n "$REMOTE_NAME_FN" || { fail "_host_script_remote_name extract has syntax errors"; exit 1; }

# Resolve installed-name -> repo-relative path.
resolve_repo_path() {
    local name="$1" repo
    repo=$(bash -c "source '$REMOTE_NAME_FN'; _host_script_remote_name '$name'")
    # _host_script_remote_name returns a REPO_RAW-relative path; for files
    # staged at repo root that is just the basename, for lib/ files it carries
    # the lib/ prefix, for scripts/ files the scripts/ prefix. All are valid
    # repo-relative reads.
    echo "$repo"
}

# ---------------------------------------------------------------------------
# release.yml: extract the SHA256SUMS staging list and the gh release upload
# list (both are backslash-continued argument blocks).
# ---------------------------------------------------------------------------
# SHA256SUMS block: lines after `sha256sum \` up to (not incl) `> SHA256SUMS`.
SHA256_STAGED=$(grep -A200 'sha256sum \\' "$RELEASE_YML" \
    | grep -v 'sha256sum \\' \
    | awk '/> SHA256SUMS/{exit} {print}' \
    | tr -d ' \\' | grep -v '^$')
# Upload block: lines after `gh release upload "$TAG" \` up to (not incl)
# `--clobber` (the trailing flag that ends the asset list).
UPLOAD_STAGED=$(awk '/gh release upload/{f=1;next} f&&/--clobber/{exit} f{print}' "$RELEASE_YML" \
    | tr -d ' \\' | grep -v '^$')

# ---------------------------------------------------------------------------
# For each shipped sbin file, derive the same-dir sibling .sh sources.
# Pattern: a line that builds a path via dirname of BASH_SOURCE/$0 (optionally
# wrapped in readlink -f / cd ... pwd), then concatenates )/<basename>.sh.
# Same-dir = the basename follows )/ directly (no intermediate directory).
# Subdir sources like lib/compose-lib.sh are EXCLUDED (the / in the path breaks
# the single-component basename match) — those are not PREFIX_SBIN siblings.
# ---------------------------------------------------------------------------
declare -A sibling_to_sourcers=()   # sibling basename -> "sourcer:sourcer ..."
declare -A sibling_seen=()

for f in "${SBIN_FILES[@]}"; do
    repo_path="$(resolve_repo_path "$f")"
    src="$REPO_ROOT/$repo_path"
    if [[ ! -f "$src" ]]; then
        fail "shipped sbin '$f' repo path '$repo_path' not found on disk"
        continue
    fi
    # Lines resolving a path relative to this script's own dir.
    while IFS= read -r sib; do
        [[ -n "$sib" ]] || continue
        sibling_to_sourcers["$sib"]+="${f} "
        sibling_seen["$sib"]=1
    done < <(
        grep -E 'dirname.*(BASH_SOURCE|\$0|readlink)' "$src" 2>/dev/null \
            | grep -oE '\)/[A-Za-z0-9._-]+\.sh' \
            | sed 's#^)/##' | sort -u
    )
done

# ---------------------------------------------------------------------------
# Test A: derived sibling set is non-empty (sanity — the scanner works).
# ---------------------------------------------------------------------------
echo ""
echo "=== Test A: sourced-sibling scanner derives a non-empty set ==="
if [[ "${#sibling_seen[@]}" -gt 0 ]]; then
    pass "A: derived ${#sibling_seen[@]} sourced sibling(s): ${!sibling_seen[*]}"
else
    fail "A: scanner derived ZERO siblings — pattern broken or no shipped script sources a sibling"
fi

# ---------------------------------------------------------------------------
# Test B: every sourced sibling is in _HOST_SCRIPT_SBIN_FILES (delivery list).
# ---------------------------------------------------------------------------
echo ""
echo "=== Test B: every sourced sibling is in the delivery list ==="
for sib in "${!sibling_seen[@]}"; do
    found=0
    for f in "${SBIN_FILES[@]}"; do
        if [[ "$f" == "$sib" ]]; then found=1; break; fi
    done
    if [[ "$found" -eq 1 ]]; then
        pass "B: '$sib' in _HOST_SCRIPT_SBIN_FILES (sourced by: ${sibling_to_sourcers[$sib]})"
    else
        fail "B: '$sib' MISSING from _HOST_SCRIPT_SBIN_FILES — sourced as a same-dir sibling by: ${sibling_to_sourcers[$sib]}. sync_host_scripts never delivers it, so the source fails on every existing edge after upgrade."
    fi
done

# ---------------------------------------------------------------------------
# Test C: every sourced sibling is in release.yml SHA256SUMS staging.
# ---------------------------------------------------------------------------
echo ""
echo "=== Test C: every sourced sibling is in release.yml SHA256SUMS staging ==="
for sib in "${!sibling_seen[@]}"; do
    if grep -Fqx "$sib" <<< "$SHA256_STAGED"; then
        pass "C: '$sib' in SHA256SUMS staging"
    else
        fail "C: '$sib' MISSING from release.yml SHA256SUMS staging — sync_host_scripts fetches from REPO_RAW but cannot verify it; an unverified install is a supply-chain gap."
    fi
done

# ---------------------------------------------------------------------------
# Test D: every sourced sibling is in the gh release upload list.
# ---------------------------------------------------------------------------
echo ""
echo "=== Test D: every sourced sibling is in the gh release upload list ==="
for sib in "${!sibling_seen[@]}"; do
    if grep -Fqx "$sib" <<< "$UPLOAD_STAGED"; then
        pass "D: '$sib' in release upload list"
    else
        fail "D: '$sib' MISSING from release.yml gh release upload list — not published as a release asset."
    fi
done

# ---------------------------------------------------------------------------
# Summary.
# ---------------------------------------------------------------------------
echo ""
echo "==================================================================="
echo "sourced-sibling delivery guard: PASS=$PASS FAIL=$FAIL"
echo "==================================================================="
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
