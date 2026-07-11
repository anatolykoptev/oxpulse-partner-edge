#!/usr/bin/env bats
# tests/test_install_repo_raw_resolves_to_tag.sh — regression guard for Bug #6.
#
# Bug #6 ROOT CAUSE (discovered 2026-05-28 on edge-d nuke+install):
#   release.yml runs:  sed -i "s|@RELEASE_TAG@|${TAG}|g" partner-edge-installer.sh
#   This substitutes ALL occurrences of @RELEASE_TAG@, including:
#     L37  OXPULSE_RELEASE_TAG="${OXPULSE_RELEASE_TAG:-@RELEASE_TAG@}"   <- intended
#     L40  elif [[ "${...}" != "@RELEASE_TAG@" ]]; then                  <- NOT intended (old code)
#   After substitution (old code):
#     L40  elif [[ "${...}" != "v0.12.71" ]]; then  <- BROKEN: tag != tag always FALSE
#   Result: released installer fetches all lib/* from /main instead of the tag.
#   Combined with Bug #5 (install-firewall.sh missing from lib-checksums.txt),
#   tier-4 fresh installs die with checksum mismatch.
#
# FIX (B2-regex — more robust than sentinel renaming):
#   L40 comparison changed to:
#     elif [[ "${OXPULSE_RELEASE_TAG}" =~ ^v[0-9]+\. ]]; then
#   "@RELEASE_TAG@" does NOT match ^v[0-9]+\. → falls to else → REPO_RAW=/main (dev checkout)
#   "v0.12.71" MATCHES ^v[0-9]+\. → REPO_RAW pinned to /v0.12.71 (released installer)
#   sed s|@RELEASE_TAG@|v0.12.71|g only touches the default value line (L37), not
#   the regex comparison on L40 — no more silent rewrite.
#
# bats <1.5 compat: no bats_require_minimum_version, no 'run !'

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    INSTALL_SH_PATH="$REPO_ROOT/install.sh"
}

# ---------------------------------------------------------------------------
# Helper: simulate REPO_RAW resolution with the current B2-regex logic.
# Mirrors the exact elif logic in install.sh — intentional coupling.
# If install.sh logic changes, update this helper too.
# ---------------------------------------------------------------------------
_repo_raw_for() {
    # $1 = OXPULSE_RELEASE_TAG value (e.g. "@RELEASE_TAG@" or "v0.12.71")
    # $2 = OXPULSE_REPO_RAW override (empty = not set)
    # $3 = OXPULSE_MIRROR_BASE override (empty = not set)
    local tag_val="$1"
    local repo_raw_override="${2:-}"
    local mirror_base="${3:-}"

    bash -c "
        OXPULSE_RELEASE_TAG='$tag_val'
        OXPULSE_REPO_RAW='$repo_raw_override'
        OXPULSE_MIRROR_BASE='$mirror_base'

        if [[ -n \"\${OXPULSE_REPO_RAW:-}\" ]]; then
            REPO_RAW=\"\$OXPULSE_REPO_RAW\"
        elif [[ -n \"\${OXPULSE_MIRROR_BASE:-}\" ]]; then
            REPO_RAW=\"\$OXPULSE_MIRROR_BASE/raw\"
        elif [[ \"\${OXPULSE_RELEASE_TAG}\" =~ ^v[0-9]+\\. ]]; then
            REPO_RAW=\"https://raw.githubusercontent.com/anatolykoptev/oxpulse-partner-edge/\${OXPULSE_RELEASE_TAG}\"
        else
            REPO_RAW=\"https://raw.githubusercontent.com/anatolykoptev/oxpulse-partner-edge/main\"
        fi
        printf '%s' \"\$REPO_RAW\"
    "
}

# ---------------------------------------------------------------------------
# Case 1 — dev checkout: placeholder @RELEASE_TAG@ not substituted
#   "@RELEASE_TAG@" does NOT match ^v[0-9]+\. → REPO_RAW = /main
# ---------------------------------------------------------------------------
@test "dev checkout (unsubstituted @RELEASE_TAG@) → REPO_RAW ends with /main" {
    result=$(_repo_raw_for "@RELEASE_TAG@" "" "")
    [[ "$result" == *"/main" ]] || {
        echo "expected REPO_RAW to end with /main for unsubstituted placeholder"
        echo "got: $result"
        false
    }
}

# ---------------------------------------------------------------------------
# Case 2 — released installer: sed substituted @RELEASE_TAG@ default with v0.12.71
#   "v0.12.71" matches ^v[0-9]+\. → REPO_RAW pinned to /v0.12.71
# ---------------------------------------------------------------------------
@test "released installer (v0.12.71) → REPO_RAW ends with /v0.12.71 (not /main)" {
    result=$(_repo_raw_for "v0.12.71" "" "")
    [[ "$result" == *"/v0.12.71" && "$result" != *"/main" ]] || {
        echo "expected REPO_RAW to end with /v0.12.71 (not /main)"
        echo "got: $result"
        false
    }
}

# ---------------------------------------------------------------------------
# Case 2b — another pinned tag version
# ---------------------------------------------------------------------------
@test "released installer (v0.12.50) → REPO_RAW ends with /v0.12.50" {
    result=$(_repo_raw_for "v0.12.50" "" "")
    [[ "$result" == *"/v0.12.50" && "$result" != *"/main" ]] || {
        echo "expected REPO_RAW to end with /v0.12.50"
        echo "got: $result"
        false
    }
}

# ---------------------------------------------------------------------------
# Case 3 — operator explicit override OXPULSE_RELEASE_TAG=v0.12.50
# ---------------------------------------------------------------------------
@test "operator OXPULSE_RELEASE_TAG=v0.12.50 → REPO_RAW ends with /v0.12.50" {
    result=$(_repo_raw_for "v0.12.50" "" "")
    [[ "$result" == *"/v0.12.50" && "$result" != *"/main" ]] || {
        echo "expected REPO_RAW to end with /v0.12.50"
        echo "got: $result"
        false
    }
}

# ---------------------------------------------------------------------------
# Case 4 — OXPULSE_REPO_RAW override wins over tag detection
# ---------------------------------------------------------------------------
@test "OXPULSE_REPO_RAW override → REPO_RAW equals the override value" {
    result=$(_repo_raw_for "v0.12.71" "http://mirror.internal/raw" "")
    [[ "$result" == "http://mirror.internal/raw" ]] || {
        echo "expected REPO_RAW=http://mirror.internal/raw"
        echo "got: $result"
        false
    }
}

# ---------------------------------------------------------------------------
# Case 5 — OXPULSE_MIRROR_BASE set → REPO_RAW = mirror/raw
# ---------------------------------------------------------------------------
@test "OXPULSE_MIRROR_BASE set → REPO_RAW equals mirror/raw" {
    result=$(_repo_raw_for "@RELEASE_TAG@" "" "http://install.hub.example")
    [[ "$result" == "http://install.hub.example/raw" ]] || {
        echo "expected REPO_RAW=http://install.hub.example/raw"
        echo "got: $result"
        false
    }
}

# ---------------------------------------------------------------------------
# Structural: install.sh must use regex match on elif (not sentinel string compare).
# Ensures sed rewrite of @RELEASE_TAG@ default never breaks the condition.
# ---------------------------------------------------------------------------
@test "install.sh elif uses regex ^v[0-9]+ for tag detection (not @RELEASE_TAG@ string compare)" {
    [ -f "$INSTALL_SH_PATH" ] || skip "install.sh not found"

    # Must find the regex form
    grep -qE 'elif.*RELEASE_TAG.*=~.*\^v' "$INSTALL_SH_PATH" || {
        echo "elif regex ^v[0-9]+\\. not found in install.sh"
        echo "Bug #6 fix was not applied or was reverted."
        false
    }

    # Must NOT have @RELEASE_TAG@ on an elif/if comparison line (that's the old bug)
    if grep -qE '(elif|if).*!=.*@RELEASE_TAG@[^_]' "$INSTALL_SH_PATH"; then
        echo "FAIL: elif/if still uses bare @RELEASE_TAG@ sentinel comparison — bug #6 not fixed"
        false
    fi
}

# ---------------------------------------------------------------------------
# Structural: upgrade.sh elif also uses regex (same bug class)
# ---------------------------------------------------------------------------
@test "upgrade.sh elif uses regex ^v[0-9]+ for tag detection (not @RELEASE_TAG@ string compare)" {
    UPGRADE_SH="$(dirname "$INSTALL_SH_PATH")/upgrade.sh"
    [ -f "$UPGRADE_SH" ] || skip "upgrade.sh not found"

    grep -qE 'elif.*UPGRADE_TAG.*=~.*\^v' "$UPGRADE_SH" || {
        echo "elif regex ^v[0-9]+\\. not found in upgrade.sh"
        echo "Bug #6 fix was not applied to upgrade.sh or was reverted."
        false
    }

    if grep -qE '(elif|if).*==.*@RELEASE_TAG@[^_]' "$UPGRADE_SH"; then
        echo "FAIL: elif/if still uses bare @RELEASE_TAG@ sentinel in upgrade.sh — bug #6 not fixed"
        false
    fi
}
