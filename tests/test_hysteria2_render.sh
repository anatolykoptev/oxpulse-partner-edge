#!/usr/bin/env bash
# Golden-file test for hysteria2-client.yaml rendering.
# Renders the template with known fixture values and compares to golden.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TPL="$REPO_ROOT/hysteria2-client.yaml.tpl"
GOLDEN="$SCRIPT_DIR/fixtures/hysteria2-client-golden.yaml"
RENDERED="$(mktemp)"
trap 'rm -f "$RENDERED"' EXIT

# Source the render library to get re_render_hysteria2()
source "$REPO_ROOT/channel-render-lib.sh"

# Set fixture values
KROLIK_SERVER="192.9.243.148:51822"
HY2_AUTH_PASS="GOLDEN_AUTH_PASS_FIXTURE"
HY2_OBFS_PASS="GOLDEN_OBFS_PASS_FIXTURE"
HY2_LOCAL_LISTEN="0.0.0.0:18443"
HY2_REMOTE_BACKEND="127.0.0.1:8907"

# Render
_render_hysteria2_to "$TPL" "$RENDERED" \
    "$KROLIK_SERVER" "$HY2_AUTH_PASS" "$HY2_OBFS_PASS" \
    "$HY2_LOCAL_LISTEN" "$HY2_REMOTE_BACKEND"

# Compare
if ! diff -u "$GOLDEN" "$RENDERED"; then
    echo "FAIL: rendered output differs from golden fixture"
    exit 1
fi
echo "PASS: hysteria2-client.yaml rendering matches golden"
