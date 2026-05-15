#!/usr/bin/env bash
# update.sh — idempotent self-healing update for a partner-edge node.
#
# Heals xray-client.json drift caused by manual server config changes that
# do NOT bump channels_version (bypassing the daily refresh script's check).
# Run this explicitly when the operator knows the server config has changed.
#
# Unlike oxpulse-partner-edge-refresh.sh (which is a passive daily heartbeat),
# this script is an active, explicit remediation tool.
#
# Usage:
#   update.sh                           # normal run (as root)
#   PARTNER_EDGE_PREFIX_ETC=/path update.sh  # override for testing
#
# Works WITHOUT install.env — only node-config.json is required.
# Token is optional: if /etc/oxpulse-partner-edge/token exists, the script
# re-fetches node-config.json from the registry API before rendering.
# Falls back to the locally-cached node-config.json if the API is unavailable.
#
# Exit codes:
#   0 — success (tunnel healthy after update, or already up-to-date)
#   1 — hard failure (missing required files, render error, smoke failure)
set -euo pipefail

# ---------------------------------------------------------------------------
# Paths (all overridable via env for tests)
# ---------------------------------------------------------------------------
PREFIX_ETC="${PARTNER_EDGE_PREFIX_ETC:-/etc/oxpulse-partner-edge}"
NODE_CFG="${NODE_CFG:-$PREFIX_ETC/node-config.json}"
XRAY_CFG="${XRAY_CFG:-$PREFIX_ETC/xray-client.json}"
TOKEN_FILE="${TOKEN_FILE:-$PREFIX_ETC/token}"
BACKEND_URL="${OXPULSE_BACKEND_URL:-https://oxpulse.chat}"
BACKEND_URL="${BACKEND_URL%/}"
LOG_FILE="${LOG_FILE:-/var/log/oxpulse-partner-edge-update.log}"

# Template: prefer local checkout copy (dev/ci), then REPO_RAW network fetch.
# OXPULSE_REPO_RAW can override to point at a local path (tests).
_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
TPL_LOCAL="${_script_dir}/xray-client.json.tpl"
REPO_RAW="${OXPULSE_REPO_RAW:-https://raw.githubusercontent.com/anatolykoptev/oxpulse-partner-edge/main}"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
ts()   { date -Iseconds 2>/dev/null || date; }
log()  { printf '%s %s\n' "$(ts)" "$*" | tee -a "$LOG_FILE" 2>/dev/null || printf '%s %s\n' "$(ts)" "$*" >&2; }
warn() { log "WARN $*"; }
die()  { log "ERR  $*"; exit 1; }

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------
command -v jq      >/dev/null 2>&1 || die "jq required but not installed"
command -v curl    >/dev/null 2>&1 || die "curl required but not installed"
command -v python3 >/dev/null 2>&1 || die "python3 required but not installed"
command -v docker  >/dev/null 2>&1 || die "docker required but not installed"

# ---------------------------------------------------------------------------
# Token check (required for API re-fetch; optional overall)
# ---------------------------------------------------------------------------
TOKEN=""
if [[ -f "$TOKEN_FILE" ]]; then
    TOKEN="$(tr -d '\r\n[:space:]' < "$TOKEN_FILE")"
fi

# If no token AND no local node-config, we cannot proceed at all.
if [[ -z "$TOKEN" && ! -f "$NODE_CFG" ]]; then
    die "no token at $TOKEN_FILE and no local node-config.json at $NODE_CFG
  To fix:
    - If this node was registered via install.sh: the bootstrap token is
      single-use and not stored. Place a service token at $TOKEN_FILE (chmod 0600).
    - Or restore node-config.json from backup:
        cp ${NODE_CFG}.bak.<timestamp> $NODE_CFG"
fi

# If no token, skip API re-fetch and warn.
if [[ -z "$TOKEN" ]]; then
    warn "no token at $TOKEN_FILE — skipping API re-fetch, using local node-config.json"
fi

# ---------------------------------------------------------------------------
# Step 1: Re-fetch node-config.json from API (if token available)
# ---------------------------------------------------------------------------
if [[ -n "$TOKEN" ]]; then
    log "token found — attempting to re-fetch node-config.json from API"
    _node_id=""
    if [[ -f "$NODE_CFG" ]]; then
        _node_id=$(jq -r '.node_id // .partner_id // empty' "$NODE_CFG" 2>/dev/null || true)
    fi

    _api_resp=""
    _api_ok=0
    _api_resp=$(curl -fsSL --max-time 15 \
        -H "Authorization: Bearer $TOKEN" \
        ${_node_id:+-H "X-Node-Id: $_node_id"} \
        "$BACKEND_URL/api/partner/node-config" 2>/dev/null) && _api_ok=1 || true

    if [[ $_api_ok -eq 1 && -n "$_api_resp" ]]; then
        _fetched_id=$(printf '%s' "$_api_resp" | jq -r '.node_id // empty' 2>/dev/null || true)
        if [[ -n "$_fetched_id" ]]; then
            install -d -m 0755 "$PREFIX_ETC"
            [[ -f "$NODE_CFG" ]] && cp -a "$NODE_CFG" "${NODE_CFG}.bak.$(date +%s)" 2>/dev/null || true
            printf '%s\n' "$_api_resp" | install -m 0600 /dev/stdin "$NODE_CFG"
            log "node-config.json refreshed from API (node_id=$_fetched_id)"
        else
            warn "API response missing node_id — ignoring, using local node-config.json"
        fi
    else
        warn "API re-fetch failed or returned empty — using local node-config.json"
    fi
fi

# ---------------------------------------------------------------------------
# Step 2: Verify node-config.json is present and has required fields
# ---------------------------------------------------------------------------
[[ -f "$NODE_CFG" ]] || die "node-config.json not found at $NODE_CFG
  Cannot render xray-client.json without it.
  Restore from backup or re-register via install.sh."

# Check required fields (flat schema OR channels[] schema)
_has_flat_fields=1
for _field in reality_uuid reality_public_key backend_endpoint; do
    _val=$(jq -r ".$_field // empty" "$NODE_CFG" 2>/dev/null || true)
    [[ -n "$_val" ]] || _has_flat_fields=0
done

if [[ $_has_flat_fields -eq 0 ]]; then
    _ch_count=$(jq '.channels // [] | length' "$NODE_CFG" 2>/dev/null || echo 0)
    if [[ "$_ch_count" -eq 0 ]]; then
        die "node-config.json is missing required fields (reality_uuid, reality_public_key, backend_endpoint)
  and has no channels[] array. See docs/piter-normalization.md."
    fi
    log "channels[] schema detected — fields will be read from channels[0]"
fi

# ---------------------------------------------------------------------------
# Step 3: Acquire xray template
#
# Prefer local checkout copy (always fresh when deployed from git).
# Fall back to network fetch from REPO_RAW.
# ---------------------------------------------------------------------------
_tpl=$(mktemp)
trap 'rm -f "$_tpl"' EXIT

if [[ -f "$TPL_LOCAL" ]]; then
    cp "$TPL_LOCAL" "$_tpl"
    log "using local xray-client.json.tpl"
else
    log "fetching xray-client.json.tpl from $REPO_RAW"
    if ! curl -fsSL --max-time 30 "$REPO_RAW/xray-client.json.tpl" -o "$_tpl"; then
        die "could not fetch xray-client.json.tpl from $REPO_RAW — cannot render"
    fi
fi

# Verify template is non-empty
[[ -s "$_tpl" ]] || die "xray-client.json.tpl is empty after fetch"

# ---------------------------------------------------------------------------
# Step 4: Read secrets from node-config.json
#
# Same dual-schema logic as channel-render-lib.sh::re_render_xray.
# ---------------------------------------------------------------------------
log "reading secrets from node-config.json"

_read_field() {
    local primary="$1"
    local fallback="$2"
    python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
ch = d.get('channels', [])
x = ch[0].get('xray', {}) if ch and ch[0].get('protocol', '') == 'vless-reality' else {}
val = x.get('$primary', '') or d.get('$fallback', '')
print(val if val is not None else '')
" "$NODE_CFG" 2>/dev/null || true
}

_uuid=$(python3 -c "
import json, sys; d = json.load(open(sys.argv[1]))
ch = d.get('channels', [])
x = ch[0].get('xray', {}) if ch and ch[0].get('protocol', '') == 'vless-reality' else {}
print(x.get('uuid', '') or d.get('reality_uuid', ''))
" "$NODE_CFG")

_pub_key=$(python3 -c "
import json, sys; d = json.load(open(sys.argv[1]))
ch = d.get('channels', [])
x = ch[0].get('xray', {}) if ch and ch[0].get('protocol', '') == 'vless-reality' else {}
print(x.get('public_key', '') or d.get('reality_public_key', ''))
" "$NODE_CFG")

_enc=$(python3 -c "
import json, sys; d = json.load(open(sys.argv[1]))
ch = d.get('channels', [])
x = ch[0].get('xray', {}) if ch and ch[0].get('protocol', '') == 'vless-reality' else {}
print(x.get('encryption', '') or d.get('reality_encryption', '') or '')
" "$NODE_CFG")

_short_id=$(python3 -c "
import json, sys; d = json.load(open(sys.argv[1]))
ch = d.get('channels', [])
x = ch[0].get('xray', {}) if ch and ch[0].get('protocol', '') == 'vless-reality' else {}
print(x.get('short_id', '') or d.get('reality_short_id', ''))
" "$NODE_CFG")

_server_name=$(python3 -c "
import json, sys; d = json.load(open(sys.argv[1]))
ch = d.get('channels', [])
x = ch[0].get('xray', {}) if ch and ch[0].get('protocol', '') == 'vless-reality' else {}
names = x.get('server_names') or d.get('reality_server_names')
print((names[0] if names else None) or x.get('server_name', '') or d.get('reality_server_name', 'www.samsung.com'))
" "$NODE_CFG")

_backend=$(python3 -c "
import json, sys; d = json.load(open(sys.argv[1]))
ch = d.get('channels', [])
if ch and ch[0].get('protocol', '') == 'vless-reality':
    c0 = ch[0]; print('{}:{}'.format(c0.get('host', ''), c0.get('port', '')))
else:
    print(d.get('backend_endpoint', ''))
" "$NODE_CFG")

# Validate required fields
[[ -n "$_uuid" ]]     || die "reality_uuid missing from node-config.json"
[[ -n "$_pub_key" ]]  || die "reality_public_key missing from node-config.json"
[[ -n "$_backend" ]]  || die "backend_endpoint missing from node-config.json"

# Fallback: read encryption from live xray-client.json if node-config has none
if [[ -z "$_enc" && -f "$XRAY_CFG" ]]; then
    _enc=$(python3 -c "
import json, sys
try:
    c = json.load(open(sys.argv[1]))
    u = c['outbounds'][0]['settings']['vnext'][0]['users'][0]
    print(u.get('encryption', ''))
except Exception:
    print('')
" "$XRAY_CFG" 2>/dev/null || true)
fi
[[ -z "$_enc" ]] && _enc="none"

_backend_host="${_backend%:*}"
_backend_port="${_backend##*:}"

# ---------------------------------------------------------------------------
# Step 5: Render xray-client.json from template
# ---------------------------------------------------------------------------
log "rendering xray-client.json (uuid=${_uuid:0:8}… pub=${_pub_key:0:8}… backend=$_backend)"

# Escape sed replacement metacharacters (|, &, \)
_esc() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

_out=$(mktemp)
trap 'rm -f "$_tpl" "$_out"' EXIT

sed \
    -e "s|{{REALITY_UUID}}|$(_esc "$_uuid")|g" \
    -e "s|{{REALITY_ENCRYPTION}}|$(_esc "$_enc")|g" \
    -e "s|{{REALITY_PUBLIC_KEY}}|$(_esc "$_pub_key")|g" \
    -e "s|{{REALITY_SHORT_ID}}|$(_esc "$_short_id")|g" \
    -e "s|{{REALITY_SERVER_NAME}}|$(_esc "$_server_name")|g" \
    -e "s|{{BACKEND_HOST}}|$(_esc "$_backend_host")|g" \
    -e "s|{{BACKEND_PORT}}|$(_esc "$_backend_port")|g" \
    -e "s|{{BACKEND_ENDPOINT}}|$(_esc "$_backend")|g" \
    "$_tpl" > "$_out"

# Validate rendered JSON
if ! python3 -m json.tool "$_out" >/dev/null 2>&1; then
    die "rendered xray-client.json is not valid JSON — template may be corrupt"
fi

# Verify mode field (fail-loud on template drift)
_rendered_mode=$(python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
for ob in d.get('outbounds', []):
    s = ob.get('streamSettings', {}).get('xhttpSettings', {})
    if s: print(s.get('mode', '')); sys.exit(0)
print('')
" "$_out" 2>/dev/null || true)

if [[ -z "$_rendered_mode" ]]; then
    warn "xhttpSettings.mode not found in rendered config — template structure unexpected"
fi
log "rendered config mode=$_rendered_mode"

# Back up old config, install new one
_xray_bak="${XRAY_CFG}.bak.$(date +%s)"
[[ -f "$XRAY_CFG" ]] && cp -a "$XRAY_CFG" "$_xray_bak" 2>/dev/null || true

install -d -m 0755 "$(dirname "$XRAY_CFG")"
install -m 0600 "$_out" "$XRAY_CFG"
rm -f "$_tpl" "$_out"
trap - EXIT

log "xray-client.json written to $XRAY_CFG"

# ---------------------------------------------------------------------------
# Step 6: Restart xray-client container with hard error capture
# ---------------------------------------------------------------------------
log "restarting xray-client container"
COMPOSE_DIR="$PREFIX_ETC"

_restart_log=$(mktemp)
_restart_ok=0
if (cd "$COMPOSE_DIR" && docker compose restart xray-client 2>&1 | tee "$_restart_log" | tee -a "$LOG_FILE"); then
    _restart_ok=1
fi
rm -f "$_restart_log"

if [[ $_restart_ok -eq 0 ]]; then
    [[ -f "$_xray_bak" ]] && cp -a "$_xray_bak" "$XRAY_CFG" && log "restored backup $XRAY_CFG from $_xray_bak"
    die "docker compose restart xray-client failed — backup restored, operator intervention required"
fi
log "xray-client container restarted"

# ---------------------------------------------------------------------------
# Step 7: Post-restart smoke test
#
# Reality handshake check:
#   - "received real certificate" in logs → handshake failed (xray fell back
#     to direct TLS, leaking the real server certificate to the client).
#     This means the publicKey or mode mismatch with the server.
#   - Port 3080 not listening → container crashed or inbound not configured.
# ---------------------------------------------------------------------------
SMOKE_WAIT="${OXPULSE_SMOKE_WAIT:-8}"
log "waiting ${SMOKE_WAIT}s for xray-client to stabilise"
sleep "$SMOKE_WAIT"

log "smoke test: verifying Reality handshake"
_smoke_ok=1
_smoke_details=""

# Check 1: port 3080 open (tunnel inbound dokodemo-door)
if command -v ss >/dev/null 2>&1; then
    if ! ss -tlnH 2>/dev/null | grep -q ':3080'; then
        _smoke_ok=0
        _smoke_details="${_smoke_details}port 3080 not listening after restart; "
    fi
fi

# Check 2: no "received real certificate" in recent xray-client logs (last 30s)
_since=$(date -d "-30 seconds" +%s 2>/dev/null || date -v-30S +%s 2>/dev/null || echo 0)
_logs=$(docker logs --since "${_since}" xray-client 2>&1 || \
        docker logs --tail 50 xray-client 2>&1 || true)

if echo "$_logs" | grep -q "received real certificate"; then
    _smoke_ok=0
    _smoke_details="${_smoke_details}Reality handshake failed — 'received real certificate' in xray-client logs (publicKey mismatch?); "
fi

if [[ $_smoke_ok -eq 0 ]]; then
    die "smoke test FAILED: ${_smoke_details}
  xray tunnel is NOT working after update. Possible causes:
    - reality_public_key in node-config.json does not match krolik server
    - krolik server privateKey changed and /api/partner/keys not yet updated
    - xray-client container image is incompatible with new protocol settings
  Operator action required. Backup config at: $_xray_bak"
fi

log "smoke test PASSED — Reality handshake OK, no real-cert leakage"
log "update complete — xray-client serving traffic via mode=$_rendered_mode + Reality"
