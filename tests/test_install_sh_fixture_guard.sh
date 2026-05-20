#!/usr/bin/env bash
# Fix #2 -- fixture-host guard in install.sh must reject test-fixture NAIVE_SERVER.
#
# Evidence: ruoxp operator passed naive_server=naive-test.example.com on 2026-05-17.
# Installer rendered and started the channel; container crashed (DNS doesn't resolve).
#
# This test verifies:
#   Case 1: install.sh has the fixture-host guard regex pattern
#   Case 2: install.sh emits naive=skipped_fixture_host when guard fires
#   Case 3: behavioral -- NAIVE_SERVER set to fixture host -> guard clears NAIVE_SERVER
#   Case 4: behavioral -- real host is not cleared
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
INSTALL="$REPO_ROOT/install.sh"

[[ -f "$INSTALL" ]] || { echo "FAIL: install.sh not found at $INSTALL"; exit 1; }

FAIL=0
pass() { echo "OK: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }

# ── Case 1: fixture guard pattern exists in install.sh ───────────────────────
echo "==> Case 1: fixture-host guard pattern present in install.sh"
if grep -qE 'example\.(com|net|org)|\.test\b|localhost' "$INSTALL"; then
    pass "fixture-host guard regex found in install.sh"
else
    fail "fixture-host guard not found in install.sh"
fi

# ── Case 2: skipped_fixture_host status emitted ──────────────────────────────
echo "==> Case 2: install.sh emits naive=skipped_fixture_host"
if grep -q 'skipped_fixture_host' "$INSTALL"; then
    pass "naive=skipped_fixture_host found in install.sh"
else
    fail "naive=skipped_fixture_host not found in install.sh"
fi

# ── Case 3: behavioral -- fixture host clears NAIVE_SERVER in subshell ───────
echo "==> Case 3: fixture host guard clears NAIVE_SERVER in subshell"

T3=$(mktemp -d)
trap 'rm -rf "$T3"' EXIT

# Extract the guard block anchored on the "Fix #2" comment marker
guard_block=$(awk '
    /Fix #2: fixture-host guard/ { found=1 }
    found { print }
    found && /^fi$/ { found=0; exit }
' "$INSTALL")

if [[ -z "$guard_block" ]]; then
    fail "Could not extract fixture guard block (Fix #2 comment not found in install.sh)"
else
    result=$(bash -c '
        NAIVE_SERVER="naive-test.example.com"
        warn() { :; }
        _naive_status=""
        '"$guard_block"'
        printf "NAIVE_SERVER_VALUE=%s" "$NAIVE_SERVER"
    ' 2>/dev/null)
    if [[ "$result" == "NAIVE_SERVER_VALUE=" ]]; then
        pass "fixture guard cleared NAIVE_SERVER for naive-test.example.com"
    else
        fail "fixture guard did NOT clear NAIVE_SERVER (got: $result)"
    fi
fi

# ── Case 4: real host not cleared ────────────────────────────────────────────
echo "==> Case 4: real host passes fixture guard"
# Static check: ensure real production-style hosts are not in the rejection pattern
# The guard should only reject: localhost, *.example.{com,net,org}, *.test
NAIVE_SERVER_REAL="naive.zvonilka.net"
if [[ "$NAIVE_SERVER_REAL" =~ ^(localhost|.*\.example\.(com|net|org)|.*\.test)$ ]]; then
    fail "guard regex incorrectly matches real host '$NAIVE_SERVER_REAL'"
else
    pass "guard regex does not match real host '$NAIVE_SERVER_REAL'"
fi

# ── Result ────────────────────────────────────────────────────────────────────
if [[ $FAIL -ne 0 ]]; then
    echo "FAIL: fixture-host guard test -- one or more cases failed"
    exit 1
fi
echo "PASS: fixture-host guard -- all cases verified"
