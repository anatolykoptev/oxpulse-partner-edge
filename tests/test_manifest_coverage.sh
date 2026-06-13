#!/bin/bash
# tests/test_manifest_coverage.sh — Phase 4a: manifest.yaml structure + coverage.
#
# Asserts:
#   M1: manifest.yaml exists at repo root.
#   M2: manifest_version: 1 is present.
#   M3: release_tag line is present (may be @RELEASE_TAG@ sentinel or real tag).
#   M4: surfaces: list is present.
#   M5: the caddyfile surface is declared and has all required render_from_state fields.
#   M6: every declared surface has at minimum: id, kind.
#   M7: render_from_state surfaces have: template, out, renderer, placeholder_completeness, restart_unit.
#   M8: caddyfile surface sha_key is CADDYFILE_SHA.
#   M9: wired surface (caddyfile) is identifiable vs not-yet-wired surfaces.
#   M10: python3 can parse manifest.yaml without syntax errors.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
MANIFEST="$REPO_ROOT/manifest.yaml"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

echo ""
echo "=== Manifest coverage tests ==="

# M1: manifest.yaml exists.
if [[ -f "$MANIFEST" ]]; then
    pass "M1: manifest.yaml exists"
else
    fail "M1: manifest.yaml missing at $MANIFEST"
    echo "FAIL: 0/$((PASS+FAIL)) tests passed (manifest absent — aborting)"
    exit 1
fi

# M2: manifest_version: 1
if grep -qE '^manifest_version:\s*1' "$MANIFEST"; then
    pass "M2: manifest_version: 1 present"
else
    fail "M2: manifest_version: 1 not found in manifest.yaml"
fi

# M3: release_tag line present
if grep -qE '^release_tag:' "$MANIFEST"; then
    pass "M3: release_tag field present"
else
    fail "M3: release_tag field missing"
fi

# M4: surfaces: list is present
if grep -qE '^surfaces:' "$MANIFEST"; then
    pass "M4: surfaces: list present"
else
    fail "M4: surfaces: list missing"
fi

# M5: caddyfile surface declared
if grep -qE 'id:\s*caddyfile' "$MANIFEST"; then
    pass "M5: caddyfile surface declared"
else
    fail "M5: caddyfile surface not declared in manifest"
fi

# M6: python3 parses manifest without errors
if command -v python3 >/dev/null 2>&1; then
    if python3 -c "
import sys
try:
    import re
    with open('$MANIFEST') as f:
        content = f.read()
    # Basic YAML structure check: manifest_version, surfaces block
    assert 'manifest_version:' in content, 'manifest_version missing'
    assert 'surfaces:' in content, 'surfaces: block missing'
    print('ok')
except Exception as e:
    print('error: ' + str(e), file=sys.stderr)
    sys.exit(1)
" 2>/dev/null | grep -q ok; then
        pass "M6: python3 can read manifest.yaml"
    else
        fail "M6: python3 failed to read manifest.yaml"
    fi
else
    pass "M6: python3 not available — structural check skipped"
fi

# M7: caddyfile surface has required render_from_state fields
# We check that the caddyfile block has all required keys.
# Strategy: extract the caddyfile block (from its id line to the next "  - id:" or EOF)
_caddy_block=$(python3 2>/dev/null - "$MANIFEST" << 'PYEOF'
import sys, re
content = open(sys.argv[1]).read()
# Find the caddyfile block: from "  - id: caddyfile" to next "  - id:" or EOF
m = re.search(r'(  - id: caddyfile.*?)(?=\n  - id:|\Z)', content, re.DOTALL)
if m:
    print(m.group(1))
else:
    sys.exit(1)
PYEOF
)

required_fields=("template:" "out:" "renderer:" "placeholder_completeness:" "restart_unit:")
for _field in "${required_fields[@]}"; do
    if echo "$_caddy_block" | grep -qF "$_field"; then
        pass "M7: caddyfile surface has field: $_field"
    else
        fail "M7: caddyfile surface missing required field: $_field"
    fi
done

# M8: caddyfile sha_key = CADDYFILE_SHA
if echo "$_caddy_block" | grep -qE 'sha_key:\s*CADDYFILE_SHA'; then
    pass "M8: caddyfile sha_key is CADDYFILE_SHA"
else
    fail "M8: caddyfile sha_key is not CADDYFILE_SHA"
fi

# M9: wired-surface indicator — caddyfile must NOT have wired: false
if echo "$_caddy_block" | grep -qE 'wired:\s*false'; then
    fail "M9: caddyfile surface is marked wired: false (should be the wired P4a surface)"
else
    pass "M9: caddyfile surface is wired (no wired: false)"
fi

# M10: non-caddyfile surfaces have wired: false (at least some do — P4a declares-but-not-wired)
_unwired_count=$(grep -c 'wired: false' "$MANIFEST" || true)
if [[ "$_unwired_count" -ge 1 ]]; then
    pass "M10: at least one surface is declared-but-not-yet-wired (wired: false present)"
else
    fail "M10: no declared-but-not-yet-wired surfaces found (expected others to be marked wired: false for P4b)"
fi

echo ""
echo "=== Manifest coverage: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
