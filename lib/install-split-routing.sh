#!/usr/bin/env bash
# lib/install-split-routing.sh — CL-2: install split-routing scripts + systemd oneshot unit.
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
# Canon reference: §8 "Durability" in
#   ~/deploy/krolik-server/plans/oxpulse-partner-edge/2026-05-27-split-routing-settings-canon.md
#
# Design notes (CL-2):
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
#   - EXPECTED_SBIN_FILES is updated in install-systemd.sh where it lives (canonical location).
#     TODO(CL-3): caller must source install-split-routing.sh and invoke split_routing_run.

_SPLIT_ROUTING_UNIT=oxpulse-partner-edge-split-routing.service

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

# Public entry point — orchestrates the split-routing install.
# Idempotent: safe to re-run (install -m is atomic; unit file is overwritten; enable is no-op
# if already enabled).
split_routing_run() {
	log "[split-routing] installing split-routing scripts and systemd unit"
	if [[ "${DRY_RUN:-0}" -eq 0 ]]; then
		_split_routing_install_scripts
		_split_routing_install_unit
		_split_routing_enable_unit
	else
		warn "  [dry-run] skipping split-routing install"
	fi
}
