#!/usr/bin/env bash
# lib/install-systemd.sh — Phase 4.7 extracted from install.sh Step 8.
#
# Exports: systemd_run
#
# Requires (caller globals):
#   DRY_RUN          int, skip side-effecting branches when 1
#   src_dir          string, local checkout dir (empty when curl|bash)
#   REPO_RAW         string, raw GitHub URL base for fallback fetches
#   PREFIX_SBIN      path, e.g. /usr/local/sbin
#   SYSTEMD_DIR      path, e.g. /etc/systemd/system
#   BAKE_MODE        string, "0" = full install, "1" = bake/snapshot mode
#   TURNS_SUBDOMAIN  string, e.g. api-test01
#   DOMAIN           string, e.g. example.net
#   _chan_lib_tmp    string (optional), temp path to pre-fetched channel-render-lib.sh
#   log warn die     functions (install.sh provides)

# Install upgrade.sh, hydrate.sh, refresh.sh, sni-rotate.sh, channels-health-report.sh
# into $PREFIX_SBIN.
_systemd_install_helper_scripts() {
	# upgrade.sh
	if [[ -n "$src_dir" && -f "$src_dir/upgrade.sh" ]]; then
		install -m 0755 "$src_dir/upgrade.sh" "$PREFIX_SBIN/oxpulse-partner-edge-upgrade"
	else
		curl -fsSL "$REPO_RAW/upgrade.sh" -o "$PREFIX_SBIN/oxpulse-partner-edge-upgrade"
		chmod 0755 "$PREFIX_SBIN/oxpulse-partner-edge-upgrade"
	fi

	# hydrate.sh (sentinel-gated; fires on first boot after clone)
	if [[ -n "$src_dir" && -f "$src_dir/hydrate.sh" ]]; then
		install -m 0755 "$src_dir/hydrate.sh" "$PREFIX_SBIN/oxpulse-partner-edge-hydrate"
	else
		curl -fsSL "$REPO_RAW/hydrate.sh" -o "$PREFIX_SBIN/oxpulse-partner-edge-hydrate"
		chmod 0755 "$PREFIX_SBIN/oxpulse-partner-edge-hydrate"
	fi

	# Auto-refresh script (daily check of /api/partner/keys for keypair rotation)
	if [[ -n "$src_dir" && -f "$src_dir/oxpulse-partner-edge-refresh.sh" ]]; then
		install -m 0755 "$src_dir/oxpulse-partner-edge-refresh.sh" "$PREFIX_SBIN/oxpulse-partner-edge-refresh"
	else
		curl -fsSL "$REPO_RAW/oxpulse-partner-edge-refresh.sh" -o "$PREFIX_SBIN/oxpulse-partner-edge-refresh"
		chmod 0755 "$PREFIX_SBIN/oxpulse-partner-edge-refresh"
	fi

	# SNI rotation script
	if [[ -n "$src_dir" && -f "$src_dir/oxpulse-partner-edge-sni-rotate.sh" ]]; then
		install -m 0755 "$src_dir/oxpulse-partner-edge-sni-rotate.sh" \
			"$PREFIX_SBIN/oxpulse-partner-edge-sni-rotate"
	else
		curl -fsSL "$REPO_RAW/oxpulse-partner-edge-sni-rotate.sh" \
			-o "$PREFIX_SBIN/oxpulse-partner-edge-sni-rotate"
		chmod 0755 "$PREFIX_SBIN/oxpulse-partner-edge-sni-rotate"
	fi

	# Per-channel health reporter (60s timer → POST /api/partner/channel-health)
	if [[ -n "$src_dir" && -f "$src_dir/oxpulse-channels-health-report.sh" ]]; then
		install -m 0755 "$src_dir/oxpulse-channels-health-report.sh" "$PREFIX_SBIN/oxpulse-channels-health-report"
	else
		curl -fsSL "$REPO_RAW/oxpulse-channels-health-report.sh" -o "$PREFIX_SBIN/oxpulse-channels-health-report"
		chmod 0755 "$PREFIX_SBIN/oxpulse-channels-health-report"
	fi

	# Bounded self-heal for a container that is UNHEALTHY but still running
	# (60s timer). restart: unless-stopped acts on container EXIT, not on a
	# failing healthcheck, so before this nothing restarted a wedged container:
	# cheburator sat dark 26h on 2026-08-10 reporting unhealthy the whole time.
	if [[ -n "$src_dir" && -f "$src_dir/oxpulse-partner-edge-selfheal.sh" ]]; then
		install -m 0755 "$src_dir/oxpulse-partner-edge-selfheal.sh" "$PREFIX_SBIN/oxpulse-partner-edge-selfheal"
	else
		curl -fsSL "$REPO_RAW/oxpulse-partner-edge-selfheal.sh" -o "$PREFIX_SBIN/oxpulse-partner-edge-selfheal"
		chmod 0755 "$PREFIX_SBIN/oxpulse-partner-edge-selfheal"
	fi
}

# Install channel-render-lib.sh, ghcr-auth-lib.sh, oxpulse-token-lib.sh
# into $PREFIX_SBIN.
_systemd_install_lib_scripts() {
	# Shared channel render library (sourced by upgrade.sh + refresh.sh).
	if [[ -n "$src_dir" && -f "$src_dir/channel-render-lib.sh" ]]; then
		install -m 0644 "$src_dir/channel-render-lib.sh" "$PREFIX_SBIN/channel-render-lib.sh"
	elif [[ -n "${_chan_lib_tmp:-}" && -f "$_chan_lib_tmp" ]]; then
		install -m 0644 "$_chan_lib_tmp" "$PREFIX_SBIN/channel-render-lib.sh"
		rm -f "$_chan_lib_tmp"
	else
		curl -fsSL "$REPO_RAW/channel-render-lib.sh" -o "$PREFIX_SBIN/channel-render-lib.sh"
		chmod 0644 "$PREFIX_SBIN/channel-render-lib.sh"
	fi

	# Shared SNI selection helper — sourced by channel-render-lib.sh (every
	# render) AND oxpulse-partner-edge-sni-rotate.sh (daily timer). Single
	# source of the sha256(node_id:date) mod pool_size arithmetic; co-installed
	# to PREFIX_SBIN so both callers resolve it as a sibling.
	if [[ -n "$src_dir" && -f "$src_dir/sni-select-lib.sh" ]]; then
		install -m 0644 "$src_dir/sni-select-lib.sh" "$PREFIX_SBIN/sni-select-lib.sh"
	else
		curl -fsSL "$REPO_RAW/sni-select-lib.sh" -o "$PREFIX_SBIN/sni-select-lib.sh"
		chmod 0644 "$PREFIX_SBIN/sni-select-lib.sh"
	fi

	# Phase 5.5 MAJOR 1: fail-soft render helpers (render_channel_soft, CHANNELS_FAILED,
	# compose_strip_failed_channels) — sourced by install.sh, hydrate.sh, update.sh, refresh.sh.
	# Bug 17 fix: install to BOTH PREFIX_SBIN (tier-3) and PREFIX_LIBDIR (tier-2) so that
	# install.sh's top-of-file resolver finds the file at _rl_installed on staged/operator
	# installs (where INSTALL_LIB_DIR=/usr/local/lib/partner-edge is pre-populated).
	# Bug 19 fix: triple-fallback for the source path so release-asset flat layout works:
	#   1. $src_dir/lib/render-channel-lib.sh   (git-clone / dev layout)
	#   2. $src_dir/render-channel-lib.sh       (release-asset flat layout — curl|bash)
	#   3. ${INSTALL_LIB_DIR}/render-channel-lib.sh (operator-staged ahead of install)
	#   else: curl from REPO_RAW
	install -d -m 0755 "$PREFIX_LIBDIR"
	_rcl_src=""
	if [[ -n "$src_dir" && -f "$src_dir/lib/render-channel-lib.sh" ]]; then
		_rcl_src="$src_dir/lib/render-channel-lib.sh"
	elif [[ -n "$src_dir" && -f "$src_dir/render-channel-lib.sh" ]]; then
		_rcl_src="$src_dir/render-channel-lib.sh"
	elif [[ -f "${INSTALL_LIB_DIR:-/usr/local/lib/partner-edge}/render-channel-lib.sh" ]]; then
		_rcl_src="${INSTALL_LIB_DIR:-/usr/local/lib/partner-edge}/render-channel-lib.sh"
	fi
	if [[ -n "$_rcl_src" ]]; then
		install -m 0644 "$_rcl_src" "$PREFIX_SBIN/render-channel-lib.sh"
		# Bug 8/10: when operator pre-stages the file into PREFIX_LIBDIR (workaround
		# for Bug R), _rcl_src == dst and `install` errors "are the same file".
		# Guard with -ef so same-file is a silent no-op.
		if [[ ! "$_rcl_src" -ef "$PREFIX_LIBDIR/render-channel-lib.sh" ]]; then
			install -m 0644 "$_rcl_src" "$PREFIX_LIBDIR/render-channel-lib.sh"
		fi
	else
		curl -fsSL "$REPO_RAW/lib/render-channel-lib.sh" -o "$PREFIX_SBIN/render-channel-lib.sh"
		chmod 0644 "$PREFIX_SBIN/render-channel-lib.sh"
		curl -fsSL "$REPO_RAW/lib/render-channel-lib.sh" -o "$PREFIX_LIBDIR/render-channel-lib.sh"
		chmod 0644 "$PREFIX_LIBDIR/render-channel-lib.sh"
	fi

	# GHCR auth lib (sourced by upgrade.sh)
	if [[ -n "$src_dir" && -f "$src_dir/ghcr-auth-lib.sh" ]]; then
		install -m 0644 "$src_dir/ghcr-auth-lib.sh" "$PREFIX_SBIN/ghcr-auth-lib.sh"
	else
		curl -fsSL "$REPO_RAW/ghcr-auth-lib.sh" -o "$PREFIX_SBIN/ghcr-auth-lib.sh"
		chmod 0644 "$PREFIX_SBIN/ghcr-auth-lib.sh"
	fi

	# Peer-IP-guard lib (SSRF / internal-IP classification) — sourced fail-
	# closed by oxpulse-channels-health-report.sh from PREFIX_SBIN at every
	# 60s tick (P1 of the 2026-07-08 health-report-lib-extraction plan).
	# Mirrors the telegram-alert-lib.sh block above exactly — same consumer
	# (oxpulse-channels-health-report.sh), same PREFIX_SBIN destination, same
	# 4-way src_dir/lib → src_dir/flat → operator-staged INSTALL_LIB_DIR →
	# curl fallback shape. Existing fleet nodes get this synced on upgrade via
	# upgrade.sh's separate _HOST_SCRIPT_SBIN_FILES array (this function only
	# covers fresh installs) — see that array's peer-ip-guard-lib.sh entry.
	if [[ -n "${src_dir:-}" && -f "$src_dir/lib/peer-ip-guard-lib.sh" ]]; then
		install -m 0755 "$src_dir/lib/peer-ip-guard-lib.sh" "$PREFIX_SBIN/peer-ip-guard-lib.sh"
	elif [[ -n "${src_dir:-}" && -f "$src_dir/peer-ip-guard-lib.sh" ]]; then
		install -m 0755 "$src_dir/peer-ip-guard-lib.sh" "$PREFIX_SBIN/peer-ip-guard-lib.sh"
	elif [[ -f "${INSTALL_LIB_DIR:-/usr/local/lib/partner-edge}/peer-ip-guard-lib.sh" ]]; then
		install -m 0755 "${INSTALL_LIB_DIR:-/usr/local/lib/partner-edge}/peer-ip-guard-lib.sh" \
			"$PREFIX_SBIN/peer-ip-guard-lib.sh"
	else
		curl -fsSL "$REPO_RAW/lib/peer-ip-guard-lib.sh" -o "$PREFIX_SBIN/peer-ip-guard-lib.sh"
		chmod 0755 "$PREFIX_SBIN/peer-ip-guard-lib.sh"
	fi

	# Service token lib (sourced by refresh.sh + any script calling authenticated
	# /api/partner/* endpoints)
	if [[ -n "$src_dir" && -f "$src_dir/oxpulse-token-lib.sh" ]]; then
		install -m 0644 "$src_dir/oxpulse-token-lib.sh" "$PREFIX_SBIN/oxpulse-token-lib.sh"
	else
		curl -fsSL "$REPO_RAW/oxpulse-token-lib.sh" -o "$PREFIX_SBIN/oxpulse-token-lib.sh"
		chmod 0644 "$PREFIX_SBIN/oxpulse-token-lib.sh"
	fi

	# Hy2 channel render lib (sourced by oxpulse-partner-edge-hydrate on
	# first-boot). 0644 (sourced, not executed). Same 4-way delivery tiers
	# as cross-probe-lib.sh; upgrade.sh syncs it to existing boxes via
	# _HOST_SCRIPT_SBIN_FILES.
	if [[ -n "${src_dir:-}" && -f "$src_dir/lib/hydrate-hy2.sh" ]]; then
		install -m 0644 "$src_dir/lib/hydrate-hy2.sh" "$PREFIX_SBIN/hydrate-hy2.sh"
	elif [[ -n "${src_dir:-}" && -f "$src_dir/hydrate-hy2.sh" ]]; then
		install -m 0644 "$src_dir/hydrate-hy2.sh" "$PREFIX_SBIN/hydrate-hy2.sh"
	elif [[ -f "${INSTALL_LIB_DIR:-/usr/local/lib/partner-edge}/hydrate-hy2.sh" ]]; then
		install -m 0644 "${INSTALL_LIB_DIR:-/usr/local/lib/partner-edge}/hydrate-hy2.sh" \
			"$PREFIX_SBIN/hydrate-hy2.sh"
	else
		curl -fsSL "$REPO_RAW/lib/hydrate-hy2.sh" -o "$PREFIX_SBIN/hydrate-hy2.sh"
		chmod 0644 "$PREFIX_SBIN/hydrate-hy2.sh"
	fi

	# Phase 5.8 Task 6: telegram-alert-lib.sh — shared rate-limited Telegram
	# alert primitive (used by oxpulse-channels-health-report.sh transition
	# detector + future per-channel watchdogs).
	if [[ -n "${src_dir:-}" && -f "$src_dir/lib/telegram-alert-lib.sh" ]]; then
		install -m 0755 "$src_dir/lib/telegram-alert-lib.sh" "$PREFIX_SBIN/telegram-alert-lib.sh"
	elif [[ -n "${src_dir:-}" && -f "$src_dir/telegram-alert-lib.sh" ]]; then
		install -m 0755 "$src_dir/telegram-alert-lib.sh" "$PREFIX_SBIN/telegram-alert-lib.sh"
	elif [[ -f "${INSTALL_LIB_DIR:-/usr/local/lib/partner-edge}/telegram-alert-lib.sh" ]]; then
		install -m 0755 "${INSTALL_LIB_DIR:-/usr/local/lib/partner-edge}/telegram-alert-lib.sh" \
			"$PREFIX_SBIN/telegram-alert-lib.sh"
	else
		curl -fsSL "$REPO_RAW/lib/telegram-alert-lib.sh" -o "$PREFIX_SBIN/telegram-alert-lib.sh"
		chmod 0755 "$PREFIX_SBIN/telegram-alert-lib.sh"
	fi

	# P2 strangler extraction (2026-07-08 plan): channel-health-lib.sh — E2E
	# channel probes + report/verdict logic sourced fail-closed by
	# oxpulse-channels-health-report.sh every 60s tick. Bears both externally-
	# depended wire contracts (see the lib's own header). Mirrors the
	# telegram-alert-lib.sh install pattern immediately above exactly.
	if [[ -n "${src_dir:-}" && -f "$src_dir/lib/channel-health-lib.sh" ]]; then
		install -m 0755 "$src_dir/lib/channel-health-lib.sh" "$PREFIX_SBIN/channel-health-lib.sh"
	elif [[ -n "${src_dir:-}" && -f "$src_dir/channel-health-lib.sh" ]]; then
		install -m 0755 "$src_dir/channel-health-lib.sh" "$PREFIX_SBIN/channel-health-lib.sh"
	elif [[ -f "${INSTALL_LIB_DIR:-/usr/local/lib/partner-edge}/channel-health-lib.sh" ]]; then
		install -m 0755 "${INSTALL_LIB_DIR:-/usr/local/lib/partner-edge}/channel-health-lib.sh" \
			"$PREFIX_SBIN/channel-health-lib.sh"
	else
		curl -fsSL "$REPO_RAW/lib/channel-health-lib.sh" -o "$PREFIX_SBIN/channel-health-lib.sh"
		chmod 0755 "$PREFIX_SBIN/channel-health-lib.sh"
	fi

	# P3b cross-probe lib — mesh peer-probe functions sourced by
	# oxpulse-channels-health-report.sh at runtime (strangler-fig extraction).
	# 0644 (sourced, not executed). Same delivery tiers as telegram-alert-lib.sh;
	# upgrade.sh syncs it to existing boxes via _HOST_SCRIPT_SBIN_FILES.
	if [[ -n "${src_dir:-}" && -f "$src_dir/lib/cross-probe-lib.sh" ]]; then
		install -m 0644 "$src_dir/lib/cross-probe-lib.sh" "$PREFIX_SBIN/cross-probe-lib.sh"
	elif [[ -n "${src_dir:-}" && -f "$src_dir/cross-probe-lib.sh" ]]; then
		install -m 0644 "$src_dir/cross-probe-lib.sh" "$PREFIX_SBIN/cross-probe-lib.sh"
	elif [[ -f "${INSTALL_LIB_DIR:-/usr/local/lib/partner-edge}/cross-probe-lib.sh" ]]; then
		install -m 0644 "${INSTALL_LIB_DIR:-/usr/local/lib/partner-edge}/cross-probe-lib.sh" \
			"$PREFIX_SBIN/cross-probe-lib.sh"
	else
		curl -fsSL "$REPO_RAW/lib/cross-probe-lib.sh" -o "$PREFIX_SBIN/cross-probe-lib.sh"
		chmod 0644 "$PREFIX_SBIN/cross-probe-lib.sh"
	fi

	# Metric-sink lib (P1 of the 2026-07-08 refresh-lib-extraction-strangler
	# plan) — emit_metric/emit_gauge Prometheus textfile sink sourced
	# fail-CLOSED by oxpulse-partner-edge-refresh.sh at every daily tick (no
	# safe inline fallback for emit_metric's load-bearing PR #328 fix). Same
	# delivery tier + 0644 mode as cross-probe-lib.sh directly above (sourced,
	# not executed); upgrade.sh syncs it to existing boxes via
	# _HOST_SCRIPT_SBIN_FILES.
	if [[ -n "${src_dir:-}" && -f "$src_dir/lib/metric-sink-lib.sh" ]]; then
		install -m 0644 "$src_dir/lib/metric-sink-lib.sh" "$PREFIX_SBIN/metric-sink-lib.sh"
	elif [[ -n "${src_dir:-}" && -f "$src_dir/metric-sink-lib.sh" ]]; then
		install -m 0644 "$src_dir/metric-sink-lib.sh" "$PREFIX_SBIN/metric-sink-lib.sh"
	elif [[ -f "${INSTALL_LIB_DIR:-/usr/local/lib/partner-edge}/metric-sink-lib.sh" ]]; then
		install -m 0644 "${INSTALL_LIB_DIR:-/usr/local/lib/partner-edge}/metric-sink-lib.sh" \
			"$PREFIX_SBIN/metric-sink-lib.sh"
	else
		curl -fsSL "$REPO_RAW/lib/metric-sink-lib.sh" -o "$PREFIX_SBIN/metric-sink-lib.sh"
		chmod 0644 "$PREFIX_SBIN/metric-sink-lib.sh"
	fi

	# Surgical-restart lib (P2 of the 2026-07-08 refresh-lib-extraction-
	# strangler plan) — the sha-diff-gated docker restart/recreate mechanism,
	# sourced fail-CLOSED by oxpulse-partner-edge-refresh.sh at every daily
	# tick (no safe inline fallback: a missing lib would leave channel/SFU
	# config changes silently un-applied forever). Same delivery tier + 0644
	# mode as metric-sink-lib.sh directly above (sourced, not executed);
	# upgrade.sh syncs it to existing boxes via _HOST_SCRIPT_SBIN_FILES.
	if [[ -n "${src_dir:-}" && -f "$src_dir/lib/surgical-restart-lib.sh" ]]; then
		install -m 0644 "$src_dir/lib/surgical-restart-lib.sh" "$PREFIX_SBIN/surgical-restart-lib.sh"
	elif [[ -n "${src_dir:-}" && -f "$src_dir/surgical-restart-lib.sh" ]]; then
		install -m 0644 "$src_dir/surgical-restart-lib.sh" "$PREFIX_SBIN/surgical-restart-lib.sh"
	elif [[ -f "${INSTALL_LIB_DIR:-/usr/local/lib/partner-edge}/surgical-restart-lib.sh" ]]; then
		install -m 0644 "${INSTALL_LIB_DIR:-/usr/local/lib/partner-edge}/surgical-restart-lib.sh" \
			"$PREFIX_SBIN/surgical-restart-lib.sh"
	else
		curl -fsSL "$REPO_RAW/lib/surgical-restart-lib.sh" -o "$PREFIX_SBIN/surgical-restart-lib.sh"
		chmod 0644 "$PREFIX_SBIN/surgical-restart-lib.sh"
	fi

	# Xprb-refresh lib (P3 of the 2026-07-08 refresh-lib-extraction-strangler
	# plan) — the cross-probe (xprb_) bearer-token daily re-mint leg, sourced
	# fail-CLOSED by oxpulse-partner-edge-refresh.sh at every daily tick (no
	# safe inline fallback: a missing lib would silently stop the daily
	# re-mint forever). Requires metric-sink-lib.sh to already be sourced
	# (refresh.sh enforces the order). Same delivery tier + 0644 mode as
	# surgical-restart-lib.sh directly above (sourced, not executed);
	# upgrade.sh syncs it to existing boxes via _HOST_SCRIPT_SBIN_FILES.
	if [[ -n "${src_dir:-}" && -f "$src_dir/lib/xprb-refresh-lib.sh" ]]; then
		install -m 0644 "$src_dir/lib/xprb-refresh-lib.sh" "$PREFIX_SBIN/xprb-refresh-lib.sh"
	elif [[ -n "${src_dir:-}" && -f "$src_dir/xprb-refresh-lib.sh" ]]; then
		install -m 0644 "$src_dir/xprb-refresh-lib.sh" "$PREFIX_SBIN/xprb-refresh-lib.sh"
	elif [[ -f "${INSTALL_LIB_DIR:-/usr/local/lib/partner-edge}/xprb-refresh-lib.sh" ]]; then
		install -m 0644 "${INSTALL_LIB_DIR:-/usr/local/lib/partner-edge}/xprb-refresh-lib.sh" \
			"$PREFIX_SBIN/xprb-refresh-lib.sh"
	else
		curl -fsSL "$REPO_RAW/lib/xprb-refresh-lib.sh" -o "$PREFIX_SBIN/xprb-refresh-lib.sh"
		chmod 0644 "$PREFIX_SBIN/xprb-refresh-lib.sh"
	fi

	# Fleet-wide infrastructure defaults (Bug 8 fix — install to canonical share path).
	# channel-render-lib.sh and oxpulse-channels-health-report.sh both source this file
	# from /usr/local/share/oxpulse-partner-edge/config/defaults.conf at runtime.
	install -d -m 0755 "/usr/local/share/oxpulse-partner-edge/config"
	if [[ -n "$src_dir" && -f "$src_dir/config/defaults.conf" ]]; then
		install -m 0644 "$src_dir/config/defaults.conf" \
			"/usr/local/share/oxpulse-partner-edge/config/defaults.conf"
	else
		curl -fsSL "$REPO_RAW/config/defaults.conf" \
			-o "/usr/local/share/oxpulse-partner-edge/config/defaults.conf"
	fi

	# VERSION file: oxpulse-channels-health-report.sh reads installer_version from
	# /usr/local/share/oxpulse-partner-edge/VERSION (canonical path, line 96).
	# Without this install the field is always absent from health-report payloads.
	install -d -m 0755 "/usr/local/share/oxpulse-partner-edge"
	if [[ -n "$src_dir" && -f "$src_dir/VERSION" ]]; then
		install -m 0644 "$src_dir/VERSION" \
			"/usr/local/share/oxpulse-partner-edge/VERSION"
	else
		curl -fsSL "$REPO_RAW/VERSION" \
			-o "/usr/local/share/oxpulse-partner-edge/VERSION"
	fi
}

# Install pre-made systemd unit files (no placeholder substitution).
# Covers: main service, hydrate oneshot, refresh + sni-rotate + xray-update
# + geoip-refresh + channels-health-report timer/service pairs.
# Render the channel-health reporter drop-in so it targets the central API host
# (BACKEND_API; default https://api.oxpulse.chat) instead of the script's
# oxpulse.chat fallback. On a partner edge, oxpulse.chat geo-resolves to the
# edge's OWN IP -> loops back to local reality :443 -> TLS internal error ->
# HTTP 000, so last_seen never updates (incident 2026-05-26). Mirrors the
# awg-params-agent OXPULSE_CENTRAL_URL. Honors OXPULSE_BACKEND_API / staging via BACKEND_API.
_systemd_render_channel_health_dropin() {
	local _d="$SYSTEMD_DIR/oxpulse-channels-health-report.service.d"
	mkdir -p "$_d"
	cat > "$_d/10-central-url.conf" <<DROPIN
[Service]
Environment=OXPULSE_BACKEND_API=${BACKEND_API}
DROPIN
}

_systemd_install_units() {
	# Main service unit
	if [[ -n "$src_dir" && -f "$src_dir/systemd/oxpulse-partner-edge.service" ]]; then
		install -m 0644 "$src_dir/systemd/oxpulse-partner-edge.service" \
			"$SYSTEMD_DIR/oxpulse-partner-edge.service"
	else
		curl -fsSL "$REPO_RAW/systemd/oxpulse-partner-edge.service" \
			-o "$SYSTEMD_DIR/oxpulse-partner-edge.service"
	fi

	# Hydrate oneshot unit
	if [[ -n "$src_dir" && -f "$src_dir/systemd/oxpulse-partner-edge-hydrate.service" ]]; then
		install -m 0644 "$src_dir/systemd/oxpulse-partner-edge-hydrate.service" \
			"$SYSTEMD_DIR/oxpulse-partner-edge-hydrate.service"
	else
		curl -fsSL "$REPO_RAW/systemd/oxpulse-partner-edge-hydrate.service" \
			-o "$SYSTEMD_DIR/oxpulse-partner-edge-hydrate.service"
	fi

	# Refresh service + timer
	for unit in oxpulse-partner-edge-refresh.service oxpulse-partner-edge-refresh.timer; do
		if [[ -n "$src_dir" && -f "$src_dir/systemd/${unit}" ]]; then
			install -m 0644 "$src_dir/systemd/${unit}" "$SYSTEMD_DIR/${unit}"
		else
			curl -fsSL "$REPO_RAW/systemd/${unit}" -o "$SYSTEMD_DIR/${unit}"
		fi
	done

	# SNI rotation service + timer
	for unit in oxpulse-partner-edge-sni-rotate.service oxpulse-partner-edge-sni-rotate.timer; do
		if [[ -n "$src_dir" && -f "$src_dir/systemd/${unit}" ]]; then
			install -m 0644 "$src_dir/systemd/${unit}" "$SYSTEMD_DIR/${unit}"
		else
			curl -fsSL "$REPO_RAW/systemd/${unit}" -o "$SYSTEMD_DIR/${unit}"
		fi
	done

	# xray-update service + timer
	for unit in oxpulse-xray-update.service oxpulse-xray-update.timer; do
		if [[ -n "$src_dir" && -f "$src_dir/systemd/${unit}" ]]; then
			install -m 0644 "$src_dir/systemd/${unit}" "$SYSTEMD_DIR/${unit}"
		else
			curl -fsSL "$REPO_RAW/systemd/${unit}" -o "$SYSTEMD_DIR/${unit}"
		fi
	done

	# Monthly geoip-refresh timer (script placed in PREFIX_SBIN by Step 5b)
	for unit in oxpulse-geoip-refresh.service oxpulse-geoip-refresh.timer; do
		if [[ -n "$src_dir" && -f "$src_dir/systemd/${unit}" ]]; then
			install -m 0644 "$src_dir/systemd/${unit}" "$SYSTEMD_DIR/${unit}"
		else
			curl -fsSL "$REPO_RAW/systemd/${unit}" -o "$SYSTEMD_DIR/${unit}"
		fi
	done

	# Per-channel health reporter service + timer
	for unit in oxpulse-channels-health-report.service oxpulse-channels-health-report.timer; do
		if [[ -n "$src_dir" && -f "$src_dir/systemd/${unit}" ]]; then
			install -m 0644 "$src_dir/systemd/${unit}" "$SYSTEMD_DIR/${unit}"
		else
			curl -fsSL "$REPO_RAW/systemd/${unit}" -o "$SYSTEMD_DIR/${unit}"
		fi
	done

	_systemd_render_channel_health_dropin
}

# Install cert-watch units after sed-substituting {{TURNS_SUBDOMAIN}} and
# {{PARTNER_DOMAIN}} placeholders.
_systemd_install_cert_watch_units() {
	for unit in oxpulse-partner-cert-watch.path oxpulse-partner-cert-watch.service; do
		local local_src=""
		if [[ -n "$src_dir" && -f "$src_dir/systemd/${unit}" ]]; then
			local_src="$src_dir/systemd/${unit}"
		else
			curl -fsSL "$REPO_RAW/systemd/${unit}" -o "/tmp/${unit}.fetched"
			local_src="/tmp/${unit}.fetched"
		fi
		sed -e "s|{{TURNS_SUBDOMAIN}}|${TURNS_SUBDOMAIN}|g" \
			-e "s|{{PARTNER_DOMAIN}}|${DOMAIN}|g" \
			"$local_src" > "/tmp/${unit}.rendered"
		install -m 0644 "/tmp/${unit}.rendered" "$SYSTEMD_DIR/${unit}"
		rm -f "/tmp/${unit}.rendered" "/tmp/${unit}.fetched"
	done
}

# Install xray auto-update script into /usr/local/bin/ (mirrors SFU pattern).
_systemd_install_xray_update_script() {
	if [[ -n "$src_dir" && -f "$src_dir/scripts/oxpulse-xray-update.sh" ]]; then
		install -m 0755 "$src_dir/scripts/oxpulse-xray-update.sh" \
			"/usr/local/bin/oxpulse-xray-update.sh"
	else
		curl -fsSL "$REPO_RAW/scripts/oxpulse-xray-update.sh" \
			-o "/usr/local/bin/oxpulse-xray-update.sh"
		chmod 0755 "/usr/local/bin/oxpulse-xray-update.sh"
	fi
}

# Enable units via systemctl. Distinguishes bake mode (pre-snapshot; do NOT start
# services — secrets not yet present) from full-install mode.
_systemd_enable_units() {
	systemctl daemon-reload
	if [ "$BAKE_MODE" = "0" ]; then
		systemctl enable --now oxpulse-partner-edge.service
		systemctl enable --now oxpulse-partner-cert-watch.path
		systemctl enable --now oxpulse-partner-edge-refresh.timer
		systemctl enable --now oxpulse-partner-edge-sni-rotate.timer
		systemctl enable --now oxpulse-xray-update.timer
		systemctl enable --now oxpulse-geoip-refresh.timer
		systemctl enable --now oxpulse-channels-health-report.timer
		systemctl enable --now oxpulse-partner-edge-selfheal.timer
	else
		# Bake mode: enable hydrate so it fires on first boot after snapshot→clone.
		# Do NOT start it now — secrets aren't present yet.
		systemctl enable oxpulse-partner-edge-hydrate.service
		systemctl enable oxpulse-partner-edge-refresh.timer
		systemctl enable oxpulse-partner-edge-sni-rotate.timer
		systemctl enable oxpulse-xray-update.timer
		systemctl enable oxpulse-geoip-refresh.timer
		systemctl enable oxpulse-channels-health-report.timer
		systemctl enable oxpulse-partner-edge-selfheal.timer
		log "  [bake] units installed, daemon-reloaded; hydrate + refresh enabled for first boot"
	fi
}

# Phase 5.7 Item 5: known sbin files for this release.
# Any file matching oxpulse-* in PREFIX_SBIN that is NOT in this list is a zombie
# from a prior install version. sbin_cleanup_zombies() warns about them; with
# CLEAN_SBIN=1 (--clean-sbin flag) it removes them.
# IMPORTANT: update this list whenever a new sbin script is added or removed.
EXPECTED_SBIN_FILES=(
	oxpulse-partner-edge-upgrade
	oxpulse-partner-edge-hydrate
	oxpulse-partner-edge-refresh
	oxpulse-partner-edge-sni-rotate
	oxpulse-channels-health-report
	oxpulse-geoip-refresh
	oxpulse-xray-update.sh
	ghcr-auth-lib.sh
	channel-render-lib.sh
	sni-select-lib.sh
	metric-sink-lib.sh
	telegram-alert-lib.sh
	xprb-refresh-lib.sh
	surgical-restart-lib.sh
	cross-probe-lib.sh
	channel-health-lib.sh
	render-channel-lib.sh
	oxpulse-token-lib.sh
	# Hy2 channel render lib — sourced by oxpulse-partner-edge-hydrate.
	hydrate-hy2.sh
	# CL-2: split-routing scripts (suffixless executables — matches sbin convention)
	oxpulse-partner-edge-split-routing
	oxpulse-partner-edge-split-disable
	# CL-3: RU-subnet feed script (suffixless executable)
	oxpulse-partner-edge-ru-subnets-update
)

# Scan PREFIX_SBIN for oxpulse-* files not in EXPECTED_SBIN_FILES.
# Warns for all zombies; removes them only when CLEAN_SBIN=1.
sbin_cleanup_zombies() {
	local _zombies=()
	local _f _base
	# MAJOR 1 review-fix: expanded glob covers lib scripts (not just oxpulse-* executables).
	# Prior glob missed stale versions of channel-render-lib.sh, ghcr-auth-lib.sh,
	# render-channel-lib.sh, oxpulse-token-lib.sh when they were renamed/removed.
	for _f in \
		"${PREFIX_SBIN}"/oxpulse-* \
		"${PREFIX_SBIN}"/*-render-lib.sh \
		"${PREFIX_SBIN}"/*-auth-lib.sh \
		"${PREFIX_SBIN}"/*-token-lib.sh; do
		[[ -e "$_f" ]] || continue
		_base="$(basename "$_f")"
		local _known=0
		local _e
		for _e in "${EXPECTED_SBIN_FILES[@]}"; do
			[[ "$_base" == "$_e" ]] && _known=1 && break
		done
		[[ $_known -eq 0 ]] && _zombies+=("$_base")
	done
	if [[ ${#_zombies[@]} -eq 0 ]]; then
		return 0
	fi
	warn "  sbin zombie files found (not in expected list for this version):"
	for _z in "${_zombies[@]}"; do
		warn "    ${PREFIX_SBIN}/${_z}"
	done
	if [[ "${CLEAN_SBIN:-0}" -eq 1 ]]; then
		warn "  --clean-sbin set: removing zombie files"
		for _z in "${_zombies[@]}"; do
			rm -f "${PREFIX_SBIN}/${_z}" 2>/dev/null \
				|| warn "  could not remove: ${PREFIX_SBIN}/${_z}"
		done
	else
		warn "  Run with --clean-sbin to remove automatically (no data loss risk — these are scripts, not config)."
	fi
	unset _zombies _f _base _known _e _z
}

# Public entry point — orchestrates the full Step 8 systemd install.
systemd_run() {
	log "[8/10] installing systemd unit"
	if [[ $DRY_RUN -eq 0 ]]; then
		_systemd_install_lib_scripts
		_systemd_install_helper_scripts
		_systemd_install_units
		_systemd_install_cert_watch_units
		_systemd_install_xray_update_script
		_systemd_enable_units
		# Phase 5.7 Item 5: scan for zombie sbin scripts from prior versions.
		# Requires CLEAN_SBIN (set by --clean-sbin) to actually remove.
		sbin_cleanup_zombies
	else
		warn "  [dry-run] skipping systemd install"
	fi
}
