#!/bin/bash
# tests/test_selfheal.sh — coverage for oxpulse-partner-edge-selfheal.sh.
#
# Every case below is one whose failure would be SILENT in production:
#
#   1. unhealthy + budget available  → restarts        (without this the script
#      is decoration and the 26h cheburator outage repeats)
#   2. attempts at MAX               → does NOT restart, raises given_up, alerts
#      ONCE (this is the failingstreak=19471 case from FOLLOWUPS.md — an
#      unbounded healer would restart such a box forever and call it healthy
#      maintenance; this bound is the reason the compose template refused a
#      restart loop in the first place)
#   3. inside start grace            → does NOT restart (otherwise a slow-
#      starting container is killed on every tick and never finishes starting)
#   4. no healthcheck                → never touched   (`naive` ships without
#      one on purpose; acting without evidence is the thing being avoided)
#   5. healthy                       → does nothing
#   6. pending attempt now healthy   → counts `healed`, clears pending
#   7. MIN_GAP not elapsed           → does NOT restart
#
# `docker` is a PATH shim driven by fixture files, so no daemon is needed.
set -uo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SCRIPT="$REPO_ROOT/oxpulse-partner-edge-selfheal.sh"
[[ -f "$SCRIPT" ]] || { echo "FAIL: $SCRIPT not found"; exit 1; }

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# Build a sandbox: fake docker + isolated state dir. FIXTURES holds one file per
# container: "<health> <started_epoch> <has_health>".
setup() {
	TMP="$(mktemp -d)"; BIN="$TMP/bin"; mkdir -p "$BIN" "$TMP/state" "$TMP/fixtures"
	cat > "$BIN/docker" <<'DOCKER'
#!/bin/bash
FX="$FIXTURES"
case "$1" in
  ps)      ls "$FX" 2>/dev/null ;;
  inspect)
    fmt="$3"; c="$4"; f="$FX/$c"
    [[ -r "$f" ]] || exit 1
    read -r health started hashc < "$f"
    case "$fmt" in
      *State.Health.Status*) echo "$health" ;;
      *if\ .State.Health*)   [[ "$hashc" == y ]] && echo y ;;
      *State.StartedAt*)     date -d "@$started" -Is ;;
    esac ;;
  restart) echo "$2" >> "$RESTART_LOG"; exit "${DOCKER_RESTART_RC:-0}" ;;
esac
DOCKER
	chmod +x "$BIN/docker"
	# tg_alert stand-in: the script sources a lib if present; here we prove the
	# alert path fires by shipping a lib that records the call.
	cat > "$TMP/telegram-alert-lib.sh" <<'TG'
tg_alert() { echo "$1" >> "$ALERT_LOG"; }
TG
	export FIXTURES="$TMP/fixtures" RESTART_LOG="$TMP/restarts" ALERT_LOG="$TMP/alerts"
	: > "$RESTART_LOG"; : > "$ALERT_LOG"
	export PATH="$BIN:$PATH"
	export OXPULSE_SELFHEAL_STATE_DIR="$TMP/state"
	export OXPULSE_SELFHEAL_LOCK="$TMP/lock"
	export OXPULSE_SELFHEAL_UPGRADE_LOCK="$TMP/nonexistent-upgrade.lock"
	export INSTALL_LIB_DIR="$TMP"
	export PARTNER_EDGE_TEXTFILE_DIR="$TMP/textfile"; mkdir -p "$TMP/textfile"
	unset OXPULSE_SELFHEAL_DRY_RUN
}
teardown() { rm -rf "$TMP"; }
fixture() { echo "$2 $3 ${4:-y}" > "$FIXTURES/$1"; }        # name health started [hashc]
run_it()  { bash "$SCRIPT" >"$TMP/out" 2>&1; }
restarts() { wc -l < "$RESTART_LOG" | tr -d ' '; }
alerts()   { wc -l < "$ALERT_LOG" | tr -d ' '; }
state()    { awk -F= -v k="$2" '$1==k{print $2}' "$OXPULSE_SELFHEAL_STATE_DIR/$1.state" 2>/dev/null; }

echo ""
echo "=== oxpulse-partner-edge-selfheal.sh ==="

# 1 — the healing case
setup; fixture c1 unhealthy $(( $(date +%s) - 9999 )); run_it
[[ "$(restarts)" == 1 ]] && pass "unhealthy container is restarted" \
                         || fail "unhealthy container NOT restarted (got $(restarts))"
teardown

# 2 — the bound: this is the one that matters
setup; fixture c1 unhealthy $(( $(date +%s) - 9999 ))
t=$(( $(date +%s) - 4000 ))
mkdir -p "$OXPULSE_SELFHEAL_STATE_DIR"
# A window that is still open (started 100s ago) with the budget already spent.
printf 'win_start=%s\nattempts=3\nlast_attempt=%s\npending_since=0\n' \
  "$(( $(date +%s) - 100 ))" "$(( $(date +%s) - 999 ))" > "$OXPULSE_SELFHEAL_STATE_DIR/c1.state"
run_it
r=$(restarts); a=$(alerts); g=$(state c1 gave_up)
[[ "$r" == 0 ]] && pass "budget exhausted → NO fourth restart" || fail "restarted despite exhausted budget ($r)"
[[ "$a" == 1 ]] && pass "budget exhausted → alerts exactly once" || fail "alert count $a, expected 1"
[[ "$g" == 1 ]] && pass "budget exhausted → gave_up recorded" || fail "gave_up=$g, expected 1"
run_it                                  # a second tick must not re-alert
[[ "$(alerts)" == 1 ]] && pass "give-up alert is not repeated every tick" || fail "re-alerted: $(alerts)"
teardown

# 3 — start grace
setup; fixture c1 unhealthy $(( $(date +%s) - 5 )); run_it
[[ "$(restarts)" == 0 ]] && pass "inside start grace → not restarted" || fail "restarted a just-started container"
teardown

# 4 — no healthcheck is never touched
setup; fixture c1 unhealthy $(( $(date +%s) - 9999 )) n; run_it
[[ "$(restarts)" == 0 ]] && pass "container without a healthcheck is never touched" || fail "touched a container with no healthcheck"
teardown

# 5 — healthy is left alone
setup; fixture c1 healthy $(( $(date +%s) - 9999 )); run_it
[[ "$(restarts)" == 0 ]] && pass "healthy container is left alone" || fail "restarted a healthy container"
teardown

# 6 — a pending attempt that came back healthy is counted as healed
setup; fixture c1 healthy $(( $(date +%s) - 9999 ))
mkdir -p "$OXPULSE_SELFHEAL_STATE_DIR"
printf 'pending_since=%s\nattempts=1\nwin_start=%s\n' "$(( $(date +%s) - 60 ))" "$(( $(date +%s) - 60 ))" \
  > "$OXPULSE_SELFHEAL_STATE_DIR/c1.state"
run_it
[[ "$(state c1 pending_since)" == 0 ]] && pass "verified heal clears the pending marker" \
                                       || fail "pending marker not cleared: $(state c1 pending_since)"
teardown

# 7 — MIN_GAP
setup; fixture c1 unhealthy $(( $(date +%s) - 9999 ))
mkdir -p "$OXPULSE_SELFHEAL_STATE_DIR"
printf 'win_start=%s\nattempts=1\nlast_attempt=%s\npending_since=0\n' \
  "$(( $(date +%s) - 100 ))" "$(( $(date +%s) - 10 ))" > "$OXPULSE_SELFHEAL_STATE_DIR/c1.state"
run_it
[[ "$(restarts)" == 0 ]] && pass "MIN_GAP not elapsed → not restarted" || fail "restarted inside MIN_GAP"
teardown

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
