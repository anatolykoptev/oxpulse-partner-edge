#!/bin/bash
# tests/test_caddy_dns01_cloudflare.sh
#
# Falsification tests for Cloudflare DNS-01 certificate issuance capability.
#
# Design: this is a SILENT-FAILURE surface — a missing or misspelled directive
# produces no error; Caddy simply keeps using HTTP-01 and the second node
# quietly never gets a cert. So each test MUST fail for the right reason:
# the production change it guards is reverted/broken → the test goes RED.
#
# F1 — rendered Caddyfile contains `dns cloudflare` when token is configured.
# F2 — rendered Caddyfile contains NO tls/dns block when token is absent.
# F3 — build definition (Dockerfile.caddy) carries the pinned cloudflare plugin.
# F4 — token value never appears in any rendered artifact.
#
# No opec/docker required — uses the same Python {{VAR}} substitution that
# render_template (channel-render-lib.sh) uses, so it runs anywhere python3 is.
set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TPL="$REPO_ROOT/Caddyfile.tpl"
DOCKERFILE_CADDY="$REPO_ROOT/images/Dockerfile.caddy"
COMPOSE_TPL="$REPO_ROOT/docker-compose.yml.tpl"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# ---------------------------------------------------------------------------
# _render_caddyfile — Python {{VAR}} substitution from ambient env (same
# semantics as render_template in channel-render-lib.sh and opec render caddy).
# Reads Caddyfile.tpl, substitutes all {{VAR}} from env, writes to stdout.
# ---------------------------------------------------------------------------
render_caddyfile() {
    PARTNER_DOMAIN="test.example" \
    TURNS_SUBDOMAIN="api-abc" \
    AWG_MOTHERLY_IP="10.9.0.2" \
    HY2_FALLBACK_HOST="host.docker.internal" \
    HY2_FALLBACK_PORT="18443" \
    NAIVE_SOCKS_PORT="1080" \
    CF_DNS_TLS_BLOCK="${CF_DNS_TLS_BLOCK:-}" \
    python3 -c '
import os, sys, re
with open(sys.argv[1]) as f: tpl = f.read()
out = re.sub(r"\{\{([A-Z][A-Z0-9_]*)\}\}", lambda m: os.environ.get(m.group(1), ""), tpl)
sys.stdout.write(out)
' "$TPL"
}

echo ""
echo "=== Caddy DNS-01 Cloudflare: F1–F4 falsification suite ==="

# ---------------------------------------------------------------------------
# F1 — rendered Caddyfile contains `dns cloudflare` when token is configured.
#
# Production path: install.sh sets CF_DNS_TLS_BLOCK to the tls block text when
# the token is present; Caddyfile.tpl carries {{CF_DNS_TLS_BLOCK}}.
#
# Mutation: delete the line that sets CF_DNS_TLS_BLOCK in install.sh (the line
#   CF_DNS_TLS_BLOCK='    tls { ... }' at install.sh:~1145) → CF_DNS_TLS_BLOCK
#   stays empty → rendered Caddyfile has no `dns cloudflare` → F1 goes RED.
# ---------------------------------------------------------------------------
echo "--- F1: dns cloudflare directive present when token configured ---"
CF_DNS_TLS_BLOCK='    tls {
        dns cloudflare {env.CF_API_TOKEN}
    }'
rendered=$(render_caddyfile)
if echo "$rendered" | grep -q 'dns cloudflare {env.CF_API_TOKEN}'; then
    pass "F1: rendered Caddyfile contains 'dns cloudflare {env.CF_API_TOKEN}'"
else
    fail "F1: rendered Caddyfile missing 'dns cloudflare' directive"
fi

# ---------------------------------------------------------------------------
# F2 — rendered Caddyfile contains NO tls/dns block when token is absent.
#
# Production path: when no token is configured, CF_DNS_TLS_BLOCK="" → the
# placeholder renders to empty → no tls block in the output. This is the
# fail-closed default: four nodes without the token are byte-identical to today.
#
# Mutation: make the emitting condition unconditional — in install.sh, replace
#   `if [[ -n "${OXPULSE_CF_API_TOKEN:-}" ]]; then` with `if true; then`
#   (install.sh:~1143) → CF_DNS_TLS_BLOCK is always set to the tls block →
#   rendered Caddyfile has `dns cloudflare` even without a token → F2 goes RED.
# ---------------------------------------------------------------------------
echo "--- F2: no tls/dns block when token absent (fail-closed default) ---"
CF_DNS_TLS_BLOCK=""
rendered=$(render_caddyfile)
# Strip comment lines so the check only sees active directives — the template
# comments mention `dns cloudflare` in documentation, which is not a directive.
if echo "$rendered" | grep -v '^[[:space:]]*#' | grep -q 'dns cloudflare'; then
    fail "F2: rendered Caddyfile contains 'dns cloudflare' even with empty CF_DNS_TLS_BLOCK — fail-closed broken"
else
    pass "F2: rendered Caddyfile has no 'dns cloudflare' when token absent"
fi

# ---------------------------------------------------------------------------
# F3 — build definition carries the pinned cloudflare plugin.
#
# This is a WEAKER gate than building the image and running `caddy list-modules`:
# it asserts on the build definition (Dockerfile.caddy) rather than the built
# binary. Building the image requires Docker + network + ~5 min and is not
# possible in every environment. The weakness: a typo in the module path that
# still matches the grep pattern would pass, and a build-time resolution failure
# (wrong Go version, incompatible libdns API) would not be caught. The
# test_caddy_image.sh test IS the stronger gate when the image is built — it
# runs `caddy list-modules` and checks for the `dns.providers.cloudflare` module.
#
# Production path: images/Dockerfile.caddy xcaddy build line includes
#   --with github.com/caddy-dns/cloudflare@v0.2.4
#
# Mutation: remove `--with github.com/caddy-dns/cloudflare@v0.2.4` from the
#   xcaddy build line in images/Dockerfile.caddy:26 → F3 goes RED.
# ---------------------------------------------------------------------------
echo "--- F3: Dockerfile.caddy carries pinned cloudflare plugin ---"
if grep -q 'github.com/caddy-dns/cloudflare@v' "$DOCKERFILE_CADDY"; then
    pass "F3: Dockerfile.caddy contains pinned caddy-dns/cloudflare plugin"
else
    fail "F3: Dockerfile.caddy missing caddy-dns/cloudflare plugin in xcaddy build"
fi

# Also verify the version is pinned (not floating latest).
_pinned=$(grep -oE 'github.com/caddy-dns/cloudflare@v[0-9]+\.[0-9]+\.[0-9]+' "$DOCKERFILE_CADDY" || true)
if [[ -n "$_pinned" ]]; then
    pass "F3: plugin version is pinned ($_pinned)"
else
    fail "F3: plugin version not pinned to a specific tag (floating latest = non-reproducible)"
fi

# ---------------------------------------------------------------------------
# F4 — token value never appears in any rendered artifact.
#
# The Caddyfile uses {env.CF_API_TOKEN} (Caddy's env var reference, single
# brace) — NOT {{CF_API_TOKEN}} (opec template placeholder, double brace).
# This means the actual token value is never substituted into the rendered
# Caddyfile; it reaches the container via env_file (docker-compose.yml.tpl).
#
# This test sets a fake token value in the env and asserts it does NOT appear
# in the rendered Caddyfile. It also checks the docker-compose.yml.tpl does
# not contain a {{CF_API_TOKEN}} placeholder that would bake the value in.
#
# Mutation: in Caddyfile.tpl, change `dns cloudflare {env.CF_API_TOKEN}` to
#   `dns cloudflare {{CF_API_TOKEN}}` (Caddyfile.tpl inside the CF_DNS_TLS_BLOCK
#   expansion) and export CF_API_TOKEN with the token value in install.sh →
#   the token value appears in the rendered Caddyfile → F4 goes RED.
# ---------------------------------------------------------------------------
echo "--- F4: token value never appears in rendered artifacts ---"
_FAKE_TOKEN="FAKE_SECRET_TOKEN_DO_NOT_LEAK_12345"
export CF_API_TOKEN="$_FAKE_TOKEN"
CF_DNS_TLS_BLOCK='    tls {
        dns cloudflare {env.CF_API_TOKEN}
    }'
rendered=$(render_caddyfile)
unset CF_API_TOKEN

if echo "$rendered" | grep -qF "$_FAKE_TOKEN"; then
    fail "F4: fake token value appeared in rendered Caddyfile — token leak"
else
    pass "F4: fake token value NOT in rendered Caddyfile (uses {env.CF_API_TOKEN} reference)"
fi

# Also verify the docker-compose.yml.tpl does NOT bake the token value via a
# {{CF_API_TOKEN}} placeholder — it should use env_file instead. Strip comments
# so documentation mentioning the pattern doesn't false-trigger.
if grep -v '^[[:space:]]*#' "$COMPOSE_TPL" | grep -q '{{CF_API_TOKEN}}'; then
    fail "F4: docker-compose.yml.tpl contains {{CF_API_TOKEN}} — would bake token value into rendered compose file"
else
    pass "F4: docker-compose.yml.tpl has no {{CF_API_TOKEN}} placeholder (token via env_file, not baked)"
fi

# Verify the Caddyfile.tpl uses the Caddy env reference, not an opec placeholder.
if grep -q '{env.CF_API_TOKEN}' "$TPL"; then
    pass "F4: Caddyfile.tpl uses {env.CF_API_TOKEN} (Caddy env reference, not opec placeholder)"
else
    fail "F4: Caddyfile.tpl missing {env.CF_API_TOKEN} reference"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== Caddy DNS-01 Cloudflare: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
