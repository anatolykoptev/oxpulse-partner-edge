#!/bin/bash
# tests/test_caddy_admin_origins.sh — issue #518 regression guard.
#
# Caddy 2.11's checkHost (admin.go) compares r.Host against each origin's
# url.URL.Host by exact string equality. A request to http://127.0.0.1:2019/
# sends Host: 127.0.0.1:2019 (WITH port); bare `origins 127.0.0.1` never
# matches → 403 "host not allowed". `caddy reload` sends Host: localhost:2019;
# bare `origins localhost` never matches either. Both bare AND host:port forms
# must be in the origins list.
#
# This test asserts:
#   1. The admin block exists in Caddyfile.tpl (healthcheck contract).
#   2. The origins list contains the port-qualified forms localhost:2019 and
#      127.0.0.1:2019 (so caddy reload + direct wget work).
#   3. The origins list contains the bare forms localhost and 127.0.0.1 (so
#      the compose healthcheck's --header=Host:localhost override works).
#   4. No non-loopback origin is present (admin stays loopback-only).
#   5. Every fixture that renders or asserts this block is consistent.
#
# Falsification (anti-vacuous):
#   F1: revert origins to `origins localhost 127.0.0.1` → checks 2/5 go RED.
#   F2: remove the admin block entirely → checks 1/2/3/5 go RED.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# Files that render or assert the admin origins block.
declare -a ORIGINS_FILES=(
    "$REPO_ROOT/Caddyfile.tpl"
    "$REPO_ROOT/tests/fixtures/install-render/caddy.tpl"
    "$REPO_ROOT/tests/fixtures/install-render/expected/caddy.txt"
    "$REPO_ROOT/tests/fixtures/hydrate-render/expected/caddy.txt"
    "$REPO_ROOT/tests/fixtures/caddyfile-golden-v0.13.0.txt"
)

echo ""
echo "=== caddy admin origins port-form regression (issue #518) ==="

# ---------------------------------------------------------------------------
# Check 1: admin block exists in Caddyfile.tpl (healthcheck contract).
# ---------------------------------------------------------------------------
TPL="$REPO_ROOT/Caddyfile.tpl"
if grep -qF 'admin localhost:2019 {' "$TPL"; then
    pass "admin block present in Caddyfile.tpl"
else
    fail "admin block MISSING from Caddyfile.tpl — healthcheck contract broken"
fi

# ---------------------------------------------------------------------------
# Check 2: port-qualified origins present in the origins LINE of every file.
# We extract the `origins` directive line specifically — not the admin listen
# address — so the test is vacuous-proof against `admin localhost:2019 {`.
# ---------------------------------------------------------------------------
for f in "${ORIGINS_FILES[@]}"; do
    if [[ ! -f "$f" ]]; then
        fail "file not found: $f"
        continue
    fi
    _base=$(basename "$f")
    _origins_line=$(grep -m 1 -E '^[[:space:]]*origins[[:space:]]' "$f")
    if grep -qF 'localhost:2019' <<< "$_origins_line" \
       && grep -qF '127.0.0.1:2019' <<< "$_origins_line"; then
        pass "$_base: port-qualified origins (localhost:2019, 127.0.0.1:2019) in origins line"
    else
        fail "$_base: port-qualified origins MISSING from origins line — caddy reload + wget will 403"
    fi
done

# ---------------------------------------------------------------------------
# Check 3: bare origins still present (compose healthcheck --header=Host:localhost).
# ---------------------------------------------------------------------------
for f in "${ORIGINS_FILES[@]}"; do
    [[ -f "$f" ]] || continue
    _base=$(basename "$f")
    # Match the origins line and check it contains bare localhost and 127.0.0.1.
    _origins_line=$(grep -m 1 -E '^\s*origins\s' "$f")
    if grep -qF 'localhost' <<< "$_origins_line" && grep -qF '127.0.0.1' <<< "$_origins_line"; then
        pass "$_base: bare origins (localhost, 127.0.0.1) present"
    else
        fail "$_base: bare origins MISSING — compose healthcheck Host:localhost will 403"
    fi
done

# ---------------------------------------------------------------------------
# Check 4: no non-loopback origin (admin stays loopback-only).
# Extract the origins line from Caddyfile.tpl and verify every token is loopback.
# ---------------------------------------------------------------------------
_origins_line=$(grep -m 1 -E '^\s*origins\s' "$TPL")
# Strip leading whitespace and the 'origins' keyword, leaving just the origin tokens.
_origins_tokens=$(echo "$_origins_line" | sed 's/^[[:space:]]*origins[[:space:]]*//')
_non_loopback=""
for token in $_origins_tokens; do
    case "$token" in
        localhost|127.0.0.1|localhost:2019|127.0.0.1:2019|::1|::1:2019)
            ;;
        *)
            _non_loopback="$_non_loopback $token"
            ;;
    esac
done
if [[ -z "$_non_loopback" ]]; then
    pass "all origins are loopback-only (no public exposure)"
else
    fail "non-loopback origin(s) detected:$_non_loopback"
fi

# ---------------------------------------------------------------------------
# Check 5: golden JSON fixture has port-qualified origins in the array.
# ---------------------------------------------------------------------------
GOLDEN_JSON="$REPO_ROOT/tests/fixtures/caddyfile-golden-v0.13.0.json"
if [[ -f "$GOLDEN_JSON" ]]; then
    # Extract the origins array from the JSON and check for port forms.
    _json_origins=$(python3 -c "
import json, sys
with open('$GOLDEN_JSON') as f:
    data = json.load(f)
origins = data.get('admin', {}).get('origins', [])
print(' '.join(origins))
" 2>/dev/null || true)
    if grep -qF 'localhost:2019' <<< "$_json_origins" \
       && grep -qF '127.0.0.1:2019' <<< "$_json_origins"; then
        pass "golden JSON: port-qualified origins present in admin.origins array"
    else
        fail "golden JSON: port-qualified origins MISSING from admin.origins array"
    fi
    if grep -qF 'localhost' <<< "$_json_origins" \
       && grep -qF '127.0.0.1' <<< "$_json_origins"; then
        pass "golden JSON: bare origins present in admin.origins array"
    else
        fail "golden JSON: bare origins MISSING from admin.origins array"
    fi
else
    fail "golden JSON file not found: $GOLDEN_JSON"
fi

# ---------------------------------------------------------------------------
# Check 6: migrate-bak test fixture has port-qualified origins.
# ---------------------------------------------------------------------------
MIGRATE_TEST="$REPO_ROOT/tests/test_migrate_bak.sh"
if [[ -f "$MIGRATE_TEST" ]]; then
    if grep -qF 'localhost:2019' "$MIGRATE_TEST" && grep -qF '127.0.0.1:2019' "$MIGRATE_TEST"; then
        pass "test_migrate_bak.sh: port-qualified origins present in .bak fixture"
    else
        fail "test_migrate_bak.sh: port-qualified origins MISSING from .bak fixture"
    fi
else
    fail "test_migrate_bak.sh not found"
fi

# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
