#!/usr/bin/env bash
# oxpulse-partner-edge-sni-rotate.sh — daily rotation of xray CH1 serverName.
#
# Picks one SNI from the pool in node-config.json (reality_server_names).
# Selection is deterministic per node per day: sha256(node_id:YYYY-MM-DD)
# mod pool_size — same node gets the same SNI all day, different nodes
# spread across the pool.
#
# Called by oxpulse-partner-edge-sni-rotate.timer (daily, random 04-06 UTC).
set -euo pipefail

PREFIX_ETC="${PREFIX_ETC:-/etc/oxpulse-partner-edge}"
NODE_CFG="${NODE_CFG:-$PREFIX_ETC/node-config.json}"
XRAY_CFG="${XRAY_CFG:-$PREFIX_ETC/xray-client.json}"
LOG="${LOG:-/var/log/oxpulse-partner-edge-sni-rotate.log}"

# Source fleet-wide infrastructure defaults.
_defaults_installed="/usr/local/share/oxpulse-partner-edge/config/defaults.conf"
if [[ -f "$_defaults_installed" ]]; then
    # shellcheck source=/dev/null
    source "$_defaults_installed"
fi
unset _defaults_installed

# Source the shared SNI selection helper (sibling in PREFIX_SBIN at install
# time, or next to this script in a dev/test checkout). This is the SINGLE
# source of the sha256(node_id:date) mod pool_size arithmetic — the renderer
# (channel-render-lib.sh) sources the same file so the two can never disagree.
_sni_lib="$(cd "$(dirname "$(readlink -f "$0")")" 2>/dev/null && pwd)/sni-select-lib.sh"
if [[ -f "$_sni_lib" ]]; then
    # shellcheck source=sni-select-lib.sh
    source "$_sni_lib"
elif [[ -f /usr/local/sbin/sni-select-lib.sh ]]; then
    # shellcheck source=/dev/null
    source /usr/local/sbin/sni-select-lib.sh
else
    echo "ERR: sni-select-lib.sh not found (looked: $_sni_lib, /usr/local/sbin/sni-select-lib.sh)" >&2
    exit 1
fi
unset _sni_lib

ts()  { date -Iseconds; }
log() { printf '%s %s\n' "$(ts)" "$*" | tee -a "$LOG"; }

[[ -f "$NODE_CFG" ]] || { log "node-config.json not found — skip"; exit 0; }
[[ -f "$XRAY_CFG" ]] || { log "xray-client.json not found — skip"; exit 0; }

# Read SNI pool from node-config.json.
# Prefers reality_server_names array; falls back to single reality_server_name.
POOL=$(python3 -c "
import json, os, sys
d = json.load(open(sys.argv[1]))
names = d.get('reality_server_names') or [d.get('reality_server_name', '') or os.environ.get('OXPULSE_REALITY_SERVER_NAME', 'www.samsung.com')]
names = [n for n in names if n]
print('\n'.join(names))
" "$NODE_CFG")

POOL_SIZE=$(printf '%s\n' "$POOL" | grep -c .)
if [[ "$POOL_SIZE" -lt 1 ]]; then
    log "empty SNI pool — skip"
    exit 0
fi

# Deterministic pick via the shared helper: sha256(node_id:today) mod pool_size.
# node_id read raw (empty when missing) so sni_select applies the unified rule
# (missing/empty node_id -> index 0 + warn) instead of the old 'unknown' hash.
NODE_ID=$(python3 -c "
import json, sys
print(json.load(open(sys.argv[1])).get('node_id', '') or '')
" "$NODE_CFG")

NEW_SNI=$(sni_select "$NODE_ID" "$(date -I)" "$POOL") || {
    log "could not select SNI (pool_size=$POOL_SIZE) — skip"
    exit 1
}
if [[ -z "$NEW_SNI" ]]; then
    log "could not select SNI (pool_size=$POOL_SIZE) — skip"
    exit 1
fi

# Read current SNI from live xray config.
CURRENT_SNI=$(python3 -c "
import json, sys
try:
    c = json.load(open(sys.argv[1]))
    print(c['outbounds'][0]['streamSettings']['realitySettings'].get('serverName', ''))
except Exception:
    print('')
" "$XRAY_CFG" 2>/dev/null || echo "")

if [[ "$CURRENT_SNI" == "$NEW_SNI" ]]; then
    log "SNI unchanged: $NEW_SNI (pool_size=$POOL_SIZE)"
    exit 0
fi

log "rotating SNI: ${CURRENT_SNI:-<unset>} → $NEW_SNI (pool_size=$POOL_SIZE)"

# Patch xray-client.json in place.
python3 -c "
import json, sys
cfg = json.load(open(sys.argv[1]))
cfg['outbounds'][0]['streamSettings']['realitySettings']['serverName'] = sys.argv[2]
open(sys.argv[1], 'w').write(json.dumps(cfg, indent=2))
" "$XRAY_CFG" "$NEW_SNI"

# Restart xray-client service.
cd "$PREFIX_ETC" && docker compose restart xray-client 2>/dev/null \
    || docker restart oxpulse-partner-xray 2>/dev/null \
    || { log "WARNING: could not restart xray-client"; exit 1; }

log "SNI rotation complete: now=$NEW_SNI"
