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

# Script directory — used to locate channel-render-lib.sh from same checkout.
# OXPULSE_REPO_RAW can override the template source in channel-render-lib.sh.
_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
REPO_RAW="${OXPULSE_REPO_RAW:-https://raw.githubusercontent.com/anatolykoptev/oxpulse-partner-edge/main}"
export REPO_RAW  # consumed by channel-render-lib::re_render_xray

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
ts()   { date -Iseconds 2>/dev/null || date; }
log()  { printf '%s %s\n' "$(ts)" "$*" | tee -a "$LOG_FILE" 2>/dev/null || printf '%s %s\n' "$(ts)" "$*" >&2; }
warn() { log "WARN $*"; }
die()  { log "ERR  $*"; exit 1; }

# ---------------------------------------------------------------------------
# Source channel-render-lib.sh (owns re_render_xray and _esc helpers)
# ---------------------------------------------------------------------------
_chan_lib_local="${_script_dir}/channel-render-lib.sh"
_chan_lib_installed="${PREFIX_SBIN:-/usr/local/sbin}/channel-render-lib.sh"
if [[ -f "$_chan_lib_local" ]]; then
    # shellcheck source=channel-render-lib.sh
    source "$_chan_lib_local"
elif [[ -f "$_chan_lib_installed" ]]; then
    # shellcheck source=/dev/null
    source "$_chan_lib_installed"
else
    die "channel-render-lib.sh not found (looked at $_chan_lib_local and $_chan_lib_installed)"
fi
unset _chan_lib_local _chan_lib_installed

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
# Steps 3-6: Render xray-client.json + atomic install + container restart
#
# Delegated to channel-render-lib::re_render_xray — the canonical
# implementation shared by oxpulse-partner-edge-refresh.sh and upgrade.sh.
# The lib reads NODE_CFG (already refreshed in Step 1), fetches/validates the
# template, substitutes secrets (dual flat/channels[] schema), installs
# atomically, and restarts the container.
# ---------------------------------------------------------------------------
re_render_xray || die "re_render_xray failed — xray-client.json not updated"

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
  Operator action required. Backup config at: ${XRAY_CFG}.bak.* (see ls ${XRAY_CFG}.bak.*)"
fi

log "smoke test PASSED — Reality handshake OK, no real-cert leakage"
log "update complete — xray-client.json refreshed and container restarted"
