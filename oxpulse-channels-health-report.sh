#!/usr/bin/env bash
# oxpulse-channels-health-report.sh — per-channel liveness probe + health report
# to the central server via POST /api/partner/channel-health.
#
# Invoked by oxpulse-channels-health-report.timer every 60s.
# Each provisioned channel produces one POST with the server's schema:
#   { node_id, channel_name, channel_rtt_ms?, channel_handshake_ok?,
#     channel_probed_at }
#
# Usage:
#   oxpulse-channels-health-report           — probe + report, exit
#   oxpulse-channels-health-report --dry-run — print JSON to stdout, skip POST
#   oxpulse-channels-health-report --once    — synonym for default (for clarity)
#   oxpulse-channels-health-report --curl-trace — log Authorization header (dry-run only)
#
# Federation plan §12, M2 #6a.
set -euo pipefail

# ---------- paths / env ----------
_SBIN=/usr/local/sbin
_TOKEN_LIB="${_TOKEN_LIB:-${_SBIN}/oxpulse-token-lib.sh}"
_PREFIX_ETC="${PARTNER_EDGE_PREFIX_ETC:-/etc/oxpulse-partner-edge}"
_NODE_CONFIG="${_NODE_CONFIG:-${_PREFIX_ETC}/node-config.json}"

# Prefer installed defaults.conf (canonical share path — Bug 8 fix);
# fall back to repo-relative for local testing.
# install-systemd.sh installs this to /usr/local/share/oxpulse-partner-edge/config/.
_DEFAULTS_CONF="${_DEFAULTS_CONF:-/usr/local/share/oxpulse-partner-edge/config/defaults.conf}"
_DEFAULTS_CONF_LOCAL="${_DEFAULTS_CONF_LOCAL:-$(dirname "$0")/config/defaults.conf}"

# ---------- flags ----------
DRY_RUN=0
CURL_TRACE=0

for _arg in "$@"; do
    case "$_arg" in
        --dry-run)    DRY_RUN=1 ;;
        --curl-trace) CURL_TRACE=1 ;;
        --once)       ;;   # no-op; timer drives cadence, --once is for clarity
        *) printf 'WARN: unknown flag: %s\n' "$_arg" >&2 ;;
    esac
done
unset _arg

# ---------- logging ----------
log()  { printf '[oxpulse-health] %s\n' "$*" >&2; }
warn() { printf '[oxpulse-health] WARN: %s\n' "$*" >&2; }
die()  { printf '[oxpulse-health] ERR:  %s\n' "$*" >&2; exit 1; }

# ---------- load token lib ----------
if [[ -r "$_TOKEN_LIB" ]]; then
    # shellcheck source=/dev/null
    source "$_TOKEN_LIB"
else
    # Inline fallback — same logic as oxpulse-token-lib.sh.
    read_service_token() {
        if [[ -n "${OXPULSE_SERVICE_TOKEN:-}" ]]; then
            printf '%s' "$OXPULSE_SERVICE_TOKEN"; return 0
        fi
        if [[ -r "${_PREFIX_ETC}/token" ]]; then
            cat "${_PREFIX_ETC}/token"; return 0
        fi
        return 1
    }
fi

# ---------- load defaults.conf ----------
if [[ -r "$_DEFAULTS_CONF" ]]; then
    # shellcheck source=/dev/null
    source "$_DEFAULTS_CONF"
elif [[ -r "$_DEFAULTS_CONF_LOCAL" ]]; then
    # shellcheck source=/dev/null
    source "$_DEFAULTS_CONF_LOCAL"
fi

OXPULSE_BACKEND_API="${OXPULSE_BACKEND_API:-${OXPULSE_BACKEND_URL:-https://oxpulse.chat}}"
OXPULSE_BACKEND_API="${OXPULSE_BACKEND_API%/}"

# ---------- preflight ----------
command -v jq    >/dev/null 2>&1 || die "jq not found — install jq"
command -v curl  >/dev/null 2>&1 || die "curl not found"

[[ -r "$_NODE_CONFIG" ]] || die "node-config.json not found at $_NODE_CONFIG"

NODE_ID=$(jq -r '.node_id // empty' "$_NODE_CONFIG" 2>/dev/null)
[[ -n "$NODE_ID" ]] || die "node_id missing in $_NODE_CONFIG"

# ---------- helper: elapsed milliseconds ----------
# Args: t0 t1 (EPOCHREALTIME floats)
_elapsed_ms() {
    awk "BEGIN { printf \"%d\", ($2 - $1) * 1000 }"
}

# ---------- probe: ch1 — xray dokodemo-door :3080 ----------
# RTT = container exec time (ms). handshake_ok = listener present.
probe_ch1() {
    local t0 t1 exit_code rtt_ms

    t0="${EPOCHREALTIME}"
    docker exec oxpulse-partner-xray ss -ltn 2>/dev/null | grep -q ':3080'
    exit_code=$?
    t1="${EPOCHREALTIME}"

    rtt_ms=$(_elapsed_ms "$t0" "$t1")

    if [[ "$exit_code" -eq 0 ]]; then
        printf '{"channel_name":"ch1","channel_rtt_ms":%d,"channel_handshake_ok":true}' "$rtt_ms"
    else
        printf '{"channel_name":"ch1","channel_rtt_ms":%d,"channel_handshake_ok":false}' "$rtt_ms"
    fi
}

# ---------- probe: ch2 — AmneziaWG mesh ping ----------
# ch2: no RTT concept (awg-show is age-based). handshake_ok = ping reachable.
probe_ch2() {
    local motherly_ip exit_code

    motherly_ip="${OXPULSE_AWG_MOTHERLY_IP:-10.9.0.2}"

    ping -c 1 -W 2 "$motherly_ip" >/dev/null 2>&1
    exit_code=$?

    if [[ "$exit_code" -eq 0 ]]; then
        printf '{"channel_name":"ch2","channel_handshake_ok":true}'
    else
        printf '{"channel_name":"ch2","channel_handshake_ok":false}'
    fi
}

# ---------- probe: ch3 — Hysteria2 TCP forwarder ----------
# RTT = nc connect time (ms). No handshake concept for Hysteria2 UDP.
probe_ch3() {
    local listen port t0 t1 exit_code rtt_ms

    # Derive port from OXPULSE_HY2_LOCAL_LISTEN (addr:port) or override.
    listen="${OXPULSE_HY2_LOCAL_LISTEN:-0.0.0.0:18443}"
    port="${listen##*:}"
    port="${OXPULSE_HY2_FALLBACK_PORT:-${port:-18443}}"

    t0="${EPOCHREALTIME}"
    nc -z 127.0.0.1 "$port" >/dev/null 2>&1
    exit_code=$?
    t1="${EPOCHREALTIME}"

    if [[ "$exit_code" -eq 0 ]]; then
        rtt_ms=$(_elapsed_ms "$t0" "$t1")
    else
        rtt_ms=0
    fi

    # channel_handshake_ok intentionally absent for ch3 (no handshake concept).
    printf '{"channel_name":"ch3","channel_rtt_ms":%d}' "$rtt_ms"
}

# ---------- post one channel payload ----------
_post_channel() {
    local payload="$1"
    local token

    token=$(read_service_token 2>/dev/null || true)
    if [[ -z "$token" ]]; then
        warn "no service token — skipping $(printf '%s' "$payload" | jq -r '.channel_name // "?"')"
        return 1
    fi

    local probed_at
    probed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    local full_payload
    full_payload=$(printf '%s' "$payload" | jq \
        --arg node_id "$NODE_ID" \
        --arg ts "$probed_at" \
        '. + {node_id: $node_id, channel_probed_at: $ts}')

    local channel_name
    channel_name=$(printf '%s' "$payload" | jq -r '.channel_name // "?"')

    if [[ "$DRY_RUN" -eq 1 ]]; then
        printf '%s\n' "$full_payload"
        if [[ "$CURL_TRACE" -eq 1 ]]; then
            printf 'Authorization: Bearer %s\n' "$token" >&2
        fi
        return 0
    fi

    local http_code
    http_code=$(curl -s -o /dev/null -w '%{http_code}' \
        --max-time 15 \
        -X POST \
        -H 'Content-Type: application/json' \
        -H "Authorization: Bearer $token" \
        -d "$full_payload" \
        "${OXPULSE_BACKEND_API}/api/partner/channel-health" \
        2>/dev/null || echo '000')

    if [[ "$http_code" =~ ^2 ]]; then
        log "channel $channel_name reported OK (HTTP $http_code)"
        return 0
    elif [[ "$http_code" =~ ^4 ]]; then
        warn "channel $channel_name: HTTP $http_code — check service token"
        return 1   # auth failure — exit 1 so timer logs it
    else
        # 5xx / 000 (timeout/network) — transient, try next tick
        warn "channel $channel_name: HTTP $http_code — server/network hiccup, retry next tick"
        return 0
    fi
}

# ---------- Phase 5.8 Task 5: upstream-transition Telegram alerting ----------
# Polls Caddy /metrics (or fixture file via OXPULSE_METRICS_SRC), compares
# upstream health against persisted state, fires tg_alert() on transitions.
# State file: ${STATE_DIR:-/var/lib/oxpulse-partner-edge}/upstream-state.env
#
# Env overrides:
#   OXPULSE_METRICS_SRC  — file path or URL (default http://127.0.0.1:2019/metrics)
#   STATE_DIR            — directory for upstream-state.env
#                          (default /var/lib/oxpulse-partner-edge)

_check_upstream_transitions() {
    local metrics_src="${OXPULSE_METRICS_SRC:-http://127.0.0.1:2019/metrics}"
    local state_dir="${STATE_DIR:-/var/lib/oxpulse-partner-edge}"
    local state_file="$state_dir/upstream-state.env"
    local raw

    if [[ "$metrics_src" =~ ^http ]]; then
        raw=$(curl -sf --max-time 3 "$metrics_src" 2>/dev/null || return 0)
    else
        [[ -r "$metrics_src" ]] || return 0
        raw=$(cat "$metrics_src")
    fi

    declare -A current
    local line up val
    while IFS= read -r line; do
        [[ "$line" =~ ^caddy_reverse_proxy_upstreams_healthy ]] || continue
        up=$(printf '%s' "$line" | sed -nE 's/.*upstream="([^"]+)".*/\1/p')
        val=$(printf '%s' "$line" | sed -nE 's/.* ([01])$/\1/p')
        [[ -z "$up" || -z "$val" ]] && continue
        if [[ "$val" == "1" ]]; then
            current["$up"]=healthy
        else
            current["$up"]=unhealthy
        fi
    done <<< "$raw"

    declare -A previous
    if [[ -r "$state_file" ]]; then
        local key rest
        while IFS='=' read -r key rest; do
            [[ -z "$key" || "$key" =~ ^# ]] && continue
            previous["$key"]=$(printf '%s' "$rest" | cut -d: -f1)
        done < "$state_file"
    fi

    # Load alert lib from SCRIPT_DIR, then sbin fallback; silent-skip if missing.
    local _lib_loaded=0
    # shellcheck source=lib/telegram-alert-lib.sh
    if source "${SCRIPT_DIR:-$(dirname "$0")}/lib/telegram-alert-lib.sh" 2>/dev/null; then
        _lib_loaded=1
    elif source "${PREFIX_SBIN:-/usr/local/sbin}/telegram-alert-lib.sh" 2>/dev/null; then
        _lib_loaded=1
    fi

    if [[ "$_lib_loaded" -eq 0 ]]; then
        warn "telegram-alert-lib.sh not found — skipping transition alerts"
        return 0
    fi

    local cur prev _hostname
    _hostname=$(hostname -s 2>/dev/null || echo edge)

    for up in "${!current[@]}"; do
        cur="${current[$up]}"
        prev="${previous[$up]:-}"
        if [[ -n "$prev" && "$cur" != "$prev" ]]; then
            tg_alert "[$_hostname] TRANSITION upstream=${up} ${prev} -> ${cur}"
        fi
    done

    # Persist current state atomically.
    # mktemp -p same dir as state_file ensures rename stays intra-fs (POSIX atomic).
    # Cross-fs mv (e.g. /tmp → /var/lib) is non-atomic — MAJOR 4 fix.
    mkdir -p "$state_dir" 2>/dev/null || true
    local tmp
    tmp=$(mktemp -p "$(dirname "$state_file")" upstream-state.XXXXXX) || {
        warn "mktemp failed in $(dirname "$state_file") — skipping state persist"
        return 0
    }
    {
        echo "# Generated by oxpulse-channels-health-report.sh — do not edit"
        for up in "${!current[@]}"; do
            printf '%s=%s:%s\n' "$up" "${current[$up]}" "$(date +%s)"
        done
    } > "$tmp"
    chmod 0640 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$state_file"
}

# ---------- main ----------
mapfile -t _PROVISIONED < <(jq -r '.channels[]?.id // empty' "$_NODE_CONFIG" 2>/dev/null || true)

if [[ "${#_PROVISIONED[@]}" -eq 0 ]]; then
    log "no channels in node-config.json — nothing to report"
    _check_upstream_transitions
    exit 0
fi

_AUTH_FAIL=0

for _chan in "${_PROVISIONED[@]}"; do
    # Channel ids in node-config may carry a node-specific suffix (e.g. "ch1-zvonilka").
    # Match on prefix: ch1* = Reality/VLESS, ch2* = AmneziaWG, ch3* = Hysteria2.
    # The server expects canonical names ch1/ch2/ch3, not the local variant.
    case "$_chan" in
        ch1*)
            _payload=$(probe_ch1 2>/dev/null || printf '{"channel_name":"ch1","channel_handshake_ok":false}')
            ;;
        ch2*)
            _payload=$(probe_ch2 2>/dev/null || printf '{"channel_name":"ch2","channel_handshake_ok":false}')
            ;;
        ch3*)
            _payload=$(probe_ch3 2>/dev/null || printf '{"channel_name":"ch3","channel_rtt_ms":0}')
            ;;
        ch4*|ch5*|ch6*)
            log "$_chan not yet wired on edge — skipping"
            continue
            ;;
        *)
            warn "unknown channel '$_chan' — skipping"
            continue
            ;;
    esac

    if ! _post_channel "$_payload"; then
        _AUTH_FAIL=$((_AUTH_FAIL + 1))
    fi
done

# auth failures = exit 1 (timer logs; no infinite loop)
[[ "$_AUTH_FAIL" -eq 0 ]] || exit 1

_check_upstream_transitions
exit 0
