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
# The load-bearing test is T5: the FUNCTIONAL snapshot is clean and the gate
# must STILL fail because a watched container went unhealthy after it passed.
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
    echo 'log(){ :; }'
    echo 'warn(){ printf "WARN: %s\n" "$*" >> "'"$TC"'/warns"; }'
    echo '_settle_emit_rollback_metric(){ printf "%s\n" "$1" >> "'"$TC"'/metrics"; }'
    _extract_fn settle_healthcheck_with_retry
    _extract_fn _settle_docker_health_watch
} > "$PRE"

if bash -n "$PRE" 2>/dev/null; then
    ok "T0: settle + late-wedge watch extract and parse together"
else
    bad "T0: preamble parse failed"
fi

# ── docker stub ─────────────────────────────────────────────────────────────
# `docker ps ... --format {{.Names}}`      -> $TC/names
# `docker inspect -f {{.State.Health.Status}} NAME` -> $TC/health_NAME (empty if absent)
mkdir -p "$TC/bin"
cat > "$TC/bin/docker" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "ps" ]; then cat "$TC/names" 2>/dev/null; exit 0; fi
if [ "\$1" = "inspect" ]; then
  _n="\${!#}"
  [ -f "$TC/health_\$_n" ] && cat "$TC/health_\$_n"
  exit 0
fi
exit 0
STUB
chmod +x "$TC/bin/docker"
export PATH="$TC/bin:$PATH"

_reset() { : > "$TC/warns"; : > "$TC/metrics"; rm -f "$TC"/health_*; }

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

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
