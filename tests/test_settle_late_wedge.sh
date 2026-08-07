#!/usr/bin/env bash
# tests/test_settle_late_wedge.sh — the upgrade gate must not declare success
# while a container it just recreated goes unhealthy afterwards (#522).
#
# Motivating case, measured converging the fleet onto v0.16.9 on 2026-07-30:
# upgrade.sh printed `upgraded to latest successfully` on rvpn and ruoxp and
# settle_healthcheck saw no regression. MINUTES LATER both nodes'
# oxpulse-partner-xray were unhealthy (FailingStreak 10 and 9) with
# `Connection reset by peer` on :3080 — a stale outbound from the compose
# recreate. While wedged, xray kept accepting and forwarding connections, so it
# looked alive from every angle except the end-to-end probe, and the control
# plane had already dropped rvpn-seed from the handout pool.
#
# Two load-bearing cases:
#   T5 — the FUNCTIONAL snapshot is clean and the gate must STILL fail because
#        a watched container went unhealthy after it passed.
#   T8 — the watch stays open long enough for that signal to be able to EXIST.
#        Docker writes `unhealthy` only after `retries` consecutive failures
#        following start_period, so a watch shorter than that can never fire
#        and reads as coverage while catching nothing.
#
# Plain bash, no bats (repo convention).
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
UPGRADE="$REPO_ROOT/upgrade.sh"
[[ -f "$UPGRADE" ]] || { echo "FAIL: $UPGRADE not found"; exit 1; }
PASS=0
FAIL=0
ok()  { echo "  PASS: $*"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
echo "test_settle_late_wedge.sh"
echo

TC=$(mktemp -d)
trap 'rm -rf "$TC"' EXIT

_extract_fn() { awk -v fn="$1" '$0 ~ "^"fn"\\(\\) \\{"{f=1} f{print} /^\}$/ && f{exit}' "$UPGRADE"; }

PRE="$TC/preamble.sh"
{
    echo 'log(){ printf "LOG: %s\n" "$*" >> "'"$TC"'/logs"; }'
    echo 'warn(){ printf "WARN: %s\n" "$*" >> "'"$TC"'/warns"; }'
    echo '_settle_emit_rollback_metric(){ printf "%s\n" "$1" >> "'"$TC"'/metrics"; }'
    _extract_fn settle_healthcheck_with_retry
    _extract_fn _settle_derive_recheck_window
    _extract_fn _settle_docker_health_watch
} > "$PRE"

if bash -n "$PRE" 2>/dev/null; then
    ok "T0: settle + late-wedge watch extract and parse together"
else
    bad "T0: preamble parse failed"
fi

# ── docker stub ─────────────────────────────────────────────────────────────
# `docker ps ... --format {{.Names}}`                -> $TC/names
# `docker inspect -f {{.State.Health.Status}} NAME`  -> $TC/health_NAME
# `docker inspect -f {{...Config.Healthcheck...}}`   -> $TC/hcfg_NAME
# An absent file means an absent HEALTHCHECK: the real docker emits a template
# ERROR there, not an empty field, and upgrade.sh discards it to empty.
mkdir -p "$TC/bin"
cat > "$TC/bin/docker" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "ps" ]; then cat "$TC/names" 2>/dev/null; exit 0; fi
if [ "\$1" = "inspect" ]; then
  _n="\${!#}"
  case "\$*" in
    *Config.Healthcheck*) [ -f "$TC/hcfg_\$_n" ]   && cat "$TC/hcfg_\$_n";   exit 0 ;;
    *)                    [ -f "$TC/health_\$_n" ] && cat "$TC/health_\$_n"; exit 0 ;;
  esac
fi
exit 0
STUB
chmod +x "$TC/bin/docker"
export PATH="$TC/bin:$PATH"

_reset() { : > "$TC/warns"; : > "$TC/metrics"; : > "$TC/logs"; rm -f "$TC"/health_* "$TC"/hcfg_*; }

# _watch -> echoes rc of _settle_docker_health_watch
_watch() {
    bash -c "source '$PRE'
             export OXPULSE_UPGRADE_SETTLE_RECHECK_SECS='${WINDOW:-2}'
             export OXPULSE_UPGRADE_SETTLE_RECHECK_INTERVAL=1
             _settle_docker_health_watch t; echo rc=\$?" 2>/dev/null | sed -n 's/^rc=//p'
}

# ── T1 — a watched container goes unhealthy -> the watch FAILS ───────────────
_reset
printf 'oxpulse-partner-xray\noxpulse-partner-caddy\n' > "$TC/names"
printf 'unhealthy\n' > "$TC/health_oxpulse-partner-xray"
printf 'healthy\n'   > "$TC/health_oxpulse-partner-caddy"
rc=$(_watch)
[[ "$rc" != "0" ]] && ok "T1: unhealthy container -> watch fails (rc=$rc)" \
                   || bad "T1: unhealthy container did NOT fail the watch"

# ── T2 — everything healthy -> passes ───────────────────────────────────────
_reset
printf 'oxpulse-partner-xray\n' > "$TC/names"
printf 'healthy\n' > "$TC/health_oxpulse-partner-xray"
rc=$(_watch)
[[ "$rc" == "0" ]] && ok "T2: all healthy -> watch passes" \
                   || bad "T2: all-healthy wrongly failed (rc=$rc)"

# ── T3 — container declares NO healthcheck -> SKIPPED, never failed ─────────
# This is the objection that kept a docker-health gate off the critical path.
_reset
printf 'oxpulse-partner-awg\n' > "$TC/names"
# no health_ file at all => docker inspect emits nothing
rc=$(_watch)
[[ "$rc" == "0" ]] && ok "T3: container without a HEALTHCHECK is skipped, not failed" \
                   || bad "T3: absent HEALTHCHECK wrongly failed the watch (rc=$rc)"

# ── T4 — window=0 disables the watch ───────────────────────────────────────
_reset
printf 'oxpulse-partner-xray\n' > "$TC/names"
printf 'unhealthy\n' > "$TC/health_oxpulse-partner-xray"
rc=$(WINDOW=0 _watch)
[[ "$rc" == "0" ]] && ok "T4: OXPULSE_UPGRADE_SETTLE_RECHECK_SECS=0 disables the watch" \
                   || bad "T4: window=0 did not disable the watch (rc=$rc)"

# ── T5 — THE REGRESSION: functional snapshot CLEAN, container unhealthy ─────
# The exact 2026-07-30 shape. Before this change the gate returned 0 here.
_reset
cat > "$TC/hc" <<'HCSTUB'
#!/bin/sh
[ "$1" = "--snapshot" ] && { cat "$HC_POST"; exit 0; }
exit 1
HCSTUB
chmod +x "$TC/hc"
printf 'check_01=GREEN\ncheck_02=GREEN\n' > "$TC/hc_baseline"
printf 'check_01=GREEN\ncheck_02=GREEN\n' > "$TC/hc_post"
printf 'oxpulse-partner-xray\n' > "$TC/names"
printf 'unhealthy\n' > "$TC/health_oxpulse-partner-xray"

rc=$(bash -c "source '$PRE'
    export HEALTHCHECK='$TC/hc'
    export HC_POST='$TC/hc_post'
    export OXPULSE_UPGRADE_HEALTH_TIMEOUT=3
    export OXPULSE_UPGRADE_SETTLE_RECHECK_SECS=2
    export OXPULSE_UPGRADE_SETTLE_RECHECK_INTERVAL=1
    settle_healthcheck_with_retry late-wedge '$TC/hc_baseline' ''; echo rc=\$?" 2>/dev/null \
    | sed -n 's/^rc=//p')
[[ "$rc" != "0" ]] && ok "T5: clean functional snapshot + unhealthy container -> gate FAILS (rc=$rc)" \
                   || bad "T5: gate declared SUCCESS over a late wedge — this is #522 (rc=$rc)"

# T5b asserts the OPERATOR-VISIBLE signal, not the metric. _settle_emit_rollback_metric
# is defined INSIDE settle_healthcheck_with_retry (upgrade.sh:1694), so it shadows any
# top-level stub, and its real body is a no-op unless _reconcile_emit_prom_gauge exists.
# Asserting on it would be testing the stub rather than the code.
if grep -q 'LATE WEDGE' "$TC/warns" 2>/dev/null; then
    ok "T5b: the upgrade log carries a LATE WEDGE warning naming the container"
else
    bad "T5b: no LATE WEDGE warning — an operator would see a silent rollback"
fi

# ── T6 — the declare -F guard keeps the isolation harness behaviour ─────────
# A preamble WITHOUT the helper must still return 0 on a clean snapshot.
PRE2="$TC/preamble_noguard.sh"
{
    echo 'log(){ :; }'
    echo 'warn(){ :; }'
    echo '_settle_emit_rollback_metric(){ :; }'
    _extract_fn settle_healthcheck_with_retry
} > "$PRE2"
rc=$(bash -c "source '$PRE2'
    export HEALTHCHECK='$TC/hc'
    export HC_POST='$TC/hc_post'
    export OXPULSE_UPGRADE_HEALTH_TIMEOUT=3
    settle_healthcheck_with_retry noguard '$TC/hc_baseline' ''; echo rc=\$?" 2>/dev/null \
    | sed -n 's/^rc=//p')
[[ "$rc" == "0" ]] && ok "T6: without the helper the guard is a no-op (isolation harness unchanged)" \
                   || bad "T6: guard changed behaviour when the helper is absent (rc=$rc)"

# ── T7 — the detection budget must outlast TIME-TO-UNHEALTHY (arithmetic) ───
# Measured on rvpn 2026-08-07: oxpulse-partner-xray declares
#   start_period=30s  interval=30s  retries=3  timeout=10s
# Docker cannot write `unhealthy` before start_period + retries*interval = 120s.
# A budget shorter than that closes before the signal can exist.
_reset
printf 'oxpulse-partner-xray\n' > "$TC/names"
printf '30 30 10 3\n' > "$TC/hcfg_oxpulse-partner-xray"
w=$(bash -c "source '$PRE'; _settle_derive_recheck_window \"\$(cat '$TC/names')\"" 2>/dev/null)
if [[ "${w:-0}" =~ ^[0-9]+$ ]] && [[ "$w" -ge 130 ]]; then
    ok "T7: budget derived from the container's own healthcheck config (${w}s >= 130s)"
else
    bad "T7: derived budget ${w:-?}s cannot outlast time-to-unhealthy (30+3*30+10=130s) — the watch would close before the signal exists"
fi

# ── T7b — a container with no HEALTHCHECK still yields the floor, not 0 ─────
# An old docker whose inspect template lacks these fields must degrade to the
# previous fixed behaviour, never to a disabled watch.
_reset
printf 'oxpulse-partner-awg\n' > "$TC/names"
w=$(bash -c "source '$PRE'; _settle_derive_recheck_window \"\$(cat '$TC/names')\"" 2>/dev/null)
[[ "${w:-0}" -ge 60 ]] && ok "T7b: no derivable config -> floor (${w}s), watch never silently disabled" \
                       || bad "T7b: undeclared healthcheck collapsed the budget to ${w:-?}s"

# ── T8 — the WATCH uses the derived budget (the call site, not the helper) ──
# Run with the container already unhealthy so the watch returns on the first
# poll and the test does not actually sleep the derived window.
_reset
printf 'oxpulse-partner-xray\n' > "$TC/names"
printf '30 30 10 3\n' > "$TC/hcfg_oxpulse-partner-xray"
printf 'unhealthy\n'  > "$TC/health_oxpulse-partner-xray"
bash -c "source '$PRE'
    unset OXPULSE_UPGRADE_SETTLE_RECHECK_SECS
    export OXPULSE_UPGRADE_SETTLE_RECHECK_INTERVAL=1
    _settle_docker_health_watch t" >/dev/null 2>&1 || true
# First match only, without piping into a truncating reader: under
# `set -o pipefail` such a reader exits early, SIGPIPEs its producer and can
# mask a failure, which the repo's pipefail guard rejects. `q` after the first
# substitution does the same job inside sed.
logged=$(sed -n '/late-wedge watch for/{s/.*late-wedge watch for \([0-9]*\)s.*/\1/p;q;}' "$TC/logs" 2>/dev/null)
if [[ "${logged:-0}" =~ ^[0-9]+$ ]] && [[ "$logged" -ge 130 ]]; then
    ok "T8: the watch opens for the DERIVED budget (${logged}s), not a fixed default"
else
    bad "T8: watch opened for ${logged:-?}s — it is not using the derived budget, so it closes before docker can report unhealthy"
fi

# ── T9 — an explicit override still wins (the escape hatch stays real) ─────
_reset
printf 'oxpulse-partner-xray\n' > "$TC/names"
printf '30 30 10 3\n' > "$TC/hcfg_oxpulse-partner-xray"
printf 'unhealthy\n'  > "$TC/health_oxpulse-partner-xray"
rc=$(WINDOW=7 _watch)
# First match only, without piping into a truncating reader: under
# `set -o pipefail` such a reader exits early, SIGPIPEs its producer and can
# mask a failure, which the repo's pipefail guard rejects. `q` after the first
# substitution does the same job inside sed.
logged=$(sed -n '/late-wedge watch for/{s/.*late-wedge watch for \([0-9]*\)s.*/\1/p;q;}' "$TC/logs" 2>/dev/null)
[[ "$logged" == "7" ]] && ok "T9: OXPULSE_UPGRADE_SETTLE_RECHECK_SECS overrides the derivation (${logged}s)" \
                       || bad "T9: explicit override ignored — logged ${logged:-?}s instead of 7s"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
