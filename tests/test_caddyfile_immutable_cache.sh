#!/bin/bash
# tests/test_caddyfile_immutable_cache.sh
#
# The edge caches content-hashed SPA assets and NOTHING else.
#
# Measured 2026-08-07: a visitor in Russia loads 69 assets, each tunnelled
# Moscow → San Jose over AWG → xray → HY2 → naive. Proven by firing 8 requests
# at one chunk on zvonilka.net and watching the origin counter move by exactly 8.
#
# The load-bearing assertion here is NOT that caching works — it is C4/C5, the
# boundary. The document is branded per-partner at serve time by the Rust SPA
# fallback (__BRANDING_*__ substitution), so a cached document would serve one
# partner's branding to another partner's users. That is a worse bug than the
# latency this fixes, it is silent, and the only thing standing between us and
# it is that `cache` appears in exactly one route.
#
# Falsification (anti-vacuous):
#   C4  add `cache` to the generic `handle {` block   → RED (this is the leak)
#   C1  drop the global cache block                   → RED (directive unusable)
#   C2  widen the matcher to /_app/*                  → RED
#   C6  drop `import tunnel_upstream_default`         → RED (miss would 404)
set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TPL="$REPO_ROOT/Caddyfile.tpl"

PASS=0
FAIL=0
pass() {
	echo "PASS: $1"
	PASS=$((PASS + 1))
}
fail() {
	echo "FAIL: $1"
	FAIL=$((FAIL + 1))
}

echo ""
echo "=== immutable asset cache: scoped to content-hashed assets only ==="

[[ -f "$TPL" ]] || {
	fail "C0: Caddyfile.tpl not found"
	exit 1
}

# Comments blanked line-for-line so prose about caching cannot satisfy an
# assertion about caching.
CODE=$(sed 's/#.*//' "$TPL")

# --- C1: the global cache app is declared ---------------------------------
if grep -qE '^[[:space:]]*cache[[:space:]]*\{' <<<"$CODE"; then
	pass "C1: global cache block present"
else
	fail "C1: no global cache block — the route-level directive cannot work without it"
fi

# --- C2: the matcher is the content-hashed path, exactly ------------------
if grep -qE '^[[:space:]]*@immutable[[:space:]]+path[[:space:]]+/_app/immutable/\*[[:space:]]*$' <<<"$CODE"; then
	pass "C2: @immutable matches /_app/immutable/* and nothing wider"
else
	fail "C2: @immutable matcher missing or widened — only content-hashed paths may be cached"
	printf '%s\n' "$CODE" | grep -n '@immutable' || true
fi

# --- C3: the cache directive lives in the immutable route -----------------
if awk '
    /^[[:space:]]*handle @immutable[[:space:]]*\{/ {f=1}
    f && /^[[:space:]]*cache[[:space:]]*$/ {found=1}
    f && /^[[:space:]]*\}[[:space:]]*$/ {f=0}
    END {exit !found}
' <<<"$CODE"; then
	pass "C3: cache directive is inside handle @immutable"
else
	fail "C3: handle @immutable does not enable the cache"
fi

# --- C4: THE BOUNDARY — exactly one route-level cache in the whole file ---
# A `cache` added to the generic handle would cache the branded document. This
# count is what turns that from a silent cross-partner leak into a red test.
n=$(grep -cE '^[[:space:]]*cache[[:space:]]*$' <<<"$CODE" || true)
if [[ "$n" -eq 1 ]]; then
	pass "C4: exactly one route-level cache directive in the template"
else
	fail "C4: found $n route-level cache directives — expected exactly 1 (the branded document must NEVER be cached)"
	printf '%s\n' "$CODE" | grep -nE '^[[:space:]]*cache[[:space:]]*$' || true
fi

# --- C5: the tunnel-only routes carry no cache ----------------------------
# Stated separately from C4 so a future refactor that legitimately adds a second
# cached route still cannot quietly put one of these behind it.
leak=0
for route in '/api/\*' '/ws/\*' '/events/\*' '/sfu/ws/\*' '/relay/\*'; do
	_ctx=$(grep -A6 -E "handle $route|tunnel_upstream $route" <<<"$CODE")
	if grep -qE '^[[:space:]]*cache[[:space:]]*$' <<<"$_ctx"; then
		fail "C5: cache directive reachable from $route"
		leak=1
	fi
done
[[ $leak -eq 0 ]] && pass "C5: api / ws / events / sfu / relay stay uncached"

# --- C6: a cache MISS must still reach the origin -------------------------
if awk '
    /^[[:space:]]*handle @immutable[[:space:]]*\{/ {f=1}
    f && /import tunnel_upstream_default/ {found=1}
    f && /^[[:space:]]*\}[[:space:]]*$/ {f=0}
    END {exit !found}
' <<<"$CODE"; then
	pass "C6: cache miss falls through to the tunnel"
else
	fail "C6: handle @immutable has no upstream — a miss would not be served at all"
fi

# --- C7: one source of truth for the immutable path -----------------------
# The pre-change template matched the same paths with path_regexp purely to set
# a response header. Leaving both would mean two matchers to keep in sync.
if grep -q 'path_regexp /_app/immutable' <<<"$CODE"; then
	fail "C7: the old path_regexp matcher is still present — two definitions of the same surface"
else
	pass "C7: single @immutable definition"
fi

# --- C8: browser TTL preserved --------------------------------------------
if grep -qE 'Cache-Control "public, max-age=31536000, immutable"' <<<"$CODE"; then
	pass "C8: one-year immutable browser TTL still emitted"
else
	fail "C8: the browser Cache-Control header was lost in the move"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
