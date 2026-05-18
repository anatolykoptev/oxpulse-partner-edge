#!/bin/bash
# Regression: install.sh exports XRAY_XHTTP_* env before render_with_opec xray
#
# Bug 4 (live-edge catch 2026-05-18): Phase 3 (#151) absorbed xray render into
# `opec render xray` which is pure mustache env-substitution.  Old bash
# re_render_xray read XRAY_XHTTP_* from node-config.json; after #151 install.sh
# never exported them → opec renders empty placeholders → invalid JSON →
# validation rejects → install fails at Step 5.
#
# This test covers:
#   Case 1: XRAY_XHTTP_* vars are exported in the render block (static check)
#   Case 2: inline python reads correct values from node-config with xhttp block
#   Case 3: inline python falls back to defaults when xhttp block is absent
#   Case 4: Bug 3 — AWG_MOTHERLY_IP / HY2_* have :- fallback in install.sh
#
# Test method: static analysis + direct inline-python execution.
# We do NOT execute install.sh (it requires root + real infra).
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
INSTALL="$REPO_ROOT/install.sh"
READ_XHTTP="$REPO_ROOT/scripts/read-xhttp.py"

[[ -f "$INSTALL" ]] || { echo "FAIL: install.sh not found at $INSTALL"; exit 1; }
[[ -f "$READ_XHTTP" ]] || { echo "FAIL: scripts/read-xhttp.py not found"; exit 1; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not installed"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

FAIL=0

# ── Case 1: XRAY_XHTTP_* are exported in install.sh render block (static) ──
echo "==> Case 1: install.sh exports XRAY_XHTTP_* before render_with_opec xray"

# Extract the render block: from "# `opec render` reads" comment to the
# first render_with_opec xray call.
awk '/opec render.*reads template placeholders from ambient env/,/render_with_opec xray/' \
    "$INSTALL" > "$TMP/render_block.txt"

[[ -s "$TMP/render_block.txt" ]] \
    || { echo "FAIL [case1]: could not locate render block in install.sh"; FAIL=1; }

for var in XRAY_XHTTP_MODE XRAY_XHTTP_PATH \
           XRAY_XHTTP_XMUX_MAX_CONCURRENCY \
           XRAY_XHTTP_XMUX_C_MAX_REUSE_TIMES \
           XRAY_XHTTP_XMUX_C_MAX_LIFETIME_MS \
           XRAY_XHTTP_X_PADDING_BYTES; do
    if ! grep -q "$var" "$TMP/render_block.txt"; then
        echo "FAIL [case1]: $var not found in render block before render_with_opec xray"
        FAIL=1
    fi
done

# The export line must reference all 6 XRAY_XHTTP_* vars
if grep -q "export.*XRAY_XHTTP_MODE" "$TMP/render_block.txt"; then
    echo "  OK: XRAY_XHTTP_* present in render block (export line found)"
else
    echo "FAIL [case1]: export of XRAY_XHTTP_* vars not found in render block"
    FAIL=1
fi

# ── Case 2: inline python reads correct values from node-config with xhttp block
echo "==> Case 2: python reads xhttp values when block present"

FIXTURE_WITH_XHTTP="$TMP/node-config-with-xhttp.json"
cat > "$FIXTURE_WITH_XHTTP" << 'FIXTURE_EOF'
{
  "node_id": "test-node-xhttp",
  "partner_id": "test",
  "public_ip": "192.0.2.5",
  "channels": [
    {
      "protocol": "vless-reality",
      "host": "192.0.2.5",
      "port": 5349,
      "xray": {
        "uuid": "00000000-0000-4000-8000-000000000099",
        "encryption": "none",
        "public_key": "testpubkey999",
        "short_id": "aabb1122",
        "server_names": ["samsung.com"],
        "xhttp": {
          "mode": "packet-up",
          "path": "/custom-path",
          "xmux": {
            "maxConcurrency": 4,
            "cMaxReuseTimes": 32,
            "cMaxLifetimeMs": 30000
          },
          "extra": {
            "xPaddingBytes": "200-2000"
          }
        }
      }
    }
  ]
}
FIXTURE_EOF

GOT_MODE=$(python3 "$READ_XHTTP" "$FIXTURE_WITH_XHTTP" mode --default stream-one)
GOT_PATH=$(python3 "$READ_XHTTP" "$FIXTURE_WITH_XHTTP" path --default /xh)
GOT_CONCURRENCY=$(python3 "$READ_XHTTP" "$FIXTURE_WITH_XHTTP" xmux_concurrency --default 1 --type int)
GOT_REUSE=$(python3 "$READ_XHTTP" "$FIXTURE_WITH_XHTTP" xmux_reuse --default 64 --type int)
GOT_LIFETIME=$(python3 "$READ_XHTTP" "$FIXTURE_WITH_XHTTP" xmux_lifetime --default 15000 --type int)
GOT_PADDING=$(python3 "$READ_XHTTP" "$FIXTURE_WITH_XHTTP" padding --default 100-1000)

[[ "$GOT_MODE" == "packet-up" ]]      || { echo "FAIL [case2]: mode expected=packet-up got=$GOT_MODE"; FAIL=1; }
[[ "$GOT_PATH" == "/custom-path" ]]   || { echo "FAIL [case2]: path expected=/custom-path got=$GOT_PATH"; FAIL=1; }
[[ "$GOT_CONCURRENCY" == "4" ]]       || { echo "FAIL [case2]: xmux_concurrency expected=4 got=$GOT_CONCURRENCY"; FAIL=1; }
[[ "$GOT_REUSE" == "32" ]]            || { echo "FAIL [case2]: xmux_reuse expected=32 got=$GOT_REUSE"; FAIL=1; }
[[ "$GOT_LIFETIME" == "30000" ]]      || { echo "FAIL [case2]: xmux_lifetime expected=30000 got=$GOT_LIFETIME"; FAIL=1; }
[[ "$GOT_PADDING" == "200-2000" ]]    || { echo "FAIL [case2]: padding expected=200-2000 got=$GOT_PADDING"; FAIL=1; }

[[ $FAIL -eq 0 ]] && echo "  OK: xhttp values read correctly from fixture"

# ── Case 3: defaults when xhttp block absent ─────────────────────────────────
echo "==> Case 3: python returns defaults when xhttp block is absent"

FIXTURE_NO_XHTTP="$TMP/node-config-no-xhttp.json"
cat > "$FIXTURE_NO_XHTTP" << 'FIXTURE_EOF'
{
  "node_id": "test-node-no-xhttp",
  "partner_id": "test",
  "public_ip": "192.0.2.6",
  "channels": [
    {
      "protocol": "vless-reality",
      "host": "192.0.2.6",
      "port": 5349,
      "xray": {
        "uuid": "00000000-0000-4000-8000-000000000088",
        "encryption": "none",
        "public_key": "testpubkey888",
        "short_id": "ccdd3344"
      }
    }
  ]
}
FIXTURE_EOF

DEF_MODE=$(python3 "$READ_XHTTP" "$FIXTURE_NO_XHTTP" mode --default stream-one)
DEF_PATH=$(python3 "$READ_XHTTP" "$FIXTURE_NO_XHTTP" path --default /xh)
DEF_CONCURRENCY=$(python3 "$READ_XHTTP" "$FIXTURE_NO_XHTTP" xmux_concurrency --default 1 --type int)
DEF_REUSE=$(python3 "$READ_XHTTP" "$FIXTURE_NO_XHTTP" xmux_reuse --default 64 --type int)
DEF_LIFETIME=$(python3 "$READ_XHTTP" "$FIXTURE_NO_XHTTP" xmux_lifetime --default 15000 --type int)
DEF_PADDING=$(python3 "$READ_XHTTP" "$FIXTURE_NO_XHTTP" padding --default 100-1000)

[[ "$DEF_MODE" == "stream-one" ]]  || { echo "FAIL [case3]: default mode expected=stream-one got=$DEF_MODE"; FAIL=1; }
[[ "$DEF_PATH" == "/xh" ]]         || { echo "FAIL [case3]: default path expected=/xh got=$DEF_PATH"; FAIL=1; }
[[ "$DEF_CONCURRENCY" == "1" ]]    || { echo "FAIL [case3]: default xmux_concurrency expected=1 got=$DEF_CONCURRENCY"; FAIL=1; }
[[ "$DEF_REUSE" == "64" ]]         || { echo "FAIL [case3]: default xmux_reuse expected=64 got=$DEF_REUSE"; FAIL=1; }
[[ "$DEF_LIFETIME" == "15000" ]]   || { echo "FAIL [case3]: default xmux_lifetime expected=15000 got=$DEF_LIFETIME"; FAIL=1; }
[[ "$DEF_PADDING" == "100-1000" ]] || { echo "FAIL [case3]: default padding expected=100-1000 got=$DEF_PADDING"; FAIL=1; }

[[ $FAIL -eq 0 ]] && echo "  OK: defaults returned when xhttp block absent"

# ── Case 4: Bug 3 — AWG/HY2 vars have :- fallback in install.sh ─────────────
echo "==> Case 4: Bug 3 — OXPULSE_AWG_MOTHERLY_IP / HY2_* have :- fallback"

# All three assignments must use :- (not bare variable reference)
for pattern in \
    'AWG_MOTHERLY_IP.*OXPULSE_AWG_MOTHERLY_IP.*:-' \
    'HY2_FALLBACK_HOST.*OXPULSE_HY2_FALLBACK_HOST.*:-' \
    'HY2_FALLBACK_PORT.*OXPULSE_HY2_FALLBACK_PORT.*:-'; do
    if ! grep -P "$pattern" "$INSTALL" > /dev/null 2>&1; then
        echo "FAIL [case4]: install.sh missing :- fallback for pattern: $pattern"
        FAIL=1
    fi
done

[[ $FAIL -eq 0 ]] && echo "  OK: AWG/HY2 vars have :- fallback"

# ── Result ───────────────────────────────────────────────────────────────────
if [[ $FAIL -ne 0 ]]; then
    echo "FAIL: one or more xray xhttp export tests failed"
    exit 1
fi
echo "PASS: XRAY_XHTTP_* export + Bug 3 fallback — all 4 cases verified"
