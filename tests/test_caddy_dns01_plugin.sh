#!/usr/bin/env bash
# Guards the caddy-dns/cloudflare plugin in the partner-edge Caddy build.
#
# WHY THIS EXISTS
# Both public entry points (oxpulse.chat, zvonilka.net) resolve to a single
# Moscow IP, so a user behind a third-party VPN cannot reach either — their
# traffic would have to re-enter Russia from a foreign exit. The fix is to let
# a second, foreign node answer for the same apex name.
#
# That is blocked on certificates and nothing else: two nodes serving one name
# cannot both prove control with HTTP-01 or TLS-ALPN-01, because the ACME
# challenge lands on whichever address the CA happens to resolve and the other
# node silently never gets a cert (see conf.d/oxpulse-www.caddy, where exactly
# that ran for days). DNS-01 needs no challenge traffic to the node at all.
#
# WHAT THIS GATE IS, AND IS NOT
# Building the image here would cost an xcaddy compile per test run, so this
# asserts the BUILD DEFINITION pins the plugin. That is deliberately weaker
# than asserting the built artifact carries the module: it cannot catch a
# build that silently drops the plugin. The strong check is one command
# against a built image and belongs in the release/rollout step:
#
#     docker run --rm <image> caddy list-modules | grep -c '^dns\.providers\.'
#
# A node whose image lacks the module will FAIL TO START if its Caddyfile
# names the dns provider — loud, not silent — which is why the weak gate is
# acceptable here and the strong one is a rollout check.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCKERFILE="$REPO_ROOT/images/Dockerfile.caddy"
fails=0

check() {
    local desc="$1" cond="$2"
    if eval "$cond"; then
        echo "PASS: $desc"
    else
        echo "FAIL: $desc"
        fails=$((fails + 1))
    fi
}

echo "=== caddy-dns/cloudflare plugin pin ==="

check "Dockerfile.caddy exists" '[[ -f "$DOCKERFILE" ]]'

# Read once; no pipes into grep -q (this repo's pipefail guard: an early exit
# SIGPIPEs the writer, so a SUCCESSFUL match can return non-zero).
content="$(cat "$DOCKERFILE")"

check "xcaddy build line carries the cloudflare DNS provider" \
    '[[ "$content" == *"--with github.com/caddy-dns/cloudflare@"* ]]'

# An unpinned plugin makes the image non-reproducible and can silently pull a
# libdns-v0 build that does not link against Caddy 2.8+.
#
# Anchored to the --with BUILD LINE, not to the file as a whole: an earlier
# draft matched anywhere in the file, so deleting the build line while leaving
# the rationale comment in place kept this check GREEN. It passed for the wrong
# reason. The regex below cannot be satisfied by prose.
check "the BUILD LINE pins an explicit version, not floating" \
    '[[ "$content" =~ --with[[:space:]]+github\.com/caddy-dns/cloudflare@v[0-9]+\.[0-9]+\.[0-9]+ ]]'

# Every other plugin in this file is pinned with a rationale comment; a bare
# --with line with no explanation is how a pin later gets bumped blindly.
check "the pin is documented in the version-pins comment block" \
    '[[ "$content" == *"caddy-dns/cloudflare@"*"DNS-01"* ]]'

echo
if [[ $fails -gt 0 ]]; then
    echo "FAIL: $fails check(s) failed"
    exit 1
fi
echo "PASS: all checks passed"
