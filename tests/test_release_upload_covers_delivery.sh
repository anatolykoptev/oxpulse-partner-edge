#!/bin/bash
# tests/test_release_upload_covers_delivery.sh
#
# Class guard: every file upgrade.sh promises to deliver must actually be
# UPLOADED as a release asset.
#
# `gh release upload` in release.yml takes an EXPLICIT file list. Staging a file
# with `cp` puts it in the workflow's working directory and nothing more — if the
# name is missing from the upload list, the asset never exists, `SHA256SUMS` has
# no entry to verify against, and sync_host_scripts silently skips it on every
# node. The change reaches main, the release is green, and the fleet gets
# nothing.
#
# Measured on v0.16.17 (2026-08-10): the self-heal script and its two units were
# added to all three _HOST_SCRIPT_* arrays and staged in release.yml, but not
# added to the upload list. The release published 61 assets, none of them these.
# Every other gate was green.
#
# tests/test_release_assets.sh does NOT cover this — it asserts install.sh /
# bootstrap.sh staging only, and is in run-shell-tests.sh's BATS_SKIP for
# unrelated assertion drift, so it could not have caught it even if it did.
#
# Neighbour style: tests/test_sourced_sibling_delivery.sh (plain bash, PASS/FAIL
# counters, arrays extracted from upgrade.sh via awk).
set -uo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
UPGRADE="$REPO_ROOT/upgrade.sh"
RELEASE_YML="$REPO_ROOT/.github/workflows/release.yml"
[[ -f "$UPGRADE"     ]] || { echo "FAIL: upgrade.sh not found";   exit 1; }
[[ -f "$RELEASE_YML" ]] || { echo "FAIL: release.yml not found";  exit 1; }

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

extract_array() {   # $1 = array name
    awk -v name="$1" '
        $0 ~ "^" name "=\\(" { f=1; next }
        f && /^\)$/          { exit }
        f {
            sub(/#.*/, "")
            gsub(/^[ \t]+|[ \t]+$/, "")
            if ($0 != "") print $0
        }' "$UPGRADE"
}

# The upload list: everything between `gh release upload "$TAG" \` and the first
# line that does not end in a continuation backslash.
upload_list() {
    awk '
        /gh release upload/ { f=1; next }
        f {
            line = $0
            sub(/^[ \t]+/, "", line)
            has_cont = (line ~ /\\$/)
            sub(/[ \t]*\\$/, "", line)
            if (line != "") print line
            if (!has_cont) exit
        }' "$RELEASE_YML"
}

# Some assets are uploaded under a DELIBERATELY RENAMED name
# (`cp upgrade.sh partner-edge-upgrade.sh`). Build the rename map from the
# staging lines so the guard accepts those instead of crying wolf.
rename_target() {   # $1 = repo path -> staged asset name, or empty
    awk -v src="$1" '
        $1 == "cp" && $2 == src { print $3; exit }' "$RELEASE_YML"
}

UPLOADED="$(upload_list)"
[[ -n "$UPLOADED" ]] && pass "upload list parsed ($(wc -l <<<"$UPLOADED") entries)" \
                     || { fail "could not parse the gh release upload list — the guard is blind"; exit 1; }

# --- sbin files -------------------------------------------------------------
# The installed name maps to a repo path via _host_script_remote_name; the
# release stages under the BASENAME of that path.
REMOTE_FN="$REPO_ROOT/.remote_name_fn.$$"
awk '/^_host_script_remote_name\(\)/{f=1} f{print} f&&/^}$/{exit}' "$UPGRADE" > "$REMOTE_FN"
trap 'rm -f "$REMOTE_FN"' EXIT

missing=0
while IFS= read -r installed; do
    [[ -n "$installed" ]] || continue
    repo_path="$(bash -c "source '$REMOTE_FN'; _host_script_remote_name '$installed'")"
    base="$(basename "$repo_path")"
    # A handful are uploaded under a deliberately RENAMED asset name; accept
    # either the basename or the installed name.
    renamed="$(rename_target "$repo_path")"
    if ! grep -qxF "$base" <<<"$UPLOADED" \
       && ! grep -qxF "$installed" <<<"$UPLOADED" \
       && { [[ -z "$renamed" ]] || ! grep -qxF "$renamed" <<<"$UPLOADED"; }; then
        fail "sbin '$installed' (repo: $repo_path) is delivered by upgrade.sh but NEVER uploaded as a release asset"
        missing=$((missing+1))
    fi
done < <(extract_array _HOST_SCRIPT_SBIN_FILES)
(( missing == 0 )) && pass "every _HOST_SCRIPT_SBIN_FILES entry is uploaded"

# --- systemd units ----------------------------------------------------------
missing=0
while IFS= read -r unit; do
    [[ -n "$unit" ]] || continue
    renamed="$(rename_target "systemd/$unit")"
    if ! grep -qxF "$unit" <<<"$UPLOADED" \
       && { [[ -z "$renamed" ]] || ! grep -qxF "$renamed" <<<"$UPLOADED"; }; then
        fail "unit '$unit' is delivered by upgrade.sh but NEVER uploaded as a release asset"
        missing=$((missing+1))
    fi
done < <(extract_array _HOST_SCRIPT_SYSTEMD_FILES)
(( missing == 0 )) && pass "every _HOST_SCRIPT_SYSTEMD_FILES entry is uploaded"

echo ""
echo "release-upload delivery guard: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
