#!/bin/bash
# oxpulse-partner-edge-selfheal.sh — bounded, verified, escalating recovery for
# the parts of a partner edge whose failure is SILENT.
#
# WHY THIS EXISTS
# ---------------
# docker-compose.yml.tpl's xray-client block states the original gap
# deliberately:
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
# So this script heals what an action can fix, and ESCALATES what it cannot: at
# most MAX attempts per rolling WINDOW per subject, then it stops, raises
# `..._given_up`, and alerts once. Giving up is a first-class outcome, not a
# failure of the script.
#
# THE FOUR SUBSYSTEMS IT WATCHES
# ------------------------------
# Each was chosen because a live probe of the fleet found it already broken and
# unobserved, not because it seemed plausible:
#
#   1. containers, UNHEALTHY   — the cheburator wedge above.
#   2. containers, STOPPED     — `restart: unless-stopped` gives up after a
#                                daemon restart or an OOM-kill storm; an exited
#                                container is invisible to check 1, which only
#                                ever inspects health.
#   3. oxpulse units, FAILED   — measured 2026-08-11: oxpulse-geoip-refresh
#                                .service had been `failed` on ruoxp AND
#                                cheburator since 01 Aug. db-ip publishes
#                                dbip-country-lite-<YYYY-MM>.mmdb.gz during the
#                                1st; the monthly timer fired at 03:40 and got
#                                404. curl --retry does not retry a 404, the
#                                unit is Type=oneshot with no Restart=, and the
#                                timer is monthly — so ONE lost race froze the
#                                geo database for a month. rvpn's mmdb was from
#                                20 May. Nothing alerted for ten days. A plain
#                                `systemctl restart` fixes it, because by the
#                                time anyone looks the file is published.
#   4. the declared ENABLE-SET — a unit that is installed but not enabled comes
#                                back from a reboot dead. This already happened
#                                fleet-wide (see tests/test_upgrade_enable_set_
#                                matches_installer.sh: two nodes sat with
#                                oxpulse-partner-edge.service DISABLED). The
#                                upgrade path now enables them, but only when an
#                                upgrade runs; nothing checks in between.
#   5. DISK pressure           — measured: rvpn / at 80% with 9.5 GB of docker
#                                build cache and 8.9 GB of images reclaimable.
#                                A full disk wedges every one of the above at
#                                once and turns each of their healers into a
#                                no-op.
#
# WHAT IT DELIBERATELY DOES NOT DO
#   • It never recreates or re-renders. A wedge is process state; config
#     convergence belongs to oxpulse-partner-edge-refresh and upgrade.sh.
#   • It never touches a container without a healthcheck (`naive` ships without
#     one on purpose) — no healthcheck means no evidence, and acting without
#     evidence is what this file exists to avoid.
#   • It never runs while upgrade.sh holds its lock: a container restarted
#     mid-upgrade looks exactly like the upgrade failing.
#   • It never enables a unit outside the declared set. Measured 2026-08-11:
#     oxpulse-partner-edge-ru-subnets-update.timer is `disabled` on 4 of 4
#     nodes and is NOT in the enable-set — disabled is its intended state. A
#     healer keyed on "every oxpulse timer" would have switched on a feature
#     that is deliberately off, on every edge.
#   • It never touches its own timer (see ENABLE_UNITS below) and never
#     restarts its own service.
#
# THE OPERATOR ESCAPE HATCH
#   touch /var/lib/oxpulse-partner-edge/selfheal.hold            → stop everything
#   touch /var/lib/oxpulse-partner-edge/selfheal.hold.<subject>  → stop one subject
# <subject> is the natural name: a container name, a unit name, or `disk`.
# Nothing else pauses this script, and `systemctl stop`ping a container to debug
# it does NOT — that is precisely the case the hold file exists for. rvpn shares
# its docker daemon with a neighbouring project, which makes this load-bearing.
#
# Env overrides (tests set these; operators normally should not):
#   OXPULSE_SELFHEAL_STATE_DIR   default /var/lib/oxpulse-partner-edge/selfheal
#   OXPULSE_SELFHEAL_MAX         default 3     container restarts per window
#   OXPULSE_SELFHEAL_WINDOW      default 3600  rolling window, seconds
#   OXPULSE_SELFHEAL_MIN_GAP     default 300   min seconds between attempts
#   OXPULSE_SELFHEAL_START_GRACE default 180   ignore a container younger than this
#   OXPULSE_SELFHEAL_VERIFY      default 300   seconds before an attempt is failed
#   OXPULSE_SELFHEAL_UNIT_MAX    default 3     unit actions per window
#   OXPULSE_SELFHEAL_UNIT_GAP    default 600   min seconds between unit actions
#   OXPULSE_SELFHEAL_DISK_PCT    default 85    heal above this used-percent
#   OXPULSE_SELFHEAL_DISK_MAX    default 2     prunes per disk window
#   OXPULSE_SELFHEAL_DISK_WINDOW default 21600 disk rolling window, seconds
#   OXPULSE_SELFHEAL_DISK_GAP    default 3600  min seconds between prunes
#   OXPULSE_SELFHEAL_ACTS_PER_TICK default 2   max unit actions in one tick
#   OXPULSE_SELFHEAL_DRY_RUN     default 0     log the action, do not perform it
#   OXPULSE_SELFHEAL_PROJECT     default oxpulse-partner-edge  compose project
#   OXPULSE_SELFHEAL_NAME_PREFIX default oxpulse-partner-      container prefix
set -uo pipefail

STATE_DIR="${OXPULSE_SELFHEAL_STATE_DIR:-/var/lib/oxpulse-partner-edge/selfheal}"
MAX_ATTEMPTS="${OXPULSE_SELFHEAL_MAX:-3}"
WINDOW="${OXPULSE_SELFHEAL_WINDOW:-3600}"
MIN_GAP="${OXPULSE_SELFHEAL_MIN_GAP:-300}"
START_GRACE="${OXPULSE_SELFHEAL_START_GRACE:-180}"
VERIFY_DEADLINE="${OXPULSE_SELFHEAL_VERIFY:-300}"
UNIT_MAX="${OXPULSE_SELFHEAL_UNIT_MAX:-3}"
UNIT_GAP="${OXPULSE_SELFHEAL_UNIT_GAP:-600}"
DISK_PCT="${OXPULSE_SELFHEAL_DISK_PCT:-85}"
DISK_MAX="${OXPULSE_SELFHEAL_DISK_MAX:-2}"
DISK_WINDOW="${OXPULSE_SELFHEAL_DISK_WINDOW:-21600}"
DISK_GAP="${OXPULSE_SELFHEAL_DISK_GAP:-3600}"
ACTS_PER_TICK="${OXPULSE_SELFHEAL_ACTS_PER_TICK:-2}"
DRY_RUN="${OXPULSE_SELFHEAL_DRY_RUN:-0}"
PROJECT="${OXPULSE_SELFHEAL_PROJECT:-oxpulse-partner-edge}"
NAME_PREFIX="${OXPULSE_SELFHEAL_NAME_PREFIX:-oxpulse-partner-}"
DOCKER_ROOT="${OXPULSE_SELFHEAL_DOCKER_ROOT:-/var/lib/docker}"
LOCK_FILE="${OXPULSE_SELFHEAL_LOCK:-/var/lib/oxpulse-partner-edge/selfheal.lock}"
UPGRADE_LOCK="${OXPULSE_SELFHEAL_UPGRADE_LOCK:-/usr/local/lib/partner-edge/upgrade.lock}"
HOLD_FILE="${OXPULSE_SELFHEAL_HOLD:-/var/lib/oxpulse-partner-edge/selfheal.hold}"

# The units this node must have ENABLED. Not a fourth hand-maintained copy: it
# is asserted equal to upgrade.sh's _HOST_SCRIPT_ENABLE_UNITS — itself already
# asserted equal to lib/install-systemd.sh's BAKE_MODE=0 branch — by
# tests/test_upgrade_enable_set_matches_installer.sh (assertion S6), minus this
# script's OWN timer. That exclusion is deliberate: disabling the timer is the
# obvious way an operator stops this script, and a healer that re-enables
# itself cannot be switched off by the person it is fighting.
ENABLE_UNITS=(
	oxpulse-partner-edge.service
	oxpulse-partner-cert-watch.path
	oxpulse-partner-edge-refresh.timer
	oxpulse-partner-edge-sni-rotate.timer
	oxpulse-xray-update.timer
	oxpulse-geoip-refresh.timer
	oxpulse-channels-health-report.timer
)

# Per-tick cap on systemd actions. A unit restart BLOCKS (a Type=oneshot runs to
# completion), so an unbounded sweep could outlive the service's own
# TimeoutStartSec and be killed halfway through, leaving no record of what it did.
ACTS_TAKEN=0

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

_count() {   # name labels delta
	declare -F emit_metric >/dev/null 2>&1 && emit_metric "$1" "$2" "$3" || true
}
_alert() {   # message
	declare -F tg_alert >/dev/null 2>&1 && tg_alert "$1" force || log "ALERT (no sink): $1"
}

# --- gauge series -------------------------------------------------------------
# A gauge textfile is truncated on every write, so one write per subject leaves
# only the LAST subject. Measured on ruoxp and rvpn 2026-08-11: the healer
# reported `containers_seen 5` beside a single surviving
# `partner_edge_container_unhealthy{container="oxpulse-partner-xray"}` sample —
# four containers unobserved behind a metric that looked healthy. So samples
# are ACCUMULATED here and every series for a metric is written in one pass.
#
# Keyed by (metric, labels) so a later write REPLACES an earlier one for the
# same series. Appending instead would put two lines with identical labels in
# one file, and node_exporter rejects the whole file on a duplicate series —
# turning a metrics fix into a metrics outage.
declare -A _GVAL
_gauge() {   # name labels value
	_GVAL["${1}"$'\x1f'"${2}"]="$3"
}
_flush_gauges() {
	local k m l v
	declare -A _bym=()
	for k in "${!_GVAL[@]}"; do
		m="${k%%$'\x1f'*}"; l="${k#*$'\x1f'}"
		_bym["$m"]+="${l}"$'\t'"${_GVAL[$k]}"$'\n'
	done
	for m in "${!_bym[@]}"; do
		if declare -F _emit_prom_gauge_series >/dev/null 2>&1; then
			printf '%s' "${_bym[$m]}" | _emit_prom_gauge_series "${m}.prom" "$m"
		elif declare -F emit_gauge >/dev/null 2>&1; then
			# Older lib still on the node (the sync between this script and
			# metric-sink-lib.sh is not transactional). Degrade to the
			# one-series-wins behaviour rather than emitting nothing.
			local line
			while IFS= read -r line; do   # see the lib: a TAB is IFS whitespace
				l="${line%%$'\t'*}"; v="${line#*$'\t'}"
				[[ -n "$v" ]] && emit_gauge "$m" "$l" "$v"
			done <<< "${_bym[$m]}"
		fi
	done
}

# --- state --------------------------------------------------------------------
# One file per SUBJECT, key=value. Keys: win_start, attempts, last_attempt,
# pending_since, gave_up. Container subjects keep their bare v1 filename so the
# budget already accrued on the fleet survives this upgrade; the newer kinds are
# namespaced so `unit:x` and `enable:x` cannot share one budget.
_state_file() { echo "$STATE_DIR/${1//[^A-Za-z0-9._@-]/_}.state"; }
_get() {   # subject key default
	local f; f="$(_state_file "$1")"
	[[ -r "$f" ]] || { echo "$3"; return; }
	local v; v="$(awk -F= -v k="$2" '$1==k{print $2; exit}' "$f")"
	echo "${v:-$3}"
}
_set() {   # subject key value
	local f; f="$(_state_file "$1")"; mkdir -p "$STATE_DIR"
	local tmp; tmp="$(mktemp "${f}.XXXXXX")"
	{ [[ -r "$f" ]] && grep -v "^$2=" "$f"; echo "$2=$3"; } > "$tmp" 2>/dev/null
	mv -f "$tmp" "$f"
}

# --- the operator escape hatch ------------------------------------------------
_held() {   # natural-name [namespaced-subject]
	[[ -e "$HOLD_FILE" ]] && return 0
	[[ -n "${1:-}" && -e "$HOLD_FILE.$1" ]] && return 0
	[[ -n "${2:-}" && -e "$HOLD_FILE.$2" ]] && return 0
	return 1
}

# --- the budget engine --------------------------------------------------------
# Shared by every healer so the bound cannot be forgotten in a new one.
# Returns 0 when an attempt may be made. Raises the give-up alert exactly once
# per window when the budget is spent.
_budget_gate() {   # subject max window gap now label give-up-message
	local s="$1" max="$2" win="$3" gap="$4" t="$5" lbl="$6" msg="$7"
	local win_start attempts last
	win_start="$(_get "$s" win_start 0)"; attempts="$(_get "$s" attempts 0)"; last="$(_get "$s" last_attempt 0)"
	if (( win_start == 0 || t - win_start >= win )); then
		_set "$s" win_start "$t"; _set "$s" attempts 0
		_set "$s" gave_up 0
		attempts=0
	fi
	_gauge partner_edge_selfheal_given_up "$lbl" "$(_get "$s" gave_up 0)"
	if (( t - last < gap )); then
		log "$s: last attempt was $((t - last))s ago (< ${gap}s) — waiting"
		return 1
	fi
	if (( attempts >= max )); then
		# THE POINT OF THE WHOLE FILE. An action that has not worked MAX times
		# will not work on the next try; something else is wrong — very possibly
		# the detector itself, as in the failingstreak=19471 case. Escalate once.
		if [[ "$(_get "$s" gave_up 0)" != 1 ]]; then
			_set "$s" gave_up 1
			_gauge partner_edge_selfheal_given_up "$lbl" 1
			_alert "$msg"
			log "$s: GAVE UP after $attempts attempts — alerted"
		fi
		return 1
	fi
	return 0
}
_budget_spend() {   # subject now
	_set "$1" attempts "$(( $(_get "$1" attempts 0) + 1 ))"
	_set "$1" last_attempt "$2"
}
_budget_clear() {   # subject
	_set "$1" attempts 0; _set "$1" gave_up 0
}

# --- docker facts -------------------------------------------------------------
# The container set is DERIVED from the running compose project, never a
# hand-written list: a list cannot detect a service added later, and this fleet
# has been bitten by exactly that.
#
# The NAME_PREFIX is a second, narrowing gate, and it is not redundant: measured
# 2026-08-11, rvpn's `all-rvpn-gate` — a container belonging to the neighbouring
# rvpnm project that shares that box's docker daemon — carries
# com.docker.compose.project=oxpulse-partner-edge. The project label alone puts
# a foreign container inside our blast radius. A prefix is not a hand-written
# list: a service added later as oxpulse-partner-<new> still matches.
_managed_containers() {   # [ps-extra-args...]
	docker ps "$@" --filter "label=com.docker.compose.project=$PROJECT" \
	          --format '{{.Names}}' 2>/dev/null | grep "^${NAME_PREFIX}" | sort
}
_has_healthcheck() { [[ -n "$(docker inspect -f '{{if .State.Health}}y{{end}}' "$1" 2>/dev/null)" ]]; }
_health()          { docker inspect -f '{{.State.Health.Status}}' "$1" 2>/dev/null; }
_started_epoch()   { date -d "$(docker inspect -f '{{.State.StartedAt}}' "$1" 2>/dev/null)" +%s 2>/dev/null || echo 0; }
_finished_epoch()  { date -d "$(docker inspect -f '{{.State.FinishedAt}}' "$1" 2>/dev/null)" +%s 2>/dev/null || echo 0; }
_oneoff()          { [[ "$(docker inspect -f '{{index .Config.Labels "com.docker.compose.oneoff"}}' "$1" 2>/dev/null)" == True ]]; }

# ==============================================================================
main() {
	mkdir -p "$STATE_DIR"

	# Single-flight. A previous tick still working is not an error.
	exec 9>"$LOCK_FILE"
	flock -n 9 || { log "another run holds the lock — skipping"; exit 0; }

	local t; t="$(now)"

	# The global hold. Checked before anything is inspected, so a held node is
	# also a node that stops touching docker at all.
	if [[ -e "$HOLD_FILE" ]]; then
		log "hold file $HOLD_FILE present — taking no action"
		_gauge partner_edge_selfheal_hold "" 1
		_gauge partner_edge_selfheal_last_run_timestamp_seconds "" "$t"
		_flush_gauges
		exit 0
	fi
	_gauge partner_edge_selfheal_hold "" 0

	# Never fight an upgrade. Non-blocking, same shape as upgrade.sh's own lock.
	if [[ -e "$UPGRADE_LOCK" ]]; then
		exec 8>"$UPGRADE_LOCK"
		if ! flock -n 8; then
			log "upgrade.sh holds $UPGRADE_LOCK — skipping this tick"
			_gauge partner_edge_selfheal_last_run_timestamp_seconds "" "$t"
			_flush_gauges
			exit 0
		fi
		flock -u 8
	fi

	ACTS_TAKEN=0
	heal_containers "$t"
	heal_units "$t"
	heal_enable_drift "$t"
	heal_disk "$t"

	_gauge partner_edge_selfheal_last_run_timestamp_seconds "" "$t"
	_flush_gauges
}

# --- 1 + 2: containers, unhealthy and stopped ---------------------------------
heal_containers() {   # now
	local t="$1" seen=0 c
	local running; running="$(_managed_containers)"
	local all;     all="$(_managed_containers -a)"

	if [[ -z "$all" ]]; then
		log "no containers found for compose project '$PROJECT'"
		# Reported, not silent: an empty set is indistinguishable from a healthy
		# fleet in a counter, and this script going blind must be visible.
		_gauge partner_edge_selfheal_containers_seen "" 0
		return 0
	fi

	while read -r c; do
		[[ -n "$c" ]] || continue
		if grep -qxF "$c" <<< "$running"; then
			_has_healthcheck "$c" || continue
			seen=$((seen + 1))
			_evaluate_container "$c" "$t"
		else
			_evaluate_stopped "$c" "$t"
		fi
	done <<< "$all"

	_gauge partner_edge_selfheal_containers_seen "" "$seen"
}

_evaluate_container() {   # container now
	local c="$1" t="$2"
	local status; status="$(_health "$c")"
	local lbl="container=\"$c\""

	_gauge partner_edge_container_unhealthy "$lbl" "$([[ "$status" == unhealthy ]] && echo 1 || echo 0)"
	_gauge partner_edge_container_stopped "$lbl" 0

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
	_held "$c" && { log "$c: unhealthy, but a hold file is present — not acting"; return 0; }

	# --- guards ---------------------------------------------------------------
	local started; started="$(_started_epoch "$c")"
	if (( started > 0 && t - started < START_GRACE )); then
		log "$c: unhealthy but only $((t - started))s old — inside start grace"
		return 0
	fi

	_budget_gate "$c" "$MAX_ATTEMPTS" "$WINDOW" "$MIN_GAP" "$t" "$lbl" \
		"partner-edge $(hostname): GAVE UP healing container '$c' — $(_get "$c" attempts 0) restarts did not restore health. Suspect the service OR its healthcheck (a mis-rendered probe reports unhealthy forever). No further restarts this window." \
		|| return 0

	# --- heal -----------------------------------------------------------------
	log "$c: unhealthy — restarting (attempt $(( $(_get "$c" attempts 0) + 1 ))/$MAX_ATTEMPTS this window)"
	if [[ "$DRY_RUN" == 1 ]]; then
		log "$c: [dry-run] docker restart $c"
	elif ! docker restart "$c" >/dev/null 2>&1; then
		log "$c: docker restart FAILED"
		_count partner_edge_selfheal_attempts_total "$lbl,outcome=\"restart_error\"" 1
		_budget_spend "$c" "$t"
		return 0
	fi
	_budget_spend "$c" "$t"
	_set "$c" pending_since "$t"
}

# A managed container that is not running at all. `restart: unless-stopped`
# covers a crash, but not a daemon that came back without it, and not a
# container an OOM storm exhausted. _evaluate_container never sees this case —
# it only ever inspects health, and a stopped container has none.
_evaluate_stopped() {   # container now
	local c="$1" t="$2"
	# Two `local`s on purpose: a variable assigned in the SAME `local` is not yet
	# in effect, so `s="stopped:$c"` up there would read the CALLER's `c` — which
	# happens to hold the same value today, making it accidentally correct and
	# silently wrong the day this is called from anywhere else.
	local s="stopped:$c"
	local lbl="container=\"$c\""
	_gauge partner_edge_container_stopped "$lbl" 1

	# A `docker compose run` container is not a service; it is expected to sit
	# exited forever and starting it would run a one-off task again.
	_oneoff "$c" && return 0
	_held "$c" "$s" && { log "$c: stopped, but a hold file is present — not acting"; return 0; }

	# Do not race docker's own restart policy, and do not fight an operator who
	# stopped this a moment ago to look at something.
	local fin; fin="$(_finished_epoch "$c")"
	if (( fin > 0 && t - fin < START_GRACE )); then
		log "$c: stopped $((t - fin))s ago — inside start grace"
		return 0
	fi

	_budget_gate "$s" "$MAX_ATTEMPTS" "$WINDOW" "$MIN_GAP" "$t" "$lbl" \
		"partner-edge $(hostname): GAVE UP starting container '$c' — it will not stay running. Check its logs; this is not a wedge a restart clears." \
		|| return 0

	log "$c: not running — starting (attempt $(( $(_get "$s" attempts 0) + 1 ))/$MAX_ATTEMPTS this window)"
	if [[ "$DRY_RUN" == 1 ]]; then
		log "$c: [dry-run] docker start $c"
	elif ! docker start "$c" >/dev/null 2>&1; then
		log "$c: docker start FAILED"
		_count partner_edge_selfheal_attempts_total "$lbl,outcome=\"start_error\"" 1
		_budget_spend "$s" "$t"
		return 0
	fi
	_count partner_edge_selfheal_attempts_total "$lbl,outcome=\"started\"" 1
	_budget_spend "$s" "$t"
}

# --- 3: oxpulse units in a failed state ---------------------------------------
# The failed set comes from systemd itself, filtered to the units this project
# installs — never a hand-written list of units to watch, which could not see a
# unit added by a later release.
_failed_units() {
	systemctl list-units --state=failed --no-legend --plain 'oxpulse-*' 2>/dev/null \
		| awk '{print $1}' | grep -v '^oxpulse-partner-edge-selfheal\.service$'
}

heal_units() {   # now
	local t="$1" u
	local failed; failed="$(_failed_units)"
	[[ -n "$failed" ]] || return 0

	while read -r u; do
		[[ -n "$u" ]] || continue
		local s="unit:$u" lbl="unit=\"$u\""
		_gauge partner_edge_unit_failed "$lbl" 1
		_held "$u" "$s" && { log "$u: failed, but a hold file is present — not acting"; continue; }
		(( ACTS_TAKEN >= ACTS_PER_TICK )) && { log "$u: failed, but this tick's action budget is spent"; continue; }

		_budget_gate "$s" "$UNIT_MAX" "$WINDOW" "$UNIT_GAP" "$t" "$lbl" \
			"partner-edge $(hostname): GAVE UP restarting unit '$u' — it fails every time. journalctl -u $u. No further restarts this window." \
			|| continue

		log "$u: failed — restarting (attempt $(( $(_get "$s" attempts 0) + 1 ))/$UNIT_MAX this window)"
		_budget_spend "$s" "$t"
		ACTS_TAKEN=$((ACTS_TAKEN + 1))
		if [[ "$DRY_RUN" == 1 ]]; then
			log "$u: [dry-run] systemctl restart $u"
			continue
		fi
		# Bounded: a Type=oneshot restart BLOCKS until the unit finishes, and this
		# script runs under a systemd TimeoutStartSec of its own.
		timeout 60 systemctl restart "$u" >/dev/null 2>&1
		# For a oneshot that is the real verdict; for a long-running service it
		# only means "started", and a crash three seconds later shows up as a
		# failed unit on the next tick, which spends another attempt and
		# eventually gives up. Both are correct.
		if systemctl is-failed --quiet "$u" 2>/dev/null; then
			log "$u: still failed after restart"
			_count partner_edge_selfheal_attempts_total "$lbl,outcome=\"failed\"" 1
		else
			log "$u: recovered"
			_count partner_edge_selfheal_attempts_total "$lbl,outcome=\"healed\"" 1
			_gauge partner_edge_unit_failed "$lbl" 0
			_budget_clear "$s"
		fi
	done <<< "$failed"
}

# --- 4: units that must be enabled --------------------------------------------
heal_enable_drift() {   # now
	local t="$1" u
	for u in "${ENABLE_UNITS[@]}"; do
		local state; state="$(systemctl is-enabled "$u" 2>/dev/null)"
		# An empty answer means systemd has no such unit — a broken delivery, not
		# a disabled unit. Naming it that way is the difference between an alert
		# someone can act on and one that reads as a systemd quirk.
		[[ -n "$state" ]] || state="not-installed"
		local lbl="unit=\"$u\""
		# `enabled-runtime` is drift too — it does not survive a reboot, which is
		# the entire failure this check exists to prevent.
		if [[ "$state" == enabled || "$state" == static || "$state" == indirect ]]; then
			_gauge partner_edge_unit_enable_drift "$lbl" 0
			continue
		fi
		_gauge partner_edge_unit_enable_drift "$lbl" 1
		local s="enable:$u"
		_held "$u" "$s" && { log "$u: is '$state', but a hold file is present — not acting"; continue; }
		(( ACTS_TAKEN >= ACTS_PER_TICK )) && { log "$u: is '$state', but this tick's action budget is spent"; continue; }

		_budget_gate "$s" "$UNIT_MAX" "$WINDOW" "$UNIT_GAP" "$t" "$lbl" \
			"partner-edge $(hostname): GAVE UP enabling '$u' (systemctl reports '$state'). Until this is fixed the unit does NOT come back after a reboot." \
			|| continue

		log "$u: is '$state', must be enabled — enabling"
		_budget_spend "$s" "$t"
		ACTS_TAKEN=$((ACTS_TAKEN + 1))
		if [[ "$DRY_RUN" == 1 ]]; then
			log "$u: [dry-run] systemctl enable --now $u"
			continue
		fi
		timeout 60 systemctl enable --now "$u" >/dev/null 2>&1
		if [[ "$(systemctl is-enabled "$u" 2>/dev/null)" == enabled ]]; then
			log "$u: enabled"
			_count partner_edge_selfheal_attempts_total "$lbl,outcome=\"enabled\"" 1
			_gauge partner_edge_unit_enable_drift "$lbl" 0
			_budget_clear "$s"
		else
			log "$u: enable did not take"
			_count partner_edge_selfheal_attempts_total "$lbl,outcome=\"failed\"" 1
		fi
	done
}

# --- 5: disk pressure ---------------------------------------------------------
# A full disk wedges every other healer at once: docker cannot write a layer,
# systemd cannot journal, the metric sink cannot rename its tmp file. Both
# actions below reclaim only things docker can recreate.
_disk_pct() { df -P "$DOCKER_ROOT" 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5+0}'; }

heal_disk() {   # now
	local t="$1" pct; pct="$(_disk_pct)"
	[[ -n "$pct" ]] || return 0
	local lbl="mount=\"$DOCKER_ROOT\""
	_gauge partner_edge_disk_used_percent "$lbl" "$pct"
	(( pct < DISK_PCT )) && { _budget_clear disk; return 0; }

	_held disk && { log "disk at ${pct}%, but a hold file is present — not acting"; return 0; }
	_budget_gate disk "$DISK_MAX" "$DISK_WINDOW" "$DISK_GAP" "$t" "$lbl" \
		"partner-edge $(hostname): GAVE UP reclaiming disk — ${DOCKER_ROOT} still at ${pct}% after $DISK_MAX prunes. This needs a human; nothing else on this node can recover from a full disk." \
		|| return 0

	log "disk at ${pct}% (>= ${DISK_PCT}%) — reclaiming"
	_budget_spend disk "$t"
	if [[ "$DRY_RUN" == 1 ]]; then
		log "[dry-run] docker image prune -f; docker builder prune -f --filter until=168h"
		return 0
	fi

	# Dangling images first: unreferenced by definition, so nothing that is
	# running or tagged can be affected.
	timeout 120 docker image prune -f >/dev/null 2>&1
	pct="$(_disk_pct)"
	if (( pct >= DISK_PCT )); then
		# Then build cache older than a week. rvpn shares this daemon with a
		# neighbouring project, so this is scoped by AGE rather than pruning
		# everything — the cost of a miss is a slower rebuild, never a loss.
		log "disk still at ${pct}% after image prune — pruning build cache older than 7d"
		timeout 120 docker builder prune -f --filter until=168h >/dev/null 2>&1
		pct="$(_disk_pct)"
	fi
	_gauge partner_edge_disk_used_percent "$lbl" "$pct"

	if (( pct < DISK_PCT )); then
		log "disk reclaimed to ${pct}%"
		_count partner_edge_selfheal_attempts_total "$lbl,outcome=\"healed\"" 1
		_budget_clear disk
	else
		log "disk still at ${pct}% after reclaim"
		_count partner_edge_selfheal_attempts_total "$lbl,outcome=\"failed\"" 1
	fi
}

main "$@"
