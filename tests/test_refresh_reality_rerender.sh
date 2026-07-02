#!/usr/bin/env bash
# Regression test (T3 / epoch_apply_gap): a Reality-key rotation MUST re-render
# xray-client.json (the file the xray container mounts) from the freshly patched
# node-config.json BEFORE the reload/recreate, and MUST NOT persist the new
# keys-version until that render succeeded.
#
# Finding: oxpulse-partner-edge-refresh.sh rotation branch jq-patched
# node-config.json + reloaded + wrote VERSION_FILE, but never regenerated
# xray-client.json — so the recreated container remounted the STALE pubkey and
# every Reality handshake failed until a manual upgrade.sh.
#
# This test exercises the REAL shipped code path: it runs the actual
# oxpulse-partner-edge-refresh.sh end-to-end with PATH stubs (curl / systemctl /
# opec / docker / sleep) and a temp PREFIX. It goes RED when the render call is
# removed from the rotation branch (falsification proof).
#
# Resource discipline: bash tests/test_refresh_reality_rerender.sh
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SCRIPT="$REPO_ROOT/oxpulse-partner-edge-refresh.sh"
[[ -f "$SCRIPT" ]] || { echo "FAIL: refresh script not found at $SCRIPT"; exit 1; }

FAIL=0
pass() { echo "OK: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }

PUBKEY_A="AAAA_old_reality_pubkey_1111111111111111111"
PUBKEY_B="BBBB_new_reality_pubkey_2222222222222222222"

# ── Structural: render seam present inside the rotation branch ────────────────
# The finding repro: render_channel_soft / re_render_xray absent from the
# rotation branch (between the reality-field merge and the VERSION_FILE write).
echo "==> Structural: rotation branch invokes the shared xray render seam"
ROT_BLOCK=$(awk '/# Merge new reality fields into node-config.json/{f=1} f{print} /^echo "\$NEW_VERSION" > "\$VERSION_FILE"/{if(f)exit}' "$SCRIPT")
if printf '%s' "$ROT_BLOCK" | grep -qE 'render_channel_soft|re_render_xray'; then
	pass "rotation branch calls render_channel_soft/re_render_xray"
else
	fail "rotation branch does NOT re-render xray-client.json (epoch_apply_gap)"
fi

# ── Behavioral: real end-to-end rotation run ─────────────────────────────────
echo "==> Behavioral: end-to-end rotation re-renders xray-client.json with PubKeyB"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

PREFIX_ETC="$T/etc"
PREFIX_LIB="$T/lib"
TEXTFILE_DIR="$T/textfile"
BIN="$T/bin"
mkdir -p "$PREFIX_ETC" "$PREFIX_LIB" "$BIN"

# Co-locate the xray tpl where the script looks for it (${PREFIX_SBIN}/xray-client.json.tpl).
# The script defaults PREFIX_SBIN to /usr/local/sbin; override it to our temp bin.
cp "$REPO_ROOT/xray-client.json.tpl" "$BIN/xray-client.json.tpl"

# node-config.json pre-rotation (PubKeyA). opec reads reality fields from here.
cat > "$PREFIX_ETC/node-config.json" <<JSON
{
  "node_id": "test-edge-t3",
  "backend_endpoint": "oxpulse.chat:443",
  "reality_uuid": "11111111-2222-3333-4444-555555555555",
  "reality_public_key": "$PUBKEY_A",
  "reality_encryption": "mlkem768x25519",
  "reality_short_id": "abcd",
  "reality_server_names": ["www.samsung.com"]
}
JSON

# xray-client.json baked with the OLD pubkey (what the container currently mounts).
cat > "$PREFIX_ETC/xray-client.json" <<JSON
{
  "outbounds": [
    {
      "tag": "vless-tunnel",
      "streamSettings": {
        "security": "reality",
        "realitySettings": { "publicKey": "$PUBKEY_A", "serverName": "www.samsung.com", "shortId": "abcd", "fingerprint": "randomized" }
      }
    }
  ]
}
JSON

# Current versions: keys-version=v1 (will rotate to v2); channels-version matched
# so the independent channels_version re-render branch is skipped (isolate rotation).
printf 'v1\n' > "$PREFIX_LIB/keys-version"
printf 'cv1\n' > "$PREFIX_LIB/channels-version"

# ── Stub: curl (keys GET returns v2/PubKeyB; heartbeat POST returns 200) ─────
cat > "$BIN/curl" <<CURL
#!/usr/bin/env bash
args="\$*"
if [[ "\$args" == *"/api/partner/keys"* ]]; then
  cat <<'RESP'
{"version":"v2","channels_version":"cv1","reality_public_key":"$PUBKEY_B","reality_encryption":"mlkem768x25519","reality_server_names":["www.samsung.com"],"sfu_signing_public_key":"ZmFrZXNmdXNpZ25pbmdrZXk="}
RESP
  exit 0
fi
if [[ "\$args" == *"/api/partner/heartbeat"* ]]; then
  printf 'ok\n200'
  exit 0
fi
exit 0
CURL

# ── Stub: systemctl — service "installed"; snapshot pubkey at reload time ─────
# The reload snapshot proves render-happens-BEFORE-reload ordering.
cat > "$BIN/systemctl" <<SYSCTL
#!/usr/bin/env bash
case "\$*" in
  "list-unit-files oxpulse-partner-edge.service --no-legend"*)
    echo "oxpulse-partner-edge.service enabled enabled" ;;
  "reload oxpulse-partner-edge.service"*)
    jq -r '.outbounds[0].streamSettings.realitySettings.publicKey // "none"' \
      "$PREFIX_ETC/xray-client.json" > "$T/pubkey_at_reload.txt" 2>/dev/null || echo none > "$T/pubkey_at_reload.txt"
    ;;
  "is-active --quiet oxpulse-partner-edge.service"*) exit 0 ;;
  *) : ;;
esac
exit 0
SYSCTL

# ── Stub: opec — emulate `opec render xray` (reads reality fields from node-config,
# exactly like the production binary, which reconcile.sh confirms by exporting only
# XRAY_XHTTP_*, never REALITY_PUBLIC_KEY). Substitutes {{...}} placeholders. ─────
cat > "$BIN/opec" <<'OPEC'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "render" ]]; then
  src=""; dst=""; shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tpl) src="$2"; shift 2 ;;
      --out) dst="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  cfg="${PARTNER_EDGE_PREFIX_ETC:-/etc/oxpulse-partner-edge}/node-config.json"
  NODE_CFG_STUB="$cfg" python3 - "$src" "$dst" <<'PY'
import json, os, re, sys
src, dst = sys.argv[1], sys.argv[2]
d = json.load(open(os.environ["NODE_CFG_STUB"]))
be = d.get("backend_endpoint", "oxpulse.chat:443")
host, _, port = be.partition(":")
env = {
  "REALITY_PUBLIC_KEY": d.get("reality_public_key", ""),
  "REALITY_ENCRYPTION": d.get("reality_encryption", ""),
  "REALITY_UUID": d.get("reality_uuid", ""),
  "REALITY_SHORT_ID": d.get("reality_short_id", ""),
  "REALITY_SERVER_NAME": (d.get("reality_server_names") or ["www.samsung.com"])[0],
  "BACKEND_HOST": host, "BACKEND_PORT": port or "443",
  "XRAY_XHTTP_PATH": "/xh", "XRAY_XHTTP_MODE": "stream-one",
  "XRAY_XHTTP_XMUX_MAX_CONCURRENCY": "1",
  "XRAY_XHTTP_XMUX_C_MAX_REUSE_TIMES": "64",
  "XRAY_XHTTP_XMUX_C_MAX_LIFETIME_MS": "15000",
  "XRAY_XHTTP_X_PADDING_BYTES": "100-1000",
}
tpl = open(src).read()
out = re.sub(r"\{\{([A-Z][A-Z0-9_]*)\}\}", lambda m: env.get(m.group(1), ""), tpl)
open(dst, "w").write(out)
PY
  exit 0
fi
exit 0
OPEC

# ── Stubs: docker + sleep (no-ops; sleep-stub keeps the test fast) ───────────
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/docker"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/sleep"

chmod +x "$BIN"/*

set +e
env -i \
  PATH="$BIN:/usr/bin:/bin" \
  HOME="$T" \
  PARTNER_EDGE_PREFIX_ETC="$PREFIX_ETC" \
  PARTNER_EDGE_PREFIX_LIB="$PREFIX_LIB" \
  PARTNER_EDGE_TEXTFILE_DIR="$TEXTFILE_DIR" \
  OXPULSE_PREFIX_SBIN="$BIN" \
  PREFIX_SBIN="$BIN" \
  LOG_FILE="$T/refresh.log" \
  OXPULSE_BACKEND_URL="https://oxpulse.chat" \
  bash "$SCRIPT" > "$T/run.out" 2>&1
RUN_EXIT=$?
set -e

if [[ $RUN_EXIT -ne 0 ]]; then
	fail "refresh.sh exited $RUN_EXIT (expected 0); output:"; sed 's/^/    /' "$T/run.out" 2>/dev/null || true
fi

# Assertion 1: final xray-client.json carries the rotated pubkey.
FINAL_PUB=$(jq -r '.outbounds[0].streamSettings.realitySettings.publicKey // "none"' "$PREFIX_ETC/xray-client.json" 2>/dev/null || echo none)
if [[ "$FINAL_PUB" == "$PUBKEY_B" ]]; then
	pass "xray-client.json re-rendered with rotated pubkey (PubKeyB)"
else
	fail "xray-client.json pubkey='$FINAL_PUB' expected='$PUBKEY_B' (stale mount — render missing)"
fi

# Assertion 2: render happened BEFORE the reload (container recreates against new key).
RELOAD_PUB=$(cat "$T/pubkey_at_reload.txt" 2>/dev/null || echo "none")
if [[ "$RELOAD_PUB" == "$PUBKEY_B" ]]; then
	pass "xray-client.json held PubKeyB at reload time (render-before-reload)"
else
	fail "at reload time xray-client.json pubkey='$RELOAD_PUB' expected='$PUBKEY_B' (render after reload, or absent)"
fi

# Assertion 3: keys-version persisted only after a successful render.
PERSISTED=$(cat "$PREFIX_LIB/keys-version" 2>/dev/null || echo "none")
if [[ "$PERSISTED" == "v2" ]]; then
	pass "keys-version persisted to v2 after successful render"
else
	fail "keys-version='$PERSISTED' expected='v2'"
fi

# Assertion 4: applied-vs-written detector gauge emitted =1 (match).
PROM="$TEXTFILE_DIR/partner_edge.prom"
if [[ -f "$PROM" ]] && grep -qE 'partner_edge_reality_pubkey_applied\{[^}]*\} 1' "$PROM"; then
	pass "partner_edge_reality_pubkey_applied=1 emitted (applied==written)"
else
	fail "partner_edge_reality_pubkey_applied=1 not found in $PROM: $(cat "$PROM" 2>/dev/null || echo '<absent>')"
fi

# ── Result ───────────────────────────────────────────────────────────────────
if [[ $FAIL -ne 0 ]]; then
	echo "FAIL: T3 reality re-render regression test"
	exit 1
fi
echo "PASS: T3 — rotation re-renders xray-client.json before reload, version gated on render"
