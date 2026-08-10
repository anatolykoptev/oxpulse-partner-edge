#!/bin/bash
# tests/test_selfheal.sh — coverage for oxpulse-partner-edge-selfheal.sh.
#
# Every case below is one whose failure would be SILENT in production:
#
#   containers
#     1. unhealthy + budget available  → restarts        (without this the script
#        is decoration and the 26h cheburator outage repeats)
#     2. attempts at MAX               → does NOT restart, raises given_up, alerts
#        ONCE (this is the failingstreak=19471 case from FOLLOWUPS.md — an
#        unbounded healer would restart such a box forever and call it healthy
#        maintenance; this bound is the reason the compose template refused a
#        restart loop in the first place)
#     3. inside start grace            → does NOT restart (otherwise a slow-
#        starting container is killed on every tick and never finishes starting)
#     4. no healthcheck                → never touched   (`naive` ships without
#        one on purpose; acting without evidence is the thing being avoided)
#     5. healthy                       → does nothing
#     6. pending attempt now healthy   → counts `healed`, clears pending
#     7. MIN_GAP not elapsed           → does NOT restart
#     8. a FOREIGN container carrying our compose project label is never touched
#        (measured: rvpn's `all-rvpn-gate` belongs to a neighbouring project and
#        has com.docker.compose.project=oxpulse-partner-edge)
#     9. stopped                       → started
#    10. stopped `compose run` one-off → never started
#    11. stopped seconds ago           → left alone (docker's own restart policy
#        and a debugging operator both need that window)
#
#   the operator escape hatch
#    12. global hold file              → nothing is touched at all
#    13. per-subject hold file         → that subject only
#
#   systemd
#    14. a failed oxpulse unit         → restarted, and recorded healed
#    15. the healer's OWN service      → never restarted by itself
#    16. a unit in the declared enable-set that is disabled → enabled
#    17. a unit NOT in the set         → never enabled (ru-subnets is disabled on
#        4 of 4 live nodes BY DESIGN; a healer keyed on "every oxpulse timer"
#        would switch on a deliberately-off feature fleet-wide)
#    18. the healer's OWN timer is absent from its enable-set (disabling that
#        timer is how an operator stops this script; a healer that re-enables
#        itself cannot be switched off)
#    19. per-tick action cap honoured
#
#   disk
#    20. below threshold               → never prunes
#    21. at threshold                  → prunes, verifies, records healed
#
#   metrics
#    22. EVERY container gets a series in the gauge file, not just the last one
#        (shipped-and-measured regression: a gauge textfile is truncated per
#        write, so five per-container writes left one surviving sample)
#
# `docker`, `systemctl`, `df` and `timeout` are PATH shims driven by fixture
# files, so no daemon, no init system and no real disk are needed.
set -uo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SCRIPT="$REPO_ROOT/oxpulse-partner-edge-selfheal.sh"
[[ -f "$SCRIPT" ]] || { echo "FAIL: $SCRIPT not found"; exit 1; }

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# Build a sandbox. FIXTURES holds one file per container:
#   "<health> <started> <has_health> <state> <finished> <oneoff>"
setup() {
	TMP="$(mktemp -d)"; BIN="$TMP/bin"
	mkdir -p "$BIN" "$TMP/state" "$TMP/fixtures" "$TMP/units" "$TMP/textfile"

	cat > "$BIN/docker" <<'DOCKER'
#!/bin/bash
FX="$FIXTURES"
read_fx() {   # container -> sets health started hashc state finished oneoff
	local f="$FX/$1"
	[[ -r "$f" ]] || return 1
	read -r health started hashc state finished oneoff < "$f"
	state="${state:-running}"; finished="${finished:-0}"; oneoff="${oneoff:-False}"
	return 0
}
case "$1" in
  ps)
    shift
    all=0; for a in "$@"; do [[ "$a" == "-a" ]] && all=1; done
    for f in "$FX"/*; do
      [[ -e "$f" ]] || continue
      n="$(basename "$f")"; read_fx "$n" || continue
      [[ $all == 1 || "$state" == running ]] && echo "$n"
    done ;;
  inspect)
    fmt="$3"; c="$4"; read_fx "$c" || exit 1
    case "$fmt" in
      *State.Health.Status*)  echo "$health" ;;
      *if\ .State.Health*)    [[ "$hashc" == y ]] && echo y ;;
      *State.StartedAt*)      date -d "@$started" -Is ;;
      *State.FinishedAt*)     date -d "@$finished" -Is ;;
      *compose.oneoff*)       echo "$oneoff" ;;
    esac ;;
  restart) echo "$2" >> "$RESTART_LOG"; exit "${DOCKER_RESTART_RC:-0}" ;;
  start)
    echo "$2" >> "$START_LOG"
    [[ "${DOCKER_START_RC:-0}" == 0 ]] || exit "${DOCKER_START_RC}"
    # A successful start makes it running, exactly as the daemon would.
    read_fx "$2" && echo "$health $started $hashc running $finished $oneoff" > "$FX/$2"
    ;;
  image|builder)
    echo "$1 $2" >> "$PRUNE_LOG"
    # A prune reclaims space; the fixture disk drops to the post-prune value.
    [[ -n "${FAKE_DISK_AFTER:-}" ]] && echo "$FAKE_DISK_AFTER" > "$TMPDIR_DISK"
    ;;
esac
exit 0
DOCKER

	cat > "$BIN/systemctl" <<'SYSTEMCTL'
#!/bin/bash
U="$FX_UNITS"
failed_file="$U/failed"
case "$1" in
  list-units)
    [[ -r "$failed_file" ]] || exit 0
    while read -r u; do [[ -n "$u" ]] && echo "$u loaded failed failed Some unit"; done < "$failed_file" ;;
  is-failed)
    for a in "$@"; do :; done
    unit="${!#}"
    grep -qxF "$unit" "$failed_file" 2>/dev/null && exit 0 || exit 1 ;;
  is-enabled)
    unit="${!#}"
    if [[ -r "$U/enabled.$unit" ]]; then cat "$U/enabled.$unit"; else echo enabled; fi ;;
  restart)
    unit="${!#}"; echo "restart $unit" >> "$UNIT_LOG"
    if grep -qxF "$unit" "$U/heals" 2>/dev/null; then
        grep -vxF "$unit" "$failed_file" > "$failed_file.t" 2>/dev/null; mv -f "$failed_file.t" "$failed_file"
    fi ;;
  enable)
    unit="${!#}"; echo "enable $unit" >> "$UNIT_LOG"
    grep -qxF "$unit" "$U/heals" 2>/dev/null && echo enabled > "$U/enabled.$unit" ;;
esac
exit 0
SYSTEMCTL

	# `timeout N cmd ...` — run cmd, ignore the bound. Keeps the suite identical
	# on a box whose coreutils has no `timeout` (macOS) and in CI.
	cat > "$BIN/timeout" <<'TIMEOUT'
#!/bin/bash
shift
exec "$@"
TIMEOUT

	cat > "$BIN/df" <<'DF'
#!/bin/bash
pct="$(cat "$TMPDIR_DISK" 2>/dev/null || echo 10)"
echo "Filesystem 1024-blocks Used Available Capacity Mounted"
echo "/dev/fake 100 ${pct} 10 ${pct}% /var/lib/docker"
DF

	chmod +x "$BIN/docker" "$BIN/systemctl" "$BIN/timeout" "$BIN/df"

	# tg_alert stand-in: the script sources a lib if present; here we prove the
	# alert path fires by shipping a lib that records the call.
	cat > "$TMP/telegram-alert-lib.sh" <<'TG'
tg_alert() { echo "$1" >> "$ALERT_LOG"; }
TG
	# The REAL metric sink, so the gauge assertions exercise the shipped writer.
	cp "$REPO_ROOT/lib/metric-sink-lib.sh" "$TMP/metric-sink-lib.sh"

	export FIXTURES="$TMP/fixtures" FX_UNITS="$TMP/units"
	export RESTART_LOG="$TMP/restarts" START_LOG="$TMP/starts"
	export ALERT_LOG="$TMP/alerts" UNIT_LOG="$TMP/units.log" PRUNE_LOG="$TMP/prunes"
	export TMPDIR_DISK="$TMP/diskpct"
	: > "$RESTART_LOG"; : > "$START_LOG"; : > "$ALERT_LOG"
	: > "$UNIT_LOG"; : > "$PRUNE_LOG"; : > "$FX_UNITS/failed"; : > "$FX_UNITS/heals"
	echo 10 > "$TMPDIR_DISK"
	export PATH="$BIN:$PATH"
	export OXPULSE_SELFHEAL_STATE_DIR="$TMP/state"
	export OXPULSE_SELFHEAL_LOCK="$TMP/lock"
	export OXPULSE_SELFHEAL_UPGRADE_LOCK="$TMP/nonexistent-upgrade.lock"
	export OXPULSE_SELFHEAL_HOLD="$TMP/selfheal.hold"
	export INSTALL_LIB_DIR="$TMP"
	export PARTNER_EDGE_TEXTFILE_DIR="$TMP/textfile"
	unset OXPULSE_SELFHEAL_DRY_RUN FAKE_DISK_AFTER DOCKER_START_RC DOCKER_RESTART_RC
}
teardown() { rm -rf "$TMP"; }

# name health started [hashc] [state] [finished] [oneoff]
fixture() { echo "$2 $3 ${4:-y} ${5:-running} ${6:-0} ${7:-False}" > "$FIXTURES/$1"; }
run_it()   { bash "$SCRIPT" >"$TMP/out" 2>&1; }
restarts() { wc -l < "$RESTART_LOG" | tr -d ' '; }
starts()   { wc -l < "$START_LOG"   | tr -d ' '; }
alerts()   { wc -l < "$ALERT_LOG"   | tr -d ' '; }
prunes()   { wc -l < "$PRUNE_LOG"   | tr -d ' '; }
state()    { awk -F= -v k="$2" '$1==k{print $2}' "$OXPULSE_SELFHEAL_STATE_DIR/${1//[^A-Za-z0-9._@-]/_}.state" 2>/dev/null; }
OLD=$(( $(date +%s) - 9999 ))

echo ""
echo "=== oxpulse-partner-edge-selfheal.sh ==="

# 1 — the healing case
setup; fixture oxpulse-partner-c1 unhealthy "$OLD"; run_it
[[ "$(restarts)" == 1 ]] && pass "unhealthy container is restarted" \
                         || fail "unhealthy container NOT restarted (got $(restarts))"
teardown

# 2 — the bound: this is the one that matters
setup; fixture oxpulse-partner-c1 unhealthy "$OLD"
mkdir -p "$OXPULSE_SELFHEAL_STATE_DIR"
printf 'win_start=%s\nattempts=3\nlast_attempt=%s\npending_since=0\n' \
  "$(( $(date +%s) - 100 ))" "$(( $(date +%s) - 999 ))" > "$OXPULSE_SELFHEAL_STATE_DIR/oxpulse-partner-c1.state"
run_it
r=$(restarts); a=$(alerts); g=$(state oxpulse-partner-c1 gave_up)
[[ "$r" == 0 ]] && pass "budget exhausted → NO fourth restart" || fail "restarted despite exhausted budget ($r)"
[[ "$a" == 1 ]] && pass "budget exhausted → alerts exactly once" || fail "alert count $a, expected 1"
[[ "$g" == 1 ]] && pass "budget exhausted → gave_up recorded" || fail "gave_up=$g, expected 1"
run_it
[[ "$(alerts)" == 1 ]] && pass "give-up alert is not repeated every tick" || fail "re-alerted: $(alerts)"
teardown

# 3 — start grace
setup; fixture oxpulse-partner-c1 unhealthy "$(( $(date +%s) - 5 ))"; run_it
[[ "$(restarts)" == 0 ]] && pass "inside start grace → not restarted" || fail "restarted a just-started container"
teardown

# 4 — no healthcheck is never touched
setup; fixture oxpulse-partner-c1 unhealthy "$OLD" n; run_it
[[ "$(restarts)" == 0 ]] && pass "container without a healthcheck is never touched" || fail "touched a container with no healthcheck"
teardown

# 5 — healthy is left alone
setup; fixture oxpulse-partner-c1 healthy "$OLD"; run_it
[[ "$(restarts)" == 0 ]] && pass "healthy container is left alone" || fail "restarted a healthy container"
teardown

# 6 — a pending attempt that came back healthy is counted as healed
setup; fixture oxpulse-partner-c1 healthy "$OLD"
mkdir -p "$OXPULSE_SELFHEAL_STATE_DIR"
printf 'pending_since=%s\nattempts=1\nwin_start=%s\n' "$(( $(date +%s) - 60 ))" "$(( $(date +%s) - 60 ))" \
  > "$OXPULSE_SELFHEAL_STATE_DIR/oxpulse-partner-c1.state"
run_it
[[ "$(state oxpulse-partner-c1 pending_since)" == 0 ]] && pass "verified heal clears the pending marker" \
                                                       || fail "pending marker not cleared"
teardown

# 7 — MIN_GAP
setup; fixture oxpulse-partner-c1 unhealthy "$OLD"
mkdir -p "$OXPULSE_SELFHEAL_STATE_DIR"
printf 'win_start=%s\nattempts=1\nlast_attempt=%s\npending_since=0\n' \
  "$(( $(date +%s) - 100 ))" "$(( $(date +%s) - 10 ))" > "$OXPULSE_SELFHEAL_STATE_DIR/oxpulse-partner-c1.state"
run_it
[[ "$(restarts)" == 0 ]] && pass "MIN_GAP not elapsed → not restarted" || fail "restarted inside MIN_GAP"
teardown

# 8 — a foreign container carrying our project label
setup; fixture all-rvpn-gate unhealthy "$OLD"; run_it
[[ "$(restarts)" == 0 ]] && pass "foreign container sharing our project label is never touched" \
                         || fail "restarted a container belonging to another project"
teardown

# 9 — stopped is started
setup; fixture oxpulse-partner-c1 none "$OLD" y exited "$OLD"; run_it
[[ "$(starts)" == 1 ]] && pass "stopped container is started" || fail "stopped container NOT started (got $(starts))"
teardown

# 10 — a compose one-off is never started
setup; fixture oxpulse-partner-c1 none "$OLD" y exited "$OLD" True; run_it
[[ "$(starts)" == 0 ]] && pass "compose one-off container is never started" || fail "started a compose one-off"
teardown

# 11 — stopped moments ago
setup; fixture oxpulse-partner-c1 none "$OLD" y exited "$(( $(date +%s) - 5 ))"; run_it
[[ "$(starts)" == 0 ]] && pass "just-stopped container is left alone" || fail "raced docker's restart policy"
teardown

# 12 — the global hold file stops everything
setup
fixture oxpulse-partner-c1 unhealthy "$OLD"
fixture oxpulse-partner-c2 none "$OLD" y exited "$OLD"
echo oxpulse-geoip-refresh.service > "$FX_UNITS/failed"
echo 99 > "$TMPDIR_DISK"
touch "$OXPULSE_SELFHEAL_HOLD"
run_it
tot=$(( $(restarts) + $(starts) + $(prunes) ))
[[ "$tot" == 0 && ! -s "$UNIT_LOG" ]] && pass "global hold file → no action of any kind" \
                                      || fail "acted despite the hold file (docker=$tot units=$(wc -l <"$UNIT_LOG"))"
# The early exit is a SECOND layer over the per-subject checks, and without its
# own assertion it is untested: every healer independently honours the global
# hold, so deleting the early exit changes no action and the case above stays
# green. What it uniquely buys is that a held node stops inspecting anything at
# all — a new healer added later that forgets its own _held call is covered by
# this and nothing else.
grep -q "taking no action" "$TMP/out" && pass "global hold exits BEFORE inspecting anything" \
                                      || fail "hold honoured only per-subject — a healer that forgets _held would act"
grep -q '^partner_edge_selfheal_hold 1$' "$PARTNER_EDGE_TEXTFILE_DIR/partner_edge_selfheal_hold.prom" 2>/dev/null \
	&& pass "a held node is VISIBLE as held in metrics" \
	|| fail "a held node is indistinguishable from a healthy one in metrics"
teardown

# 13 — a per-subject hold file stops exactly one subject
setup
fixture oxpulse-partner-c1 unhealthy "$OLD"
fixture oxpulse-partner-c2 unhealthy "$OLD"
touch "${OXPULSE_SELFHEAL_HOLD}.oxpulse-partner-c1"
run_it
[[ "$(restarts)" == 1 ]] && grep -qxF oxpulse-partner-c2 "$RESTART_LOG" \
	&& pass "per-subject hold file holds exactly that subject" \
	|| fail "per-subject hold wrong: restarted [$(tr '\n' ' ' <"$RESTART_LOG")]"
teardown

# 14 — a failed oxpulse unit is restarted and recorded healed
setup
echo oxpulse-geoip-refresh.service > "$FX_UNITS/failed"
echo oxpulse-geoip-refresh.service > "$FX_UNITS/heals"
run_it
grep -q "restart oxpulse-geoip-refresh.service" "$UNIT_LOG" \
	&& pass "a failed oxpulse unit is restarted" || fail "failed unit NOT restarted"
grep -q "oxpulse-geoip-refresh.service: recovered" "$TMP/out" \
	&& pass "a unit that comes back is recorded as healed" || fail "recovery not recorded"
teardown

# 15 — never restart itself
setup
printf 'oxpulse-partner-edge-selfheal.service\n' > "$FX_UNITS/failed"
run_it
[[ ! -s "$UNIT_LOG" ]] && pass "the healer never restarts its own service" \
                       || fail "restarted itself: $(cat "$UNIT_LOG")"
teardown

# 16 — enable-set drift is repaired
setup
echo disabled > "$FX_UNITS/enabled.oxpulse-xray-update.timer"
echo oxpulse-xray-update.timer > "$FX_UNITS/heals"
run_it
grep -q "enable oxpulse-xray-update.timer" "$UNIT_LOG" \
	&& pass "a declared unit found disabled is enabled" || fail "enable drift NOT repaired"
teardown

# 17 — a unit outside the declared set is never enabled
setup
echo disabled > "$FX_UNITS/enabled.oxpulse-partner-edge-ru-subnets-update.timer"
run_it
grep -q "ru-subnets" "$UNIT_LOG" \
	&& fail "enabled a unit that is deliberately disabled fleet-wide" \
	|| pass "a unit outside the declared enable-set is never enabled"
teardown

# 18 — the healer's own timer must not be in its enable-set
if grep -qE '^\s*oxpulse-partner-edge-selfheal\.timer\s*$' \
     <(awk '/^ENABLE_UNITS=\(/{f=1;next} f&&/^\)/{exit} f' "$SCRIPT"); then
	fail "the healer's own timer is in its enable-set — it would re-enable itself when switched off"
else
	pass "the healer's own timer is absent from its enable-set"
fi

# 19 — the per-tick action cap
setup
printf 'oxpulse-a.service\noxpulse-b.service\noxpulse-c.service\n' > "$FX_UNITS/failed"
export OXPULSE_SELFHEAL_ACTS_PER_TICK=2
run_it
n=$(grep -c '^restart ' "$UNIT_LOG")
[[ "$n" == 2 ]] && pass "per-tick action cap honoured ($n of 3 failed units)" \
               || fail "action cap ignored: $n actions, expected 2"
unset OXPULSE_SELFHEAL_ACTS_PER_TICK
teardown

# 20 — a disk below the threshold is never pruned
setup; echo 50 > "$TMPDIR_DISK"; run_it
[[ "$(prunes)" == 0 ]] && pass "disk below threshold → never pruned" || fail "pruned a disk that was fine"
teardown

# 21 — a disk at the threshold is reclaimed
setup; echo 92 > "$TMPDIR_DISK"; export FAKE_DISK_AFTER=40; run_it
[[ "$(prunes)" -ge 1 ]] && pass "disk over threshold → reclaimed" || fail "disk over threshold NOT reclaimed"
grep -q "disk reclaimed to 40%" "$TMP/out" && pass "reclaim is VERIFIED, not assumed" \
                                           || fail "reclaim outcome not verified"
teardown

# 23 — a prune that does NOT help is recorded as a failure, never as a heal.
# This is the assertion that keeps the disk healer honest: without it the script
# could report success on every run while the disk stayed full, and the give-up
# alert — the only thing that reaches a human before the node wedges — would
# never fire.
setup; echo 92 > "$TMPDIR_DISK"; export FAKE_DISK_AFTER=95; run_it
grep -q "disk still at 95% after reclaim" "$TMP/out" \
	&& pass "a prune that frees nothing is recorded as failed" \
	|| fail "an ineffective prune was not reported as such"
grep -q "disk reclaimed" "$TMP/out" \
	&& fail "claimed a heal while the disk was still over threshold" \
	|| pass "never claims a heal it cannot verify"
unset FAKE_DISK_AFTER
teardown

# 22 — every container gets a series, not just the last one
setup
fixture oxpulse-partner-aaa healthy "$OLD"
fixture oxpulse-partner-mmm unhealthy "$OLD"
fixture oxpulse-partner-zzz healthy "$OLD"
run_it
prom="$PARTNER_EDGE_TEXTFILE_DIR/partner_edge_container_unhealthy.prom"
n=$(grep -c '^partner_edge_container_unhealthy{' "$prom" 2>/dev/null || echo 0)
types=$(grep -c '^# TYPE' "$prom" 2>/dev/null || echo 0)
[[ "$n" == 3 ]] && pass "every container has a gauge series ($n of 3)" \
               || fail "only $n of 3 container series survived the gauge write"
[[ "$types" == 1 ]] && pass "exactly one # TYPE line" || fail "$types TYPE lines — node_exporter drops the file"
grep -q '^partner_edge_container_unhealthy{container="oxpulse-partner-mmm"} 1$' "$prom" \
	&& pass "the unhealthy container reports 1" || fail "unhealthy container's sample is wrong"
teardown

# 24 — a CRASHLOOPING long-running service is bounded and escalates.
#
# The subtle one. `systemctl restart` on a long-running service returns as soon
# as it STARTS, so `is-failed` immediately after is false even for a unit that
# dies three seconds later. If success on that reading cleared the budget, a
# crashlooper would get a fresh budget every tick: one restart per UNIT_GAP
# forever, no given_up, no alert, and nothing in any metric to tell it apart
# from a healthy node — the unbounded healer this whole file exists to prevent.
# oxpulse-awg-params-agent.service is long-running on every node.
setup
export OXPULSE_SELFHEAL_UNIT_GAP=0        # the gap is not what is under test here
echo oxpulse-crash.service > "$FX_UNITS/heals"   # "restart" always reports success
for i in 1 2 3 4 5; do
	echo oxpulse-crash.service > "$FX_UNITS/failed"   # ...and it is failed again next tick
	run_it
done
n=$(grep -c '^restart oxpulse-crash.service$' "$UNIT_LOG")
[[ "$n" == 3 ]] && pass "a crashlooping unit is bounded at 3 restarts ($n)" \
               || fail "crashloop restarted $n times, expected 3 — the budget is being reset on a false 'recovered'"
[[ "$(alerts)" == 1 ]] && pass "a crashlooping unit escalates exactly once" \
                       || fail "crashloop alert count $(alerts), expected 1"
unset OXPULSE_SELFHEAL_UNIT_GAP
teardown

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
