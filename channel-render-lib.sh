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
# BOTH the sha256(node_id:date) mod pool_size arithmetic AND the pool
# derivation (sni_pool_from_config) — the daily SNI rotator
# (oxpulse-partner-edge-sni-rotate.sh) sources the same file, so the renderer
# and the rotator can never disagree on which SNI a node presents OR on the
# pool.
#
# Two live paths source THIS file from a mktemp file, where
# readlink -f "${BASH_SOURCE[0]}" resolves to /tmp and the sibling lookup
# misses. Mirror the rotator's installed-path fallback (PREFIX_SBIN) so the
# helper is still found; warn when neither resolves — without it the renderer
# falls back to pool index 0, the exact regression this helper exists to remove.
#
# The fallback rescues upgrade.sh's _source_lib tier-3 (source "$_fetch_tmp"),
# where PREFIX_SBIN is already populated by a previous install. It does NOT
# rescue install.sh's curl|bash fresh install: that sources this lib around
# install.sh:414 while nothing writes $PREFIX_SBIN/sni-select-lib.sh until
# systemd_run at :1679, so on a brand-new box neither path resolves and the
# warn branch is correct rather than avoidable.
_sni_lib="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" 2>/dev/null && pwd)/sni-select-lib.sh"
if [[ -f "$_sni_lib" ]]; then
    # shellcheck source=sni-select-lib.sh
    source "$_sni_lib"
elif [[ -f "${PREFIX_SBIN:-/usr/local/sbin}/sni-select-lib.sh" ]]; then
    # shellcheck source=/dev/null
    source "${PREFIX_SBIN:-/usr/local/sbin}/sni-select-lib.sh"
else
    warn "sni-select-lib.sh not found (looked: $_sni_lib, ${PREFIX_SBIN:-/usr/local/sbin}/sni-select-lib.sh) — SNI selection will fall back to pool index 0"
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
    install -d -m 0750 "$PREFIX_ETC"
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
    _backup_secret_file "$NODE_CFG"
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

# _backup_secret_file SRC [KEEP] — copy SRC to SRC.bak.<epoch> with mode 0600,
# then keep only the newest KEEP (default 5) epoch-named backups.
#
# `cp -a` copies the SOURCE mode, so one historically world-readable live file
# bred world-readable backups forever; install -m fixes the mode regardless of
# the source.  The epoch suffix is fixed-width (10 digits), so a reverse
# lexical sort is newest-first.  Never fails the caller (a backup is best effort).
_backup_secret_file() {
    local src=$1 keep=${2:-5} f n=0
    [[ -f "$src" ]] || return 0
    install -m 0600 "$src" "${src}.bak.$(date +%s)" 2>/dev/null || return 0
    while IFS= read -r f; do
        n=$((n + 1))
        if (( n > keep )); then rm -f -- "$f"; fi
    done < <(printf '%s\n' "${src}".bak.[0-9]* 2>/dev/null | sort -r)
    return 0
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
    # The POOL is derived by the shared helper (sni_pool_from_config) — same
    # function the rotator uses, so the two can never disagree on pool_size or
    # on which schema (channels[0].xray.server_names vs flat reality_server_names)
    # is preferred. The pick is delegated to sni_select (sha256(node_id:date)
    # mod pool_size). Blank/whitespace-only pool entries are stripped inside the
    # helper, so an empty slot can never be selected.
    local sni_pool sni_node_id sni_fallback
    if command -v sni_pool_from_config >/dev/null 2>&1; then
        sni_pool=$(sni_pool_from_config "$NODE_CFG" 2>/dev/null || true)
    else
        # Helper not sourced (sni-select-lib.sh missing) — derive the pool
        # inline. NOT identical to sni_pool_from_config: no singular-field
        # fallback, which only fails to matter because sni_fallback covers the
        # same case below. And when the helper is missing so is sni_select, so
        # this branch ends at index 0 either way — it exists to keep the
        # fallback chain intact, not to preserve the pick.
        sni_pool=$(python3 -c "
import json,sys; d=json.load(open(sys.argv[1]))
ch=d.get('channels',[])
x=ch[0].get('xray',{}) if ch and ch[0].get('protocol','')=='vless-reality' else {}
names=x.get('server_names') or d.get('reality_server_names') or []
names=[n for n in names if n and n.strip()]
print('\n'.join(names))" "$NODE_CFG" 2>/dev/null || true)
    fi
    sni_node_id=$(python3 -c "
import json,sys; d=json.load(open(sys.argv[1]))
print(d.get('node_id','') or '')" "$NODE_CFG")
    # Pool-absent fallback chain (preserved verbatim from the prior inline pick):
    # x.server_name -> d.reality_server_name -> OXPULSE_REALITY_SERVER_NAME ->
    # hardcoded default. This is the FALLBACK for when there is no pool at all
    # (www.samsung.com is NOT a pool member — see sni-select-lib.sh).
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
    _backup_secret_file "$XRAY_CFG"
    install -m 0600 "$out" "$XRAY_CFG"
    rm -f "$out"

    log "xray-client.json refreshed from template"
    # The result used to be swallowed by `2>/dev/null || true` while the next
    # line asserted the restart had happened, so a restart that did not occur
    # was reported to the operator as one that did (#514).
    if (cd "$PREFIX_ETC" && docker compose restart xray-client >/dev/null 2>&1); then
        log "xray-client restarted"
    else
        warn "xray-client restart FAILED — the rendered config is on disk but NOT in effect until the container restarts"
    fi
}

# Escape sed replacement metacharacters (\, &, |, ") for sed replacement strings.
# Single source used by the render functions in this module.
_esc() { printf '%s' "$1" | sed -e 's/[\\&|"]/\\&/g'; }

# ── hysteria2 (CH3) — RETIRED ────────────────────────────────────────────
#
# CH3 was a control-plane-only fallback tunnel (QUIC to a hysteria2 server on
# the central host). Its server was stopped on purpose on 2026-10-09 after a
# secrets incident; the edges kept restarting a client that could not connect
# (rvpn: 30,440 restarts). The edge now decides on its own that CH3 is gone, so
# the presence or absence of `hysteria2_server` in node-config does not matter.
#
# retire_hysteria2_ch3 — idempotent teardown, called from upgrade.sh and from
# every refresh cycle. It touches ONLY the hysteria2 client: its container, its
# rendered config + sha, the `ch3` compose profile, the channels-status line and
# the two CH3-only host scripts.
# A node that never had CH3 is left byte-identical (no log line either).
#
# Never fails the caller (both run under `set -e`): a step that cannot complete
# warns and the next cycle retries.
#
# Order is load-bearing: the config file is deleted only once the container is
# verifiably gone. A leftover container whose bind-mount source has vanished is
# restarted by docker, which creates a DIRECTORY at the missing path.
# retire_ch3_close_port — close :18443, the retired forwarder's port, in the HOST
# firewall. The CH3 client listened on 0.0.0.0:18443 and older releases opened it
# to the world; a plain upgrade never re-runs firewall_apply, so the rule would
# outlive the container. Runs on every call of retire_hysteria2_ch3 on its OWN
# check (never gated on the container/files, which a first run already removed)
# and is silent once the port is absent. Only allow rules for 18443/tcp|udp are
# deleted; no reset, no nft/docker chains. Never fails the caller.
retire_ch3_close_port() {
    local closed="" proto st l
    # ufw: only when active. `ufw status` lists v4 and v6 lines:
    #   18443/tcp            ALLOW       Anywhere
    #   18443/tcp (v6)       ALLOW       Anywhere (v6)
    _ch3_ufw_allows() {   # status-text rule
        awk -v rule="$2" '
            $1 == rule { i = 2; if ($i == "(v6)") i++
                if ($i == "ALLOW") { i++; if ($i == "IN") i++
                    if ($i == "Anywhere") f = 1 } }
            END { exit !f }' <<< "$1"
    }
    if command -v ufw >/dev/null 2>&1; then
        st=$(ufw status 2>/dev/null) || st=""
        if [[ "$st" == "Status: active"* ]]; then
            for proto in tcp udp; do
                if _ch3_ufw_allows "$st" "18443/$proto"; then
                    ufw --force delete allow "18443/$proto" >/dev/null 2>&1 || true
                    st=$(ufw status 2>/dev/null) || st=""
                    if _ch3_ufw_allows "$st" "18443/$proto"; then
                        warn "retire_ch3_close_port: ufw still allows 18443/$proto — will retry"
                    else
                        closed+=" ufw:$proto"
                    fi
                fi
            done
        fi
    fi
    # firewalld: only when running. Check each scope; the rule can be permanent,
    # runtime, or both.
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        for proto in tcp udp; do
            for l in "--permanent" ""; do
                # Capture, then match (no `| grep -q` under pipefail).
                # shellcheck disable=SC2086  # $l is one flag or empty
                st=$(firewall-cmd $l --zone=public --list-ports 2>/dev/null) || st=""
                if grep -qx "18443/$proto" <<< "${st// /$'\n'}"; then
                    # shellcheck disable=SC2086
                    firewall-cmd $l --zone=public --remove-port="18443/$proto" >/dev/null 2>&1 || true
                    closed+=" firewalld${l:+-perm}:$proto"
                fi
            done
        done
    fi
    unset -f _ch3_ufw_allows
    [[ -z "$closed" ]] || log "CH3 port 18443 closed in the host firewall:${closed}"
    return 0
}

retire_hysteria2_ch3() {
    retire_ch3_close_port || true
    local etc="${PREFIX_ETC:-/etc/oxpulse-partner-edge}" lib="${PREFIX_LIB:-/var/lib/oxpulse-partner-edge}"
    local docker="${DOCKER_BIN:-docker}" ctr="oxpulse-partner-hysteria2"
    local env_file="$etc/.env" chs="$lib/channels-status.env"
    local sbin="${PREFIX_SBIN:-/usr/local/sbin}"
    local have_ctr=0 have_files=0 have_profile=0 f

    # 0 = present, 1 = absent, 2 = docker is installed but cannot answer (dockerd
    # restarting). 2 must never read as "absent": the container may be alive, and
    # deleting its bind-mount source under it makes docker create a directory there.
    # Capture, then match: `docker ps | grep -q` under pipefail reports failure
    # when grep exits on the first hit and docker takes SIGPIPE.
    _ch3_ctr_present() {
        local names rc=0
        command -v "$docker" >/dev/null 2>&1 || return 1
        names=$("$docker" ps -a --format '{{.Names}}' 2>/dev/null) || rc=$?
        (( rc == 0 )) || return 2
        grep -qx "$ctr" <<< "$names"
    }

    local present=0
    _ch3_ctr_present || present=$?
    if (( present == 2 )); then
        warn "retire_hysteria2_ch3: docker is not answering — touching nothing, will retry"
        unset -f _ch3_ctr_present
        return 0
    fi
    (( present == 0 )) && have_ctr=1
    # The rendered yaml and its backups (re_render_* left hysteria2-client.yaml.bak.<epoch>
    # copies, which carry the same credentials), the restart-gate sha, and the two
    # host scripts that could bring CH3 back (the activation helper and the
    # first-boot render lib) — no release delivers them any more.
    for f in "$etc"/hysteria2-client.yaml* "$lib/hysteria2-config.sha" \
             "$sbin/oxpulse-partner-edge-enable-hy2" "$sbin/hydrate-hy2.sh"; do
        [[ -e "$f" ]] && { have_files=1; break; }
    done
    if [[ -f "$env_file" ]] && awk -F= '$1=="COMPOSE_PROFILES"{ n=split($2,a,","); for(i=1;i<=n;i++) if(a[i]=="ch3") f=1 } END{exit !f}' "$env_file"; then
        have_profile=1
    fi
    if (( ! have_ctr && ! have_files && ! have_profile )); then
        unset -f _ch3_ctr_present
        return 0
    fi

    # 1. Container. Compose first, through the node's own project dir: `cd` there
    #    so .env's COMPOSE_FILE (rvpn's docker-compose.override.yml) is honoured.
    #    On a node whose compose no longer defines the service that fails, so a
    #    plain `docker rm -f` by name is the fallback — by name, never a pattern.
    if (( have_ctr )); then
        ( cd "$etc" 2>/dev/null && "$docker" compose --profile ch3 rm -sf hysteria2-client ) >/dev/null 2>&1 || true
        present=0; _ch3_ctr_present || present=$?
        if (( present == 0 )); then
            "$docker" rm -f "$ctr" >/dev/null 2>&1 || true
            present=0; _ch3_ctr_present || present=$?
        fi
        if (( present != 1 )); then
            warn "retire_hysteria2_ch3: could not confirm container $ctr is gone — leaving its config in place, will retry"
            unset -f _ch3_ctr_present
            return 0
        fi
    fi
    unset -f _ch3_ctr_present

    # 2. Config + sha (yaml, .bak.*, .tmp.* — all carry the channel credentials)
    #    and the helper scripts.
    for f in "$etc"/hysteria2-client.yaml* "$lib/hysteria2-config.sha" \
             "$sbin/oxpulse-partner-edge-enable-hy2" "$sbin/hydrate-hy2.sh"; do
        # A directory at the yaml path is what docker leaves behind when it started
        # the container with the file missing; remove exactly that path.
        if [[ -d "$f" && ! -L "$f" ]]; then rm -r -- "$f"; continue; fi
        [[ -e "$f" ]] && rm -f "$f"
    done

    # 3. `ch3` out of COMPOSE_PROFILES, keeping every other line (COMPOSE_FILE!).
    if (( have_profile )); then
        local tmp
        if tmp=$(mktemp "${env_file}.XXXXXX" 2>/dev/null); then
            if awk -F= '
                $1=="COMPOSE_PROFILES" {
                    n=split(substr($0, index($0,"=")+1), a, ","); out=""
                    for(i=1;i<=n;i++) if(a[i]!="ch3" && a[i]!="") out = out (out==""?"":",") a[i]
                    if(out!="") print "COMPOSE_PROFILES=" out
                    next }
                { print }' "$env_file" > "$tmp"; then
                chmod --reference="$env_file" "$tmp" 2>/dev/null || chmod 0644 "$tmp" 2>/dev/null || true
                mv -f "$tmp" "$env_file" || { rm -f "$tmp"; warn "retire_hysteria2_ch3: could not rewrite $env_file"; }
            else
                rm -f "$tmp"; warn "retire_hysteria2_ch3: could not drop ch3 from $env_file"
            fi
        fi
    fi

    # 4. channels-status.env: hysteria2=retired (replace or append, atomically).
    if [[ -f "$chs" ]]; then
        local ctmp
        if ctmp=$(mktemp "$lib/.channels-status-XXXXXX.tmp" 2>/dev/null); then
            { grep -v '^hysteria2=' "$chs" || true; echo 'hysteria2=retired'; } > "$ctmp"
            chmod --reference="$chs" "$ctmp" 2>/dev/null || chmod 0640 "$ctmp" 2>/dev/null || true
            mv -f "$ctmp" "$chs" || { rm -f "$ctmp"; warn "retire_hysteria2_ch3: could not update $chs"; }
        fi
    fi

    log "CH3 (hysteria2) retired: container_removed=${have_ctr} config_removed=${have_files} profile_dropped=${have_profile}"
    return 0
}
