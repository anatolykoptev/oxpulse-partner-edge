#!/usr/bin/env bash
# Phase 5.8 Task 5 — verify _check_upstream_transitions detects Caddy upstream
# state transitions and fires Telegram alert via lib/telegram-alert-lib.sh.
# Mirrors piter-server vpn-watchdog alert pattern.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

STATE_DIR=$(mktemp -d)
ALERT_LOG=$(mktemp)
export STATE_DIR ALERT_LOG OXPULSE_TG_STATE_DIR="$STATE_DIR" OXPULSE_TG_MIN_INTERVAL=0

# Stub curl: record alert invocations to ALERT_LOG (path embedded at creation)
printf '#!/usr/bin/env bash\nprintf "ALERT_FIRED: %%s\\n" "$*" >> %s\necho '"'"'{"ok":true}'"'"'\n' \
    "$ALERT_LOG" > "$STATE_DIR/curl"
chmod +x "$STATE_DIR/curl"
export PATH="$STATE_DIR:$PATH"

# Seed previous state: xray-client healthy
printf 'xray-client:3080=healthy:%s\n' "$(date +%s)" > "$STATE_DIR/upstream-state.env"

# Stub metrics: xray-client now unhealthy
printf 'caddy_reverse_proxy_upstreams_healthy{upstream="xray-client:3080"} 0\n' \
    > "$STATE_DIR/metrics-stub"
printf 'caddy_reverse_proxy_upstreams_healthy{upstream="host.docker.internal:18443"} 1\n' \
    >> "$STATE_DIR/metrics-stub"

# Driver: source lib then call the function directly (not the full main script,
# which exits early when node-config.json is absent).
OXPULSE_METRICS_SRC="$STATE_DIR/metrics-stub" \
SCRIPT_DIR="$REPO_ROOT" \
    bash -c '
        source "$SCRIPT_DIR/lib/telegram-alert-lib.sh"

        # Extract and define _check_upstream_transitions by sourcing only the
        # function block (we set guard vars to prevent main execution — guard
        # is irrelevant since we call bash -c, not source).
        #
        # P2 strangler extraction (2026-07-08 plan): _check_upstream_transitions
        # moved into lib/channel-health-lib.sh — extract from its new home, not
        # the orchestrator (a stale path here would silently no-op this test the
        # moment the function moved, per the plans own "test-porting no-op" risk).
        # Use sed to extract function body from the lib and eval it:
        func_body=$(sed -n "/^_check_upstream_transitions()/,/^}/p" \
            "$SCRIPT_DIR/lib/channel-health-lib.sh")
        eval "$func_body"

        _check_upstream_transitions
    '

if ! grep -qE "xray-client:3080" "$ALERT_LOG"; then
    echo "FAIL: no transition alert in ALERT_LOG"
    printf "--- ALERT_LOG ---\n"; cat "$ALERT_LOG" 2>/dev/null || true
    printf "--- state file ---\n"; cat "$STATE_DIR/upstream-state.env" 2>/dev/null || true
    exit 1
fi
echo "OK: xray-client transition healthy->unhealthy alert fired"
