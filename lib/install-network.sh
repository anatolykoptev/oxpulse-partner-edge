#!/usr/bin/env bash
# lib/install-network.sh — Phase 4.2 extracted from install.sh Step 3.
#
# Exports: network_run
#
# Sets (caller globals):
#   PUBLIC_IP     non-empty IPv4 string
#   PRIVATE_IP    IPv4 or empty (no private IP detected / explicitly disabled)
#   REGION        lowercase '<country>-<city3>' or empty (auto-detect failed)
#
# Reads (caller globals):
#   OXPULSE_PUBLIC_IP    operator env override
#   OXPULSE_PRIVATE_IP   operator env override
#   REGION               operator arg override (kept if non-empty)
#   log warn die         functions (install.sh provides; die MUST exit, not return)

_network_detect_public_ipv4() {
    local ip
    ip=$(curl -fsS --max-time 2 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || true)
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then printf '%s' "$ip"; return 0; fi
    ip=$(curl -fsS --max-time 3 https://api.ipify.org 2>/dev/null || true)
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then printf '%s' "$ip"; return 0; fi
    ip=$(curl -fsS --max-time 3 https://ifconfig.me 2>/dev/null || true)
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then printf '%s' "$ip"; return 0; fi
    return 1
}

_network_detect_region() {
    local payload cc city
    payload=$(curl -fsS --max-time 3 "https://ipinfo.io/${PUBLIC_IP}/json" 2>/dev/null || true)
    [[ -z "$payload" ]] && return 1
    cc=$(printf '%s' "$payload" | python3 -c 'import json,sys; d=json.load(sys.stdin); print((d.get("country") or "").lower())' 2>/dev/null || true)
    city=$(printf '%s' "$payload" | python3 -c 'import json,sys; d=json.load(sys.stdin); print((d.get("city") or "").lower())' 2>/dev/null || true)
    [[ -z "$cc" || -z "$city" ]] && return 1
    city=$(printf '%s' "$city" | tr -cd 'a-z' | cut -c1-3)
    [[ -z "$city" ]] && return 1
    printf '%s-%s' "$cc" "$city"
}

network_run() {
    log "[3/10] detecting IPs"
    PUBLIC_IP="${OXPULSE_PUBLIC_IP:-}"
    [[ -z "$PUBLIC_IP" ]] && PUBLIC_IP=$(_network_detect_public_ipv4 || true)
    [[ -z "$PUBLIC_IP" ]] && die "unable to autodetect public IP — set OXPULSE_PUBLIC_IP"

    PRIVATE_IP="${OXPULSE_PRIVATE_IP:-}"
    if [[ -z "$PRIVATE_IP" ]]; then
        local iface cand
        iface=$(ip -4 route show default 2>/dev/null | awk '/default/ {print $5; exit}')
        if [[ -n "$iface" ]]; then
            cand=$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1 || true)
            [[ "$cand" != "$PUBLIC_IP" ]] && PRIVATE_IP="$cand"
        fi
    fi
    log "  public=$PUBLIC_IP private=${PRIVATE_IP:-<none>}"

    # Region auto-detect (skipped if operator passed REGION arg).
    if [[ -z "$REGION" ]]; then
        if REGION=$(_network_detect_region); then
            log "  region auto-detected: $REGION"
        else
            REGION=""
            warn "  region auto-detect failed (ipinfo.io unreachable or missing fields) — registering with NULL region"
        fi
    else
        log "  region (override): $REGION"
    fi
}
