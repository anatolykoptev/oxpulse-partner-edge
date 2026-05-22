#!/usr/bin/env bash
# lib/install-awg-params-agent.sh — T1.3.f: install oxpulse-awg-params-agent
#   binary, systemd unit, env file, and state directory.
#
# Exports: awg_params_agent_run
#
# Requires (caller globals):
#   DRY_RUN          int, skip side-effecting branches when 1
#   BAKE_MODE        string, "0" = full install, "1" = bake/snapshot mode
#   src_dir          string, local checkout dir (empty when curl|bash)
#   REPO_RAW         string, raw GitHub URL base for fallback fetches
#   SYSTEMD_DIR      path, e.g. /etc/systemd/system
#   PREFIX_ETC       path, e.g. /etc/oxpulse-partner-edge
#   PREFIX_LIB       path, e.g. /var/lib/oxpulse-partner-edge
#   BACKEND_API      string, e.g. https://api.oxpulse.chat (central URL)
#   NODE_ID          string, partner node identifier
#   log warn die     functions (install.sh provides)

_AWG_PARAMS_AGENT_BIN=/usr/local/bin/oxpulse-awg-params-agent
_AWG_PARAMS_AGENT_UNIT=oxpulse-awg-params-agent.service

# Install the pre-built binary from the release bundle or REPO_RAW release assets.
# Mirrors the _ensure_opec_binary pattern in install.sh.
_awg_params_agent_install_binary() {
	local _machine _arch _asset _dest _bundled
	_machine=$(uname -m)
	case "$_machine" in
		x86_64)  _arch=amd64 ;;
		aarch64) _arch=arm64 ;;
		*) die "awg-params-agent: unsupported architecture: $_machine" ;;
	esac
	_asset="oxpulse-awg-params-agent-${_arch}"
	_dest="$_AWG_PARAMS_AGENT_BIN"

	# Prefer bundled binary from checkout root (src_dir) — set when install.sh
	# runs from a local git checkout rather than curl|bash.
	_bundled=""
	if [[ -n "${src_dir:-}" && -f "${src_dir}/${_asset}" ]]; then
		_bundled="${src_dir}/${_asset}"
	fi
	# Release bundle flat layout: installer + binaries sit in the same directory
	# as install.sh. Use INSTALL_SH_DIR (exported by install.sh near src_dir
	# setup) instead of BASH_SOURCE[1] which resolves to this lib file, not
	# to install.sh itself.
	if [[ -z "$_bundled" && -n "${INSTALL_SH_DIR:-}" ]]; then
		if [[ -f "${INSTALL_SH_DIR}/${_asset}" ]]; then
			_bundled="${INSTALL_SH_DIR}/${_asset}"
		fi
	fi

	if [[ -n "$_bundled" ]]; then
		log "  awg-params-agent: installing bundled binary ($_arch)"
		install -m 0755 "$_bundled" "$_dest" \
			|| die "awg-params-agent: install failed: $_bundled -> $_dest"
		return 0
	fi

	# Fall back to release asset download from GitHub releases.
	local _url="https://github.com/anatolykoptev/oxpulse-partner-edge/releases/latest/download/${_asset}"
	log "  awg-params-agent: downloading release binary ($_arch) from releases"
	if curl -fsSL --proto '=https' --tlsv1.2 --max-time 60 "$_url" -o "$_dest" 2>/dev/null; then
		chmod 0755 "$_dest"
	else
		rm -f "$_dest"
		die "awg-params-agent: binary download failed from $_url — check network connectivity to GitHub releases"
	fi
}

# Install the systemd unit file (no placeholder substitution needed).
_awg_params_agent_install_unit() {
	if [[ -n "${src_dir:-}" && -f "${src_dir}/systemd/${_AWG_PARAMS_AGENT_UNIT}" ]]; then
		install -m 0644 "${src_dir}/systemd/${_AWG_PARAMS_AGENT_UNIT}" \
			"${SYSTEMD_DIR}/${_AWG_PARAMS_AGENT_UNIT}"
	else
		curl -fsSL --proto '=https' --tlsv1.2 --max-time 60 \
			"${REPO_RAW}/systemd/${_AWG_PARAMS_AGENT_UNIT}" \
			-o "${SYSTEMD_DIR}/${_AWG_PARAMS_AGENT_UNIT}" \
			|| die "awg-params-agent: failed to fetch unit from REPO_RAW"
	fi
}

# Render /etc/oxpulse-partner-edge/awg-params-agent.env.
# BACKEND_API and NODE_ID are set by install.sh before awg_params_agent_run fires.
_awg_params_agent_render_env() {
	local _env_file="${PREFIX_ETC}/awg-params-agent.env"
	cat > "$_env_file" <<ENV
OXPULSE_CENTRAL_URL=${BACKEND_API}
OXPULSE_NODE_ID=${NODE_ID}
OXPULSE_SERVICE_TOKEN_PATH=${PREFIX_ETC}/token
OXPULSE_AWG_CONF_PATH=/etc/amnezia/amneziawg/awg0.conf
OXPULSE_AWG_IFACE=awg0
OXPULSE_STATE_PATH=${PREFIX_LIB}/awg-params-state.json
OXPULSE_POLL_INTERVAL=30s
ENV
	chmod 0640 "$_env_file"
}

# Ensure the state directory exists (idempotent).
_awg_params_agent_state_dir() {
	install -d -m 0755 "$PREFIX_LIB"
}

# Enable the systemd unit.
# BAKE_MODE = enable only (no --now) to avoid starting before secrets exist.
# Full install = enable --now.
_awg_params_agent_enable() {
	systemctl daemon-reload
	if [[ "${BAKE_MODE:-0}" == "0" ]]; then
		systemctl enable --now "$_AWG_PARAMS_AGENT_UNIT"
	else
		systemctl enable "$_AWG_PARAMS_AGENT_UNIT"
		log "  [bake] ${_AWG_PARAMS_AGENT_UNIT} enabled for first boot; not started"
	fi
}

# Post-install smoke: warn (not die) if agent is not active within 10s.
# Token rotation lag and network delays are expected on first install.
_awg_params_agent_smoke() {
	[[ "$BAKE_MODE" != "0" ]] && return 0
	local _i
	for _i in 1 2 3 4 5; do
		if systemctl is-active --quiet "$_AWG_PARAMS_AGENT_UNIT" 2>/dev/null; then
			log "  awg-params-agent: active"
			return 0
		fi
		sleep 2
	done
	warn "  awg-params-agent: not yet active after 10s — check: journalctl -u ${_AWG_PARAMS_AGENT_UNIT} -n 50"
	warn "  this is normal if token rotation is pending or network is slow; agent will retry"
}

# Public entry point — orchestrates the awg-params-agent install.
awg_params_agent_run() {
	log "[8b/10] installing awg-params-agent"
	if [[ $DRY_RUN -eq 0 ]]; then
		_awg_params_agent_state_dir
		_awg_params_agent_install_binary
		_awg_params_agent_install_unit
		_awg_params_agent_render_env
		_awg_params_agent_enable
		_awg_params_agent_smoke
	else
		warn "  [dry-run] skipping awg-params-agent install"
	fi
}
