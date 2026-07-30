#!/usr/bin/env bash
# update.sh — idempotent self-healing update for a partner-edge node.
#
# Phase 5.5 MAJOR 1 (PR feat/phase5-6-...): render_channel_soft + CHANNELS_FAILED
# + compose_strip_failed_channels sourced from lib/render-channel-lib.sh.
# update.sh's loud-fail-on-hash-unchanged semantics are preserved (Phase 1 mandate).
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
#
# Content-aware resolution: a candidate that exists but lacks refetch_node_config
# (a stale pre-PR copy from a sync skew where oxpulse-xray-update.sh landed but
# channel-render-lib.sh did not — sync_host_scripts verifies and skips per file,
# so that skew is reachable) is NOT a hit — source it, re-check, keep going.  The
# previous existence-only resolution sourced a stale lib and returned, leaving
# refetch_node_config undefined → exit 127 at the call site (update.sh:122) under
# `set -euo pipefail`, in the operator's explicit remediation tool.  A named die
# when no candidate provides it never reaches 127.
# ---------------------------------------------------------------------------
_chan_lib_local="${_script_dir}/channel-render-lib.sh"
_chan_lib_installed="${PREFIX_SBIN:-/usr/local/sbin}/channel-render-lib.sh"
if [[ -f "$_chan_lib_local" ]]; then
    # shellcheck source=channel-render-lib.sh
    source "$_chan_lib_local"
fi
if ! command -v refetch_node_config >/dev/null 2>&1 \
   && [[ -f "$_chan_lib_installed" && "$_chan_lib_installed" != "$_chan_lib_local" ]]; then
    # shellcheck source=/dev/null
    source "$_chan_lib_installed"
fi
command -v refetch_node_config >/dev/null 2>&1 \
    || die "channel-render-lib.sh does not provide refetch_node_config (looked at $_chan_lib_local and $_chan_lib_installed) — the installed lib is stale (sync skew: oxpulse-xray-update.sh landed but channel-render-lib.sh did not). Re-run 'oxpulse-partner-edge-upgrade' to sync host scripts."
unset _chan_lib_local _chan_lib_installed

# Phase 5.5 MAJOR 1: load fail-soft render helpers.
_rl_local="${_script_dir}/lib/render-channel-lib.sh"
_rl_sbin="${PREFIX_SBIN:-/usr/local/sbin}/render-channel-lib.sh"
if [[ -f "$_rl_local" ]]; then
    # shellcheck source=lib/render-channel-lib.sh
    source "$_rl_local"
elif [[ -f "$_rl_sbin" ]]; then
    # shellcheck source=/dev/null
    source "$_rl_sbin"
else
    warn "render-channel-lib.sh not found — render_channel_soft unavailable"
    render_channel_soft() { warn "render_channel_soft: lib not found"; return 1; }
    # shellcheck disable=SC2034
    CHANNELS_FAILED=()
fi
unset _rl_local _rl_sbin

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

# ---------------------------------------------------------------------------
# Step 1: Re-fetch node-config.json from API (if token available)
#
# Delegated to channel-render-lib::refetch_node_config — the canonical
# implementation shared with upgrade.sh.  Behaviour-preserving extraction:
# same Bearer auth, same endpoint, same fallback-to-local on failure.
# The lib adds temp-then-rename + JSON/field validation so a truncated or
# malformed response never overwrites the good local file.
# ---------------------------------------------------------------------------
refetch_node_config

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
  and has no channels[] array. See docs/relay-x-normalization.md."
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
#
# IMPORTANT: re_render_xray uses soft-fail semantics (warn + return 0) for:
#   - template fetch failure (curl error)
#   - missing required fields in node-config.json
#   - docker restart failure (|| true)
# The lib ALSO skips JSON validation and backup rollback entirely.
# Phase 1 mandate: preserve update.sh's original loud-fail semantics so the
# daily timer continues to page the operator on real drift-heal failure.
# Guards below are explicit; lib hardening is Phase 2 scope (also affects
# oxpulse-partner-edge-refresh.sh and upgrade.sh).
# ---------------------------------------------------------------------------

# Snapshot xray-client.json hash so we can detect whether re_render_xray
# actually wrote a new file (it returns 0 on soft-fail no-op paths).
_pre_hash=""
if [[ -f "$XRAY_CFG" ]]; then
    _pre_hash=$(sha256sum "$XRAY_CFG" | awk '{print $1}')
fi

re_render_xray || die "re_render_xray failed — xray-client.json not updated"

# Post-flight: verify a render actually happened. re_render_xray's soft-fail
# paths (template fetch error, missing fields) return 0 without rewriting
# xray-client.json. On Day 2+ daily-timer runs, yesterday's .bak.* persists,
# so backup presence is NOT a reliable freshness signal. Use hash compare instead.
_post_hash=""
if [[ -f "$XRAY_CFG" ]]; then
    _post_hash=$(sha256sum "$XRAY_CFG" | awk '{print $1}')
fi

_latest_bak=$(find "$(dirname "$XRAY_CFG")" -maxdepth 1 -name "$(basename "$XRAY_CFG").bak.*" -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | awk '{print $2}')

# Post-flight: verify a render actually happened. re_render_xray returns 0
# on soft-fail paths (template fetch / missing fields / restart error)
# WITHOUT rewriting xray-client.json. Stale .bak.* from yesterday's
# successful run would make a "did .bak get created?" check silently pass.
# Compare pre/post hash — change == real render; identical == soft-fail.
if [[ -n "$_pre_hash" && "$_pre_hash" = "$_post_hash" ]]; then
    warn "xray-client.json hash unchanged before/after re_render_xray — likely soft-failed"
    warn "  pre:  $_pre_hash"
    warn "  post: $_post_hash"
    die "update: xray render skipped silently — check journalctl for re_render_xray warnings"
fi
if [[ -z "$_pre_hash" && -z "$_post_hash" ]]; then
    die "update: xray-client.json missing both before and after re_render_xray"
fi

# Validate rendered JSON. If the render produced garbage, roll back from backup.
if ! python3 -m json.tool "$XRAY_CFG" >/dev/null 2>&1; then
    warn "rendered xray-client.json is not valid JSON — rolling back from $_latest_bak"
    cp -a "$_latest_bak" "$XRAY_CFG"
    die "update: invalid rendered JSON — restored backup"
fi

unset _pre_hash _post_hash _latest_bak

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
    - reality_public_key in node-config.json does not match hub server
    - hub server privateKey changed and /api/partner/keys not yet updated
    - xray-client container image is incompatible with new protocol settings
  Operator action required. Backup config at: ${XRAY_CFG}.bak.* (see ls ${XRAY_CFG}.bak.*)"
fi

log "smoke test PASSED — Reality handshake OK, no real-cert leakage"
log "update complete — xray-client.json refreshed and container restarted"
