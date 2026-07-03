#!/bin/bash
# tests/test_reconcile_xray_reality_from_node_config.sh
#
# BUG 2 regression test — the xray_client reconcile surface must resolve the
# Reality / backend render vars from node-config.json so `opec render xray`
# produces a valid config instead of leaving {{REALITY_*}}/{{BACKEND_*}}
# placeholders (which the completeness guard then fail_soft-skips on EVERY edge,
# so the Reality re-render — the whole point of the surface — never happens).
#
# Root cause: _setup_xray_client_render_env only exported XRAY_XHTTP_* from
# node-config.json; REALITY_UUID/PUBLIC_KEY/SHORT_ID/SERVER_NAME/ENCRYPTION and
# BACKEND_HOST/PORT were never populated. install.env does NOT persist them —
# they live in node-config.json (the same flat keys install.sh json_get's), so
# sourcing install.env would not have fixed it. Fix: read those flat keys from
# node-config.json (mirrors _setup_coturn_render_env reading STATE/on-disk
# last-known-good) and export them for opec.
#
# Fail-closed (coturn TURN_SECRET landmine class): when the Reality creds cannot
# be resolved (node-config absent / reality_public_key empty), the surface must
# SKIP — never render a blank publicKey and swap it live (that would zero the
# VLESS tunnel; opec would emit "" not a {{placeholder}}, so the completeness
# guard would NOT catch it).
#
# Falsification:
#   R1/R2 (env resolution) FAIL before the fix (vars stay empty).
#   RENDER (valid creds => a swap + non-blank pubkey in the rendered file) FAILs
#     before the fix (placeholders remain → completeness guard skips → 0 swaps).
#   FAILCLOSED (empty reality_public_key => 0 swaps, live config kept) guards the
#     tunnel-zeroing regression.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LIB="$REPO_ROOT/lib/reconcile.sh"

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not installed"; exit 0; }

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

echo ""
echo "=== BUG2: xray_client surface resolves REALITY_*/BACKEND_* from node-config.json ==="

[[ -f "$LIB" ]] || { fail "P0: lib/reconcile.sh not found"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

log()  { :; }
warn() { printf '[warn] %s\n' "$*" >>"$TMP/warn.log"; }
die()  { printf '[die] %s\n' "$*" >>"$TMP/warn.log"; exit 1; }

# shellcheck source=lib/reconcile.sh
. "$LIB"

# --- Fixture node-config.json with the flat register-response keys install.sh reads. ---
_write_node_cfg() {
    local _dir="$1" _pubkey="$2"
    mkdir -p "$_dir"
    cat > "$_dir/node-config.json" << NODECFG
{
  "node_id": "test-node-01",
  "backend_endpoint": "192.0.2.7:5349",
  "reality_uuid": "00000000-0000-4000-8000-00000000abcd",
  "reality_public_key": "${_pubkey}",
  "reality_short_id": "0123abcd",
  "reality_server_name": "www.samsung.com",
  "reality_encryption": "none",
  "channels": [
    { "protocol": "vless-reality",
      "xray": { "xhttp": { "mode": "stream-one", "path": "/xh" } } }
  ]
}
NODECFG
}

# ---------------------------------------------------------------------------
# R1/R2: _setup_xray_client_render_env exports REALITY_*/BACKEND_* from node-config
# ---------------------------------------------------------------------------
ETC1="$TMP/etc1"
_write_node_cfg "$ETC1" "REALPUBKEY_deadbeef"

# Prove the values come from node-config, not the ambient env.
unset REALITY_UUID REALITY_PUBLIC_KEY REALITY_SHORT_ID REALITY_SERVER_NAME \
      REALITY_ENCRYPTION BACKEND_HOST BACKEND_PORT
_setup_xray_client_render_env "$ETC1"

if [[ "${REALITY_PUBLIC_KEY:-}" == "REALPUBKEY_deadbeef" ]]; then
    pass "R1: REALITY_PUBLIC_KEY resolved from node-config.json"
else
    fail "R1: REALITY_PUBLIC_KEY='${REALITY_PUBLIC_KEY:-<empty>}' (expected REALPUBKEY_deadbeef)"
fi
_ok=1
[[ "${REALITY_UUID:-}" == "00000000-0000-4000-8000-00000000abcd" ]] || _ok=0
[[ "${REALITY_SHORT_ID:-}" == "0123abcd" ]] || _ok=0
[[ "${REALITY_SERVER_NAME:-}" == "www.samsung.com" ]] || _ok=0
[[ "${REALITY_ENCRYPTION:-}" == "none" ]] || _ok=0
[[ "${BACKEND_HOST:-}" == "192.0.2.7" ]] || _ok=0
[[ "${BACKEND_PORT:-}" == "5349" ]] || _ok=0
if [[ "$_ok" -eq 1 ]]; then
    pass "R2: REALITY_UUID/SHORT_ID/SERVER_NAME/ENCRYPTION + BACKEND_HOST/PORT resolved"
else
    fail "R2: one+ reality/backend var unresolved (UUID='${REALITY_UUID:-}' SHORT='${REALITY_SHORT_ID:-}' SNI='${REALITY_SERVER_NAME:-}' ENC='${REALITY_ENCRYPTION:-}' HOST='${BACKEND_HOST:-}' PORT='${BACKEND_PORT:-}')"
fi

# ---------------------------------------------------------------------------
# RENDER: with valid creds the surface renders (no placeholder residue) + swaps.
# opec mock substitutes the resolved env into the output (real substitution, so
# an unresolved var would leave a {{...}} placeholder → completeness guard skips).
# ---------------------------------------------------------------------------
ETC2="$TMP/etc2"
_write_node_cfg "$ETC2" "REALPUBKEY_valid01"
# Minimal xray-client.json.tpl carrying the placeholders opec must resolve.
TPL="$TMP/xray.tpl"
printf '{"reality":{"publicKey":"{{REALITY_PUBLIC_KEY}}","uuid":"{{REALITY_UUID}}"},"backend":"{{BACKEND_HOST}}:{{BACKEND_PORT}}"}\n' > "$TPL"

_SWAP_COUNT=0
atomic_swap() { _SWAP_COUNT=$((_SWAP_COUNT+1)); cp "$2" "$1"; }
opec() {
    if [[ "${1:-}" == "render" && "${2:-}" == "xray" ]]; then
        local _tpl="" _out="" _next="" i
        for i in "$@"; do
            [[ "$_next" == "tpl" ]] && { _tpl="$i"; _next=""; }
            [[ "$_next" == "out" ]] && { _out="$i"; _next=""; }
            [[ "$i" == "--tpl" ]] && _next="tpl"
            [[ "$i" == "--out" ]] && _next="out"
        done
        # Substitute resolved env into the template (empty var => literal {{...}} stays).
        sed -e "s|{{REALITY_PUBLIC_KEY}}|${REALITY_PUBLIC_KEY:-{{REALITY_PUBLIC_KEY}}}|g" \
            -e "s|{{REALITY_UUID}}|${REALITY_UUID:-{{REALITY_UUID}}}|g" \
            -e "s|{{BACKEND_HOST}}|${BACKEND_HOST:-{{BACKEND_HOST}}}|g" \
            -e "s|{{BACKEND_PORT}}|${BACKEND_PORT:-{{BACKEND_PORT}}}|g" \
            "$_tpl" > "$_out"
        return 0
    fi
    return 0
}
export DOCKER_BIN=true
export COMPOSE_FILE="$TMP/docker-compose.yml"
printf 'services:\n  xray-client:\n    image: test\n' > "$COMPOSE_FILE"

unset REALITY_UUID REALITY_PUBLIC_KEY REALITY_SHORT_ID REALITY_SERVER_NAME \
      REALITY_ENCRYPTION BACKEND_HOST BACKEND_PORT
_b=$_SWAP_COUNT
reconcile_xray_client_surface "$ETC2" "$TPL" >/dev/null 2>&1 || true
_render_swaps=$((_SWAP_COUNT - _b))
if [[ "$_render_swaps" -ge 1 ]]; then
    pass "RENDER: valid creds => surface renders + swaps (Reality re-render actually happens)"
else
    fail "RENDER: valid creds => 0 swaps — placeholders unresolved, completeness guard skipped (bug present)"
fi
if [[ -f "$ETC2/xray-client.json" ]] && grep -q 'REALPUBKEY_valid01' "$ETC2/xray-client.json" \
   && ! grep -q '{{' "$ETC2/xray-client.json"; then
    pass "RENDER2: installed xray-client.json carries the real pubkey, no placeholder residue"
else
    fail "RENDER2: installed xray-client.json missing pubkey or has placeholder residue: $(cat "$ETC2/xray-client.json" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# FAILCLOSED: reality_public_key empty in node-config => SKIP, never swap a blank
# config live (tunnel-zeroing guard). A last-known-good installed config is kept.
# ---------------------------------------------------------------------------
ETC3="$TMP/etc3"
_write_node_cfg "$ETC3" ""   # empty reality_public_key
# Pre-existing good installed config that must NOT be clobbered.
printf '{"reality":{"publicKey":"GOOD_LAST_KNOWN"}}\n' > "$ETC3/xray-client.json"
_before_fc=$(cat "$ETC3/xray-client.json")
_b2=$_SWAP_COUNT
# Scrape the fail-closed observability gauge into a writable dir.
export PARTNER_EDGE_TEXTFILE_DIR="$TMP/textfile"
mkdir -p "$PARTNER_EDGE_TEXTFILE_DIR"
unset REALITY_UUID REALITY_PUBLIC_KEY REALITY_SHORT_ID REALITY_SERVER_NAME \
      REALITY_ENCRYPTION BACKEND_HOST BACKEND_PORT
reconcile_xray_client_surface "$ETC3" "$TPL" >/dev/null 2>&1 || true
_fc_swaps=$((_SWAP_COUNT - _b2))
if [[ "$_fc_swaps" -eq 0 ]]; then
    pass "FAILCLOSED: empty reality_public_key => 0 swaps (no blank Reality config swapped live)"
else
    fail "FAILCLOSED: empty reality_public_key triggered $_fc_swaps swap(s) — would zero the tunnel"
fi
if [[ "$(cat "$ETC3/xray-client.json")" == "$_before_fc" ]]; then
    pass "FAILCLOSED2: installed xray-client.json retains last-known-good (not degraded to blank)"
else
    fail "FAILCLOSED2: installed xray-client.json was overwritten: $(cat "$ETC3/xray-client.json")"
fi

# GAUGE: the fail-closed skip must emit the standing observability signal (=1).
_prom="$PARTNER_EDGE_TEXTFILE_DIR/partner_edge_xray.prom"
if [[ -f "$_prom" ]] && grep -qE '^partner_edge_xray_creds_unresolved 1$' "$_prom"; then
    pass "GAUGE: fail-closed skip emits partner_edge_xray_creds_unresolved=1 (silent-skip class observable)"
else
    fail "GAUGE: expected partner_edge_xray_creds_unresolved=1; got: $(cat "$_prom" 2>/dev/null || echo '<no file>')"
fi
# And the resolved (render) path must emit =0.
_prom2_dir="$TMP/textfile2"; mkdir -p "$_prom2_dir"
_write_node_cfg "$ETC2" "REALPUBKEY_gauge0"
unset REALITY_UUID REALITY_PUBLIC_KEY REALITY_SHORT_ID REALITY_SERVER_NAME \
      REALITY_ENCRYPTION BACKEND_HOST BACKEND_PORT
PARTNER_EDGE_TEXTFILE_DIR="$_prom2_dir" reconcile_xray_client_surface "$ETC2" "$TPL" >/dev/null 2>&1 || true
if grep -qE '^partner_edge_xray_creds_unresolved 0$' "$_prom2_dir/partner_edge_xray.prom" 2>/dev/null; then
    pass "GAUGE2: resolved-creds render path emits partner_edge_xray_creds_unresolved=0"
else
    fail "GAUGE2: expected partner_edge_xray_creds_unresolved=0 on render path; got: $(cat "$_prom2_dir/partner_edge_xray.prom" 2>/dev/null || echo '<no file>')"
fi

echo ""
echo "=== BUG2 xray reality-from-node-config tests: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
