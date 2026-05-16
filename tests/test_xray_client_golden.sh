#!/bin/bash
# Golden-file test for xray-client.json.tpl rendering.
#
# Renders the template with a fixture node-config.json, verifies the rendered
# JSON matches expected structure, and tests conditional xmux logic.
#
# Design: the server (oxpulse-chat) is the single source of truth for all
# xhttp transport settings. The edge has NO defaults — all values come from
# node-config.json (channels[0].xray.xhttp.*). This test guards that contract.
#
# Coverage:
#   1. Fixture node-config (packet-up) → rendered JSON is valid + xmux present.
#   2. Fixture node-config (stream-one) → rendered JSON is valid + xmux absent.
#   3. Fixture node-config (packet-up) → xhttpSettings values match fixture.
#
# Usage:
#   bash tests/test_xray_client_golden.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$REPO_ROOT/tests/fixtures"
TPL="$REPO_ROOT/xray-client.json.tpl"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not installed"; exit 0; }

[[ -f "$TPL" ]] || { echo "FAIL: xray-client.json.tpl not found at $TPL"; exit 1; }

# ---------------------------------------------------------------------------
# Helper: render template given a node-config.json fixture path.
# Mimics the logic in update.sh::render step + jq xmux strip.
# ---------------------------------------------------------------------------
render_from_fixture() {
    local fixture_node_cfg="$1"
    local out
    out=$(mktemp)

    # Read all xhttp fields from fixture (mirrors update.sh Step 4b)
    local xhttp_mode xhttp_path xmux_max_concurrency xmux_c_max_reuse_times xmux_c_max_lifetime_ms x_padding_bytes

    xhttp_mode=$(python3 -c "
import json,sys; d=json.load(open(sys.argv[1]))
ch=d.get('channels',[])
x=ch[0].get('xray',{}) if ch and ch[0].get('protocol','')=='vless-reality' else {}
xhttp=x.get('xhttp',{})
print(xhttp.get('mode','') or x.get('mode','stream-one'))" "$fixture_node_cfg" 2>/dev/null || echo "stream-one")
    xhttp_path=$(python3 -c "
import json,sys; d=json.load(open(sys.argv[1]))
ch=d.get('channels',[])
x=ch[0].get('xray',{}) if ch and ch[0].get('protocol','')=='vless-reality' else {}
print(x.get('xhttp',{}).get('path','/xh'))" "$fixture_node_cfg" 2>/dev/null || echo "/xh")
    xmux_max_concurrency=$(python3 -c "
import json,sys; d=json.load(open(sys.argv[1]))
ch=d.get('channels',[])
x=ch[0].get('xray',{}) if ch and ch[0].get('protocol','')=='vless-reality' else {}
xm=x.get('xhttp',{}).get('xmux') or x.get('xmux') or {}
print(xm.get('maxConcurrency',1))" "$fixture_node_cfg" 2>/dev/null || echo "1")
    xmux_c_max_reuse_times=$(python3 -c "
import json,sys; d=json.load(open(sys.argv[1]))
ch=d.get('channels',[])
x=ch[0].get('xray',{}) if ch and ch[0].get('protocol','')=='vless-reality' else {}
xm=x.get('xhttp',{}).get('xmux') or x.get('xmux') or {}
print(xm.get('cMaxReuseTimes',64))" "$fixture_node_cfg" 2>/dev/null || echo "64")
    xmux_c_max_lifetime_ms=$(python3 -c "
import json,sys; d=json.load(open(sys.argv[1]))
ch=d.get('channels',[])
x=ch[0].get('xray',{}) if ch and ch[0].get('protocol','')=='vless-reality' else {}
xm=x.get('xhttp',{}).get('xmux') or x.get('xmux') or {}
print(xm.get('cMaxLifetimeMs',15000))" "$fixture_node_cfg" 2>/dev/null || echo "15000")
    x_padding_bytes=$(python3 -c "
import json,sys; d=json.load(open(sys.argv[1]))
ch=d.get('channels',[])
x=ch[0].get('xray',{}) if ch and ch[0].get('protocol','')=='vless-reality' else {}
print(x.get('xhttp',{}).get('extra',{}).get('xPaddingBytes','100-1000'))" "$fixture_node_cfg" 2>/dev/null || echo "100-1000")

    _esc() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

    sed \
        -e "s|{{REALITY_UUID}}|00000000-0000-4000-8000-000000000001|g" \
        -e "s|{{REALITY_ENCRYPTION}}|none|g" \
        -e "s|{{REALITY_PUBLIC_KEY}}|testpubkey123|g" \
        -e "s|{{REALITY_SHORT_ID}}|abcd1234|g" \
        -e "s|{{REALITY_SERVER_NAME}}|samsung.com|g" \
        -e "s|{{BACKEND_HOST}}|192.0.2.1|g" \
        -e "s|{{BACKEND_PORT}}|5349|g" \
        -e "s|{{BACKEND_ENDPOINT}}|192.0.2.1:5349|g" \
        -e "s|{{XRAY_XHTTP_MODE}}|$(_esc "$xhttp_mode")|g" \
        -e "s|{{XRAY_XHTTP_PATH}}|$(_esc "$xhttp_path")|g" \
        -e "s|{{XRAY_XHTTP_XMUX_MAX_CONCURRENCY}}|$(_esc "$xmux_max_concurrency")|g" \
        -e "s|{{XRAY_XHTTP_XMUX_C_MAX_REUSE_TIMES}}|$(_esc "$xmux_c_max_reuse_times")|g" \
        -e "s|{{XRAY_XHTTP_XMUX_C_MAX_LIFETIME_MS}}|$(_esc "$xmux_c_max_lifetime_ms")|g" \
        -e "s|{{XRAY_XHTTP_X_PADDING_BYTES}}|$(_esc "$x_padding_bytes")|g" \
        "$TPL" > "$out"

    # Strip xmux when mode != packet-up (mirrors update.sh logic)
    if [[ "$xhttp_mode" != "packet-up" ]]; then
        local jq_tmp
        jq_tmp=$(mktemp)
        jq 'del(.outbounds[].streamSettings.xhttpSettings.xmux)' "$out" > "$jq_tmp" \
            && mv "$jq_tmp" "$out" \
            || rm -f "$jq_tmp"
    fi

    printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# Fixture: packet-up node-config
# ---------------------------------------------------------------------------
FIXTURE_PACKET_UP=$(mktemp)
cat > "$FIXTURE_PACKET_UP" << 'FIXTURE_EOF'
{
  "node_id": "test-node-001",
  "partner_id": "test",
  "public_ip": "192.0.2.1",
  "reality_uuid": "00000000-0000-4000-8000-000000000001",
  "reality_public_key": "testpubkey123",
  "reality_short_id": "abcd1234",
  "reality_server_name": "samsung.com",
  "reality_server_names": ["samsung.com"],
  "reality_encryption": "none",
  "backend_endpoint": "192.0.2.1:5349",
  "channels_version": "abcd1234ef567890",
  "channels": [
    {
      "protocol": "vless-reality",
      "host": "192.0.2.1",
      "port": 5349,
      "xray": {
        "uuid": "00000000-0000-4000-8000-000000000001",
        "encryption": "none",
        "public_key": "testpubkey123",
        "short_id": "abcd1234",
        "server_names": ["samsung.com"],
        "mode": "packet-up",
        "xmux": {
          "maxConcurrency": 1,
          "cMaxReuseTimes": 64,
          "cMaxLifetimeMs": 15000
        },
        "xhttp": {
          "mode": "packet-up",
          "path": "/xh",
          "xmux": {
            "maxConcurrency": 1,
            "cMaxReuseTimes": 64,
            "cMaxLifetimeMs": 15000
          },
          "extra": {
            "xPaddingBytes": "100-1000"
          }
        }
      }
    }
  ]
}
FIXTURE_EOF

# ---------------------------------------------------------------------------
# Fixture: stream-one node-config
# ---------------------------------------------------------------------------
FIXTURE_STREAM_ONE=$(mktemp)
cat > "$FIXTURE_STREAM_ONE" << 'FIXTURE_EOF'
{
  "node_id": "test-node-002",
  "partner_id": "test",
  "public_ip": "192.0.2.2",
  "reality_uuid": "00000000-0000-4000-8000-000000000002",
  "reality_public_key": "testpubkey456",
  "reality_short_id": "efgh5678",
  "reality_server_name": "samsung.com",
  "reality_server_names": ["samsung.com"],
  "reality_encryption": "none",
  "backend_endpoint": "192.0.2.2:5349",
  "channels_version": "abcd1234ef567890",
  "channels": [
    {
      "protocol": "vless-reality",
      "host": "192.0.2.2",
      "port": 5349,
      "xray": {
        "uuid": "00000000-0000-4000-8000-000000000002",
        "encryption": "none",
        "public_key": "testpubkey456",
        "short_id": "efgh5678",
        "server_names": ["samsung.com"],
        "mode": "stream-one",
        "xhttp": {
          "mode": "stream-one",
          "path": "/xh",
          "extra": {
            "xPaddingBytes": "100-1000"
          }
        }
      }
    }
  ]
}
FIXTURE_EOF

trap 'rm -f "$FIXTURE_PACKET_UP" "$FIXTURE_STREAM_ONE"' EXIT

FAIL=0

# ---------------------------------------------------------------------------
# Test 1: packet-up renders valid JSON
# ---------------------------------------------------------------------------
echo "==> Test 1: packet-up fixture renders valid JSON"
OUT1=$(render_from_fixture "$FIXTURE_PACKET_UP")
trap 'rm -f "$FIXTURE_PACKET_UP" "$FIXTURE_STREAM_ONE" "$OUT1"' EXIT

if ! python3 -m json.tool "$OUT1" > /dev/null 2>&1; then
    echo "FAIL: packet-up fixture rendered invalid JSON"
    cat "$OUT1" >&2
    FAIL=1
else
    echo "  OK: valid JSON"
fi

# ---------------------------------------------------------------------------
# Test 2: packet-up → xmux present, correct values
# ---------------------------------------------------------------------------
echo "==> Test 2: packet-up → xmux block present with correct values"
MODE=$(jq -r '.outbounds[0].streamSettings.xhttpSettings.mode' "$OUT1")
PATH_VAL=$(jq -r '.outbounds[0].streamSettings.xhttpSettings.path' "$OUT1")
XMUX=$(jq '.outbounds[0].streamSettings.xhttpSettings.xmux' "$OUT1")
MAX_CONCURRENCY=$(jq '.outbounds[0].streamSettings.xhttpSettings.xmux.maxConcurrency' "$OUT1")
PADDING=$(jq -r '.outbounds[0].streamSettings.xhttpSettings.extra.xPaddingBytes' "$OUT1")

[[ "$MODE" == "packet-up" ]] || { echo "FAIL: expected mode=packet-up, got $MODE"; FAIL=1; }
[[ "$PATH_VAL" == "/xh" ]] || { echo "FAIL: expected path=/xh, got $PATH_VAL"; FAIL=1; }
[[ "$XMUX" != "null" ]] || { echo "FAIL: xmux must be present for packet-up"; FAIL=1; }
[[ "$MAX_CONCURRENCY" == "1" ]] || { echo "FAIL: expected xmux.maxConcurrency=1, got $MAX_CONCURRENCY"; FAIL=1; }
[[ "$PADDING" == "100-1000" ]] || { echo "FAIL: expected xPaddingBytes=100-1000, got $PADDING"; FAIL=1; }
[[ $FAIL -eq 0 ]] && echo "  OK: xmux present with correct values"

# ---------------------------------------------------------------------------
# Test 3: stream-one renders valid JSON
# ---------------------------------------------------------------------------
echo "==> Test 3: stream-one fixture renders valid JSON"
OUT2=$(render_from_fixture "$FIXTURE_STREAM_ONE")
trap 'rm -f "$FIXTURE_PACKET_UP" "$FIXTURE_STREAM_ONE" "$OUT1" "$OUT2"' EXIT

if ! python3 -m json.tool "$OUT2" > /dev/null 2>&1; then
    echo "FAIL: stream-one fixture rendered invalid JSON"
    cat "$OUT2" >&2
    FAIL=1
else
    echo "  OK: valid JSON"
fi

# ---------------------------------------------------------------------------
# Test 4: stream-one → xmux absent
# ---------------------------------------------------------------------------
echo "==> Test 4: stream-one → xmux block must be absent"
MODE2=$(jq -r '.outbounds[0].streamSettings.xhttpSettings.mode' "$OUT2")
XMUX2=$(jq '.outbounds[0].streamSettings.xhttpSettings | has("xmux")' "$OUT2")

[[ "$MODE2" == "stream-one" ]] || { echo "FAIL: expected mode=stream-one, got $MODE2"; FAIL=1; }
[[ "$XMUX2" == "false" ]] || { echo "FAIL: xmux must be absent for stream-one, has(xmux)=$XMUX2"; FAIL=1; }
[[ $FAIL -eq 0 ]] && echo "  OK: xmux absent for stream-one"

# ---------------------------------------------------------------------------
# Test 5: realitySettings still present in both renders
# ---------------------------------------------------------------------------
echo "==> Test 5: realitySettings block present in both renders"
for out in "$OUT1" "$OUT2"; do
    FINGERPRINT=$(jq -r '.outbounds[0].streamSettings.realitySettings.fingerprint' "$out")
    PUBKEY=$(jq -r '.outbounds[0].streamSettings.realitySettings.publicKey' "$out")
    [[ "$FINGERPRINT" == "randomized" ]] || { echo "FAIL: realitySettings.fingerprint must be 'randomized', got $FINGERPRINT"; FAIL=1; }
    [[ -n "$PUBKEY" && "$PUBKEY" != "null" ]] || { echo "FAIL: realitySettings.publicKey must be present"; FAIL=1; }
done
[[ $FAIL -eq 0 ]] && echo "  OK: realitySettings present in both renders"

# ---------------------------------------------------------------------------
# Cleanup and result
# ---------------------------------------------------------------------------
rm -f "$OUT1" "$OUT2"

if [[ $FAIL -ne 0 ]]; then
    echo "FAIL: one or more xray-client golden tests failed"
    exit 1
fi
echo "PASS: xray-client.json.tpl renders correctly for packet-up and stream-one modes"
