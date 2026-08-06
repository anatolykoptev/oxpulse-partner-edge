#!/usr/bin/env bash
# Phase 5.8 Task 4 — verify per-upstream X-Channel-Tag header in Caddyfile.tpl.
# Structural check — does NOT require opec render.
set -euo pipefail

cd "$(dirname "$0")/.."

# Both tunnel_upstream + tunnel_upstream_default snippets must propagate the
# upstream hostport as X-Channel-Tag. Backend uses this to attribute requests
# to channel; Prometheus uses it to label metrics.
for snippet in tunnel_upstream tunnel_upstream_default tunnel_upstream_dpi_resistant; do
    # Extract snippet body (between '(snippet_name) {' and matching '}')
    body=$(awk -v name="$snippet" '
        $0 ~ "\\(" name "\\)[[:space:]]*\\{" { in_block=1; depth=1; next }
        in_block {
            for (i=1; i<=length($0); i++) {
                c=substr($0,i,1)
                if (c=="{") depth++
                else if (c=="}") depth--
            }
            if (depth==0) { exit }
            print
        }
    ' Caddyfile.tpl)
    if [[ -z "$body" ]]; then
        echo "FAIL: snippet ($snippet) not found in Caddyfile.tpl"
        exit 1
    fi
    if ! echo "$body" | grep -E 'header_up X-Channel-Tag[[:space:]]+\{upstream_hostport\}' >/dev/null; then
        echo "FAIL: ($snippet) missing 'header_up X-Channel-Tag {upstream_hostport}'"
        echo "--- snippet body ---"
        echo "$body"
        exit 1
    fi
    echo "OK: ($snippet) has X-Channel-Tag propagation"
done
echo "ALL UPSTREAM SNIPPETS TAG REQUESTS CORRECTLY"
