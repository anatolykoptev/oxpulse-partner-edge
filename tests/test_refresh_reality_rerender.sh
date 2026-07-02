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
PUBKEY_C="CCCC_new_reality_pubkey_3333333333333333333"

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

# ── Negative path: a failed render MUST roll back and NOT advance the version ──
# Finding (critical, review round 1): the rotation gate treated the render
# function's exit code as pass/fail, but re_render_xray's soft-fail paths
# (template fetch failure, missing fields, missing node-config) warn and
# `return 0` WITHOUT writing a new config. With opec ABSENT and the REPO_RAW
# template fetch FAILING, the old gate logged a false success, reloaded, and
# persisted the new keys-version while xray-client.json still held the OLD
# pubkey — the exact epoch_apply_gap this task closes, now hidden behind a
# "success" log line and never retried until a manual upgrade.sh.
echo "==> Negative: opec absent + template fetch fails ⇒ rollback, exit!=0, version NOT advanced"
N=$(mktemp -d)
trap 'rm -rf "$T" "$N"' EXIT

N_ETC="$N/etc"; N_LIB="$N/lib"; N_TEXT="$N/textfile"; N_BIN="$N/bin"
mkdir -p "$N_ETC" "$N_LIB" "$N_BIN"

# NO opec in N_BIN (absent) → render_channel_soft returns 1 → re_render_xray
# fallback runs. Ship the real re_render_xray lib where the rotation branch
# sources it (${PREFIX_SBIN}/channel-render-lib.sh) so the fallback is exercised.
cp "$REPO_ROOT/channel-render-lib.sh" "$N_BIN/channel-render-lib.sh"
cp "$REPO_ROOT/xray-client.json.tpl" "$N_BIN/xray-client.json.tpl"

cat > "$N_ETC/node-config.json" <<JSON
{
  "node_id": "test-edge-t3-neg",
  "backend_endpoint": "oxpulse.chat:443",
  "reality_uuid": "11111111-2222-3333-4444-555555555555",
  "reality_public_key": "$PUBKEY_A",
  "reality_encryption": "mlkem768x25519",
  "reality_short_id": "abcd",
  "reality_server_names": ["www.samsung.com"]
}
JSON
cat > "$N_ETC/xray-client.json" <<JSON
{ "outbounds": [ { "streamSettings": { "realitySettings": { "publicKey": "$PUBKEY_A" } } } ] }
JSON
printf 'v1\n'  > "$N_LIB/keys-version"
printf 'cv1\n' > "$N_LIB/channels-version"

# curl: keys GET → v2/PubKeyB ok; heartbeat → 200; REPO_RAW xray tpl fetch → FAIL.
cat > "$N_BIN/curl" <<CURL
#!/usr/bin/env bash
args="\$*"
if [[ "\$args" == *"xray-client.json.tpl"* ]]; then exit 22; fi
if [[ "\$args" == *"/api/partner/keys"* ]]; then
  cat <<'RESP'
{"version":"v2","channels_version":"cv1","reality_public_key":"$PUBKEY_B","reality_encryption":"mlkem768x25519","reality_server_names":["www.samsung.com"],"sfu_signing_public_key":"ZmFrZQ=="}
RESP
  exit 0
fi
if [[ "\$args" == *"/api/partner/heartbeat"* ]]; then printf 'ok\n200'; exit 0; fi
exit 0
CURL
cat > "$N_BIN/systemctl" <<'SYSCTL'
#!/usr/bin/env bash
case "$*" in
  "list-unit-files oxpulse-partner-edge.service --no-legend"*)
    echo "oxpulse-partner-edge.service enabled enabled" ;;
  "is-active --quiet oxpulse-partner-edge.service"*) exit 0 ;;
  *) : ;;
esac
exit 0
SYSCTL
printf '#!/usr/bin/env bash\nexit 0\n' > "$N_BIN/docker"
printf '#!/usr/bin/env bash\nexit 0\n' > "$N_BIN/sleep"
chmod +x "$N_BIN"/*

set +e
env -i \
  PATH="$N_BIN:/usr/bin:/bin" \
  HOME="$N" \
  PARTNER_EDGE_PREFIX_ETC="$N_ETC" \
  PARTNER_EDGE_PREFIX_LIB="$N_LIB" \
  PARTNER_EDGE_TEXTFILE_DIR="$N_TEXT" \
  OXPULSE_PREFIX_SBIN="$N_BIN" \
  PREFIX_SBIN="$N_BIN" \
  LOG_FILE="$N/refresh.log" \
  OXPULSE_BACKEND_URL="https://oxpulse.chat" \
  bash "$SCRIPT" > "$N/run.out" 2>&1
NEG_EXIT=$?
set -e

if [[ $NEG_EXIT -ne 0 ]]; then
	pass "refresh.sh exited non-zero ($NEG_EXIT) on failed render (no false success)"
else
	fail "refresh.sh exited 0 despite a failed render — false success (epoch_apply_gap)"
	sed 's/^/    /' "$N/run.out" 2>/dev/null || true
fi

NEG_NODE_PUB=$(jq -r '.reality_public_key // "none"' "$N_ETC/node-config.json" 2>/dev/null || echo none)
if [[ "$NEG_NODE_PUB" == "$PUBKEY_A" ]]; then
	pass "node-config.json rolled back to PubKeyA after failed render"
else
	fail "node-config.json pubkey='$NEG_NODE_PUB' expected rollback to '$PUBKEY_A'"
fi

NEG_XRAY_PUB=$(jq -r '.outbounds[0].streamSettings.realitySettings.publicKey // "none"' "$N_ETC/xray-client.json" 2>/dev/null || echo none)
if [[ "$NEG_XRAY_PUB" == "$PUBKEY_A" ]]; then
	pass "xray-client.json unchanged (still PubKeyA) — no half-applied config"
else
	fail "xray-client.json pubkey='$NEG_XRAY_PUB' expected unchanged '$PUBKEY_A'"
fi

NEG_VER=$(cat "$N_LIB/keys-version" 2>/dev/null || echo none)
if [[ "$NEG_VER" == "v1" ]]; then
	pass "keys-version NOT advanced (still v1) — rotation retried next run"
else
	fail "keys-version='$NEG_VER' expected 'v1' (must not persist on failed render)"
fi

# ── Idempotency: two rotations must NOT accumulate a duplicate metric sample ──
# Finding (medium, review round 1): emit_metric appended (>>) forever, so the
# 2nd quarterly rotation wrote a 2nd partner_edge_reality_pubkey_applied line —
# a duplicate sample (same name+labels) that makes node_exporter's textfile
# collector reject the WHOLE file, blacking out ALL partner_edge_* metrics on
# the node. This runs a real double rotation and asserts a single sample survives.
echo "==> Idempotency: two successive rotations emit a single metric sample"
I=$(mktemp -d)
trap 'rm -rf "$T" "$N" "$I"' EXIT

I_ETC="$I/etc"; I_LIB="$I/lib"; I_TEXT="$I/textfile"; I_BIN="$I/bin"
mkdir -p "$I_ETC" "$I_LIB" "$I_BIN"
cp "$REPO_ROOT/xray-client.json.tpl" "$I_BIN/xray-client.json.tpl"
cp "$BIN/opec" "$I_BIN/opec"    # reuse the happy-path opec stub (present ⇒ renders)

cat > "$I_ETC/node-config.json" <<JSON
{
  "node_id": "test-edge-t3-idem",
  "backend_endpoint": "oxpulse.chat:443",
  "reality_uuid": "11111111-2222-3333-4444-555555555555",
  "reality_public_key": "$PUBKEY_A",
  "reality_encryption": "mlkem768x25519",
  "reality_short_id": "abcd",
  "reality_server_names": ["www.samsung.com"]
}
JSON
cat > "$I_ETC/xray-client.json" <<JSON
{ "outbounds": [ { "streamSettings": { "realitySettings": { "publicKey": "$PUBKEY_A" } } } ] }
JSON
printf 'v1\n'  > "$I_LIB/keys-version"
printf 'cv1\n' > "$I_LIB/channels-version"

# curl: server is always exactly one version ahead of the node's stored version,
# so run 1 rotates v1→v2 (PubKeyB) and run 2 rotates v2→v3 (PubKeyC).
cat > "$I_BIN/curl" <<CURL
#!/usr/bin/env bash
args="\$*"
cur=\$(cat "\${PARTNER_EDGE_PREFIX_LIB}/keys-version" 2>/dev/null || echo v1)
if [[ "\$args" == *"/api/partner/keys"* ]]; then
  case "\$cur" in
    v1) ver=v2; pub="$PUBKEY_B" ;;
    v2) ver=v3; pub="$PUBKEY_C" ;;
    *)  ver="\$cur"; pub="$PUBKEY_C" ;;
  esac
  printf '{"version":"%s","channels_version":"cv1","reality_public_key":"%s","reality_encryption":"mlkem768x25519","reality_server_names":["www.samsung.com"],"sfu_signing_public_key":"ZmFrZQ=="}\n' "\$ver" "\$pub"
  exit 0
fi
if [[ "\$args" == *"/api/partner/heartbeat"* ]]; then printf 'ok\n200'; exit 0; fi
exit 0
CURL
cat > "$I_BIN/systemctl" <<'SYSCTL'
#!/usr/bin/env bash
case "$*" in
  "list-unit-files oxpulse-partner-edge.service --no-legend"*)
    echo "oxpulse-partner-edge.service enabled enabled" ;;
  "is-active --quiet oxpulse-partner-edge.service"*) exit 0 ;;
  *) : ;;
esac
exit 0
SYSCTL
printf '#!/usr/bin/env bash\nexit 0\n' > "$I_BIN/docker"
printf '#!/usr/bin/env bash\nexit 0\n' > "$I_BIN/sleep"
chmod +x "$I_BIN"/*

run_idem() {
	set +e
	env -i \
	  PATH="$I_BIN:/usr/bin:/bin" \
	  HOME="$I" \
	  PARTNER_EDGE_PREFIX_ETC="$I_ETC" \
	  PARTNER_EDGE_PREFIX_LIB="$I_LIB" \
	  PARTNER_EDGE_TEXTFILE_DIR="$I_TEXT" \
	  OXPULSE_PREFIX_SBIN="$I_BIN" \
	  PREFIX_SBIN="$I_BIN" \
	  LOG_FILE="$I/refresh.log" \
	  OXPULSE_BACKEND_URL="https://oxpulse.chat" \
	  bash "$SCRIPT" > "$I/run.out" 2>&1
	local rc=$?
	set -e
	return $rc
}
run_idem || { fail "idempotency run 1 exited non-zero"; sed 's/^/    /' "$I/run.out" 2>/dev/null || true; }
run_idem || { fail "idempotency run 2 exited non-zero"; sed 's/^/    /' "$I/run.out" 2>/dev/null || true; }

IPROM="$I_TEXT/partner_edge.prom"
COUNT=$(grep -cE '^partner_edge_reality_pubkey_applied\{' "$IPROM" 2>/dev/null || true)
COUNT="${COUNT:-0}"
if [[ "$COUNT" == "1" ]]; then
	pass "single partner_edge_reality_pubkey_applied sample after 2 rotations (no duplicate)"
else
	fail "found $COUNT partner_edge_reality_pubkey_applied samples after 2 rotations (expected 1); textfile:"
	sed 's/^/    /' "$IPROM" 2>/dev/null || true
fi

IDEM_XRAY=$(jq -r '.outbounds[0].streamSettings.realitySettings.publicKey // "none"' "$I_ETC/xray-client.json" 2>/dev/null || echo none)
if [[ "$IDEM_XRAY" == "$PUBKEY_C" ]]; then
	pass "second rotation applied PubKeyC (both rotations executed)"
else
	fail "after 2 rotations xray pubkey='$IDEM_XRAY' expected '$PUBKEY_C'"
fi

# ── Result ───────────────────────────────────────────────────────────────────
if [[ $FAIL -ne 0 ]]; then
	echo "FAIL: T3 reality re-render regression test"
	exit 1
fi
echo "PASS: T3 — rotation re-renders xray-client.json before reload, version gated on render"
