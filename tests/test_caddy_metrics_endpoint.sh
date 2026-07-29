#!/usr/bin/env bash
# Phase 5.8 Task 3 — verify Caddyfile.tpl contains 'metrics' inside servers{} block.
# Structural check on the template — does NOT require opec render.
set -euo pipefail

cd "$(dirname "$0")/.."

# Extract content between 'servers {' and its matching '}'
servers_block=$(awk '
    /^[[:space:]]*servers[[:space:]]*\{/ { in_block=1; depth=1; next }
    in_block {
        # Crude brace depth tracking — adequate for top-level Caddyfile.
        for (i=1; i<=length($0); i++) {
            c=substr($0,i,1)
            if (c=="{") depth++
            else if (c=="}") depth--
        }
        if (depth==0) { exit }
        print
    }
' Caddyfile.tpl)

if [[ -z "$servers_block" ]]; then
    echo "FAIL: no servers{} block found in Caddyfile.tpl"
    exit 1
fi

if ! echo "$servers_block" | grep -E '^[[:space:]]*metrics[[:space:]]*$' >/dev/null; then
    echo "FAIL: 'metrics' directive missing from servers{} block"
    echo "--- servers block content ---"
    echo "$servers_block"
    exit 1
fi

echo "OK: Caddyfile.tpl servers{} contains metrics directive"
