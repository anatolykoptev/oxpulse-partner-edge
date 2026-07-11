#!/usr/bin/env bash
# tests/test_settle_serveability.sh — serve-ability-aware upgrade settle gate.
#
# Covers the multi-homed-box false-rollback fix (P3 of the channel-honest arc):
#   PART A: oxpulse-channels-health-report.sh --serveability emits parseable
#           chN=OK|DOWN lines for provisioned ch1/ch2/ch3 by REUSING the honest
#           end-to-end probe_ch1/ch2/ch3 (no POST, no peer-probe, no ch4).
#   PART B: upgrade.sh's _settle_serveability_adjudicate pure diff logic —
#           all-regressed -> LOST, some -> SERVING_PARTIAL, none -> SERVING_FULL,
#           no baseline serving -> INDETERMINATE. OR-quorum shape mirrors the
#           server oracle compute_health_signal_perchannel (health_poller.rs).
#   PART C: settle_healthcheck_with_retry SUPPRESSES a snapshot-regression
#           rollback when >=1 provisioned channel still serves, and STILL rolls
#           back when every serving channel went dark (real serve-ability loss)
#           or when no serve data is available (INDETERMINATE -> current behavior).
#
# Live-verified motivating case (edge-b, 2026-07): xray ТСПУ-blocked (canary
# 502) while AmneziaWG + Hysteria2 served real users at 200 via Caddy's
# multi-homed tunnel_upstream — the xray-only canary alone must NOT roll back.
#
# Plain bash, no bats (repo convention). Negation: `run; [ "$status" -ne 0 ]`.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
HEALTH_REPORT="$REPO_ROOT/oxpulse-channels-health-report.sh"
UPGRADE="$REPO_ROOT/upgrade.sh"

[[ -f "$HEALTH_REPORT" ]] || { echo "FAIL: $HEALTH_REPORT not found"; exit 1; }
[[ -f "$UPGRADE" ]]       || { echo "FAIL: $UPGRADE not found"; exit 1; }

PASS=0
FAIL=0
ok()  { echo "  PASS: $*"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

echo "test_settle_serveability.sh"
echo

# ── PATH stub: real coreutils + jq, a URL-branching curl stub ─────────────────
# The curl stub returns a controllable %{http_code} keyed on the dialled URL so
# a test can simulate "xray blocked, awg+hy2 serving" without any containers.
make_bin() {
    local dir="$1"
    local cmd loc
    for cmd in bash sh env date printf cat tee cp mv mkdir chmod install sleep \
                sed grep head tail wc stat cut tr expr test awk dirname realpath \
                hostname mktemp rm sort; do
        loc=$(command -v "$cmd" 2>/dev/null || true)
        [[ -n "$loc" ]] && ln -sf "$loc" "$dir/$cmd"
    done
    command -v jq >/dev/null 2>&1 && ln -sf "$(command -v jq)" "$dir/jq"
    # curl stub: last arg is the URL (curl -s -o /dev/null -w '%{http_code}' ... URL).
    cat > "$dir/curl" <<'STUB'
#!/bin/sh
url=""
for a in "$@"; do url="$a"; done
case "$url" in
    *canary/tunnel*)   printf '502' ;;   # ch1 xray — ТСПУ-blocked
    *10.9.0.2:8907*)   printf '200' ;;   # ch2 AmneziaWG — serving
    *127.0.0.1:18443*) printf '200' ;;   # ch3 Hysteria2 — serving
    *)                 printf '000' ;;
esac
exit 0
STUB
    chmod +x "$dir/curl"
}

write_node_config() {
    local dir="$1" channels="$2"
    printf '{"node_id":"test-node","channels":[%s]}\n' "$channels" > "$dir/node-config.json"
}

# ─────────────────────────────────────────────────────────────────────────────
# PART A — --serveability mode of oxpulse-channels-health-report.sh
# ─────────────────────────────────────────────────────────────────────────────
echo "PART A: --serveability mode"

TA=$(mktemp -d)
trap 'rm -rf "$TA"' EXIT
make_bin "$TA"
mkdir -p "$TA/etc"
write_node_config "$TA/etc" '{"id":"ch1"},{"id":"ch2"},{"id":"ch3"}'

set +e
OUT_A=$(PATH="$TA:/usr/bin:/bin" \
    _NODE_CONFIG="$TA/etc/node-config.json" \
    _TOKEN_LIB=/nonexistent \
    OXPULSE_SERVICE_TOKEN="stkn_test" \
    OXPULSE_CH1_CANARY_URL="http://127.0.0.1:9080/canary/tunnel" \
    OXPULSE_AWG_MOTHERLY_IP="10.9.0.2" \
    OXPULSE_BACKEND_PORT="8907" \
    OXPULSE_HY2_FALLBACK_PORT="18443" \
    bash "$HEALTH_REPORT" --serveability 2>/dev/null)
EXIT_A=$?
set -e

SERVE_A=$(printf '%s\n' "$OUT_A" | grep -E '^ch[0-9]+=(OK|DOWN)$' || true)

if [[ "$EXIT_A" -eq 0 ]]; then
    ok "A0: --serveability exits 0"
else
    bad "A0: --serveability exited $EXIT_A (expected 0); output: $OUT_A"
fi
if printf '%s\n' "$SERVE_A" | grep -qx 'ch1=DOWN'; then
    ok "A1: ch1 (xray canary 502) reported DOWN"
else
    bad "A1: expected 'ch1=DOWN'; got: $SERVE_A"
fi
if printf '%s\n' "$SERVE_A" | grep -qx 'ch2=OK'; then
    ok "A2: ch2 (awg 200) reported OK"
else
    bad "A2: expected 'ch2=OK'; got: $SERVE_A"
fi
if printf '%s\n' "$SERVE_A" | grep -qx 'ch3=OK'; then
    ok "A3: ch3 (hy2 200) reported OK"
else
    bad "A3: expected 'ch3=OK'; got: $SERVE_A"
fi
# Contract: pure chN=OK|DOWN lines (no JSON/POST noise, no ch4).
NOISE_A=$(printf '%s\n' "$OUT_A" | grep -vE '^ch[0-9]+=(OK|DOWN)$' | grep -vE '^$' || true)
if [[ -z "$NOISE_A" ]]; then
    ok "A4: stdout is pure chN=OK|DOWN lines (no JSON/POST noise, no ch4)"
else
    bad "A4: unexpected non-serveability stdout: $NOISE_A"
fi

rm -rf "$TA"
trap - EXIT

# ─────────────────────────────────────────────────────────────────────────────
# PART B — _settle_serveability_adjudicate pure diff logic (upgrade.sh)
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "PART B: _settle_serveability_adjudicate"

ADJ=$(mktemp)
awk '/^_settle_serveability_adjudicate\(\) \{/{f=1} f{print} /^\}$/ && f{exit}' "$UPGRADE" > "$ADJ"
if [[ -s "$ADJ" ]] && bash -n "$ADJ" 2>/dev/null; then
    ok "B0: extracted _settle_serveability_adjudicate parses (self-contained)"
else
    bad "B0: _settle_serveability_adjudicate missing/unparseable in upgrade.sh"
fi
# shellcheck disable=SC1090
source "$ADJ" 2>/dev/null || true

_adj() {
    local _bl _po
    _bl=$(mktemp); _po=$(mktemp)
    printf '%s\n' "$1" > "$_bl"
    printf '%s\n' "$2" > "$_po"
    declare -F _settle_serveability_adjudicate >/dev/null 2>&1 \
        && _settle_serveability_adjudicate "$_bl" "$_po" || printf 'NO_FN'
    rm -f "$_bl" "$_po"
}

# B1: every serving channel went dark -> LOST (real rollback).
V=$(_adj $'ch1=OK\nch2=OK\nch3=OK' $'ch1=DOWN\nch2=DOWN\nch3=DOWN')
if [[ "$V" == LOST* ]]; then ok "B1: all-regressed -> LOST ($V)"; else bad "B1: expected LOST*, got '$V'"; fi

# B2/edge-b: xray down, awg+hy2 serve -> SERVING_PARTIAL (suppress + warn).
V=$(_adj $'ch1=OK\nch2=OK\nch3=OK' $'ch1=DOWN\nch2=OK\nch3=OK')
if [[ "$V" == SERVING_PARTIAL* && "$V" == *ch1* ]]; then ok "B2: xray-only-down -> SERVING_PARTIAL regressed=ch1 ($V)"; else bad "B2: expected 'SERVING_PARTIAL ... ch1', got '$V'"; fi

# B3: nothing regressed -> SERVING_FULL.
V=$(_adj $'ch1=OK\nch2=OK' $'ch1=OK\nch2=OK')
if [[ "$V" == "SERVING_FULL" ]]; then ok "B3: none-regressed -> SERVING_FULL"; else bad "B3: expected SERVING_FULL, got '$V'"; fi

# B4: nothing served pre-upgrade -> INDETERMINATE (defer to base gate).
V=$(_adj $'ch1=DOWN\nch2=DOWN' $'ch1=DOWN\nch2=DOWN')
if [[ "$V" == "INDETERMINATE" ]]; then ok "B4: no-baseline-serving -> INDETERMINATE"; else bad "B4: expected INDETERMINATE, got '$V'"; fi

# B5: a channel already DOWN pre-upgrade is DRIFT, not a regression -> SERVING_FULL.
V=$(_adj $'ch1=DOWN\nch2=OK' $'ch1=DOWN\nch2=OK')
if [[ "$V" == "SERVING_FULL" ]]; then ok "B5: pre-existing-down = drift, not regression -> SERVING_FULL"; else bad "B5: expected SERVING_FULL (drift), got '$V'"; fi

# B6: single-homed xray box (only ch1) whose xray dies -> LOST (rollback preserved).
V=$(_adj $'ch1=OK' $'ch1=DOWN')
if [[ "$V" == LOST* ]]; then ok "B6: single-homed xray death -> LOST (rollback preserved) ($V)"; else bad "B6: expected LOST*, got '$V'"; fi

rm -f "$ADJ"

# ─────────────────────────────────────────────────────────────────────────────
# PART C — settle_healthcheck_with_retry serve-ability integration (end-to-end)
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "PART C: settle integration (suppress vs strict rollback)"

TC=$(mktemp -d)

_extract_fn() { awk -v fn="$1" '$0 ~ "^"fn"\\(\\) \\{"{f=1} f{print} /^\}$/ && f{exit}' "$UPGRADE"; }
PRE="$TC/preamble.sh"
{
    echo 'log(){ :; }'
    echo 'warn(){ :; }'
    _extract_fn settle_healthcheck_with_retry
    _extract_fn _settle_nonchannel_regression
    _extract_fn _settle_serveability_snapshot
    _extract_fn _settle_serveability_adjudicate
    _extract_fn _settle_serveability_alert
} > "$PRE"
if bash -n "$PRE" 2>/dev/null; then ok "C0: settle + all serve-ability helpers extract & parse together"; else bad "C0: preamble parse failed"; fi

# Parametric healthcheck stub: --snapshot emits whatever hc_post holds.
cat > "$TC/hc" <<STUB
#!/bin/sh
[ "\$1" = "--snapshot" ] && { cat "$TC/hc_post"; exit 0; }
exit 1
STUB
chmod +x "$TC/hc"

# Reporter stub (--serveability): emits whatever serve_post holds.
cat > "$TC/reporter" <<STUB
#!/bin/sh
cat "$TC/serve_post"
STUB
chmod +x "$TC/reporter"

# Runner: source the extracted settle + helpers, record tg_alert, run the gate.
cat > "$TC/run.sh" <<RUN
#!/usr/bin/env bash
source "$PRE"
tg_alert(){ printf '%s\n' "\$*" >> "$TC/alerts"; }
export HEALTHCHECK="$TC/hc"
export OXPULSE_UPGRADE_HEALTH_TIMEOUT=3
settle_healthcheck_with_retry "c-test" "$TC/hc_baseline" "\${SERVE_BASELINE:-}"
RUN

# _run_settle HC_BASELINE HC_POST SERVE_BASELINE SERVE_POST [REPORTER] -> echoes RC
_run_settle() {
    printf '%s\n' "$1" > "$TC/hc_baseline"
    printf '%s\n' "$2" > "$TC/hc_post"
    if [[ -n "$3" ]]; then printf '%s\n' "$3" > "$TC/serve_baseline"; else : > "$TC/serve_baseline"; fi
    printf '%s\n' "$4" > "$TC/serve_post"
    : > "$TC/alerts"
    local _reporter="${5:-$TC/reporter}"
    set +e
    CHANNELS_HEALTH_REPORT="$_reporter" SERVE_BASELINE="$TC/serve_baseline" bash "$TC/run.sh" >/dev/null 2>&1
    local _rc=$?
    set -e
    echo "$_rc"
}

# C1 — edge-b: xray canary (check_13, a channel check) regresses; honest probes
# show ch1 DOWN but ch2/ch3 OK → SUPPRESS rollback + WARNING alert.
RC=$(_run_settle 'check_13_canary_tunnel=GREEN' 'check_13_canary_tunnel=RED' \
    $'ch1=OK\nch2=OK\nch3=OK' $'ch1=DOWN\nch2=OK\nch3=OK')
if [[ "$RC" -eq 0 ]]; then ok "C1: channel-only regression + box still serves -> NO rollback (rc=0)"; else bad "C1: expected rc=0 (suppress), got $RC"; fi
if grep -q 'WARNING' "$TC/alerts" 2>/dev/null && grep -q 'ch1' "$TC/alerts" 2>/dev/null; then ok "C1: partial-degradation WARNING alert emitted for ch1"; else bad "C1: expected WARNING/ch1 alert; got: $(cat "$TC/alerts" 2>/dev/null)"; fi

# C2 — every serving channel went dark -> LOST -> real rollback.
RC=$(_run_settle 'check_13_canary_tunnel=GREEN' 'check_13_canary_tunnel=RED' \
    $'ch1=OK\nch2=OK' $'ch1=DOWN\nch2=DOWN')
if [[ "$RC" -eq 1 ]]; then ok "C2: all channels down (LOST) -> rollback (rc=1)"; else bad "C2: expected rc=1 (rollback), got $RC"; fi

# C3 — no serve baseline (empty $3) -> INDETERMINATE -> current rollback behavior.
RC=$(_run_settle 'check_13_canary_tunnel=GREEN' 'check_13_canary_tunnel=RED' \
    '' $'ch1=OK')
if [[ "$RC" -eq 1 ]]; then ok "C3: no serve-ability baseline -> INDETERMINATE -> rollback (current behavior)"; else bad "C3: expected rc=1, got $RC"; fi
if [[ ! -s "$TC/alerts" ]]; then ok "C3: no alert on INDETERMINATE"; else bad "C3: unexpected alert: $(cat "$TC/alerts")"; fi

# C4 — reporter absent -> snapshot capture fails -> INDETERMINATE -> rollback.
RC=$(_run_settle 'check_13_canary_tunnel=GREEN' 'check_13_canary_tunnel=RED' \
    $'ch1=OK\nch2=OK' $'ch1=OK\nch2=OK' "$TC/no-such-reporter")
if [[ "$RC" -eq 1 ]]; then ok "C4: reporter absent -> INDETERMINATE -> rollback (fail-safe)"; else bad "C4: expected rc=1, got $RC"; fi

# C5 — a NON-channel check (coturn secret) regresses while channels serve -> STRICT
# rollback (must NOT be masked by healthy channels).
RC=$(_run_settle 'check_08_coturn_secret=GREEN' 'check_08_coturn_secret=RED' \
    $'ch1=OK\nch2=OK\nch3=OK' $'ch1=OK\nch2=OK\nch3=OK')
if [[ "$RC" -eq 1 ]]; then ok "C5: non-channel (coturn) regression -> strict rollback despite healthy channels"; else bad "C5: expected rc=1 (strict), got $RC"; fi
if [[ ! -s "$TC/alerts" ]]; then ok "C5: no partial-degradation alert on a non-channel rollback"; else bad "C5: unexpected alert: $(cat "$TC/alerts")"; fi

# C6 — combined: a channel check AND a non-channel check regress; channels would be
# SERVING_PARTIAL, but the non-channel regression must still force a strict rollback
# (proves serve-ability suppression never masks a real non-channel breakage).
RC=$(_run_settle $'check_08_coturn_secret=GREEN\ncheck_13_canary_tunnel=GREEN' \
    $'check_08_coturn_secret=RED\ncheck_13_canary_tunnel=RED' \
    $'ch1=OK\nch2=OK\nch3=OK' $'ch1=DOWN\nch2=OK\nch3=OK')
if [[ "$RC" -eq 1 ]]; then ok "C6: combined channel+non-channel regression -> strict rollback (no masking)"; else bad "C6: expected rc=1 (strict), got $RC"; fi

# C7 — single-homed xray box: only ch1 provisioned, xray dies -> LOST -> rollback.
RC=$(_run_settle 'check_13_canary_tunnel=GREEN' 'check_13_canary_tunnel=RED' \
    $'ch1=OK' $'ch1=DOWN')
if [[ "$RC" -eq 1 ]]; then ok "C7: single-homed xray death -> rollback preserved"; else bad "C7: expected rc=1, got $RC"; fi

# C8 — the WARNING alert actually reaches a REAL tg_alert, not the C1-C7 runner's
# own stub (review-fix: `declare -F tg_alert || return 0` silently no-op'd on every
# real edge box because upgrade.sh never sourced telegram-alert-lib.sh into its own
# process; C1's `tg_alert(){ ... }` stub masked this — it passed in CI while prod
# dropped the alert). This runner intentionally defines NO tg_alert stub, points
# TELEGRAM_ALERT_LIB at the REAL lib/telegram-alert-lib.sh, and routes it at
# guaranteed-unreachable endpoints so tg_alert's own fail-soft path (no network,
# no token) writes an "undelivered" breadcrumb instead of silently vanishing —
# proving the full chain (lazy-source -> real tg_alert -> real message content)
# actually runs, independent of network reachability.
TG_STATE="$TC/tg-state"
cat > "$TC/run_real_tg.sh" <<RUN
#!/usr/bin/env bash
source "$PRE"
export HEALTHCHECK="$TC/hc"
export OXPULSE_UPGRADE_HEALTH_TIMEOUT=3
export TELEGRAM_ALERT_LIB="$REPO_ROOT/lib/telegram-alert-lib.sh"
export OXPULSE_TG_STATE_DIR="$TG_STATE"
export OXPULSE_TG_WEBHOOK="http://127.0.0.1:1/unreachable"
export OXPULSE_TG_API_FALLBACK="http://127.0.0.1:1/unreachable"
unset TG_TOKEN TG_CHAT OXPULSE_TG_CHAT
settle_healthcheck_with_retry "c-test" "$TC/hc_baseline" "\${SERVE_BASELINE:-}"
RUN
rm -rf "$TG_STATE"
printf '%s\n' 'check_13_canary_tunnel=GREEN' > "$TC/hc_baseline"
printf '%s\n' 'check_13_canary_tunnel=RED' > "$TC/hc_post"
printf '%s\n' $'ch1=OK\nch2=OK\nch3=OK' > "$TC/serve_baseline"
printf '%s\n' $'ch1=DOWN\nch2=OK\nch3=OK' > "$TC/serve_post"
set +e
CHANNELS_HEALTH_REPORT="$TC/reporter" SERVE_BASELINE="$TC/serve_baseline" bash "$TC/run_real_tg.sh" >/dev/null 2>&1
RC=$?
set -e
if [[ "$RC" -eq 0 ]]; then ok "C8: real-tg_alert runner also suppresses rollback (rc=0)"; else bad "C8: expected rc=0, got $RC"; fi
if [[ -s "$TG_STATE/undelivered.log" ]] && grep -q 'ch1' "$TG_STATE/undelivered.log" 2>/dev/null; then
    ok "C8: real tg_alert was lazy-sourced and actually invoked (undelivered breadcrumb has ch1)"
else
    bad "C8: real tg_alert never ran — lazy-source is broken; undelivered.log: $(cat "$TG_STATE/undelivered.log" 2>/dev/null || echo '<absent>')"
fi

rm -rf "$TC"

echo
echo "── summary: $PASS passed, $FAIL failed ──"
[[ "$FAIL" -eq 0 ]] || exit 1
