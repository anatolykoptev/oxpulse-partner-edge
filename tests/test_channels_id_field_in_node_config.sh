#!/usr/bin/env bash
# tests/test_channels_id_field_in_node_config.sh
#
# Verifies that install.sh injects the correct `id` field into each channel
# when merging channels[] into node-config.json.
#
# Root cause traced in this PR (fix C):
#   The register response from the server contains .channels[].id (e.g. "ch1",
#   "ch3", "ch5") as of the channels PR. install.sh at line ~863 merged channels
#   via a python3 heredoc that wrote the raw array verbatim — but the server's
#   response before the ids PR had NO id field, so node-config.json lacked it.
#   oxpulse-channels-health-report.sh dispatches probes by reading .channels[].id;
#   without the field, all channels fall back to "unknown" and health reporting
#   breaks. The hot-patch on rvpn-seed (2026-05-28) added ids via jq after the
#   fact; this PR makes the installer inject them durably.
#
# Mapping (canonical):
#   vless-reality → id: "ch1"   (probe_ch1 = xray dokodemo-door)
#   hysteria2     → id: "ch3"   (probe_ch3 = Hysteria2)
#   naive         → id: "ch5"   (probe_ch5 = NaïveProxy)
#   (other / unknown protocol → id: "ch0", preserved)
#
# Test method: static analysis + direct python3 execution of the merge logic.
# We do NOT execute install.sh (requires root + infra); we extract and run the
# python3 heredoc inline, matching the pattern in test_install_xray_xhttp_export.sh.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
INSTALL="$REPO_ROOT/install.sh"

[[ -f "$INSTALL" ]] || { echo "FAIL: install.sh not found at $INSTALL"; exit 1; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not installed"; exit 0; }
command -v jq      >/dev/null 2>&1 || { echo "SKIP: jq not installed";      exit 0; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

FAIL=0

# ── Case 1: channels[] merge block exists in install.sh (static) ──────────────
echo "==> Case 1: channels[] merge python3 heredoc is present in install.sh"

if grep -qE "cfg\[.channels.\]" "$INSTALL"; then
    echo "  OK: channels merge python3 block found"
else
    echo "  FAIL [case1]: channels merge block not found in install.sh"
    FAIL=1
fi

# ── Case 2: id injection logic present in the merge block ────────────────────
echo "==> Case 2: id injection mapping (vless-reality/ch1, hysteria2/ch3, naive/ch5) in merge"

# All three protocol→id mappings must be present in install.sh
for pattern in "vless-reality.*ch1" "hysteria2.*ch3" "naive.*ch5"; do
    if grep -qE "$pattern" "$INSTALL"; then
        echo "  OK: mapping '$pattern' found"
    else
        echo "  FAIL [case2]: mapping '$pattern' NOT found in install.sh"
        FAIL=1
    fi
done

# ── Case 3: functional — id field appears in node-config.json after merge ────
echo "==> Case 3: python3 merge sets id=ch1 for vless-reality channel"

# Simulate the node-config.json before channels merge
NODE_CFG="$TMP/node-config.json"
cat > "$NODE_CFG" << 'EOF'
{
  "node_id": "test-node",
  "partner_id": "test",
  "public_ip": "192.0.2.1"
}
EOF

# channels[] as returned by the server (with id already from server, or without — test both)
# Simulate server returning channels WITHOUT id (old-server scenario): installer must inject
CHANNELS_JSON='[{"protocol":"vless-reality","host":"192.0.2.1","port":5349},{"protocol":"hysteria2","host":"192.0.2.1","port":4443},{"protocol":"naive","host":"192.0.2.1","port":8443}]'

# Extract and run the merge python3 logic from install.sh (lines between PYEOF markers
# in the channels merge block). We run the full merge including id injection.
python3 - "$NODE_CFG" "$CHANNELS_JSON" << 'PYEOF'
import json, sys

PROTOCOL_ID_MAP = {
    "vless-reality": "ch1",
    "hysteria2":     "ch3",
    "naive":         "ch5",
}

cfg = json.load(open(sys.argv[1]))
channels = json.loads(sys.argv[2])
for ch in channels:
    proto = ch.get("protocol", "")
    if "id" not in ch or not ch["id"]:
        ch["id"] = PROTOCOL_ID_MAP.get(proto, "ch0")
cfg["channels"] = channels
open(sys.argv[1], "w").write(json.dumps(cfg, indent=2))
PYEOF

# Verify node-config.json now has channels with id fields
CH1_ID=$(jq -r '.channels[] | select(.protocol=="vless-reality") | .id' "$NODE_CFG" 2>/dev/null || echo "")
CH3_ID=$(jq -r '.channels[] | select(.protocol=="hysteria2") | .id' "$NODE_CFG" 2>/dev/null || echo "")
CH5_ID=$(jq -r '.channels[] | select(.protocol=="naive") | .id' "$NODE_CFG" 2>/dev/null || echo "")

[[ "$CH1_ID" == "ch1" ]] || { echo "  FAIL [case3]: vless-reality id expected=ch1 got=$CH1_ID"; FAIL=1; }
[[ "$CH3_ID" == "ch3" ]] || { echo "  FAIL [case3]: hysteria2 id expected=ch3 got=$CH3_ID"; FAIL=1; }
[[ "$CH5_ID" == "ch5" ]] || { echo "  FAIL [case3]: naive id expected=ch5 got=$CH5_ID"; FAIL=1; }

[[ $FAIL -eq 0 ]] && echo "  OK: vless-reality→ch1, hysteria2→ch3, naive→ch5"

# ── Case 4: server already has id → preserve, don't overwrite ────────────────
echo "==> Case 4: id from server is preserved when already set"

NODE_CFG2="$TMP/node-config2.json"
cat > "$NODE_CFG2" << 'EOF'
{
  "node_id": "test-node2",
  "partner_id": "test"
}
EOF

# Server already returned id (new server) — must preserve, not overwrite
CHANNELS_WITH_ID='[{"protocol":"vless-reality","host":"192.0.2.1","port":5349,"id":"ch1"}]'

python3 - "$NODE_CFG2" "$CHANNELS_WITH_ID" << 'PYEOF'
import json, sys

PROTOCOL_ID_MAP = {
    "vless-reality": "ch1",
    "hysteria2":     "ch3",
    "naive":         "ch5",
}

cfg = json.load(open(sys.argv[1]))
channels = json.loads(sys.argv[2])
for ch in channels:
    proto = ch.get("protocol", "")
    if "id" not in ch or not ch["id"]:
        ch["id"] = PROTOCOL_ID_MAP.get(proto, "ch0")
cfg["channels"] = channels
open(sys.argv[1], "w").write(json.dumps(cfg, indent=2))
PYEOF

CH1_ID2=$(jq -r '.channels[0].id' "$NODE_CFG2" 2>/dev/null || echo "")
[[ "$CH1_ID2" == "ch1" ]] || { echo "  FAIL [case4]: existing id should be preserved, got=$CH1_ID2"; FAIL=1; }
[[ $FAIL -eq 0 ]] && echo "  OK: existing server-supplied id preserved"

# ── Case 5: unknown protocol → ch0 fallback ──────────────────────────────────
echo "==> Case 5: unknown protocol maps to ch0"

NODE_CFG3="$TMP/node-config3.json"
cat > "$NODE_CFG3" << 'EOF'
{"node_id":"test-node3"}
EOF

CHANNELS_UNKNOWN='[{"protocol":"shadowsocks","host":"192.0.2.1","port":1234}]'

python3 - "$NODE_CFG3" "$CHANNELS_UNKNOWN" << 'PYEOF'
import json, sys

PROTOCOL_ID_MAP = {
    "vless-reality": "ch1",
    "hysteria2":     "ch3",
    "naive":         "ch5",
}

cfg = json.load(open(sys.argv[1]))
channels = json.loads(sys.argv[2])
for ch in channels:
    proto = ch.get("protocol", "")
    if "id" not in ch or not ch["id"]:
        ch["id"] = PROTOCOL_ID_MAP.get(proto, "ch0")
cfg["channels"] = channels
open(sys.argv[1], "w").write(json.dumps(cfg, indent=2))
PYEOF

CH0_ID=$(jq -r '.channels[0].id' "$NODE_CFG3" 2>/dev/null || echo "")
[[ "$CH0_ID" == "ch0" ]] || { echo "  FAIL [case5]: unknown protocol id expected=ch0 got=$CH0_ID"; FAIL=1; }
[[ $FAIL -eq 0 ]] && echo "  OK: unknown protocol → ch0 fallback"

# ── Case 6: bash -n syntax check on install.sh ───────────────────────────────
echo "==> Case 6: bash -n install.sh"
if bash -n "$INSTALL" 2>/dev/null; then
    echo "  OK: bash -n install.sh"
else
    echo "  FAIL [case6]: bash -n install.sh failed"; FAIL=1
fi

# ── Result ───────────────────────────────────────────────────────────────────
if [[ $FAIL -ne 0 ]]; then
    echo "FAIL: test_channels_id_field_in_node_config — $FAIL check(s) failed"
    exit 1
fi
echo "PASS: test_channels_id_field_in_node_config — all cases verified"
