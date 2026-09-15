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
#   OXPULSE_RELEASE_TAG      string, installer's own release tag (vX.Y.Z);
#                          install.sh defaults it to the @RELEASE_TAG@
#                          placeholder that release.yml substitutes at publish
#   OXPULSE_RELEASES_BASE    string, optional test/operator override for the
#                          release-asset base (same name as upgrade.sh's)
#   OXPULSE_MIRROR_BASE      string, optional plain-TLS mirror base; the mirror
#                          contract is tag-pinned layout ($MIRROR/<tag>/<asset>)
#   log warn die     functions (install.sh provides)

_AWG_PARAMS_AGENT_BIN=/usr/local/bin/oxpulse-awg-params-agent
_AWG_PARAMS_AGENT_UNIT=oxpulse-awg-params-agent.service

# _awg_params_agent_release_arch — uname -m → release-asset arch token
# (amd64|arm64); returns 1 on anything else. SINGLE AUTHORITY for this map:
# lib/host-scripts-lib.sh's _host_script_asset_arch (the upgrade-path asset
# step that refreshes this binary) mirrors these case arms verbatim — it
# cannot source this lib on an upgrade-only box (this file is not a
# _stage_lib target and _install_lib_source does not persist it), so
# tests/test_sync_asset_delivery.sh pins the two copies identical. A third
# copy must never appear: upgrade.sh:280-283 records the resolver-drift
# incident that is the standing lesson on parallel resolvers.
_awg_params_agent_release_arch() {
	case "$(uname -m)" in
		x86_64)  printf 'amd64\n' ;;
		aarch64) printf 'arm64\n' ;;
		*) return 1 ;;
	esac
}

# Install the pre-built binary from the release bundle or the pinned,
# SHA256SUMS-verified release asset. Mirrors the _ensure_opec_binary pattern
# in install.sh.
#
# FAIL-SOFT contract (returns 1, never dies, on the network path): the AWG
# channel is optional — a binary that cannot be delivered VERIFIED must not
# abort the enclosing install, and must never be installed unverified. The
# caller (awg_params_agent_run) gates unit enablement on the binary actually
# landing, so a skipped install leaves the unit file on disk but disabled —
# sync_host_scripts' asset step then delivers the verified binary on the
# next tagged upgrade (the unit's presence is exactly its gate).
_awg_params_agent_install_binary() {
	local _arch _asset _dest _bundled
	if ! _arch=$(_awg_params_agent_release_arch); then
		# Was die(): an arch with no release asset cannot hard-fail the
		# optional AWG channel out of an otherwise-good install.
		warn "awg-params-agent: unsupported architecture: $(uname -m) — no release asset exists; skipping binary install"
		return 1
	fi
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

	# ---- network fallback: PINNED to the installer's own tag + verified ----
	#
	# Was: releases/latest/download (plus an OXPULSE_MIRROR_BASE flat fetch) —
	# unpinned (a newer-than-the-installer build could land silently) and
	# UNVERIFIED (no checksum at all). Flagged "pre-existing, not fixed" in the
	# AWG-3.1 draft; the security review reversed that deferral IN this change
	# because this work is what makes the binary security-critical: it is a
	# User=root daemon that writes awg0.conf and pipes it into `awg syncconf`,
	# soon carrying HeaderProtectionKey and must-match params to the kernel.
	#
	# Tag channel: OXPULSE_RELEASE_TAG — install.sh defaults it to the
	# @RELEASE_TAG@ placeholder that release.yml substitutes with the real tag
	# at publish. The ^v[0-9]+\. form check is the same idiom install.sh uses
	# for its REPO_RAW pinning: an unsubstituted placeholder (dev checkout,
	# curl|bash from main) does not match, so we SKIP — fail-soft, never an
	# unverified install. No AWG_PARAMS_AGENT_REF env is needed: the tag
	# channel exists.
	local _tag="${OXPULSE_RELEASE_TAG:-}"
	if [[ ! "$_tag" =~ ^v[0-9]+\. ]]; then
		warn "awg-params-agent: no pinned release tag (OXPULSE_RELEASE_TAG='${_tag:-<unset>}') — skipping network install; a bundled binary or a released (tag-pinned) installer is required (root-daemon bytes are never installed unverified)"
		return 1
	fi
	# Base polarity mirrors upgrade.sh's RELEASES_BASE resolution:
	# OXPULSE_RELEASES_BASE (test/operator override) > OXPULSE_MIRROR_BASE
	# (whose contract is the tag-pinned $MIRROR/<tag>/<asset> layout) >
	# GitHub releases/download.
	local _rel_base
	if [[ -n "${OXPULSE_RELEASES_BASE:-}" ]]; then
		_rel_base="$OXPULSE_RELEASES_BASE"
	elif [[ -n "${OXPULSE_MIRROR_BASE:-}" ]]; then
		_rel_base="$OXPULSE_MIRROR_BASE"
	else
		_rel_base="https://github.com/anatolykoptev/oxpulse-partner-edge/releases/download"
	fi

	# Same field-exact manifest lookup idiom as upgrade.sh's
	# _lookup_expected_hash and host-scripts-lib.sh's _lookup_sha256
	# (column-2 equality, optional ./ prefix — a suffix match would resolve
	# the wrong entry; the resolvers must agree — upgrade.sh:280-283 records
	# what happened when two of them didn't).
	local _sums _bintmp _expected _actual _fail=""
	_sums=$(mktemp); _bintmp=$(mktemp)
	if ! curl -fsSL --proto '=https' --tlsv1.2 --max-time 30 \
		"$_rel_base/$_tag/SHA256SUMS" -o "$_sums" 2>/dev/null; then
		_fail="could not fetch $_rel_base/$_tag/SHA256SUMS (nothing to verify against)"
	else
		_expected=$(awk -v n="$_asset" '$2 == n || $2 == "./" n { print $1; exit }' \
			"$_sums" 2>/dev/null)
		if [[ -z "$_expected" ]]; then
			_fail="no SHA256SUMS entry for $_asset at tag $_tag"
		elif ! curl -fsSL --proto '=https' --tlsv1.2 --max-time 60 \
			"$_rel_base/$_tag/$_asset" -o "$_bintmp" 2>/dev/null; then
			_fail="download failed from $_rel_base/$_tag/$_asset — check network/mirror reachability"
		else
			_actual=$(sha256sum "$_bintmp" | awk '{print $1}')
			if [[ "$_actual" != "$_expected" ]]; then
				_fail="SHA256 MISMATCH for $_asset @ $_tag (expected=$_expected actual=$_actual) — possible MITM or stale mirror"
			elif ! install -m 0755 "$_bintmp" "$_dest"; then
				_fail="install failed: $_bintmp -> $_dest"
			fi
		fi
	fi
	rm -f "$_sums" "$_bintmp"
	if [[ -n "$_fail" ]]; then
		warn "awg-params-agent: $_fail — skipping binary install (fail-soft; sync_host_scripts' asset step delivers the verified binary on the next tagged upgrade)"
		return 1
	fi
	log "  awg-params-agent: installed verified release binary ($_arch @ $_tag)"
	return 0
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
		local _bin_landed=0
		if _awg_params_agent_install_binary; then _bin_landed=1; fi
		_awg_params_agent_install_unit
		_awg_params_agent_render_env
		# Enable ONLY when a binary is actually on disk — either just
		# installed or left by a previous install. Enabling a unit whose
		# ExecStart is absent would flap forever under Restart=on-failure; a
		# binary-less node stays correctly dormant instead. The unit file is
		# still installed + env rendered above on purpose: unit presence is
		# the gate sync_host_scripts' asset step uses, so the verified binary
		# lands on the next tagged upgrade (Step 5d in
		# lib/host-scripts-lib.sh). Activation after that delivery is a
		# subsequent installer re-run or operator `systemctl enable --now` —
		# the Step 7 restart only fires for already-active units, which a
		# never-enabled unit is not.
		if [[ "$_bin_landed" -eq 1 || -f "$_AWG_PARAMS_AGENT_BIN" ]]; then
			_awg_params_agent_enable
			_awg_params_agent_smoke
		else
			warn "  awg-params-agent: no binary installed (see above) — unit file present but NOT enabled; sync_host_scripts delivers the verified binary on the next tagged upgrade"
		fi
	else
		warn "  [dry-run] skipping awg-params-agent install"
	fi
}
