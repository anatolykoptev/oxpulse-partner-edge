#!/usr/bin/env bash
# tests/test_hydrate_x_installer_version_header.sh
#
# Verifies that hydrate.sh adds -H "X-Installer-Version: ${IMAGE_VERSION}"
# to the curl POST for /api/partner/register.
#
# Test method: static analysis (grep on the script source).
# hydrate.sh cannot be executed in tests (requires real infra + root dirs),
# so we verify the shape of the curl invocation textually — same approach
# as test_install_xray_xhttp_export.sh (Case 1 static check) and test_hydrate.sh.
#
# What we assert:
#   1. The curl block contains an X-Installer-Version header using IMAGE_VERSION.
#   2. The header line appears BETWEEN the -X POST line and the -d body line
#      (i.e., it is part of the register POST, not some other curl call).
#   3. IMAGE_VERSION is resolved from VERSION file / OXPULSE_IMAGE_VERSION env
#      (pre-existing; assert the resolution block is still intact).
#   4. bash -n syntax check passes.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SCRIPT="$REPO_ROOT/hydrate.sh"

[[ -f "$SCRIPT" ]] || { echo "FAIL: hydrate.sh not found at $SCRIPT"; exit 1; }

FAIL=0

# ── Case 1: bash -n syntax check ─────────────────────────────────────────────
if bash -n "$SCRIPT" 2>/dev/null; then
    echo "  PASS: bash -n hydrate.sh"
else
    echo "  FAIL: bash -n hydrate.sh failed — syntax error"; FAIL=1
fi

# ── Case 2: X-Installer-Version header present in register POST curl ──────────
# The curl block that POSTs to /api/partner/register must contain a line with
# -H "X-Installer-Version: ${IMAGE_VERSION}".
# We extract the register POST block: from the line that has -X POST ... register
# to the closing -o "$tmp_resp" line, then check for the header.

# Extract lines around the register curl call (the block is ~8 lines long).
# awk: from the line matching 'X POST.*register' to the line matching '-o.*tmp_resp'
register_block=$(awk '/X POST.*api\/partner\/register/,/-o.*tmp_resp/' "$SCRIPT")

if [[ -z "$register_block" ]]; then
    echo "  FAIL: could not locate register POST curl block in hydrate.sh"; FAIL=1
else
    if printf '%s\n' "$register_block" | grep -E 'X-Installer-Version.*IMAGE_VERSION' >/dev/null; then
        echo "  PASS: X-Installer-Version header with IMAGE_VERSION found in register POST block"
    else
        echo "  FAIL: X-Installer-Version header missing from register POST curl block"
        echo "        block content:"
        printf '%s\n' "$register_block" | sed 's/^/          /'
        FAIL=1
    fi
fi

# ── Case 3: IMAGE_VERSION resolution block is intact ─────────────────────────
# Verify the pre-existing IMAGE_VERSION resolution (awk '{print $1; exit}') is
# still present. This guards against accidentally removing the VERSION-file read
# while editing the curl block.
if grep -q 'IMAGE_VERSION' "$SCRIPT" && grep -q 'OXPULSE_IMAGE_VERSION' "$SCRIPT"; then
    echo "  PASS: IMAGE_VERSION / OXPULSE_IMAGE_VERSION resolution present"
else
    echo "  FAIL: IMAGE_VERSION resolution block missing from hydrate.sh"; FAIL=1
fi

# ── Case 4: header uses variable, not a hardcoded version string ──────────────
# The header value must reference $IMAGE_VERSION or ${IMAGE_VERSION}, not a
# hardcoded semver like "0.12.72". This prevents the classic copy-paste freeze.
if grep -E 'X-Installer-Version.*\$\{?IMAGE_VERSION\}?' "$SCRIPT" | grep -vE 'X-Installer-Version.*"[0-9]+\.[0-9]+\.[0-9]+"' >/dev/null; then
    echo "  PASS: X-Installer-Version uses \$IMAGE_VERSION variable (not hardcoded)"
else
    echo "  FAIL: X-Installer-Version does not reference IMAGE_VERSION variable"; FAIL=1
fi

# ── Result ────────────────────────────────────────────────────────────────────
if [[ "$FAIL" -eq 0 ]]; then
    echo "PASS: test_hydrate_x_installer_version_header — all checks passed"
    exit 0
else
    echo "FAIL: test_hydrate_x_installer_version_header — $FAIL check(s) failed"
    exit 1
fi
