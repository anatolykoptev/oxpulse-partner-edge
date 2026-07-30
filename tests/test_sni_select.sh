#!/usr/bin/env bash
# tests/test_sni_select.sh — single SNI selection rule across renderer + rotator.
#
# Bug: channel-render-lib.sh:225 took names[0] unconditionally while
# oxpulse-partner-edge-sni-rotate.sh picked sha256(node_id:date) mod pool_size.
# The renderer runs far more often than the daily timer, so every node
# converged to index 0 — fleet-wide SNI uniformity, an anti-censorship
# regression (one burned name takes every relay at once).
#
# Fix: ONE shared helper sni_select() in sni-select-lib.sh, called by BOTH.
#
# Falsification (Part 2): the name the RENDERER produces must equal the name
# the ROTATION script produces for the same node_id + date + pool. This
# assertion FAILS on the unfixed code (renderer=names[0], rotator=hash-pick)
# for the right reason — not a syntax error. Part 1 (unit tests on the helper)
# skips gracefully when the helper is absent so the RED signal is unambiguous.
#
# Resource discipline: bash tests/test_sni_select.sh
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
HELPER="$REPO_ROOT/sni-select-lib.sh"
ROTATE="$REPO_ROOT/oxpulse-partner-edge-sni-rotate.sh"
RENDER_LIB="$REPO_ROOT/channel-render-lib.sh"
TPL="$REPO_ROOT/xray-client.json.tpl"

FAIL=0
pass() { echo "OK: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }

# Pool of 5 distinct names — index 0 is deliberately a common "burned" name so
# a collapse-to-index-0 is visible. node_id chosen so the rotator's hash-pick
# does NOT land on index 0 (verified empirically in the RED run).
POOL=("www.samsung.com" "www.apple.com" "www.microsoft.com" "www.google.com" "www.cloudflare.com")
NODE_ID="edge-relay-north-42"
DATE="2026-07-30"
pool_str() { printf '%s\n' "${POOL[@]}"; }

# ── Part 1: unit tests on sni_select (the shared helper) ─────────────────────
# Skips gracefully when the helper is absent (pre-implementation RED state) so
# the test's exit code is driven by Part 2's falsification, not a setup error.
echo "==> Part 1: sni_select helper contract"
if [[ ! -f "$HELPER" ]]; then
	echo "SKIP Part 1: $HELPER not present (pre-implementation)"
else
	# shellcheck source=/dev/null
	source "$HELPER"

	# 1a — determinism: same node_id + date + pool -> same name across repeats.
	N1=$(sni_select "$NODE_ID" "$DATE" "$(pool_str)")
	N2=$(sni_select "$NODE_ID" "$DATE" "$(pool_str)")
	N3=$(sni_select "$NODE_ID" "$DATE" "$(pool_str)")
	if [[ "$N1" == "$N2" && "$N2" == "$N3" && -n "$N1" ]]; then
		pass "1a determinism: $N1 stable across 3 calls"
	else
		fail "1a determinism: got '$N1' '$N2' '$N3'"
	fi

	# 1b — node spread: 5 distinct node_ids over a pool of 5 do NOT all collapse.
	declare -a SPREAD=()
	for nid in edge-a edge-b edge-c edge-d edge-e; do
		SPREAD+=("$(sni_select "$nid" "$DATE" "$(pool_str)")")
	done
	DISTINCT=$(printf '%s\n' "${SPREAD[@]}" | sort -u | grep -c .)
	if [[ "$DISTINCT" -ge 2 ]]; then
		pass "1b spread: $DISTINCT distinct names across 5 node_ids (no collapse)"
	else
		fail "1b spread: only $DISTINCT distinct name across 5 node_ids — collapse to '${SPREAD[0]}'"
	fi

	# 1c — empty/missing node_id falls back to index 0 AND warns on stderr.
	WARN_OUT=$(sni_select "" "$DATE" "$(pool_str)" 2>&1 >/dev/null) || true
	EMPTY_PICK=$(sni_select "" "$DATE" "$(pool_str)" 2>/dev/null) || true
	if [[ "$EMPTY_PICK" == "${POOL[0]}" ]]; then
		# Avoid piped grep -q (forbidden by test_pipefail_early_exit_guard).
		case "$WARN_OUT" in
			*[Nn]ode_id*) pass "1c empty node_id -> index 0 ('${POOL[0]}') + warn" ;;
			*) fail "1c empty node_id -> index 0 but NO warn on stderr (got: '$WARN_OUT')" ;;
		esac
	else
		fail "1c empty node_id -> '$EMPTY_PICK' expected index 0 '${POOL[0]}'"
	fi

	# 1d — pool of one behaves as before (the single entry, any node_id/date).
	SINGLE="only-name.example"
	SINGLE_PICK=$(sni_select "$NODE_ID" "$DATE" "$SINGLE")
	if [[ "$SINGLE_PICK" == "$SINGLE" ]]; then
		pass "1d pool-of-one -> '$SINGLE' (unchanged behaviour)"
	else
		fail "1d pool-of-one -> '$SINGLE_PICK' expected '$SINGLE'"
	fi
fi

# ── Part 2: cross-caller equality (the bug falsification) ────────────────────
# Runs the REAL rotator and the REAL renderer against identical node-config and
# asserts the serverName they write matches. Pre-fix this FAILS because the
# renderer takes names[0] while the rotator takes sha256(node_id:date) mod size.
echo "==> Part 2: renderer serverName == rotator serverName (same node_id+date+pool)"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

ETC="$T/etc"; BIN="$T/bin"
mkdir -p "$ETC" "$BIN"

# node-config.json with node_id + pool of 5 (flat schema the renderer reads).
cat > "$ETC/node-config.json" <<JSON
{
  "node_id": "$NODE_ID",
  "backend_endpoint": "oxpulse.chat:443",
  "reality_uuid": "11111111-2222-3333-4444-555555555555",
  "reality_public_key": "AAAA_pubkey_for_select_test",
  "reality_encryption": "mlkem768x25519",
  "reality_short_id": "abcd",
  "reality_server_names": $(printf '%s\n' "${POOL[@]}" | python3 -c "import sys,json; print(json.dumps([l.rstrip() for l in sys.stdin if l.strip()]))")
}
JSON

# Stub docker + sleep (no-ops) on PATH for both callers.
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/docker"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/sleep"
# Stub curl: serve the real xray template to any -o fetch; the rotator does not
# curl. Honors `-o <file>` the way re_render_xray invokes it.
cat > "$BIN/curl" <<CURL
#!/usr/bin/env bash
out=""
while [[ \$# -gt 0 ]]; do
  if [[ "\$1" == "-o" ]]; then out="\$2"; shift 2; continue; fi
  shift
done
if [[ -n "\$out" ]]; then cp "$TPL" "\$out"; exit 0; fi
exit 0
CURL
chmod +x "$BIN"/*

# --- Rotator run: writes its selected SNI into xray-client.json ---
# Seed xray-client.json with a sentinel SNI so the rotator always rotates
# (it skips when CURRENT_SNI == NEW_SNI).
cat > "$ETC/xray-client.json" <<JSON
{ "outbounds": [ { "streamSettings": { "realitySettings": { "serverName": "INITIAL_PLACEHOLDER" } } } ] }
JSON

set +e
env -i \
  PATH="$BIN:/usr/bin:/bin" \
  HOME="$T" \
  PREFIX_ETC="$ETC" \
  NODE_CFG="$ETC/node-config.json" \
  XRAY_CFG="$ETC/xray-client.json" \
  LOG="$T/rotate.log" \
  bash "$ROTATE" >"$T/rotate.out" 2>&1
ROT_EXIT=$?
set -e

if [[ $ROT_EXIT -ne 0 ]]; then
	fail "rotator exited $ROT_EXIT; output:"; sed 's/^/    /' "$T/rotate.out"
else
	ROT_SNI=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['outbounds'][0]['streamSettings']['realitySettings'].get('serverName',''))" "$ETC/xray-client.json" 2>/dev/null || echo "")
	[[ -n "$ROT_SNI" ]] || fail "rotator wrote empty serverName"
fi

# --- Renderer run: re_render_xray writes its selected SNI into xray-client.json ---
# Fresh xray-client.json (sentinel) so the renderer's sed substitution is observable.
cat > "$ETC/xray-client.json" <<JSON
{ "outbounds": [ { "streamSettings": { "realitySettings": { "serverName": "INITIAL_PLACEHOLDER" } } } ] }
JSON

# Source the render lib with env-steered paths, then call re_render_xray.
# read-xhttp.py is absent at _lib_dir=REPO_ROOT -> re_render_xray falls back to
# its `|| echo <default>` xhttp values (we only assert on serverName).
set +e
env -i \
  PATH="$BIN:/usr/bin:/bin" \
  HOME="$T" \
  PREFIX_ETC="$ETC" \
  NODE_CFG="$ETC/node-config.json" \
  XRAY_CFG="$ETC/xray-client.json" \
  REPO_RAW="http://stub.invalid" \
  OXPULSE_REALITY_SERVER_NAME="www.samsung.com" \
  bash -c '
    set -euo pipefail
    source "$0"
    re_render_xray
  ' "$RENDER_LIB" >"$T/render.out" 2>&1
REND_EXIT=$?
set -e

if [[ $REND_EXIT -ne 0 ]]; then
	fail "renderer exited $REND_EXIT; output:"; sed 's/^/    /' "$T/render.out"
else
	REND_SNI=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['outbounds'][0]['streamSettings']['realitySettings'].get('serverName',''))" "$ETC/xray-client.json" 2>/dev/null || echo "")
	[[ -n "$REND_SNI" ]] || fail "renderer wrote empty serverName"
fi

# The assertion the bug would have failed.
if [[ -n "${ROT_SNI:-}" && -n "${REND_SNI:-}" ]]; then
	if [[ "$ROT_SNI" == "$REND_SNI" ]]; then
		pass "renderer == rotator: both picked '$ROT_SNI'"
	else
		fail "renderer='$REND_SNI' != rotator='$ROT_SNI' (selection rules disagree — the bug)"
	fi
fi

# Sanity: the rotator must NOT have collapsed to index 0 for this node_id
# (otherwise the equality assertion is vacuous — both could be names[0] by
# coincidence). This guards the falsification's signal strength.
if [[ -n "${ROT_SNI:-}" && "$ROT_SNI" != "${POOL[0]}" ]]; then
	pass "rotator picked non-index-0 ('$ROT_SNI') — equality assertion is non-vacuous"
else
	fail "rotator picked index 0 ('${POOL[0]}') for node_id='$NODE_ID' — pick a node_id whose hash != 0 mod 5 so the RED signal is real"
fi

echo ""
if [[ $FAIL -eq 0 ]]; then echo "All tests passed."; else echo "TESTS FAILED."; fi
exit $FAIL
