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
# time, or next to this script in a dev/test checkout). SINGLE source of BOTH
# the sha256(node_id:date) mod pool_size arithmetic AND the pool derivation —
# the renderer (channel-render-lib.sh) sources the same file, so the two can
# never disagree on which SNI a node presents OR on what the pool is.
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

# Source the metric sink (best-effort) so the selected SNI index is emitted as
# a gauge — lets an operator ask "are nodes spread across the pool today"
# without reading xray-client.json on each box. Fail-soft: a missing sink
# skips the metric, never fails the rotation (emit_gauge returns 0 silently).
_metric_lib="$(cd "$(dirname "$(readlink -f "$0")")" 2>/dev/null && pwd)/metric-sink-lib.sh"
if [[ ! -f "$_metric_lib" ]]; then
    _metric_lib="/usr/local/sbin/metric-sink-lib.sh"
fi
if [[ -f "$_metric_lib" ]]; then
    # shellcheck source=/dev/null
    source "$_metric_lib"
fi
unset _metric_lib

ts()  { date -Iseconds; }
log() { printf '%s %s\n' "$(ts)" "$*" | tee -a "$LOG"; }

[[ -f "$NODE_CFG" ]] || { log "node-config.json not found — skip"; exit 0; }
[[ -f "$XRAY_CFG" ]] || { log "xray-client.json not found — skip"; exit 0; }

# Read SNI pool from node-config.json via the shared helper (ONE derivation —
# prefers channels[0].xray.server_names, falls back to flat reality_server_names,
# strips blank/whitespace-only entries). The synthetic www.samsung.com default
# is NOT injected here: it is the renderer's pool-ABSENT fallback, not a pool
# member. An empty pool means there is nothing to rotate to.
POOL=$(sni_pool_from_config "$NODE_CFG") || {
    log "could not read SNI pool from $NODE_CFG — skip"
    exit 0
}

# `grep -c` exits 1 when it counts zero, and under `set -euo pipefail` that
# killed the script HERE — before the empty-pool guard three lines down could
# log anything. The unit went `failed` nightly with an empty log file.
# sni_pool_from_config already strips blanks, so this count and the helper's
# internal one agree by construction.
POOL_SIZE=$(printf '%s\n' "$POOL" | grep -c . || true)
if [[ "$POOL_SIZE" -lt 1 ]]; then
    log "empty SNI pool — skip"
    exit 0
fi

# node_id read raw (empty when missing) so sni_select applies the unified rule
# (missing/empty node_id -> index 0 + warn) instead of the old 'unknown' hash.
NODE_ID=$(python3 -c "
import json, sys
print(json.load(open(sys.argv[1])).get('node_id', '') or '')
" "$NODE_CFG")

# Deterministic pick via the shared helper: sha256(node_id:today) mod pool_size.
# sni_select_indexed prints "<idx>\t<name>". The index is the only observable
# that distinguishes a real hash pick from an index-0 fallback, and both of the
# silent-index-0 bugs this file just fixed would have been visible in it.
#
# It comes back on stdout, not through a global: this is a command substitution,
# so a global set inside the helper stays in the subshell.
_SNI_SEL=$(sni_select_indexed "$NODE_ID" "$(date -I)" "$POOL") || {
    log "could not select SNI (pool_size=$POOL_SIZE) — skip"
    exit 1
}
SNI_PICK_IDX=${_SNI_SEL%%	*}
NEW_SNI=${_SNI_SEL#*	}
if [[ -z "$NEW_SNI" ]]; then
    log "could not select SNI (idx=${SNI_PICK_IDX:-?} pool_size=$POOL_SIZE) — skip"
    exit 1
fi

# Emit the selected index as a gauge so fleet-wide SNI spread is observable
# without per-box xray-client.json reads. Best-effort (emit_gauge is fail-soft).
if command -v emit_gauge >/dev/null 2>&1; then
    # A label value containing " or \ produces malformed exposition and
    # node_exporter drops the WHOLE file — every other metric on the box with
    # it. Node ids are <partner>-<hex> today; this costs nothing and removes the
    # dependency on that staying true.
    _lbl_node=${NODE_ID//\\/_}; _lbl_node=${_lbl_node//\"/_}; _lbl_node=${_lbl_node//$'\n'/_}
    emit_gauge partner_edge_sni_pick_index "node_id=\"$_lbl_node\",pool_size=\"$POOL_SIZE\"" "$SNI_PICK_IDX" || true
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
    log "SNI unchanged: $NEW_SNI (idx=$SNI_PICK_IDX/$POOL_SIZE)"
    exit 0
fi

log "rotating SNI: ${CURRENT_SNI:-<unset>} → $NEW_SNI (idx=$SNI_PICK_IDX/$POOL_SIZE)"

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
