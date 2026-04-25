#!/usr/bin/env bash
# channel-render-lib.sh — shared channel config render functions.
#
# Sourced by upgrade.sh and oxpulse-partner-edge-refresh.sh.
# Each re_render_<protocol>() function fetches the latest template for
# that channel from REPO_RAW, reads secrets from node-config.json, and
# renders + restarts the container.
#
# Adding a new channel: add re_render_<protocol>() here, call it from
# refresh.sh when channels_version changes.
#
# No shebang execution — this file is only ever sourced, never run directly.

# Defensive fallbacks: callers that already define log/warn/die keep their
# styling; refresh.sh (which has no warn()) gets a working implementation.
command -v log  >/dev/null 2>&1 || log()  { printf '%s\n' "$*" >&2; }
command -v warn >/dev/null 2>&1 || warn() { log "WARN: $*"; }
command -v die  >/dev/null 2>&1 || die()  { log "ERR $*"; exit 1; }

PREFIX_ETC="${PREFIX_ETC:-/etc/oxpulse-partner-edge}"
PREFIX_LIB="${PREFIX_LIB:-/var/lib/oxpulse-partner-edge}"
NODE_CFG="${NODE_CFG:-$PREFIX_ETC/node-config.json}"
XRAY_CFG="${XRAY_CFG:-$PREFIX_ETC/xray-client.json}"
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/anatolykoptev/oxpulse-partner-edge/main}"

# Re-render xray-client.json from the upstream template, preserving secrets
# from node-config.json. Called on every upgrade so structural changes
# (e.g. flow, mode, padding) are applied without requiring reinstall.
re_render_xray() {
    [[ -f "$NODE_CFG" ]] || { warn "node-config.json not found — skipping xray template refresh"; return 0; }
    log "re-rendering xray-client.json from updated template"

    local tpl
    tpl=$(mktemp)
    if ! curl -fsSL --max-time 15 "$REPO_RAW/xray-client.json.tpl" -o "$tpl" 2>/dev/null; then
        warn "could not fetch xray-client.json.tpl — xray config left unchanged"
        rm -f "$tpl"; return 0
    fi

    # Read secrets from node-config.json.
    # Prefers channels[0].xray.* (future schema) with fallback to flat reality_* fields
    # (current schema) for backwards compat with nodes registered before channels[] landed.
    local uuid enc pub_key short_id server_name backend
    uuid=$(python3 -c "
import json,sys; d=json.load(open(sys.argv[1]))
ch=d.get('channels',[])
x=ch[0].get('xray',{}) if ch and ch[0].get('protocol','')=='vless-reality' else {}
print(x.get('uuid','') or d.get('reality_uuid',''))" "$NODE_CFG")
    enc=$(python3 -c "
import json,sys; d=json.load(open(sys.argv[1]))
ch=d.get('channels',[])
x=ch[0].get('xray',{}) if ch and ch[0].get('protocol','')=='vless-reality' else {}
print(x.get('encryption','') or d.get('reality_encryption','') or '')" "$NODE_CFG")
    pub_key=$(python3 -c "
import json,sys; d=json.load(open(sys.argv[1]))
ch=d.get('channels',[])
x=ch[0].get('xray',{}) if ch and ch[0].get('protocol','')=='vless-reality' else {}
print(x.get('public_key','') or d.get('reality_public_key',''))" "$NODE_CFG")
    short_id=$(python3 -c "
import json,sys; d=json.load(open(sys.argv[1]))
ch=d.get('channels',[])
x=ch[0].get('xray',{}) if ch and ch[0].get('protocol','')=='vless-reality' else {}
print(x.get('short_id','') or d.get('reality_short_id',''))" "$NODE_CFG")
    server_name=$(python3 -c "
import json,sys; d=json.load(open(sys.argv[1]))
ch=d.get('channels',[])
x=ch[0].get('xray',{}) if ch and ch[0].get('protocol','')=='vless-reality' else {}
names=x.get('server_names') or d.get('reality_server_names')
print((names[0] if names else None) or x.get('server_name','') or d.get('reality_server_name','www.samsung.com'))" "$NODE_CFG")
    backend=$(python3 -c "
import json,sys; d=json.load(open(sys.argv[1]))
ch=d.get('channels',[])
if ch and ch[0].get('protocol','')=='vless-reality':
    c0=ch[0]; print('{}:{}'.format(c0.get('host',''),c0.get('port','')))
else:
    print(d.get('backend_endpoint',''))" "$NODE_CFG")

    if [[ -z "$uuid" || -z "$pub_key" || -z "$backend" ]]; then
        warn "node-config.json missing required fields — skipping xray template refresh"
        rm -f "$tpl"; return 0
    fi

    # Fallback: if node-config.json has empty encryption (pre-PQ nodes),
    # read it from the live xray-client.json so we don't downgrade to "none".
    if [[ -z "$enc" && -f "$XRAY_CFG" ]]; then
        enc=$(python3 -c "
import json,sys
try:
    c=json.load(open(sys.argv[1]))
    u=c['outbounds'][0]['settings']['vnext'][0]['users'][0]
    print(u.get('encryption',''))
except Exception:
    print('')
" "$XRAY_CFG" 2>/dev/null || true)
    fi
    [[ -z "$enc" ]] && enc="none"

    local backend_host="${backend%:*}"
    local backend_port="${backend##*:}"

    # Escape sed replacement metacharacters (|, &, \).
    _esc() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

    local out
    out=$(mktemp)
    sed \
        -e "s|{{REALITY_UUID}}|$(_esc "$uuid")|g" \
        -e "s|{{REALITY_ENCRYPTION}}|$(_esc "$enc")|g" \
        -e "s|{{REALITY_PUBLIC_KEY}}|$(_esc "$pub_key")|g" \
        -e "s|{{REALITY_SHORT_ID}}|$(_esc "$short_id")|g" \
        -e "s|{{REALITY_SERVER_NAME}}|$(_esc "$server_name")|g" \
        -e "s|{{BACKEND_HOST}}|$(_esc "$backend_host")|g" \
        -e "s|{{BACKEND_PORT}}|$(_esc "$backend_port")|g" \
        -e "s|{{BACKEND_ENDPOINT}}|$(_esc "$backend")|g" \
        "$tpl" > "$out"
    rm -f "$tpl"

    # Backup old config, install new one (0600 — contains secrets).
    cp -a "$XRAY_CFG" "${XRAY_CFG}.bak.$(date +%s)" 2>/dev/null || true
    install -m 0600 "$out" "$XRAY_CFG"
    rm -f "$out"

    log "xray-client.json refreshed from template"
    (cd "$PREFIX_ETC" && docker compose restart xray-client 2>/dev/null || true)
    log "xray-client restarted"
}
