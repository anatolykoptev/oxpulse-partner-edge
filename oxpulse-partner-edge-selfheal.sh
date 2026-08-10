#!/bin/bash
# oxpulse-partner-edge-selfheal.sh — bounded, verified, escalating recovery for
# an edge container that is UNHEALTHY but still running.
#
# WHY THIS EXISTS
# ---------------
# docker-compose.yml.tpl's xray-client block states the gap deliberately:
#
#     No restart loop: depends_on uses service_started (not service_healthy),
#     and restart: unless-stopped acts on container EXIT, not healthcheck
#     failure. A failing tunnel marks the container unhealthy (visible in
#     docker ps) without restarting it.
#
# That was the right call while the alternative was a blind restart loop. Its
# cost was measured on 2026-08-10: cheburator's xray client wedged with every
# tunnel socket in CLOSE-WAIT and sat dark for 26 HOURS, reporting `unhealthy`
# the whole time. A single `docker restart` fixed it in seconds. Nothing acted,
# because nothing was wired to act — `RestartCount` was 0 on all five nodes.
#
# The reason a blind loop is still wrong is also on record: FOLLOWUPS.md
# documents an SFU healthcheck rendered with a stray `/CIDR` suffix that
# produced a PERMANENT false unhealthy (`failingstreak=19471+`). An unbounded
# healer would have restarted that box nineteen thousand times and called it
# maintenance.
#
# So this script heals what a restart can fix, and ESCALATES what it cannot:
# at most MAX_ATTEMPTS restarts per rolling WINDOW per container, then it stops,
# raises `..._given_up`, and alerts once. Giving up is a first-class outcome,
# not a failure of the script.
#
# WHAT IT DELIBERATELY DOES NOT DO
#   • It never recreates or re-renders. A wedge is process state; config
#     convergence belongs to oxpulse-partner-edge-refresh and upgrade.sh.
#   • It never touches a container without a healthcheck (`naive` ships without
#     one on purpose) — no healthcheck means no evidence, and acting without
#     evidence is what this file exists to avoid.
#   • It never runs while upgrade.sh holds its lock: a container restarted
#     mid-upgrade looks exactly like the upgrade failing.
#
# Env overrides (tests set these; operators normally should not):
#   OXPULSE_SELFHEAL_STATE_DIR   default /var/lib/oxpulse-partner-edge/selfheal
#   OXPULSE_SELFHEAL_MAX         default 3     restarts per window per container
#   OXPULSE_SELFHEAL_WINDOW      default 3600  rolling window, seconds
#   OXPULSE_SELFHEAL_MIN_GAP     default 300   min seconds between attempts
#   OXPULSE_SELFHEAL_START_GRACE default 180   ignore a container younger than this
#   OXPULSE_SELFHEAL_VERIFY      default 300   seconds to wait before calling an
#                                              attempt failed
#   OXPULSE_SELFHEAL_DRY_RUN     default 0     log the restart, do not perform it
#   OXPULSE_SELFHEAL_PROJECT     default oxpulse-partner-edge  compose project
set -uo pipefail

STATE_DIR="${OXPULSE_SELFHEAL_STATE_DIR:-/var/lib/oxpulse-partner-edge/selfheal}"
MAX_ATTEMPTS="${OXPULSE_SELFHEAL_MAX:-3}"
WINDOW="${OXPULSE_SELFHEAL_WINDOW:-3600}"
MIN_GAP="${OXPULSE_SELFHEAL_MIN_GAP:-300}"
START_GRACE="${OXPULSE_SELFHEAL_START_GRACE:-180}"
VERIFY_DEADLINE="${OXPULSE_SELFHEAL_VERIFY:-300}"
DRY_RUN="${OXPULSE_SELFHEAL_DRY_RUN:-0}"
PROJECT="${OXPULSE_SELFHEAL_PROJECT:-oxpulse-partner-edge}"
LOCK_FILE="${OXPULSE_SELFHEAL_LOCK:-/var/lib/oxpulse-partner-edge/selfheal.lock}"
UPGRADE_LOCK="${OXPULSE_SELFHEAL_UPGRADE_LOCK:-/usr/local/lib/partner-edge/upgrade.lock}"

log() { echo "[$(date -Is)] selfheal: $*"; }
now() { date +%s; }

# --- metric + alert sinks -----------------------------------------------------
# Both are optional by design: this script's job is to restart a wedged
# container. If the metric sink or the Telegram lib is missing, healing must
# still happen — it just goes unreported, which is strictly better than not
# happening. Resolution mirrors the sibling-lookup the other host scripts use.
_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _lib in metric-sink-lib.sh telegram-alert-lib.sh; do
	for _cand in "$_SELF_DIR/$_lib" "${INSTALL_LIB_DIR:-/usr/local/lib/partner-edge}/$_lib"; do
		# shellcheck source=/dev/null  # resolved at runtime on the node
		[[ -r "$_cand" ]] && { . "$_cand"; break; }
	done
done
# Byte-for-byte the resolution oxpulse-partner-edge-refresh.sh:39 uses. Guessing
# here writes every metric into a directory node_exporter does not read, which
# looks identical to a healer that never ran.
# shellcheck disable=SC2034  # read as an ambient global by metric-sink-lib.sh
TEXTFILE_DIR="${PARTNER_EDGE_TEXTFILE_DIR:-/var/lib/prometheus-node-exporter/textfile}"

_gauge() {   # name labels value
	declare -F emit_gauge >/dev/null 2>&1 && emit_gauge "$1" "$2" "$3" || true
}
_count() {   # name labels delta
	declare -F emit_metric >/dev/null 2>&1 && emit_metric "$1" "$2" "$3" || true
}
_alert() {   # message
	declare -F tg_alert >/dev/null 2>&1 && tg_alert "$1" force || log "ALERT (no sink): $1"
}

# --- state --------------------------------------------------------------------
# One file per container, key=value. Keys: win_start, attempts, last_attempt,
# pending_since, gave_up.
_state_file() { echo "$STATE_DIR/${1}.state"; }
_get() {   # container key default
	local f; f="$(_state_file "$1")"
	[[ -r "$f" ]] || { echo "$3"; return; }
	local v; v="$(awk -F= -v k="$2" '$1==k{print $2; exit}' "$f")"
	echo "${v:-$3}"
}
_set() {   # container key value
	local f; f="$(_state_file "$1")"; mkdir -p "$STATE_DIR"
	local tmp; tmp="$(mktemp "${f}.XXXXXX")"
	{ [[ -r "$f" ]] && grep -v "^$2=" "$f"; echo "$2=$3"; } > "$tmp" 2>/dev/null
	mv -f "$tmp" "$f"
}

# --- docker facts -------------------------------------------------------------
# The container set is DERIVED from the running compose project, never a
# hand-written list: a list cannot detect a service added later, and this fleet
# has been bitten by exactly that (a guard whose ground truth is a hand-written
# list cannot see what is missing from it).
_managed_containers() {
	docker ps --filter "label=com.docker.compose.project=$PROJECT" \
	          --format '{{.Names}}' 2>/dev/null | sort
}
_has_healthcheck() { [[ -n "$(docker inspect -f '{{if .State.Health}}y{{end}}' "$1" 2>/dev/null)" ]]; }
_health()          { docker inspect -f '{{.State.Health.Status}}' "$1" 2>/dev/null; }
_started_epoch()   { date -d "$(docker inspect -f '{{.State.StartedAt}}' "$1" 2>/dev/null)" +%s 2>/dev/null || echo 0; }

# ==============================================================================
main() {
	mkdir -p "$STATE_DIR"

	# Single-flight. A previous tick still working is not an error.
	exec 9>"$LOCK_FILE"
	flock -n 9 || { log "another run holds the lock — skipping"; exit 0; }

	# Never fight an upgrade. Non-blocking, same shape as upgrade.sh's own lock.
	if [[ -e "$UPGRADE_LOCK" ]]; then
		exec 8>"$UPGRADE_LOCK"
		if ! flock -n 8; then
			log "upgrade.sh holds $UPGRADE_LOCK — skipping this tick"
			_gauge partner_edge_selfheal_last_run_timestamp_seconds "" "$(now)"
			exit 0
		fi
		flock -u 8
	fi

	local t; t="$(now)"
	local containers; containers="$(_managed_containers)"
	if [[ -z "$containers" ]]; then
		log "no containers found for compose project '$PROJECT'"
		# Reported, not silent: an empty set is indistinguishable from a healthy
		# fleet in a counter, and this script going blind must be visible.
		_gauge partner_edge_selfheal_containers_seen "" 0
		_gauge partner_edge_selfheal_last_run_timestamp_seconds "" "$t"
		exit 0
	fi

	local seen=0
	while read -r c; do
		[[ -n "$c" ]] || continue
		_has_healthcheck "$c" || continue
		seen=$((seen + 1))
		_evaluate "$c" "$t"
	done <<< "$containers"

	_gauge partner_edge_selfheal_containers_seen "" "$seen"
	_gauge partner_edge_selfheal_last_run_timestamp_seconds "" "$t"
}

_evaluate() {   # container now
	local c="$1" t="$2"
	local status; status="$(_health "$c")"
	local lbl="container=\"$c\""

	_gauge partner_edge_container_unhealthy "$lbl" "$([[ "$status" == unhealthy ]] && echo 1 || echo 0)"

	# --- resolve any attempt still awaiting a verdict --------------------------
	# Verification is asynchronous on purpose. After a restart the container sits
	# in `starting` for start_period + interval*retries — measured at ~2 min on
	# this stack — so waiting inline would make a 60 s oneshot run for minutes
	# and overlap its own timer. The next tick reads the outcome instead.
	local pending; pending="$(_get "$c" pending_since 0)"
	if [[ "$pending" != 0 ]]; then
		if [[ "$status" == healthy ]]; then
			log "$c: healed (restart at $pending verified)"
			_count partner_edge_selfheal_attempts_total "$lbl,outcome=\"healed\"" 1
			_set "$c" pending_since 0
			_set "$c" gave_up 0
			_gauge partner_edge_selfheal_given_up "$lbl" 0
		elif (( t - pending > VERIFY_DEADLINE )); then
			log "$c: restart did NOT restore health within ${VERIFY_DEADLINE}s"
			_count partner_edge_selfheal_attempts_total "$lbl,outcome=\"failed\"" 1
			_set "$c" pending_since 0
		else
			return 0   # still settling — do not stack another restart on top
		fi
	fi

	[[ "$status" == unhealthy ]] || return 0

	# --- guards ---------------------------------------------------------------
	local started; started="$(_started_epoch "$c")"
	if (( started > 0 && t - started < START_GRACE )); then
		log "$c: unhealthy but only $((t - started))s old — inside start grace"
		return 0
	fi

	# --- budget ---------------------------------------------------------------
	local win_start attempts last
	win_start="$(_get "$c" win_start 0)"; attempts="$(_get "$c" attempts 0)"; last="$(_get "$c" last_attempt 0)"
	if (( win_start == 0 || t - win_start >= WINDOW )); then
		win_start="$t"; attempts=0
		_set "$c" win_start "$t"; _set "$c" attempts 0
		_set "$c" gave_up 0; _gauge partner_edge_selfheal_given_up "$lbl" 0
	fi
	if (( t - last < MIN_GAP )); then
		log "$c: unhealthy, but last attempt was $((t - last))s ago (< ${MIN_GAP}s)"
		return 0
	fi
	if (( attempts >= MAX_ATTEMPTS )); then
		# THE POINT OF THE WHOLE FILE. A restart that has not worked three times
		# will not work the fourth; something else is wrong — very possibly the
		# healthcheck itself, as in the failingstreak=19471 case. Escalate, once.
		if [[ "$(_get "$c" gave_up 0)" != 1 ]]; then
			_set "$c" gave_up 1
			_gauge partner_edge_selfheal_given_up "$lbl" 1
			_alert "partner-edge $(hostname): GAVE UP healing container '$c' — ${attempts} restarts in $(( (t - win_start) / 60 ))m did not restore health. Suspect the service OR its healthcheck (a mis-rendered probe reports unhealthy forever). No further restarts this window."
			log "$c: GAVE UP after $attempts attempts — alerted"
		fi
		return 0
	fi

	# --- heal -----------------------------------------------------------------
	attempts=$((attempts + 1))
	log "$c: unhealthy — restarting (attempt $attempts/$MAX_ATTEMPTS this window)"
	if [[ "$DRY_RUN" == 1 ]]; then
		log "$c: [dry-run] docker restart $c"
	elif ! docker restart "$c" >/dev/null 2>&1; then
		log "$c: docker restart FAILED"
		_count partner_edge_selfheal_attempts_total "$lbl,outcome=\"restart_error\"" 1
		_set "$c" attempts "$attempts"; _set "$c" last_attempt "$t"
		return 0
	fi
	_set "$c" attempts "$attempts"
	_set "$c" last_attempt "$t"
	_set "$c" pending_since "$t"
}

main "$@"
