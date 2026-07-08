#!/usr/bin/env bash
# Phase 5.8 Task 5 fix-loop — negative tests for upstream transition alerting.
# Covers (a) healthy→healthy no-fire (b) rate-limit suppression within MIN_INTERVAL.
# Expected: alert MUST NOT fire in both cases.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

_cleanup() {
    rm -rf "$_STATE_DIR1" "$_STATE_DIR2" "$_ALERT_LOG1" "$_ALERT_LOG2" 2>/dev/null || true
}
trap _cleanup EXIT

_STATE_DIR1=$(mktemp -d)
_ALERT_LOG1=$(mktemp)
_STATE_DIR2=$(mktemp -d)
_ALERT_LOG2=$(mktemp)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Make a stub curl that appends to the given log file.
_make_curl_stub() {
    local dir="$1" log="$2"
    # shellcheck disable=SC2016
    printf '#!/usr/bin/env bash\nprintf "ALERT_FIRED: %%s\\n" "$*" >> %s\necho '"'"'{"ok":true}'"'"'\n' \
        "$log" > "$dir/curl"
    chmod +x "$dir/curl"
}

# Run _check_upstream_transitions in an isolated bash subshell.
_run_check() {
    local script_dir="$1" state_dir="$2" metrics_src="$3" tg_state_dir="$4" min_interval="$5"

    SCRIPT_DIR="$script_dir" \
    STATE_DIR="$state_dir" \
    OXPULSE_METRICS_SRC="$metrics_src" \
    OXPULSE_TG_STATE_DIR="$tg_state_dir" \
    OXPULSE_TG_MIN_INTERVAL="$min_interval" \
    bash -c '
        source "$SCRIPT_DIR/lib/telegram-alert-lib.sh"
        # P2 strangler extraction (2026-07-08 plan): _check_upstream_transitions
        # moved into lib/channel-health-lib.sh — extract from its new home, not
        # the orchestrator (a stale path here would silently no-op this test the
        # moment the function moved, per the plans own "test-porting no-op" risk).
        func_body=$(sed -n "/^_check_upstream_transitions()/,/^}/p" \
            "$SCRIPT_DIR/lib/channel-health-lib.sh")
        eval "$func_body"
        _check_upstream_transitions
    '
}

# ---------------------------------------------------------------------------
# Case 1: healthy→healthy — alert MUST NOT fire
# ---------------------------------------------------------------------------
echo "--- Case 1: healthy→healthy (no transition) ---"

_make_curl_stub "$_STATE_DIR1" "$_ALERT_LOG1"
export PATH="$_STATE_DIR1:$PATH"

# Seed previous state: xray-client healthy
printf 'xray-client:3080=healthy:%s\n' "$(date +%s)" > "$_STATE_DIR1/upstream-state.env"

# Metrics: still healthy → no transition
cat > "$_STATE_DIR1/metrics-stub" <<'EOF'
caddy_reverse_proxy_upstreams_healthy{upstream="xray-client:3080"} 1
EOF

_run_check "$REPO_ROOT" "$_STATE_DIR1" "$_STATE_DIR1/metrics-stub" "$_STATE_DIR1" "0"

if grep -q "ALERT_FIRED" "$_ALERT_LOG1" 2>/dev/null; then
    echo "FAIL case 1: alert fired on healthy→healthy (no transition expected)"
    echo "--- ALERT_LOG ---"
    cat "$_ALERT_LOG1"
    exit 1
fi
echo "OK case 1: no alert on healthy→healthy (no transition)"

# ---------------------------------------------------------------------------
# Case 2: rate-limit suppression — second alert within MIN_INTERVAL MUST NOT fire
# ---------------------------------------------------------------------------
echo "--- Case 2: rate-limit suppression within MIN_INTERVAL ---"

# Prepend a fresh directory so the stub curl is first in PATH.
export PATH="$_STATE_DIR2:${PATH#"$_STATE_DIR1:"}"
_make_curl_stub "$_STATE_DIR2" "$_ALERT_LOG2"

# Seed previous state: xray-client healthy (so a healthy→unhealthy transition
# WOULD normally fire — this is the "would-fire" scenario).
printf 'xray-client:3080=healthy:%s\n' "$(date +%s)" > "$_STATE_DIR2/upstream-state.env"

# Metrics: now unhealthy → this IS a real transition.
cat > "$_STATE_DIR2/metrics-stub" <<'EOF'
caddy_reverse_proxy_upstreams_healthy{upstream="xray-client:3080"} 0
EOF

# Plant a recent alert timestamp so rate-limit window has NOT elapsed (MIN_INTERVAL=600).
date +%s > "$_STATE_DIR2/last-alert-ts"

_run_check "$REPO_ROOT" "$_STATE_DIR2" "$_STATE_DIR2/metrics-stub" "$_STATE_DIR2" "600"

if grep -q "ALERT_FIRED" "$_ALERT_LOG2" 2>/dev/null; then
    echo "FAIL case 2: alert fired despite rate-limit window not elapsed"
    echo "--- ALERT_LOG ---"
    cat "$_ALERT_LOG2"
    exit 1
fi
echo "OK case 2: rate-limit suppresses alert within MIN_INTERVAL"

echo ""
echo "ALL NEGATIVE TESTS PASS"
