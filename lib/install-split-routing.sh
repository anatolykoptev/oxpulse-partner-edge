#!/usr/bin/env bash
# lib/install-split-routing.sh — CL-2 + CL-3: install split-routing scripts + systemd units.
#
# Exports: split_routing_run
#
# Requires (caller globals):
#   DRY_RUN          int, skip side-effecting branches when 1
#   BAKE_MODE        string, "0" = full install, "1" = bake/snapshot mode
#   src_dir          string, local checkout dir (empty when curl|bash)
#   REPO_RAW         string, raw GitHub URL base for fallback fetches
#   PREFIX_SBIN      path, e.g. /usr/local/sbin
#   SYSTEMD_DIR      path, e.g. /etc/systemd/system
#   log warn die     functions (install.sh provides)
#
# Canon reference: §8 "Durability" + §1 "RU-subnets feed" in
#   ~/deploy/krolik-server/plans/oxpulse-partner-edge/2026-05-27-split-routing-settings-canon.md
#
# Design notes:
#   CL-2:
#   - Scripts are installed SUFFIXLESS (oxpulse-partner-edge-split-routing,
#     oxpulse-partner-edge-split-disable) — consistent with the convention used
#     for all other executables in $PREFIX_SBIN (upgrade, refresh, sni-rotate, etc.).
#     Only sourced *libraries* retain the .sh suffix.
#   - ExecReload= is omitted (task spec scope; canon §8 includes it — noted as ambiguity).
#   - enable without --now (BAKE_MODE-aware) per the IR-5 lesson: enable exit=0 does NOT
#     guarantee the unit is active; --now on a oneshot with After= awg-quick@awg0 would
#     block until the awg interface exists. Verification uses is-enabled + is-active/status.
#   - ConditionPathExists= guards prevent the unit from failing at boot when the
#     ru-subnets list or awg conf have not yet been provisioned (CL-3 provisions them).
#     systemd SKIPS (not FAILs) when a ConditionPathExists= path is absent.
#   CL-3:
#   - oxpulse-partner-edge-ru-subnets-update installed SUFFIXLESS to PREFIX_SBIN.
#   - service + timer units installed from systemd/ dir.
#   - Timer enabled (not --now; daemon-reload runs before enable; IR-5 verify).
#   - Feed run once at install time (seeds ru-subnets.txt for ConditionPathExists).
#     Soft-fail: RU edges may be ТСПУ-throttled; warn + continue; timer retries on boot.
#   - BAKE_MODE: skips feed-once (no network during image bake; timer fires at first boot).
#   - EXPECTED_SBIN_FILES updated in install-systemd.sh (canonical location for that list).

_SPLIT_ROUTING_UNIT=oxpulse-partner-edge-split-routing.service
_SUBNETS_UPDATE_SCRIPT=oxpulse-partner-edge-ru-subnets-update
_SUBNETS_UPDATE_SERVICE=oxpulse-partner-edge-ru-subnets-update.service
_SUBNETS_UPDATE_TIMER=oxpulse-partner-edge-ru-subnets-update.timer

# ─── CL-2: apply + disable scripts ──────────────────────────────────────────

# Install CL-1's apply and disable scripts to $PREFIX_SBIN (suffixless — matches
# the sbin executable convention; see install-systemd.sh _systemd_install_helper_scripts).
# Prefers local src_dir copies; falls back to REPO_RAW.
_split_routing_install_scripts() {
	local _apply_src _disable_src
	local _apply_dst="${PREFIX_SBIN}/oxpulse-partner-edge-split-routing"
	local _disable_dst="${PREFIX_SBIN}/oxpulse-partner-edge-split-disable"

	# Apply script
	if [[ -n "${src_dir:-}" && -f "${src_dir}/oxpulse-partner-edge-split-routing.sh" ]]; then
		_apply_src="${src_dir}/oxpulse-partner-edge-split-routing.sh"
		install -m 0755 "$_apply_src" "$_apply_dst"
	else
		curl -fsSL --proto '=https' --tlsv1.2 --max-time 60 \
			"${REPO_RAW}/oxpulse-partner-edge-split-routing.sh" -o "$_apply_dst" \
			|| die "split-routing: failed to fetch apply script from REPO_RAW"
		chmod 0755 "$_apply_dst"
	fi

	# Disable script
	if [[ -n "${src_dir:-}" && -f "${src_dir}/oxpulse-partner-edge-split-disable.sh" ]]; then
		_disable_src="${src_dir}/oxpulse-partner-edge-split-disable.sh"
		install -m 0755 "$_disable_src" "$_disable_dst"
	else
		curl -fsSL --proto '=https' --tlsv1.2 --max-time 60 \
			"${REPO_RAW}/oxpulse-partner-edge-split-disable.sh" -o "$_disable_dst" \
			|| die "split-routing: failed to fetch disable script from REPO_RAW"
		chmod 0755 "$_disable_dst"
	fi
}

# Render and install the systemd oneshot unit.
# Rendered to a tmp file then installed at mode 0644 (mirrors install-awg-params-agent.sh
# convention) — guarantees mode regardless of umask.
#
# After= ordering (canon §8): awg-quick@awg0.service THEN oxpulse-awg-params-agent.service
# so the unit re-asserts AllowedIPs/FwMark AFTER the federation agent applies at boot.
#
# ConditionPathExists= guards (CL-2 review):
#   - ru-subnets.txt: apply script hard-exits if absent; ConditionPathExists makes systemd
#     skip (not fail) the unit at boot until CL-3 provisions the file.
#   - awg0.conf: awg set / route ops fail if awg0 is unconfigured; same skip logic.
_split_routing_install_unit() {
	local _unit_dst="${SYSTEMD_DIR}/${_SPLIT_ROUTING_UNIT}"
	local _unit_tmp
	_unit_tmp="$(mktemp /tmp/${_SPLIT_ROUTING_UNIT}.XXXXXX)"
	cat > "$_unit_tmp" <<UNIT
[Unit]
Description=OxPulse partner-edge selective split-routing (user.slice -> mesh)
After=network-online.target awg-quick@awg0.service oxpulse-awg-params-agent.service
Wants=network-online.target
ConditionPathExists=/etc/oxpulse-partner-edge/ru-subnets.txt
ConditionPathExists=/etc/amnezia/amneziawg/awg0.conf

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${PREFIX_SBIN}/oxpulse-partner-edge-split-routing

[Install]
WantedBy=multi-user.target
UNIT
	install -m 0644 "$_unit_tmp" "$_unit_dst"
	rm -f "$_unit_tmp"
}

# Enable the unit and verify it is enabled (IR-5 lesson: enable exit=0 ≠ active).
# BAKE_MODE=1: enable only, no --now (interface not yet up; unit fires at first boot).
# BAKE_MODE=0: enable + verify is-enabled + log a warning if not-active but do not die
#              (active state requires awg0 to be up, which may not be true at install time).
_split_routing_enable_unit() {
	systemctl daemon-reload

	if [[ "${BAKE_MODE:-0}" == "0" ]]; then
		systemctl enable "${_SPLIT_ROUTING_UNIT}"
		# IR-5 lesson: always verify is-enabled; enable exit=0 is not sufficient.
		local _enabled_state
		_enabled_state=$(systemctl is-enabled "${_SPLIT_ROUTING_UNIT}" 2>/dev/null || true)
		if [[ "$_enabled_state" != "enabled" ]]; then
			warn "  split-routing: unit may not be enabled — is-enabled returned: ${_enabled_state}"
			warn "  check: systemctl status ${_SPLIT_ROUTING_UNIT}"
		else
			log "  split-routing: unit enabled (is-enabled=enabled)"
		fi
		# Activity check: a oneshot with After= awg-quick@awg0 will not be active
		# until the interface is up. Warn, do not die — this is normal at install time.
		if ! systemctl is-active --quiet "${_SPLIT_ROUTING_UNIT}" 2>/dev/null; then
			log "  split-routing: unit not yet active (normal at install: awg0 may not be up)"
			log "  unit will assert at next boot or via: systemctl start ${_SPLIT_ROUTING_UNIT}"
		fi
	else
		# Bake mode: enable only; do NOT start (secrets/interface not present in snapshot)
		systemctl enable "${_SPLIT_ROUTING_UNIT}"
		log "  [bake] ${_SPLIT_ROUTING_UNIT} enabled for first boot; not started"
		# Still verify is-enabled in bake mode
		local _enabled_state
		_enabled_state=$(systemctl is-enabled "${_SPLIT_ROUTING_UNIT}" 2>/dev/null || true)
		if [[ "$_enabled_state" != "enabled" ]]; then
			warn "  split-routing: unit may not be enabled in bake mode — is-enabled: ${_enabled_state}"
		fi
	fi
}

# ─── CL-3: RU-subnet feed subsystem ─────────────────────────────────────────

# Install the RU-subnets update script to $PREFIX_SBIN (suffixless — matches sbin convention).
# Prefers local src_dir copy; falls back to REPO_RAW.
_subnets_update_install_script() {
	local _dst="${PREFIX_SBIN}/${_SUBNETS_UPDATE_SCRIPT}"

	if [[ -n "${src_dir:-}" && -f "${src_dir}/${_SUBNETS_UPDATE_SCRIPT}" ]]; then
		install -m 0755 "${src_dir}/${_SUBNETS_UPDATE_SCRIPT}" "$_dst"
	else
		curl -fsSL --proto '=https' --tlsv1.2 --max-time 60 \
			"${REPO_RAW}/${_SUBNETS_UPDATE_SCRIPT}" -o "$_dst" \
			|| die "split-routing: failed to fetch update script from REPO_RAW"
		chmod 0755 "$_dst"
	fi
}

# Install service + timer unit files from the repo's systemd/ directory.
# mode 0644 — consistent with all other unit installs in this module.
_subnets_update_install_units() {
	local _svc_dst="${SYSTEMD_DIR}/${_SUBNETS_UPDATE_SERVICE}"
	local _tmr_dst="${SYSTEMD_DIR}/${_SUBNETS_UPDATE_TIMER}"

	if [[ -n "${src_dir:-}" && -f "${src_dir}/systemd/${_SUBNETS_UPDATE_SERVICE}" ]]; then
		install -m 0644 "${src_dir}/systemd/${_SUBNETS_UPDATE_SERVICE}" "$_svc_dst"
	else
		curl -fsSL --proto '=https' --tlsv1.2 --max-time 60 \
			"${REPO_RAW}/systemd/${_SUBNETS_UPDATE_SERVICE}" -o "$_svc_dst" \
			|| die "split-routing: failed to fetch update service unit from REPO_RAW"
	fi

	if [[ -n "${src_dir:-}" && -f "${src_dir}/systemd/${_SUBNETS_UPDATE_TIMER}" ]]; then
		install -m 0644 "${src_dir}/systemd/${_SUBNETS_UPDATE_TIMER}" "$_tmr_dst"
	else
		curl -fsSL --proto '=https' --tlsv1.2 --max-time 60 \
			"${REPO_RAW}/systemd/${_SUBNETS_UPDATE_TIMER}" -o "$_tmr_dst" \
			|| die "split-routing: failed to fetch update timer unit from REPO_RAW"
	fi
}

# Enable the daily timer and verify with is-enabled + is-active (IR-5 lesson).
# daemon-reload is called by _split_routing_enable_unit before this runs.
# No --now: the timer fires on its schedule; no network-dependent side-effects at enable time.
# IR-5 lesson (feedback_systemctl_enable_not_running): for a .timer unit, is-enabled alone
# is insufficient — a hard Requires= on a missing unit drops the timer to inactive(dead)
# silently.  Always verify is-active as well.  (This timer has no Requires=, so the risk
# is narrow, but the verify pattern is mandated by the lesson.)
_subnets_update_enable_timer() {
	systemctl enable "${_SUBNETS_UPDATE_TIMER}"
	# IR-5: always verify is-enabled; enable exit=0 is not sufficient.
	local _enabled_state
	_enabled_state=$(systemctl is-enabled "${_SUBNETS_UPDATE_TIMER}" 2>/dev/null || true)
	if [[ "$_enabled_state" != "enabled" ]]; then
		warn "  split-routing: timer may not be enabled — is-enabled returned: ${_enabled_state}"
		warn "  check: systemctl status ${_SUBNETS_UPDATE_TIMER}"
	else
		log "  split-routing: ${_SUBNETS_UPDATE_TIMER} enabled"
	fi
	# IR-5: for .timer units, is-enabled ≠ running (lesson: feedback_systemctl_enable_not_running).
	# is-active catches the case where the timer dropped to inactive(dead) despite enable exit=0.
	if ! systemctl is-active --quiet "${_SUBNETS_UPDATE_TIMER}" 2>/dev/null; then
		warn "  split-routing: timer not yet active (normal if daemon-reload pending or at bake time)"
		warn "  verify: systemctl list-timers --all | grep ${_SUBNETS_UPDATE_TIMER}"
	else
		log "  split-routing: ${_SUBNETS_UPDATE_TIMER} active"
	fi
}

# Run the feed once at install time so /etc/oxpulse-partner-edge/ru-subnets.txt exists
# before the split-routing unit's ConditionPathExists= check at first boot.
#
# Soft-fail design: RU edges run in system.slice (direct/unmarked egress), which may be
# ТСПУ-throttled at install time.  A failed fetch warns but does NOT abort the install —
# the weekly timer (Persistent=true) will retry on the next network-available boot.
#
# Skipped in BAKE_MODE (network absent during image bake; stale data worse than no data).
_subnets_update_run_once() {
	if [[ "${BAKE_MODE:-0}" == "1" ]]; then
		log "  [bake] skipping feed-once (no network in bake; timer fires on first boot)"
		return 0
	fi

	log "  split-routing: seeding RU-subnet list (first feed run)"
	if "${PREFIX_SBIN}/${_SUBNETS_UPDATE_SCRIPT}" 2>&1; then
		log "  split-routing: initial feed succeeded"
	else
		warn "  split-routing: initial feed failed (ТСПУ throttle or network unavailable at install)"
		warn "  split-routing: weekly timer will retry; split-routing unit will skip until file present"
	fi
}

# ─── Public entry point ───────────────────────────────────────────────────────

# split_routing_run — orchestrates the full split-routing install (CL-2 + CL-3).
#
# Install order:
#   1. CL-2 scripts (apply, disable) → PREFIX_SBIN
#   2. CL-2 split-routing unit → SYSTEMD_DIR
#   3. CL-3 update script → PREFIX_SBIN
#   4. CL-3 service + timer units → SYSTEMD_DIR
#   5. daemon-reload + enable split-routing unit (CL-2)
#   6. enable timer (CL-3) — daemon-reload already done in step 5
#   7. run feed once (CL-3, soft-fail, skipped in BAKE_MODE)
#
# Idempotent: safe to re-run (install -m is atomic; unit files overwritten; enable is no-op).
split_routing_run() {
	log "[split-routing] installing split-routing scripts and systemd units"
	if [[ "${DRY_RUN:-0}" -eq 0 ]]; then
		# CL-2: apply/disable scripts + split-routing unit
		_split_routing_install_scripts
		_split_routing_install_unit
		# CL-3: update script + service/timer units
		_subnets_update_install_script
		_subnets_update_install_units
		# Enable units (daemon-reload inside _split_routing_enable_unit covers CL-3 units too)
		_split_routing_enable_unit
		_subnets_update_enable_timer
		# Seed the RU-subnet list (soft-fail; skipped in BAKE_MODE)
		_subnets_update_run_once
	else
		warn "  [dry-run] skipping split-routing install"
	fi
}
