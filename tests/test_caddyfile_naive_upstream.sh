#!/usr/bin/env bash
# Phase 5.10 Task 9 — verify naive (127.0.0.1:NAIVE_SOCKS_PORT) appears
# as tertiary upstream in tunnel_upstream + tunnel_upstream_default snippets.
# Structural check on the template — Caddy active health_check will skip
# this upstream when the naive container is not deployed (cheap probe cost).
set -euo pipefail

cd "$(dirname "$0")/.."

for snippet in tunnel_upstream tunnel_upstream_default; do
    # Extract the reverse_proxy line inside the snippet
    line=$(awk -v name="$snippet" '
        $0 ~ "\\(" name "\\)[[:space:]]*\\{" { in_block=1; next }
        in_block && /reverse_proxy/ { print; exit }
    ' Caddyfile.tpl)
    if [[ -z "$line" ]]; then
        echo "FAIL: snippet ($snippet) — reverse_proxy line not found"
        exit 1
    fi
    if ! echo "$line" | grep -qE '127\.0\.0\.1:\{\{NAIVE_SOCKS_PORT\}\}'; then
        echo "FAIL: ($snippet) — naive upstream 127.0.0.1:{{NAIVE_SOCKS_PORT}} missing"
        echo "  actual: $line"
        exit 1
    fi
    echo "OK: ($snippet) has naive tertiary upstream"
done

echo "ALL NAIVE-UPSTREAM POOL CHECKS PASS"
