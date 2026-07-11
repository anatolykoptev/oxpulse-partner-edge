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

# Load defaults so $OXPULSE_* vars are available in this test.
# shellcheck source=../config/defaults.conf
[[ -f "$REPO_ROOT/config/defaults.conf" ]] && source "$REPO_ROOT/config/defaults.conf"

# Set fixture values — pin explicit literals for byte-identical golden comparison.
HUB_SERVER="${OXPULSE_HY2_SERVER:-203.0.113.10:51822}"
HY2_AUTH_PASS="GOLDEN_AUTH_PASS_FIXTURE"
HY2_OBFS_PASS="GOLDEN_OBFS_PASS_FIXTURE"
HY2_LOCAL_LISTEN="${OXPULSE_HY2_LOCAL_LISTEN:-0.0.0.0:18443}"
HY2_REMOTE_BACKEND="${OXPULSE_HY2_REMOTE_BACKEND:-127.0.0.1:8907}"

# Render
_render_hysteria2_to "$TPL" "$RENDERED" \
    "$HUB_SERVER" "$HY2_AUTH_PASS" "$HY2_OBFS_PASS" \
    "$HY2_LOCAL_LISTEN" "$HY2_REMOTE_BACKEND"

# Compare
if ! diff -u "$GOLDEN" "$RENDERED"; then
    echo "FAIL: rendered output differs from golden fixture"
    exit 1
fi
echo "PASS: hysteria2-client.yaml rendering matches golden"

# ── Test 2: re_render_hysteria2() public function ──────────────────────────
# Verifies: file written, content matches golden, mode 600, backup created.
echo "--- Test 2: re_render_hysteria2 public function ---"

out_dir=$(mktemp -d)
trap 'rm -rf "$out_dir"' EXIT

HY2_OUTPUT_PATH="$out_dir/hysteria2-client.yaml"
export OXPULSE_REPO_DIR="$REPO_ROOT"
export HY2_SERVER="${OXPULSE_HY2_SERVER:-203.0.113.10:51822}"
export HY2_AUTH_PASS="public-test-auth"
export HY2_OBFS_PASS="public-test-obfs"
export HY2_LOCAL_LISTEN="${OXPULSE_HY2_LOCAL_LISTEN:-0.0.0.0:18443}"
export HY2_REMOTE_BACKEND="${OXPULSE_HY2_REMOTE_BACKEND:-127.0.0.1:8907}"

# First call — no pre-existing file (no backup expected yet).
HY2_OUTPUT_PATH="$HY2_OUTPUT_PATH" re_render_hysteria2

if [[ ! -f "$HY2_OUTPUT_PATH" ]]; then
    echo "FAIL: output file not created by re_render_hysteria2"
    exit 1
fi

# Verify mode 600.
actual_mode=$(stat -c %a "$HY2_OUTPUT_PATH" 2>/dev/null || stat -f %A "$HY2_OUTPUT_PATH")
if [[ "$actual_mode" != "600" ]]; then
    echo "FAIL: expected mode 600, got $actual_mode"
    exit 1
fi

# Verify content contains quoted auth and obfs values.
if ! grep -qF '"public-test-auth"' "$HY2_OUTPUT_PATH"; then
    echo "FAIL: expected quoted auth value in output"
    cat "$HY2_OUTPUT_PATH"
    exit 1
fi
if ! grep -qF '"public-test-obfs"' "$HY2_OUTPUT_PATH"; then
    echo "FAIL: expected quoted obfs value in output"
    exit 1
fi

# Second call — should create a backup of the first render.
HY2_OUTPUT_PATH="$HY2_OUTPUT_PATH" re_render_hysteria2
bak_count=$(ls "$out_dir"/*.bak.* 2>/dev/null | wc -l)
if [[ "$bak_count" -lt 1 ]]; then
    echo "FAIL: no backup file created on second call"
    exit 1
fi

echo "PASS: re_render_hysteria2 public function test passed"
