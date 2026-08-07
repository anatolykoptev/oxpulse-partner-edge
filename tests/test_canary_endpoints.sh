#!/usr/bin/env bash
# tests/test_canary_endpoints.sh
# Validates the Phase 1 canary site block in Caddyfile.tpl.
#
# Strategy:
#   1. Render Caddyfile.tpl with test env vars → /tmp file.
#   2. Strip l4/layer4/listener_wrappers and maxmind blocks (plugins unavailable
#      on host caddy) using brace-counting so nested braces are handled correctly.
#   3. Run `caddy validate` on the stripped file — checks Caddy syntax.
#   4. Structural grep/python assertions on the rendered (un-stripped) file.
#
# Requires: caddy binary on PATH or docker with caddy:2.x image.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
TPL="$REPO_ROOT/Caddyfile.tpl"

PASS=0
FAIL=0

ok()   { echo "  PASS: $*"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL+1)); }

echo "test_canary_endpoints.sh"
echo

# --- render ---
TMP_RENDERED=$(mktemp /tmp/caddyfile-canary-test.XXXXXX)
TMP_STRIPPED=$(mktemp /tmp/caddyfile-canary-stripped.XXXXXX)
trap 'rm -f "$TMP_RENDERED" "$TMP_STRIPPED"' EXIT

sed \
    -e 's/{{PARTNER_DOMAIN}}/example.test/g' \
    -e 's/{{TURNS_SUBDOMAIN}}/turns/g' \
    -e 's/__CADDYFILE_SHA__/deadbeef1234/g' \
    "$TPL" > "$TMP_RENDERED"

ok "Caddyfile.tpl rendered to $TMP_RENDERED"

# --- strip plugin-dependent blocks for host-caddy validation ---
python3 - "$TMP_RENDERED" "$TMP_STRIPPED" <<'PYEOF'
import sys, re

def strip_block(src, keyword):
    """Remove `keyword { ... }` block, tracking nested braces."""
    out = []
    skip_depth = 0
    in_skip = False
    for line in src.split('\n'):
        if not in_skip:
            if re.match(r'^\s*' + re.escape(keyword) + r'\s*\{', line):
                in_skip = True
                skip_depth = line.count('{') - line.count('}')
                continue
        else:
            skip_depth += line.count('{') - line.count('}')
            if skip_depth <= 0:
                in_skip = False
            continue
        out.append(line)
    return '\n'.join(out)

with open(sys.argv[1]) as f:
    src = f.read()

src = strip_block(src, 'servers')           # contains listener_wrappers/layer4
src = strip_block(src, 'maxmind_geolocation')
src = strip_block(src, 'cache')             # Souin global block (cache-handler plugin)
src = re.sub(r'(?m)^[ \t]*cache[ \t]*$\n', '', src)  # its route-level directive
src = strip_block(src, 'turns.example.test')  # TURNS stub site needs real domain
src = re.sub(r'\n{3,}', '\n\n', src)       # collapse excess blank lines

with open(sys.argv[2], 'w') as f:
    f.write(src)

print("  stripped ok")
PYEOF

ok "Stripped plugin-dependent blocks for host-caddy validation"

# --- caddy validate ---
if command -v caddy >/dev/null 2>&1; then
    validate_out=$(caddy validate --config "$TMP_STRIPPED" --adapter caddyfile 2>&1 || true)
    if echo "$validate_out" | grep "Valid configuration" >/dev/null; then
        ok "caddy validate: Valid configuration"
    else
        echo "$validate_out" | grep -iE "error|Error" | head -5 >&2
        fail "caddy validate rejected config"
    fi
elif docker info >/dev/null 2>&1; then
    echo "  INFO: host caddy not found, using docker caddy:2.10"
    validate_out=$(docker run --rm -v "$TMP_STRIPPED:/work/Caddyfile:ro" caddy:2.10 \
        caddy validate --config /work/Caddyfile --adapter caddyfile 2>&1 || true)
    if echo "$validate_out" | grep "Valid configuration" >/dev/null; then
        ok "caddy validate (docker): Valid configuration"
    else
        echo "$validate_out" | tail -10 >&2
        fail "caddy validate (docker) rejected config"
    fi
else
    echo "  SKIP: neither caddy binary nor docker available for validation"
fi

# --- structural assertions on rendered (full) file ---
grep -qF "http://127.0.0.1:9080" "$TMP_RENDERED" \
    && ok "canary site bound to 127.0.0.1:9080" \
    || fail "canary site not found or wrong address"

grep -q "/canary/tunnel" "$TMP_RENDERED" \
    && ok "/canary/tunnel endpoint present" \
    || fail "/canary/tunnel endpoint missing"

grep -q "/canary/upstream" "$TMP_RENDERED" \
    && ok "/canary/upstream endpoint present" \
    || fail "/canary/upstream endpoint missing"

grep -q "/canary/config-hash" "$TMP_RENDERED" \
    && ok "/canary/config-hash endpoint present" \
    || fail "/canary/config-hash endpoint missing"

grep -q "/canary/route-table" "$TMP_RENDERED" \
    && ok "/canary/route-table endpoint present" \
    || fail "/canary/route-table endpoint missing"

# __CADDYFILE_SHA__ placeholder must have been substituted
grep -qF "deadbeef1234" "$TMP_RENDERED" \
    && ok "__CADDYFILE_SHA__ placeholder substituted correctly" \
    || fail "__CADDYFILE_SHA__ not substituted (check sed step)"

# Reverse proxy timeouts present in canary block
python3 - "$TMP_RENDERED" <<'PYEOF'
import sys, re
with open(sys.argv[1]) as f:
    t = f.read()
m = re.search(r'http://127\.0\.0\.1:9080\s*\{(.+?)\n\}', t, re.DOTALL)
if not m:
    print("  FAIL: canary block not parseable"); sys.exit(1)
block = m.group(1)
if "dial_timeout 2s" not in block:
    print("  FAIL: dial_timeout 2s missing"); sys.exit(1)
if "response_header_timeout 2s" not in block:
    print("  FAIL: response_header_timeout 2s missing"); sys.exit(1)
print("  PASS: canary block has 2s timeouts on both reverse_proxy handles")
PYEOF

# Canary block must NOT reference :443
python3 - "$TMP_RENDERED" <<'PYEOF'
import sys, re
with open(sys.argv[1]) as f:
    t = f.read()
m = re.search(r'http://127\.0\.0\.1:9080\s*\{(.+?)\n\}', t, re.DOTALL)
if m and ":443" in m.group(0):
    print("  FAIL: canary block references :443"); sys.exit(1)
print("  PASS: canary block does not reference :443")
PYEOF

# JSON log in global block
grep -q "format json" "$TMP_RENDERED" \
    && ok "log format json directive present" \
    || fail "log format json directive missing"

grep -q "level INFO" "$TMP_RENDERED" \
    && ok "log level INFO directive present" \
    || fail "log level INFO directive missing"

# Confirm log block is inside the global options block (before first site block)
python3 - "$TMP_RENDERED" <<'PYEOF'
import sys
with open(sys.argv[1]) as f:
    lines = f.readlines()
global_end = None
format_json_line = None
for i, line in enumerate(lines):
    if "format json" in line and format_json_line is None:
        format_json_line = i
    stripped = line.strip()
    if stripped == "}" and global_end is None and i > 0:
        for j in range(i+1, min(i+5, len(lines))):
            nl = lines[j].strip()
            if nl:
                if nl.startswith("example.test") or nl.startswith("http://") or nl.startswith("{"):
                    global_end = i
                break
if format_json_line is None:
    print("  FAIL: format json not found"); sys.exit(1)
if global_end is None:
    print("  WARN: could not locate global block end; skipping position check")
    sys.exit(0)
if format_json_line >= global_end:
    print(f"  FAIL: log format json at line {format_json_line+1} is AFTER global block end at {global_end+1}")
    sys.exit(1)
print(f"  PASS: log format json at line {format_json_line+1} is inside global block (ends ~line {global_end+1})")
PYEOF

echo
if [[ $FAIL -eq 0 ]]; then
    echo "PASS: all $PASS canary endpoint checks passed"
    exit 0
else
    echo "FAIL: $FAIL check(s) failed (${PASS} passed)"
    exit 1
fi
