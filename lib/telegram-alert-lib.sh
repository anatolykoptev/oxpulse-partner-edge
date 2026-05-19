#!/usr/bin/env bash
# lib/telegram-alert-lib.sh — shared rate-limited Telegram alert primitive.
# Mirrors /home/krolik/src/piter-server/deploy/piter/vpn-watchdog.sh alert()
# pattern: 600s interval between non-CRITICAL alerts; force= bypasses limit.
# Sourceable from any partner-edge script.
#
# Env overrides:
#   OXPULSE_TG_STATE_DIR    — state directory
#                             (default /var/lib/oxpulse-partner-edge/telegram)
#   OXPULSE_TG_MIN_INTERVAL — seconds between non-force alerts (default 600)
#   OXPULSE_TG_WEBHOOK      — Telegram bus webhook (default dozor on AWG mesh)
#   OXPULSE_TG_API_FALLBACK — direct Telegram API endpoint (with bot token)
#   OXPULSE_TG_CHAT         — Telegram chat id for direct fallback

_TG_STATE_DIR="${OXPULSE_TG_STATE_DIR:-/var/lib/oxpulse-partner-edge/telegram}"
_TG_MIN_INTERVAL="${OXPULSE_TG_MIN_INTERVAL:-600}"
_TG_WEBHOOK="${OXPULSE_TG_WEBHOOK:-http://10.9.0.2:8765/webhook/monitor/healthcheck}"
_TG_API_FALLBACK="${OXPULSE_TG_API_FALLBACK:-https://api.telegram.org/bot${TG_TOKEN:-}/sendMessage}"
_TG_CHAT="${OXPULSE_TG_CHAT:-${TG_CHAT:-}}"

# tg_alert <message> [force]
# Sends to webhook first (lower latency, dozor-routed), falls back to direct
# Telegram API. Rate-limited to one alert per _TG_MIN_INTERVAL seconds unless
# second arg is the literal string "force".
tg_alert() {
    local msg="$1"
    local force="${2:-}"
    local now last_ts

    mkdir -p "$_TG_STATE_DIR" 2>/dev/null || true

    if [[ "$force" != "force" ]]; then
        last_ts=$(cat "$_TG_STATE_DIR/last-alert-ts" 2>/dev/null || echo "0")
        now=$(date +%s)
        if [[ $((now - last_ts)) -lt "$_TG_MIN_INTERVAL" ]]; then
            return 0
        fi
    fi

    date +%s > "$_TG_STATE_DIR/last-alert-ts" 2>/dev/null || true

    if ! curl -s --max-time 5 -X POST "$_TG_WEBHOOK" \
            -H "Content-Type: application/json" \
            -d "{\"message\":\"${msg}\"}" >/dev/null 2>&1; then
        if [[ -n "$_TG_CHAT" ]]; then
            curl -s --max-time 10 "$_TG_API_FALLBACK" \
                -d "chat_id=${_TG_CHAT}&text=${msg}" >/dev/null 2>&1 || true
        fi
    fi
}
