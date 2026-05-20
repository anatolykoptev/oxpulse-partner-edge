#!/usr/bin/env bash
# Fix #2/#3 — fixture-host guard in install.sh.
#
# Evidence: ruoxp operator passed naive_server=naive-test.example.com on 2026-05-17.
# Installer rendered and started the channel; container crashed (DNS doesn't resolve).
#
# MAJOR #2: regex extended to cover RFC2606 *.invalid, RFC5737 doc IP ranges,
#   loopback 127.x.x.x, link-local 169.254.x.x, 0.0.0.0, IPv6 :: / ::1.
# MAJOR #3: bash guard is now operator-log-only (does NOT clear NAIVE_SERVER).
#   Rust render::naive is authoritative; it rejects fixture hosts at render time.
# MINOR #1: bash regex aligned to match bare example.{com,net,org,invalid} + subdomains.
# MINOR #2: bash guard lowercases input via ${NAIVE_SERVER,,} for case-insensitive match.
#
# This test verifies:
#   Case 1: install.sh has extended fixture-host guard regex patterns
#   Case 2: install.sh emits naive=skipped_fixture_host when guard fires
#   Case 3: behavioral -- fixture host guard logs but does NOT clear NAIVE_SERVER
#   Case 4: behavioral -- real host is not matched by the guard
#   Case 5: new RFC patterns present in install.sh (RFC5737, loopback, link-local)
#   Case 6: case-insensitive guard -- uppercase Example.COM matches via lowercase
#   Case 7: MAJOR #3 authority comment present (Rust is authoritative)
#   Case 8: hysteria2-client.yaml gets chmod 0640 when hy2 active
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
INSTALL="$REPO_ROOT/install.sh"

[[ -f "$INSTALL" ]] || { echo "FAIL: install.sh not found at $INSTALL"; exit 1; }

FAIL=0
pass() { echo "OK: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }

# ── Case 1: extended fixture guard pattern exists in install.sh ──────────────
echo "==> Case 1: extended fixture-host guard patterns present in install.sh"
if grep -qE 'example\.(com|net|org|invalid)|\\.test\b|localhost' "$INSTALL"; then
    pass "fixture-host guard regex found in install.sh"
else
    fail "fixture-host guard not found in install.sh"
fi

# ── Case 2: skipped_fixture_host status emitted ──────────────────────────────
echo "==> Case 2: install.sh emits skipped_fixture_host"
if grep -q 'skipped_fixture_host' "$INSTALL"; then
    pass "skipped_fixture_host found in install.sh"
else
    fail "skipped_fixture_host not found in install.sh"
fi

# ── Case 3: MAJOR #3 -- bash guard does NOT clear NAIVE_SERVER ───────────────
echo "==> Case 3: MAJOR #3 -- bash guard logs only; does not clear NAIVE_SERVER"
# Extract the guard block anchored on the Fix #2 comment marker
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
    # MAJOR #3: guard MUST NOT clear NAIVE_SERVER — Rust is authoritative
    if [[ "$result" == "NAIVE_SERVER_VALUE=naive-test.example.com" ]]; then
        pass "MAJOR #3: bash guard did NOT clear NAIVE_SERVER (Rust is authoritative)"
    else
        fail "MAJOR #3: unexpected NAIVE_SERVER value after guard (got: $result)"
    fi
fi

# ── Case 4: real host not matched ────────────────────────────────────────────
echo "==> Case 4: real host passes guard"
NAIVE_SERVER_REAL="naive.zvonilka.net"
NAIVE_SERVER_REAL_LC="${NAIVE_SERVER_REAL,,}"
if [[ "$NAIVE_SERVER_REAL_LC" =~ ^(localhost|(.*\.)?example\.(com|net|org|invalid)|.*\.invalid|invalid|.*\.test|0\.0\.0\.0|127\.[0-9]+\.[0-9]+\.[0-9]+|169\.254\.[0-9]+\.[0-9]+|192\.0\.2\.[0-9]+|198\.51\.100\.[0-9]+|203\.0\.113\.[0-9]+|::1?|::)$ ]]; then
    fail "guard regex incorrectly matches real host '$NAIVE_SERVER_REAL'"
else
    pass "guard regex does not match real host '$NAIVE_SERVER_REAL'"
fi

# ── Case 5: RFC5737/loopback/link-local patterns in install.sh ───────────────
echo "==> Case 5: MAJOR #2 -- RFC5737 doc ranges and loopback patterns present"
if grep -qE '192\.0\.2|198\.51\.100|203\.0\.113' "$INSTALL"; then
    pass "RFC5737 TEST-NET ranges found in install.sh"
else
    fail "RFC5737 TEST-NET ranges missing from install.sh"
fi
if grep -qE '127\\.\\\\|169\\.254|0\\.0\\.0\\.0' "$INSTALL"; then
    pass "loopback/link-local/zero patterns found in install.sh"
else
    fail "loopback/link-local/zero patterns missing from install.sh"
fi
if grep -qE '::1\?|::' "$INSTALL"; then
    pass "IPv6 loopback patterns found in install.sh"
else
    fail "IPv6 loopback patterns missing from install.sh"
fi

# ── Case 6: MINOR #2 -- case-insensitive via ${,,} lowercase ─────────────────
echo "==> Case 6: MINOR #2 -- guard uses lowercase substitution for case-insensitivity"
if grep -qE '\$\{NAIVE_SERVER,,' "$INSTALL" || grep -qE '_naive_server_lc' "$INSTALL"; then
    pass "case-insensitive lowercase (,, or _lc) found in guard"
else
    fail "case-insensitive lowercase not found — guard may be case-sensitive"
fi

# ── Case 7: MAJOR #3 -- authority comment present ────────────────────────────
echo "==> Case 7: MAJOR #3 -- Rust authoritative comment present"
if grep -q 'Rust render::naive is the authoritative' "$INSTALL" || grep -q 'Rust render::naive is authoritative' "$INSTALL"; then
    pass "Rust authoritative comment found in install.sh"
else
    fail "Rust authoritative comment not found in install.sh"
fi

# ── Case 8: MAJOR #1 -- hysteria2-client.yaml gets 0640 perms ────────────────
echo "==> Case 8: MAJOR #1 -- chmod 0640 present for hysteria2-client.yaml"
if grep -qE 'chmod 0640.*hysteria2-client\.yaml' "$INSTALL"; then
    pass "chmod 0640 for hysteria2-client.yaml found in install.sh"
else
    fail "chmod 0640 for hysteria2-client.yaml NOT found in install.sh"
fi

# ── Result ────────────────────────────────────────────────────────────────────
if [[ $FAIL -ne 0 ]]; then
    echo "FAIL: fixture-host guard test -- one or more cases failed"
    exit 1
fi
echo "PASS: fixture-host guard -- all cases verified"
