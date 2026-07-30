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
TOKEN_FILE="${TOKEN_FILE:-$PREFIX_ETC/token}"
BACKEND_URL="${OXPULSE_BACKEND_URL:-https://oxpulse.chat}"
BACKEND_URL="${BACKEND_URL%/}"
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/anatolykoptev/oxpulse-partner-edge/main}"

# Source fleet-wide infrastructure defaults.
# Lookup order: repo root (dev/test) → installed share dir → sbin-relative.
# Operator can export OXPULSE_* vars before sourcing this file to override.
_defaults_local="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/config/defaults.conf"
_defaults_installed="/usr/local/share/oxpulse-partner-edge/config/defaults.conf"
if [[ -f "$_defaults_local" ]]; then
    # shellcheck source=config/defaults.conf
    source "$_defaults_local"
elif [[ -f "$_defaults_installed" ]]; then
    # shellcheck source=/dev/null
    source "$_defaults_installed"
else
    : # defaults not found — callers set explicit vars or fall through to per-var defaults below
fi
unset _defaults_local _defaults_installed

# Source the shared SNI selection helper (sibling of this lib at install time
# = PREFIX_SBIN, or next to this file in a dev/test checkout). SINGLE source of
# the sha256(node_id:date) mod pool_size arithmetic — the daily SNI rotator
# (oxpulse-partner-edge-sni-rotate.sh) sources the same file, so the renderer
# and the rotator can never disagree on which SNI a node presents.
_sni_lib="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" 2>/dev/null && pwd)/sni-select-lib.sh"
if [[ -f "$_sni_lib" ]]; then
    # shellcheck source=sni-select-lib.sh
    source "$_sni_lib"
fi
unset _sni_lib

# Re-fetch node-config.json from the registry API over Bearer auth.
# Extracted from update.sh Step-1 so upgrade.sh can self-heal the same way.
#
# Contract:
#   - Authenticated: same Bearer token + X-Node-Id header as update.sh.
#   - Idempotent: safe to call when node-config is already current.
#   - Config-only: writes node-config.json and a .bak — never restarts
#     containers, rotates keys, or touches anything else.
#   - Graceful fallback: on any failure (no token, network error, auth
#     error, malformed/truncated response, missing required fields) the
#     local node-config.json is left untouched and the function returns 0
#     so the caller can continue with the local file.
#   - Atomic write: the response is written to a temp file, validated as
#     JSON with the fields the renderer needs, then renamed into place.
#     A truncated or malformed response never reaches node-config.json.
#   - Loud fallback: failures are announced via warn() (the same level
#     the rest of the script uses for operator-visible conditions), not
#     debug — a silent fallback reproduces the bug this function fixes.
refetch_node_config() {
    local token=""
    if [[ -f "$TOKEN_FILE" ]]; then
        token="$(tr -d '\r\n[:space:]' < "$TOKEN_FILE")"
    fi

    if [[ -z "$token" ]]; then
        warn "no token at $TOKEN_FILE — skipping API re-fetch, using local node-config.json"
        return 0
    fi

    log "token found — attempting to re-fetch node-config.json from API"

    local node_id=""
    if [[ -f "$NODE_CFG" ]]; then
        node_id=$(jq -r '.node_id // .partner_id // empty' "$NODE_CFG" 2>/dev/null || true)
    fi

    local api_resp=""
    local api_ok=0
    api_resp=$(curl -fsSL --max-time 15 \
        -H "Authorization: Bearer $token" \
        ${node_id:+-H "X-Node-Id: $node_id"} \
        "$BACKEND_URL/api/partner/node-config" 2>/dev/null) && api_ok=1 || true

    if [[ $api_ok -ne 1 || -z "$api_resp" ]]; then
        warn "API re-fetch failed or returned empty — using local node-config.json"
        return 0
    fi

    # Write the response to a temp file in the same directory so the
    # rename is atomic on the target filesystem.  A truncated or malformed
    # response never reaches node-config.json — the temp is removed on
    # validation failure and only renamed on success.
    install -d -m 0755 "$PREFIX_ETC"
    local tmp
    tmp=$(mktemp --tmpdir="$PREFIX_ETC" ".node-config.json.XXXXXX.tmp" 2>/dev/null) || {
        warn "refetch_node_config: mktemp failed in $PREFIX_ETC — using local node-config.json"
        return 0
    }

    printf '%s\n' "$api_resp" > "$tmp"

    # Validate: parses as JSON + has node_id (same gate as update.sh Step-1).
    local fetched_id
    fetched_id=$(jq -r '.node_id // empty' "$tmp" 2>/dev/null || true)
    if [[ -z "$fetched_id" ]]; then
        warn "API response missing node_id or not valid JSON — using local node-config.json"
        rm -f "$tmp"
        return 0
    fi

    # Validate: carries the fields the renderer needs (flat reality_* OR
    # channels[] schema).  Mirrors update.sh Step-2 field check so a
    # response that would render a broken xray config is rejected at the
    # refetch gate, not after it has overwritten the good local file.
    local has_flat=1 _rf _val
    for _rf in reality_uuid reality_public_key backend_endpoint; do
        _val=$(jq -r ".$_rf // empty" "$tmp" 2>/dev/null || true)
        [[ -n "$_val" ]] || has_flat=0
    done
    if [[ $has_flat -eq 0 ]]; then
        local ch_count
        ch_count=$(jq '.channels // [] | length' "$tmp" 2>/dev/null || echo 0)
        if [[ "$ch_count" -eq 0 ]]; then
            warn "API response missing required fields (reality_uuid, reality_public_key, backend_endpoint) and has no channels[] — using local node-config.json"
            rm -f "$tmp"
            return 0
        fi
    fi

    # Atomic install: backup old, rename validated temp into place (0600 — contains secrets).
    [[ -f "$NODE_CFG" ]] && cp -a "$NODE_CFG" "${NODE_CFG}.bak.$(date +%s)" 2>/dev/null || true
    mv -f "$tmp" "$NODE_CFG"
    chmod 0600 "$NODE_CFG"
    log "node-config.json refreshed from API (node_id=$fetched_id)"
}

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
    local tmp
    tmp=$(mktemp --tmpdir="$dst_dir" ".$(basename "$dst").XXXXXX.tmp") || {
        warn "render_template: mktemp failed in $dst_dir"
        return 1
    }
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
    if ! mv -f "$tmp" "$dst"; then
        warn "render_template: mv failed: $dst"
        rm -f "$tmp"
        return 1
    fi
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
    # SNI selection — ONE rule, shared with the daily rotator via sni-select-lib.sh.
    # Read the pool, node_id, and the pool-absent fallback from node-config.json,
    # then delegate the pick to sni_select (sha256(node_id:date) mod pool_size).
    # Pool entries are filtered the same way the rotator filters them, so an
    # empty slot can never be selected.
    local sni_pool sni_node_id sni_fallback
    sni_pool=$(python3 -c "
import json,sys; d=json.load(open(sys.argv[1]))
ch=d.get('channels',[])
x=ch[0].get('xray',{}) if ch and ch[0].get('protocol','')=='vless-reality' else {}
names=x.get('server_names') or d.get('reality_server_names')
names=[n for n in (names or []) if n]
print('\n'.join(names))" "$NODE_CFG")
    sni_node_id=$(python3 -c "
import json,sys; d=json.load(open(sys.argv[1]))
print(d.get('node_id','') or '')" "$NODE_CFG")
    # Pool-absent fallback chain (preserved verbatim from the prior inline pick):
    # x.server_name -> d.reality_server_name -> OXPULSE_REALITY_SERVER_NAME ->
    # hardcoded default. (os is imported here — the prior block omitted it and
    # NameError'd if it ever reached the env lookup.)
    sni_fallback=$(python3 -c "
import json,os,sys; d=json.load(open(sys.argv[1]))
ch=d.get('channels',[])
x=ch[0].get('xray',{}) if ch and ch[0].get('protocol','')=='vless-reality' else {}
print(x.get('server_name','') or d.get('reality_server_name','') or os.environ.get('OXPULSE_REALITY_SERVER_NAME','') or 'www.samsung.com')" "$NODE_CFG")

    if [[ -n "$sni_pool" ]]; then
        if command -v sni_select >/dev/null 2>&1; then
            server_name=$(sni_select "$sni_node_id" "$(date -I)" "$sni_pool") || server_name="$sni_fallback"
        else
            warn "sni_select helper not available — falling back to first pool entry (index 0)"
            server_name=$(printf '%s\n' "$sni_pool" | sed -n '1p')
        fi
        [[ -n "$server_name" ]] || server_name="$sni_fallback"
    else
        server_name="$sni_fallback"
    fi
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
    # Read xhttp transport settings from node-config.json (server is source of truth).
    # Helper is co-installed in the same directory as this lib (PREFIX_SBIN).
    local _lib_dir
    _lib_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" 2>/dev/null && pwd)"
    local _read_xhttp="${_lib_dir}/read-xhttp.py"
    local xhttp_mode xhttp_path xmux_max_concurrency xmux_c_max_reuse_times xmux_c_max_lifetime_ms x_padding_bytes
    xhttp_mode=$("$_read_xhttp" "$NODE_CFG" mode --default stream-one 2>/dev/null || echo "stream-one")
    xhttp_path=$("$_read_xhttp" "$NODE_CFG" path --default /xh 2>/dev/null || echo "/xh")
    xmux_max_concurrency=$("$_read_xhttp" "$NODE_CFG" xmux_concurrency --default 1 --type int 2>/dev/null || echo "1")
    xmux_c_max_reuse_times=$("$_read_xhttp" "$NODE_CFG" xmux_reuse --default 64 --type int 2>/dev/null || echo "64")
    xmux_c_max_lifetime_ms=$("$_read_xhttp" "$NODE_CFG" xmux_lifetime --default 15000 --type int 2>/dev/null || echo "15000")
    x_padding_bytes=$("$_read_xhttp" "$NODE_CFG" padding --default 100-1000 2>/dev/null || echo "100-1000")

    sed \
        -e "s|{{REALITY_UUID}}|$(_esc "$uuid")|g" \
        -e "s|{{REALITY_ENCRYPTION}}|$(_esc "$enc")|g" \
        -e "s|{{REALITY_PUBLIC_KEY}}|$(_esc "$pub_key")|g" \
        -e "s|{{REALITY_SHORT_ID}}|$(_esc "$short_id")|g" \
        -e "s|{{REALITY_SERVER_NAME}}|$(_esc "$server_name")|g" \
        -e "s|{{BACKEND_HOST}}|$(_esc "$backend_host")|g" \
        -e "s|{{BACKEND_PORT}}|$(_esc "$backend_port")|g" \
        -e "s|{{BACKEND_ENDPOINT}}|$(_esc "$backend")|g" \
        -e "s|{{XRAY_XHTTP_MODE}}|$(_esc "$xhttp_mode")|g" \
        -e "s|{{XRAY_XHTTP_PATH}}|$(_esc "$xhttp_path")|g" \
        -e "s|{{XRAY_XHTTP_XMUX_MAX_CONCURRENCY}}|$(_esc "$xmux_max_concurrency")|g" \
        -e "s|{{XRAY_XHTTP_XMUX_C_MAX_REUSE_TIMES}}|$(_esc "$xmux_c_max_reuse_times")|g" \
        -e "s|{{XRAY_XHTTP_XMUX_C_MAX_LIFETIME_MS}}|$(_esc "$xmux_c_max_lifetime_ms")|g" \
        -e "s|{{XRAY_XHTTP_X_PADDING_BYTES}}|$(_esc "$x_padding_bytes")|g" \
        "$tpl" > "$out"

    # Strip xmux block when mode != packet-up.
    if [[ "$xhttp_mode" != "packet-up" ]]; then
        local jq_tmp
        jq_tmp=$(mktemp)
        jq 'del(.outbounds[].streamSettings.xhttpSettings.xmux)' "$out" > "$jq_tmp" \
            && mv "$jq_tmp" "$out" \
            || { rm -f "$jq_tmp"; die "jq xmux strip failed — refusing to install half-stripped config"; }
    fi
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
    local server="${HY2_SERVER:-${OXPULSE_HY2_SERVER:-203.0.113.10:51822}}"
    local listen="${HY2_LOCAL_LISTEN:-${OXPULSE_HY2_LOCAL_LISTEN:-0.0.0.0:18443}}"
    local backend="${HY2_REMOTE_BACKEND:-${OXPULSE_HY2_REMOTE_BACKEND:-127.0.0.1:8907}}"

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
