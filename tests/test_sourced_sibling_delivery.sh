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
# selfdir_siblings <file> — every same-dir .sh this script resolves against its
# own location, one per line.
#
# Two passes, because the repo's dominant idiom splits the directory from the
# basename across two lines:
#
#     _dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
#     source "${_dir}/some-lib.sh"
#
# A single-line pattern sees neither half. Measured over the 24 shipped sbin
# scripts, the split form is the majority; the one-line form this test
# originally matched is the exception. That mattered: the guard passed on
# hydrate.sh and install.sh while deriving nothing from either.
selfdir_siblings() {
    # A pass that matches nothing is a normal outcome — grep's exit 1 must not
    # abort the function under the caller's `set -e` (this silently reduced the
    # scanner to its first pass and made the widening a no-op).
    local src="$1"

    # 1a. One line carries both halves:  "$(... dirname ...)/name.sh"
    grep -E '(dirname|readlink)[^#]*(BASH_SOURCE|\$0)' "$src" 2>/dev/null \
        | grep -oE '\)/[A-Za-z0-9._-]+\.sh' | sed 's#^)/##' || true

    # 1b. No dirname at all:  "${BASH_SOURCE[0]%/*}/name.sh"
    grep -oE '\$\{BASH_SOURCE\[0\]%[^}]*\}/[A-Za-z0-9._-]+\.sh' "$src" 2>/dev/null \
        | sed 's#.*/##' || true

    # 2. A variable holding this script's own DIRECTORY, then any .sh built on
    #    it. Assignments that already end in a file component are excluded —
    #    those hold a path, not a directory, and 1a has them.
    local -a dirvars=()
    mapfile -t dirvars < <(
        grep -E '^[[:space:]]*(local[[:space:]]+|declare[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=.*((dirname|readlink)[^#]*(BASH_SOURCE|\$0)|BASH_SOURCE\[0\]%)' "$src" 2>/dev/null \
            | grep -vE '\)/[A-Za-z0-9._-]+\.[A-Za-z0-9]+"?[[:space:]]*$' \
            | sed -E 's/^[[:space:]]*(local[[:space:]]+|declare[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/' \
            | sort -u || true
    )
    local v
    for v in "${dirvars[@]}"; do
        [[ -n "$v" ]] || continue
        grep -oE "\\$\{?${v}\}?/[A-Za-z0-9._-]+\.sh" "$src" 2>/dev/null | sed 's#.*/##' || true
    done

    # 3. Rooted at PREFIX_SBIN rather than reached via dirname:
    #        _TOKEN_LIB="${PREFIX_SBIN:-/usr/local/sbin}/oxpulse-token-lib.sh"
    #    Same delivery dependency — the file has to BE in PREFIX_SBIN at runtime
    #    — so the same assertion applies. Not reached by pass 2 because no
    #    variable here holds the script's own directory.
    grep -oE '\$\{PREFIX_SBIN[^}]*\}/[A-Za-z0-9._-]+\.sh|/usr/local/sbin/[A-Za-z0-9._-]+\.sh' "$src" 2>/dev/null \
        | sed 's#.*/##' || true
}

declare -A sibling_to_sourcers=()   # sibling basename -> "sourcer:sourcer ..."
declare -A sibling_seen=()

for f in "${SBIN_FILES[@]}"; do
    repo_path="$(resolve_repo_path "$f")"
    src="$REPO_ROOT/$repo_path"
    if [[ ! -f "$src" ]]; then
        fail "shipped sbin '$f' repo path '$repo_path' not found on disk"
        continue
    fi
    # Paths resolved relative to this script's own dir (see selfdir_siblings).
    while IFS= read -r sib; do
        [[ -n "$sib" ]] || continue
        sibling_to_sourcers["$sib"]+="${f} "
        sibling_seen["$sib"]=1
    done < <(selfdir_siblings "$src" | sort -u)
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
# ---------------------------------------------------------------------------
# Test E: the fresh-install path both installs each sibling and verifies it.
#
# upgrade.sh never calls _systemd_install_lib_scripts — that is install.sh's
# path, and it is the only thing that puts these libs on a brand-new box, so
# the upgrade array and the release assets say nothing about a new install
# (review finding M6).
#
# Two distinct assertions. E1 is the delivery check: lib/install-systemd.sh
# must actually write the file into PREFIX_SBIN. E2 is weaker and often inert —
# EXPECTED_SBIN_FILES is the --clean-sbin prune allowlist, not a verification
# list (see the comment at the E2 branch). The first version of this test
# conflated the two and reported a false blocker on that basis.
# ---------------------------------------------------------------------------
echo ""
echo "=== Test E: fresh install writes each sibling (E1); prune allowlist covers it (E2) ==="
INSTALL_SYSTEMD="$REPO_ROOT/lib/install-systemd.sh"
if [[ ! -f "$INSTALL_SYSTEMD" ]]; then
    fail "E: lib/install-systemd.sh not found — cannot check the fresh-install list"
else
    mapfile -t EXPECTED_SBIN < <(
        awk '/^EXPECTED_SBIN_FILES=\(/{f=1;next} f&&/^\)$/{exit} f{
            gsub(/#.*/,""); gsub(/^[[:space:]]+/,""); gsub(/[[:space:]]+$/,"");
            if(length($0)>0) print
        }' "$INSTALL_SYSTEMD"
    )
    if [[ "${#EXPECTED_SBIN[@]}" -eq 0 ]]; then
        fail "E: EXPECTED_SBIN_FILES extracted empty — the awk anchor no longer matches"
    else
        for sib in "${!sibling_seen[@]}"; do
            # E1 — the fresh-install path must actually write it into PREFIX_SBIN.
            # This is the delivery assertion. EXPECTED_SBIN_FILES is a separate,
            # weaker thing (see E2): a post-install verification list, not the
            # code that installs.
            # Must match a line that WRITES the file, not merely mentions it:
            # a plain fixed-string search also hits comments, `[[ -f ... ]]`
            # probes and `rm -f`. Proved by mutation — commenting out all three
            # install lines left this assertion green.
            _e1_needle='"$PREFIX_SBIN/'"${sib}"'"'
            # Collected first, then matched from a here-string: piping into
            # `grep -q` trips this repo's pipefail early-exit guard, because the
            # -q exits on the first hit and the upstream stage dies on SIGPIPE.
            _e1_writes=$(sed 's/#.*//' "$INSTALL_SYSTEMD" | grep -E '(install -m|curl .*-o |cp )' || true)
            if grep -qF "$_e1_needle" <<<"$_e1_writes"; then
                pass "E1: '$sib' is installed into PREFIX_SBIN by the fresh-install path"
            else
                fail "E1: '$sib' is never written to PREFIX_SBIN by lib/install-systemd.sh — sourced as a same-dir sibling by: ${sibling_to_sourcers[$sib]}. upgrade.sh does not call that path, so a brand-new box would not have it."
            fi
            # E2 — EXPECTED_SBIN_FILES is NOT a post-install verification list. Its
            # only consumer is sbin_cleanup_zombies (lib/install-systemd.sh:464),
            # a --clean-sbin prune ALLOWLIST: anything in PREFIX_SBIN matching
            # its globs and absent from this array gets deleted. Membership buys
            # protection from that prune and nothing more — and for a name the
            # globs do not match, nothing at all. Asserted anyway because those
            # globs have been widened before, and a helper removed by a cleanup
            # fails exactly like one that was never delivered.
            hit=0
            for e in "${EXPECTED_SBIN[@]}"; do [[ "$e" == "$sib" ]] && { hit=1; break; }; done
            if [[ "$hit" -eq 1 ]]; then
                pass "E2: '$sib' in EXPECTED_SBIN_FILES (protected from the --clean-sbin prune)"
            else
                fail "E2: '$sib' MISSING from EXPECTED_SBIN_FILES — the --clean-sbin prune allowlist. This says nothing about whether it installed; no post-install check exists for these libs at all."
            fi
        done
    fi
fi

echo ""
echo "==================================================================="
echo "sourced-sibling delivery guard: PASS=$PASS FAIL=$FAIL"
echo "==================================================================="
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
