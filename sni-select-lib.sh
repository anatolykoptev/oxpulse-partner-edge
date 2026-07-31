#!/usr/bin/env bash
# sni-select-lib.sh — single source of truth for Reality SNI selection AND
# pool derivation.
#
# Provides:
#   sni_pool_from_config <node-config path>  — derive the SNI pool ONE way
#   sni_select <node_id> <date> <pool>       — deterministic pick
#
# Deterministic pick: sha256(node_id:YYYY-MM-DD) mod pool_size.
# Same node+date+pool -> same name; different nodes spread across the pool.
#
# Sourced by BOTH:
#   - oxpulse-partner-edge-sni-rotate.sh (daily timer)
#   - channel-render-lib.sh (every render / upgrade / key refresh / refetch)
#
# Keeping BOTH the arithmetic AND the pool derivation in ONE place guarantees
# the renderer and the rotator never disagree on which SNI a node presents.
# Before this helper existed the renderer took names[0] unconditionally while
# the rotator hashed; and even after the hash was unified the two still derived
# the POOL two different ways (renderer preferred channels[0].xray.server_names,
# rotator read flat reality_server_names only and injected a synthetic default)
# — so the same node could see a different pool_size, and therefore a different
# SNI, from each caller. Unifying the pool derivation here closes that.
#
# No shebang execution — this file is only ever sourced, never run directly.

# Diagnostics: prefer the caller's warn()/log() so messages land where the
# caller's operator looks. The rotator defines log() (writes $LOG) but NOT
# warn(), so routing warn through log (when defined) puts "node_id empty ->
# index 0" into /var/log/oxpulse-partner-edge-sni-rotate.log instead of stderr
# (which the timer drops to journald, invisible to the operator). The renderer
# defines warn() before sourcing this file, so its own warn is kept. log() is
# resolved at CALL time, so the rotator's log() (defined after sourcing this)
# wins over any fallback here.
command -v warn >/dev/null 2>&1 || warn() {
    if command -v log >/dev/null 2>&1; then
        log "WARN: $*"
    else
        printf 'WARN: %s\n' "$*" >&2
    fi
}

# sni_pool_from_config <node-config path>
#
# Derives the SNI pool from node-config.json ONE way. Prefers
# channels[0].xray.server_names (the channels[] schema the renderer treats as
# preferred), falls back to flat reality_server_names. Blank and
# whitespace-only entries are stripped HERE so the count and the index always
# see the SAME list (M3: the prior code counted with `grep -c .` which skips
# blank lines but indexed with `sed -n Np` which does not — an empty or
# whitespace-only slot could be selected and written to xray-client.json).
#
# The synthetic www.samsung.com default is NOT a pool member. It is the
# renderer's pool-ABSENT fallback (the sni_fallback chain in re_render_xray:
# x.server_name -> d.reality_server_name -> OXPULSE_REALITY_SERVER_NAME ->
# www.samsung.com), not something to hash a node_id against. The rotator, on
# an empty pool, has nothing to rotate to and skips (exit 0); the renderer
# writes its fallback. Injecting the default into the pool (as the rotator
# used to) made a node with no configured names hash against a 1-entry
# ['www.samsung.com'] pool — a second way the two callers could disagree on
# pool_size. Removed.
#
# Prints the pool newline-separated to stdout. Empty output (no configured
# names) + return 0 — the caller decides what an empty pool means. Returns 1
# only if the file is missing/unreadable/not valid JSON.
sni_pool_from_config() {
    local cfg="$1"
    [[ -f "$cfg" ]] || { warn "sni_pool_from_config: $cfg not found"; return 1; }
    python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
ch = d.get('channels', []) or []
x = ch[0].get('xray', {}) if (ch and ch[0].get('protocol', '') == 'vless-reality') else {}
names = x.get('server_names') or d.get('reality_server_names') or []
# A node configured with only the singular field has a pool of exactly one. The
# old rotator reached the same outcome via a fallback chain that ALSO injected a
# hardcoded 'www.samsung.com'; that injection is not reproduced — a name the
# operator never configured must not enter the pool.
if not names:
    single = x.get('server_name') or d.get('reality_server_name') or ''
    names = [single] if single else []
# strip blank + whitespace-only so count and index agree (M3)
names = [n for n in names if n and n.strip()]
print('\n'.join(names))
" "$cfg" 2>/dev/null || { warn "sni_pool_from_config: could not parse $cfg"; return 1; }
}

# sni_select <node_id> <date_YYYY-MM-DD> <pool_newline_separated>
#
# Prints the chosen SNI to stdout. The 0-based index is NOT returned here —
# use sni_select_indexed for that; a global cannot carry it out of the
# $(command substitution) every caller uses. Returns 0 on success, 1 if the pool is
# empty or the computed index is invalid.
#
# If node_id is empty/missing, warns and falls back to index 0 — the ONLY
# remaining path to index 0. A single-entry pool always yields that entry
# (hash mod 1 == 0), preserving prior behaviour.
#
# M1: the python3 hash is validated — pick_idx must match ^[0-9]+$ and be <
# pool_size, else warn and return 1. Before this, a python3 failure (missing
# binary, exit 127, traceback) left pick_idx empty; `$((pick_idx + 1))` coerced
# empty to 0 and `sed -n 1p` returned the first pool entry with exit 0 — a
# silent collapse to index 0, the exact behaviour this helper exists to
# remove. Note set -euo pipefail does NOT save this: both callers invoke
# sni_select in an `||` context, which suppresses set -e for the whole body.
sni_select_indexed() {
    local node_id="$1" date="$2" pool="$3"
    # Normalize ONCE: read into an array, stripping blank + whitespace-only
    # entries, then count AND index that same array (M3 — never count one
    # shape and sed another).
    local -a _names=()
    local _n
    while IFS= read -r _n; do
        if [[ -n "$_n" ]] && ! [[ "$_n" =~ ^[[:space:]]*$ ]]; then
            _names+=("$_n")
        fi
    done < <(printf '%s\n' "$pool")
    local pool_size=${#_names[@]}
    if [[ "$pool_size" -lt 1 ]]; then
        return 1
    fi
    if [[ -z "$node_id" ]]; then
        warn "sni_select: node_id empty — falling back to index 0"
        printf '0\t%s\n' "${_names[0]}"
        return 0
    fi
    local pick_idx
    pick_idx=$(python3 -c "
import hashlib, sys
seed = '{}:{}'.format(sys.argv[1], sys.argv[2])
h = int(hashlib.sha256(seed.encode()).hexdigest(), 16)
print(h % int(sys.argv[3]))
" "$node_id" "$date" "$pool_size") || {
        warn "sni_select: python3 hash failed — cannot pick (node_id=$node_id pool_size=$pool_size)"
        return 1
    }
    # Validate: a non-negative integer in range. An empty/garbage pick_idx used
    # to coerce to 0 and silently return index 0 with exit 0 (M1).
    if ! [[ "$pick_idx" =~ ^[0-9]+$ ]] || [[ "$pick_idx" -ge "$pool_size" ]]; then
        warn "sni_select: invalid pick_idx='$pick_idx' (pool_size=$pool_size) — refusing to fall back to index 0"
        return 1
    fi
    printf '%s\t%s\n' "$pick_idx" "${_names[$pick_idx]}"
}

# sni_select <node_id> <date> <pool> — the name only, for callers that do not
# need the index (the renderer). Thin wrapper so there is still ONE
# implementation of the pick.
#
# The index is returned on stdout rather than through a global: every caller
# uses $(sni_select ...), which runs in a subshell, so a global assignment is
# invisible to the parent and reading it under `set -u` aborts the script.
sni_select() {
    local _out
    _out=$(sni_select_indexed "$@") || return 1
    printf '%s\n' "${_out#*$'\t'}"
}
