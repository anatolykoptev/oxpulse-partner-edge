#!/usr/bin/env bash
# lib/telegram-alert-lib.sh — shared rate-limited Telegram alert primitive.
# Mirrors the operator's internal relay watchdog alert() pattern: 600s
# interval between non-CRITICAL alerts; force= bypasses limit.
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
# NOTE: _TG_API_FALLBACK and _TG_CHAT are resolved INSIDE tg_alert() at call
# time so that callers who export TG_TOKEN after sourcing this lib are handled
# correctly (BLOCKER fix — early-bound expansion would capture an empty token).

# tg_alert <message> [force]
# Sends to webhook first (lower latency, dozor-routed), falls back to direct
# Telegram API. Rate-limited to one alert per _TG_MIN_INTERVAL seconds unless
# second arg is "force" or "1".
#
# force sentinel values:
#   "force" — bypass rate-limit (string literal, legacy)
#   "1"     — bypass rate-limit (numeric synonym)
#   ""      — apply rate-limit (default)
tg_alert() {
    local msg="$1"
    local force="${2:-}"

    mkdir -p "$_TG_STATE_DIR" 2>/dev/null || true

    # Resolve token-bearing URL and chat at call time (BLOCKER fix: avoids
    # capturing empty TG_TOKEN at lib-source time).
    local api_fallback="${OXPULSE_TG_API_FALLBACK:-https://api.telegram.org/bot${TG_TOKEN:-}/sendMessage}"
    local chat="${OXPULSE_TG_CHAT:-${TG_CHAT:-}}"

    # Serialize concurrent invocations with flock (MAJOR 1 fix: TOCTOU race).
    # -w 5: wait up to 5s; if another caller holds the lock longer, drop this
    # invocation rather than pile up (non-re-entrant serial queue, not mutex).
    (
        flock -w 5 9 || {
            logger -t oxpulse-tg-alert "flock timeout — concurrent caller dropped: $msg"
            exit 0
        }

        # Rate-limit check (MAJOR 3 fix: accept "force" or "1" as bypass).
        if [[ "$force" != "force" && "$force" != "1" ]]; then
            local last_ts now
            last_ts=$(cat "$_TG_STATE_DIR/last-alert-ts" 2>/dev/null || echo "0")
            now=$(date +%s)
            if [[ $((now - last_ts)) -lt "$_TG_MIN_INTERVAL" ]]; then
                exit 0
            fi
        fi

        date +%s > "$_TG_STATE_DIR/last-alert-ts" 2>/dev/null || true

        # Webhook attempt first; fall back to direct Telegram API on failure.
        # (MAJOR 2 fix: log delivery failure and write breadcrumb for ops.)
        if ! curl -s --max-time 5 -X POST "$_TG_WEBHOOK" \
                -H "Content-Type: application/json" \
                -d "{\"message\":\"${msg}\"}" >/dev/null 2>&1; then
            local fallback_ok=0
            if [[ -n "$chat" ]]; then
                if curl -s --max-time 10 "$api_fallback" \
                        -d "chat_id=${chat}&text=${msg}" >/dev/null 2>&1; then
                    fallback_ok=1
                fi
            fi
            if [[ $fallback_ok -eq 0 ]]; then
                logger -t oxpulse-tg-alert "delivery FAILED for: $msg"
                # Breadcrumb for ops — persisted across restarts.
                echo "$(date -Iseconds) UNDELIVERED: $msg" \
                    >> "$_TG_STATE_DIR/undelivered.log" 2>/dev/null || true
            fi
        fi
    ) 9>"$_TG_STATE_DIR/.lock"
}
