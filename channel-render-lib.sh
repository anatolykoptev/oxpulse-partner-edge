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

# Generic mustache-style template renderer — Phase 1 dedupe target.
# Substitutes every {{NAME}} placeholder in $src with the matching env var,
# empty string when unset. Multi-line values (PEM keys, ML-KEM blobs) preserved
# verbatim. Python3-based — avoids sed PEM-newline corruption.
#
# Single source of truth — install.sh, hydrate.sh, update.sh all call this.
#
# Args:
#   $1 src — template file path (must exist)
#   $2 dst — output file path (created/overwritten atomically)
#
# Returns: 0 on success; 1 + warn on read/write/parse error.
render_template() {
    local src=$1 dst=$2
    [[ -f "$src" ]] || { warn "render_template: source not found: $src"; return 1; }
    local dst_dir
    dst_dir=$(dirname "$dst")
    [[ -d "$dst_dir" ]] || { warn "render_template: dest dir missing: $dst_dir"; return 1; }
    local tmp="${dst}.tmp.$$"
    if ! python3 -c '
import os, sys, re
src, dst = sys.argv[1], sys.argv[2]
with open(src) as f: tpl = f.read()
out = re.sub(r"\{\{([A-Z][A-Z0-9_]*)\}\}", lambda m: os.environ.get(m.group(1), ""), tpl)
with open(dst, "w") as f: f.write(out)
' "$src" "$tmp"; then
        warn "render_template: python3 substitution failed for $src"
        rm -f "$tmp"
        return 1
    fi
    mv -f "$tmp" "$dst"
}

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

# ── hysteria2 (Phase 1.7 CH3) ────────────────────────────────────────────
#
# Render the hysteria2-client.yaml from template via simple sed substitution.
# Pattern mirrors _render_xray_to() at top of this file.

# Escape sed replacement metacharacters (\, &, |, ") for sed replacement strings.
# Single source used by all render functions in this module.
_esc() { printf '%s' "$1" | sed -e 's/[\\&|"]/\\&/g'; }

# Internal — render to a specific output path. Used by the test runner.
_render_hysteria2_to() {
    local tpl="$1" out="$2"
    local server="$3" auth="$4" obfs="$5" listen="$6" backend="$7"
    sed \
        -e "s|{{HY2_SERVER}}|$(_esc "$server")|g" \
        -e "s|{{HY2_AUTH_PASS}}|$(_esc "$auth")|g" \
        -e "s|{{HY2_OBFS_PASS}}|$(_esc "$obfs")|g" \
        -e "s|{{HY2_LOCAL_LISTEN}}|$(_esc "$listen")|g" \
        -e "s|{{HY2_REMOTE_BACKEND}}|$(_esc "$backend")|g" \
        "$tpl" > "$out"
}

# Public — full render-and-install pipeline.
# Sources hy2 credentials from $HY2_AUTH_PASS, $HY2_OBFS_PASS env vars
# (populated by install.sh from /api/partner/hy2-credentials response).
# Writes to /etc/oxpulse-partner-edge/hysteria2-client.yaml with mode 600.
re_render_hysteria2() {
    local tpl="${OXPULSE_REPO_DIR:-/usr/local/share/oxpulse-partner-edge}/hysteria2-client.yaml.tpl"
    # HY2_OUTPUT_PATH: optional override for tests (default: /etc/oxpulse-partner-edge/hysteria2-client.yaml)
    local out="${HY2_OUTPUT_PATH:-/etc/oxpulse-partner-edge/hysteria2-client.yaml}"
    local backup
    backup="${out}.bak.$(date +%s)"
    local server="${HY2_SERVER:-192.9.243.148:51822}"
    local listen="${HY2_LOCAL_LISTEN:-0.0.0.0:18443}"
    local backend="${HY2_REMOTE_BACKEND:-127.0.0.1:8907}"

    if [[ ! -f "$tpl" ]]; then
        echo "ERR re_render_hysteria2: template not found: $tpl" >&2
        return 1
    fi
    if [[ -z "${HY2_AUTH_PASS:-}" || -z "${HY2_OBFS_PASS:-}" ]]; then
        echo "ERR re_render_hysteria2: HY2_AUTH_PASS or HY2_OBFS_PASS empty — call install.sh hy2-creds fetch first" >&2
        return 1
    fi

    # Backup with mode-preserved copy (install -m 600 preserves secret perms, cp does not).
    [[ -f "$out" ]] && install -m 600 "$out" "$backup"

    # Atomic write: render into a 0600 tmp in same dir, then rename.
    local tmp="${out}.tmp.$$"
    ( umask 077 && _render_hysteria2_to "$tpl" "$tmp" \
        "$server" "$HY2_AUTH_PASS" "$HY2_OBFS_PASS" "$listen" "$backend" )
    mv -f "$tmp" "$out"
    log "re_render_hysteria2: wrote $out (backup $backup)"
}
