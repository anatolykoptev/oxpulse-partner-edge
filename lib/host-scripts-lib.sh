#!/usr/bin/env bash
# lib/host-scripts-lib.sh — shared host-script snapshot/restore/sync primitives
# (Phase 4 strangler-harden, task p4).
#
# Provides (SAME names as before extraction — see the self-overwriting-
# forwarder note below):
#   snapshot_host_scripts TAG   — copy managed sbin files + systemd units into
#                                 PREV_HOST_SCRIPTS_DIR/TAG so rollback can
#                                 restore them.
#   restore_host_scripts        — restore sbin files/units/drop-ins from the
#                                 snapshot taken above.
#   sync_host_scripts TAG       — download, verify (SHA256SUMS), and install
#                                 host-scripts for TAG.
#
# Extracted verbatim from upgrade.sh (PLAIN function-library move — NO
# reconcile wiring, NO live cutover; task p4). This is a MECHANICAL
# extraction: manifest.yaml's host_scripts/systemd_units surfaces stay
# wired:false — wiring sync_host_scripts into reconcile_all (Step 6) would
# move host-script delivery AFTER the health baseline (Step 5), reintroducing
# the edge-a phantom-regression that tests/test_baseline_before_reconcile.sh
# B2 guards against (sync_host_scripts must run BEFORE health_snapshot). A
# live cutover onto the reconcile engine needs its own ADR (Phase 5,
# alongside the self-update + flock-cluster work) — not this task.
#
# Sourced LAZILY, at call time, by same-named forwarders in upgrade.sh — in
# the spirit of lib/reconcile.sh's _reconcile_resolve_healthcheck_lib /
# health_snapshot precedent for lib/healthcheck-lib.sh: on the FIRST call,
# sourcing this file defines the REAL snapshot_host_scripts/
# restore_host_scripts/sync_host_scripts under these SAME names, replacing
# the forwarders in the shell's function table — the forwarder's trailing
# "$@" call then runs the real implementation. Every later call resolves the
# name straight to the real implementation; the forwarder body never runs
# again. This (not lib/compose-lib.sh's nameref-prefixed-real-impl pattern)
# is the right shape here because none of these three functions take
# nameref array params — a plain self-overwrite is simpler and there is no
# nameref-collision risk to design around.
#
# Sourcing stays LAZY (call-time, via the forwarders in upgrade.sh) rather
# than an eager `_source_lib "host-scripts-lib.sh"` call alongside
# reconcile.sh's, so callers who never call these three functions are not
# forced to co-locate the lib at source time. This file IS, however, a
# `_stage_lib` target now (upgrade.sh's BUG1-cure block stages it — see that
# block's header comment): the delivery half of the fitness check in
# tests/test_install_lib_checksum.sh (every _stage_lib/_source_lib target
# must be in the release-pipeline regen block + lib/lib-checksums.txt —
# Makefile / .github/workflows/release.yml) is satisfied by that staging
# call, closing the synthetic_green gap where this lib was never delivered
# to an installed/curl|bash box (same fix applied to lib/healthcheck-lib.sh
# and lib/compose-lib.sh).
#
# Every helper this file's functions call BY NAME (log/warn/die,
# _HOST_SCRIPT_SBIN_FILES/_HOST_SCRIPT_SYSTEMD_FILES/_HOST_SCRIPT_RESTART_UNITS,
# _host_script_remote_name/_host_script_install_dir/_host_script_mode,
# PREV_HOST_SCRIPTS_DIR, PREFIX_SHARE/PREFIX_LIBDIR/PREFIX_SBIN/PREFIX_BIN/
# PREFIX_ETC, SYSTEMD_DIR, SYSTEMCTL_BIN, REPO_RAW, RELEASES_BASE, STATE_FILE,
# DRY_RUN, ALLOW_UNVERIFIED) deliberately STAYS in upgrade.sh, resolved
# dynamically at CALL time against the sourcing script's function/variable
# table — the same established convention lib/reconcile.sh and
# lib/compose-lib.sh already use (their functions likewise call
# log()/warn()/die()/DOCKER_BIN, defined by whichever script sources them,
# never redefined locally in the lib).
#
# Two names are the deliberate EXCEPTION to that convention and are owned by
# THIS file: _HOST_SCRIPT_ASSET_FILES and its _host_script_asset_* helpers
# (below). The release-asset step they drive is lib-internal machinery — no
# symbol in upgrade.sh references them, and the binary's install dir is
# PREFIX_BIN (not the script class's sbin default), so the routing table for
# this surface kind cannot ride _host_script_install_dir.
#
# Not executable on its own.

# Guard against double-sourcing.
[[ "${_HOST_SCRIPTS_LIB_LOADED:-0}" -eq 1 ]] && return 0
_HOST_SCRIPTS_LIB_LOADED=1

# ---------------------------------------------------------------------------
# _HOST_SCRIPT_ASSET_FILES — release-asset binaries delivered by
# sync_host_scripts' asset step (Step 5d below). A THIRD surface kind beside
# _HOST_SCRIPT_SBIN_FILES (scripts fetched from REPO_RAW) and
# _HOST_SCRIPT_SYSTEMD_FILES (units): compiled per-arch binaries that exist
# ONLY as GitHub release assets — there is no repo path to fetch them from,
# so they can never ride the script loop.
#
# The registry lives HERE in the lib, not in upgrade.sh beside the other
# _HOST_SCRIPT_* arrays: the asset step is lib-internal machinery and nothing
# in upgrade.sh references the list by name.
# tests/test_restarted_units_are_delivered.sh extracts this array from this
# file and asserts it equals the set of unit-executed asset-class binaries —
# the defect registry that measured FOUR distinct agent-binary sha256 across
# 5 edges on 2026-08-07 (every upgrade restarted the unit; nothing ever
# refreshed the binary).
#
# Everything about an entry is DERIVED, never listed — a future asset that
# breaks a convention extends the helpers below, not the step:
#   release asset name : <name>-<arch>   (arch via _host_script_asset_arch)
#   systemd unit       : <name>.service  (the step's presence gate, and the
#                        unit that must ALSO sit in _HOST_SCRIPT_RESTART_UNITS
#                        for the bytes to take effect — the registry test
#                        asserts that pairing)
#   install dir        : _host_script_asset_install_dir → $PREFIX_BIN
#   install mode       : 0755
# ---------------------------------------------------------------------------
_HOST_SCRIPT_ASSET_FILES=(
	# Compiled from crates/awg-params-agent; shipped per-arch in every release
	# (release.yml stages oxpulse-awg-params-agent-{amd64,arm64} into the
	# tag's SHA256SUMS). systemd/oxpulse-awg-params-agent.service ExecStarts
	# /usr/local/bin/oxpulse-awg-params-agent and is already in
	# _HOST_SCRIPT_RESTART_UNITS, so landing bytes flips _any_changed and the
	# existing Step 7 restart picks the new binary up.
	oxpulse-awg-params-agent
)

# _host_script_asset_arch — uname -m → release-asset arch token (amd64|arm64);
# return 1 on anything else. MIRRORS _awg_params_agent_release_arch in
# lib/install-awg-params-agent.sh — that file is the single authority for the
# map. This copy exists because the install-side lib is NOT guaranteed present
# on an upgrade-only box (it is not a _stage_lib target and _install_lib_source
# does not persist it to INSTALL_LIB_DIR), so sourcing it here would make the
# asset step depend on a file it cannot resolve. The two copies are pinned
# identical by tests/test_sync_asset_delivery.sh — the repo's resolver-drift
# incident (upgrade.sh:280-283, _source_lib vs _stage_lib diverging on the
# identical manifest lookup) is why the mirror is test-pinned rather than a
# third resolver being built.
_host_script_asset_arch() {
	case "$(uname -m)" in
		x86_64)  printf 'amd64\n' ;;
		aarch64) printf 'arm64\n' ;;
		*) return 1 ;;
	esac
}

# _host_script_asset_install_dir NAME — where asset binary NAME installs.
# Separate map from _host_script_install_dir (script class): the unit's
# ExecStart is the authority — systemd/oxpulse-awg-params-agent.service runs
# /usr/local/bin/…, i.e. PREFIX_BIN, not the sbin default the script map would
# give. tests/test_restarted_units_are_delivered.sh eval-extracts this fn and
# asserts it agrees with every asset's unit ExecStart directory.
_host_script_asset_install_dir() {
	case "$1" in
		# systemd/oxpulse-awg-params-agent.service: ExecStart=/usr/local/bin/…
		oxpulse-awg-params-agent) printf '%s\n' "$PREFIX_BIN" ;;
		*)                        printf '%s\n' "$PREFIX_BIN" ;;
	esac
}

# _host_script_asset_env_file NAME — the env file the asset's unit requires
# (EnvironmentFile= contract), or "" when the asset has none. Used by the
# fetch gate below: rendered by the install path's awg_params_agent_run, it
# distinguishes "install ran" from a bare unit file — which Step 5 installs
# unconditionally fleet-wide. NOTE: it is NOT an AWG-channel witness (the
# env renders on every install, AWG block or not) — the fetch gate only
# decides "is this ours to refresh"; the enable gate uses the conf file.
_host_script_asset_env_file() {
	case "$1" in
		# install-awg-params-agent.sh:_awg_params_agent_render_env target;
		# systemd/oxpulse-awg-params-agent.service EnvironmentFile=.
		oxpulse-awg-params-agent) printf '%s\n' "${PREFIX_ETC:-/etc/oxpulse-partner-edge}/awg-params-agent.env" ;;
		*)                        printf '%s\n' "" ;;
	esac
}

# _host_script_asset_conf_file NAME — the config file proving this node
# actually took the asset's channel, or "" when the asset needs none. For
# the params agent this is awg0.conf — the file the daemon merges into;
# a node without it has no AWG channel and enabling the unit would just
# run a root daemon erroring on a missing conf every tick. The path is
# read out of the rendered env file — the daemon's own declared read path —
# so a custom AWG_CONF_DIR at install can never diverge the witness from
# what the daemon actually opens. Falls back to the AWG_CONF_DIR-derived
# default when the env file is absent or predates the path line.
_host_script_asset_conf_file() {
	case "$1" in
		oxpulse-awg-params-agent)
			local _e="${PREFIX_ETC:-/etc/oxpulse-partner-edge}/awg-params-agent.env" _p
			_p=$(sed -n 's/^OXPULSE_AWG_CONF_PATH=//p' "$_e" 2>/dev/null | head -1)
			printf '%s\n' "${_p:-${AWG_CONF_DIR:-/etc/amnezia/amneziawg}/awg0.conf}" ;;
		*)  printf '%s\n' "" ;;
	esac
}

# _host_script_asset_enable NAME DST UNIT ENV CONF — activate the unit when
# the full prerequisite set is on disk (env + unit + binary + the channel
# conf). Closes the dormant-node gap: a node whose install took
# awg_params_agent_run's fail-soft arm (binary absent → unit rendered but
# never enabled) has no other convergent path — Step 7 restarts only
# is-active units, _HOST_SCRIPT_ENABLE_UNITS deliberately excludes the agent
# (pinned by tests/test_upgrade_enable_set_matches_installer.sh), and
# awg_params_agent_run is never called by upgrade.sh. The conf requirement
# is the AWG-channel witness the env file can't be (it renders
# unconditionally at install). `enable` runs unconditionally — idempotent,
# and it must not trust `is-enabled`'s exit 0, which also reports the
# non-persistent `enabled-runtime` state (dead after reboot). The verify
# checks BOTH persistent enable and live state — a failed --now start must
# warn, not log "enabled + started". The heal log fires only when the unit
# was not already persistently enabled+active — this runs on every tagged
# upgrade fleet-wide, so a converged node must stay quiet. Fail-soft
# throughout: a failed enable warns, never dies (same contract as Step 5d).
_host_script_asset_enable() {
	local _a="$1" _a_dst="$2" _a_unit="$3" _a_env="$4" _a_conf="$5"
	# A declared-but-absent prerequisite skips; an undeclared one ("") is
	# no requirement at all — an env-less or conf-less asset is still
	# eligible for enable.
	[[ -n "$_a_env" && ! -f "$_a_env" ]] && return 0
	[[ -f "$_a_unit" && -f "$_a_dst" ]] || return 0
	# A declared-but-absent conf means no channel was ever taken — skip.
	[[ -z "$_a_conf" || -f "$_a_conf" ]] || return 0
	# Pre-state: was the unit already persistently enabled AND live?
	local _was=0
	[[ "$("$SYSTEMCTL_BIN" is-enabled "${_a}.service" 2>/dev/null)" == "enabled" ]] \
		&& "$SYSTEMCTL_BIN" is-active --quiet "${_a}.service" 2>/dev/null && _was=1
	"$SYSTEMCTL_BIN" daemon-reload 2>/dev/null || true
	"$SYSTEMCTL_BIN" enable --now "${_a}.service" 2>/dev/null || true
	if [[ "$("$SYSTEMCTL_BIN" is-enabled "${_a}.service" 2>/dev/null)" == "enabled" ]] \
		&& "$SYSTEMCTL_BIN" is-active --quiet "${_a}.service" 2>/dev/null; then
		[[ "$_was" -eq 0 ]] \
			&& log "  host-asset: $_a — enabled + active (unit was dormant or runtime-only)"
	else
		warn "  host-asset: $_a installed but not persistently enabled + active after 'enable --now' — check: $SYSTEMCTL_BIN status ${_a}.service"
	fi
	return 0
}

# snapshot_host_scripts TAG — copy every managed sbin file + relevant systemd
# units into PREV_HOST_SCRIPTS_DIR/TAG so rollback can restore them.
snapshot_host_scripts() {
	local tag="$1"
	local snap_dir="$PREV_HOST_SCRIPTS_DIR"
	rm -rf "$snap_dir"
	mkdir -p "$snap_dir/sbin" "$snap_dir/systemd" "$snap_dir/share-config" \
	         "$snap_dir/libdir"
	printf '%s\n' "$tag" > "$snap_dir/tag"

	local f installed_path install_dir
	for f in "${_HOST_SCRIPT_SBIN_FILES[@]}"; do
		install_dir=$(_host_script_install_dir "$f")
		installed_path="$install_dir/$f"
		[[ -f "$installed_path" ]] && cp -a "$installed_path" "$snap_dir/sbin/$f" || true
	done

	# Systemd units for the affected timers/services.
	# Driven by _HOST_SCRIPT_SYSTEMD_FILES + _HOST_SCRIPT_SYSTEMD_TEMPLATED_FILES —
	# the same two sets sync_host_scripts installs (Step 5 and Step 5b). The
	# templated ones must be snapshotted too: their installed bytes are the
	# RENDERED form, which no fetch can reproduce, so a rollback that skipped
	# them would leave the node on the new render with no way back.
	local unit
	for unit in "${_HOST_SCRIPT_SYSTEMD_FILES[@]}" "${_HOST_SCRIPT_SYSTEMD_TEMPLATED_FILES[@]}"; do
		[[ -f "$SYSTEMD_DIR/$unit" ]] && cp -a "$SYSTEMD_DIR/$unit" "$snap_dir/systemd/$unit" || true
	done

	# channel-health drop-in (carries OXPULSE_BACKEND_API env override).
	local dropin_dir="$SYSTEMD_DIR/oxpulse-channels-health-report.service.d"
	[[ -d "$dropin_dir" ]] && cp -a "$dropin_dir" "$snap_dir/systemd/oxpulse-channels-health-report.service.d" || true

	# defaults.conf
	local defaults_src="$PREFIX_SHARE/oxpulse-partner-edge/config/defaults.conf"
	[[ -f "$defaults_src" ]] && cp -a "$defaults_src" "$snap_dir/share-config/defaults.conf" || true

	# VERSION file (read by oxpulse-channels-health-report.sh for installer_version)
	local version_src="$PREFIX_SHARE/oxpulse-partner-edge/VERSION"
	[[ -f "$version_src" ]] && cp -a "$version_src" "$snap_dir/share-config/VERSION" || true

	# render-channel-lib.sh duplicate in PREFIX_LIBDIR
	[[ -f "$PREFIX_LIBDIR/render-channel-lib.sh" ]] \
		&& cp -a "$PREFIX_LIBDIR/render-channel-lib.sh" "$snap_dir/libdir/render-channel-lib.sh" || true

	log "host-script snapshot saved to $snap_dir (from $tag)"
}

# restore_host_scripts — restore sbin files, units, and drop-ins from snapshot.
restore_host_scripts() {
	local snap_dir="$PREV_HOST_SCRIPTS_DIR"
	[[ -d "$snap_dir/sbin" ]] || { warn "no host-script snapshot to restore"; return 0; }

	local f restored=0 install_dir
	for f in "${_HOST_SCRIPT_SBIN_FILES[@]}"; do
		if [[ -f "$snap_dir/sbin/$f" ]]; then
			local mode
			mode=$(_host_script_mode "$f")
			install_dir=$(_host_script_install_dir "$f")
			install -d -m 0755 "$install_dir"
			install -m "$mode" "$snap_dir/sbin/$f" "$install_dir/$f"
			restored=1
		fi
	done

	# Restore systemd units.
	# NOTE (new-unit orphan edge): if this release introduces a brand-new unit
	# that was never installed before the upgrade attempt, it will NOT be in the
	# snapshot (snapshot only copies what already exists on disk).  Rollback
	# therefore leaves the new unit installed — it is harmless because its exec
	# script is also restored to the pre-upgrade version, and `daemon-reload` +
	# restart below picks up the correct state.  Disabling or removing orphaned
	# units is intentionally left to the operator to avoid silent data loss.
	local unit
	for unit in "$snap_dir/systemd/"*; do
		[[ -e "$unit" ]] || continue
		local base
		base="$(basename "$unit")"
		if [[ -d "$unit" ]]; then
			mkdir -p "$SYSTEMD_DIR/$base"
			cp -a "$unit/." "$SYSTEMD_DIR/$base/"
		else
			install -m 0644 "$unit" "$SYSTEMD_DIR/$base"
		fi
		restored=1
	done

	# Restore defaults.conf.
	if [[ -f "$snap_dir/share-config/defaults.conf" ]]; then
		install -d -m 0755 "$PREFIX_SHARE/oxpulse-partner-edge/config"
		install -m 0644 "$snap_dir/share-config/defaults.conf" \
			"$PREFIX_SHARE/oxpulse-partner-edge/config/defaults.conf"
		restored=1
	fi

	# Restore VERSION file.
	if [[ -f "$snap_dir/share-config/VERSION" ]]; then
		install -d -m 0755 "$PREFIX_SHARE/oxpulse-partner-edge"
		install -m 0644 "$snap_dir/share-config/VERSION" \
			"$PREFIX_SHARE/oxpulse-partner-edge/VERSION"
		restored=1
	fi

	# Restore render-channel-lib.sh in PREFIX_LIBDIR.
	if [[ -f "$snap_dir/libdir/render-channel-lib.sh" ]]; then
		install -d -m 0755 "$PREFIX_LIBDIR"
		install -m 0644 "$snap_dir/libdir/render-channel-lib.sh" \
			"$PREFIX_LIBDIR/render-channel-lib.sh"
		restored=1
	fi

	if [[ "$restored" -eq 1 ]]; then
		"$SYSTEMCTL_BIN" daemon-reload 2>/dev/null || true
		log "host-scripts restored from snapshot"
	fi
}

# sync_host_scripts TAG — download, verify, and install host-scripts for TAG.
# Safe to call in dry-run mode (sets DRY_RUN_HOSTSCRIPT_CHANGED to indicate
# what would change).  Returns 0 always; logs skip/apply per file.
sync_host_scripts() {
	local tag="$1"
	local tmpdir
	tmpdir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	# Resolve BACKEND_API for the channel-health drop-in.  Prefer env (already
	# exported by caller or operator) then fall back to install.env.
	local _backend_api="${BACKEND_API:-}"
	if [[ -z "$_backend_api" && -r "$STATE_FILE" ]]; then
		# shellcheck disable=SC1090
		_backend_api=$(. "$STATE_FILE" 2>/dev/null && printf '%s' "${BACKEND_API:-}")
	fi
	_backend_api="${_backend_api:-https://api.oxpulse.chat}"

	if [[ "$DRY_RUN" -eq 1 ]]; then
		log "[dry-run] host-script sync: would fetch + install sbin scripts and systemd units for tag=$tag"
		log "[dry-run]   scripts: ${_HOST_SCRIPT_SBIN_FILES[*]}"
		log "[dry-run]   BACKEND_API for channel-health drop-in: $_backend_api"
		log "[dry-run]   units: oxpulse-channels-health-report.{service,timer} + refresh/sni-rotate/xray-update/geoip-refresh"
		log "[dry-run]   templated units (rendered from STATE): ${_HOST_SCRIPT_SYSTEMD_TEMPLATED_FILES[*]}"
		log "[dry-run]   enable (enable-only, never disable): ${_HOST_SCRIPT_ENABLE_UNITS[*]}"
		log "[dry-run]   release-asset binaries (env-or-binary gated): ${_HOST_SCRIPT_ASSET_FILES[*]}"
		log "[dry-run]   reload: $SYSTEMCTL_BIN daemon-reload + restart affected timers"
		log "[dry-run]   idempotency: sha256 comparison (no-op if already current)"
		log "[dry-run]   VERSION: would install to $PREFIX_SHARE/oxpulse-partner-edge/VERSION"
		return 0
	fi

	# ------------------------------------------------------------------
	# Step 1: fetch SHA256SUMS from the GitHub release for checksum guard.
	# The release asset name is "SHA256SUMS" (as built by release.yml).
	# $tag is the release tag (vX.Y.Z starting at v0.12.60, or the caller-
	# supplied tag for pre-v0.12.60 edges that were normalized by normalize_target).
	# GitHub release URL: .../releases/download/vX.Y.Z/SHA256SUMS.
	# ------------------------------------------------------------------
	local sha256sums_url sha256sums_file sha256sums_ok=0
	if [[ "$tag" != "latest" ]]; then
		sha256sums_url="$RELEASES_BASE/$tag/SHA256SUMS"
		sha256sums_file="$tmpdir/SHA256SUMS"
		if curl -fsSL --max-time 30 "$sha256sums_url" -o "$sha256sums_file" 2>/dev/null; then
			sha256sums_ok=1
			log "fetched SHA256SUMS for $tag"
		else
			# FAIL-LOUD: a pinned-tag relay upgrade MUST NOT install unverified scripts.
			# SHA256SUMS 404 means wrong tag form, network failure, or missing release asset —
			# all of which indicate a configuration/supply-chain problem that must not be
			# papered over with a silent "proceed without checksum guard".
			# Use --allow-unverified only for developer/test runs where the release does not
			# exist yet.
			if [[ "${ALLOW_UNVERIFIED:-0}" -eq 1 ]]; then
				warn "could not fetch SHA256SUMS from $sha256sums_url — proceeding WITHOUT checksum guard (--allow-unverified)"
			else
				die "could not fetch SHA256SUMS from $sha256sums_url
Supply-chain integrity check FAILED for pinned tag $tag.
Possible causes:
  • Network/mirror unreachable
  • Release $tag does not exist on GitHub (releases ≥v0.12.60 use vX.Y.Z, earlier used partner-edge-vX.Y.Z)
  • Old-form tag passed: if you meant partner-edge-$tag, it was normalized to $tag automatically
If this is a dev/test run against a local fixture, re-run with --allow-unverified.
Aborting: host-scripts NOT installed (no unverified installs on relay)."
			fi
		fi
	else
		warn "target is 'latest' — SHA256SUMS not available from a floating tag; skipping checksum guard"
	fi

	# Helper: look up expected sha256 for a release asset name from SHA256SUMS.
	# Returns empty string if not found or checksum guard is unavailable.
	_lookup_sha256() {
		local asset_name="$1"
		[[ "$sha256sums_ok" -eq 1 ]] || return 0
		awk -v name="$asset_name" '$2 == name || $2 == "./" name { print $1; exit }' \
			"$sha256sums_file" 2>/dev/null || true
	}

	# ------------------------------------------------------------------
	# Step 2: fetch and install each managed sbin file.
	# ------------------------------------------------------------------
	local _any_changed=0

	local f remote_name fetch_url fetch_tmp mode expected_sha actual_sha installed_sha install_dir
	for f in "${_HOST_SCRIPT_SBIN_FILES[@]}"; do
		remote_name=$(_host_script_remote_name "$f")
		install_dir=$(_host_script_install_dir "$f")
		# Self-update special case (MINOR-1):
		# release.yml stages a @RELEASE_TAG_PLACEHOLDER@-substituted copy of upgrade.sh as
		# "partner-edge-upgrade.sh" in the release assets (not in REPO_RAW, which
		# serves the raw committed tree with the literal placeholder).  Fetching from
		# REPO_RAW would yield bytes that DON'T match the SHA256SUMS entry for
		# "partner-edge-upgrade.sh" (substituted bytes), so the guard would reject
		# every self-update attempt.  Instead we fetch the SUBSTITUTED asset from
		# RELEASES_BASE when the tag is not a floating "latest".
		local use_releases_asset=0
		case "$f" in
			oxpulse-partner-edge-upgrade)
				if [[ "$tag" != "latest" ]]; then
					use_releases_asset=1
				fi
				;;
		esac

		if [[ "$use_releases_asset" -eq 1 ]]; then
			# Fetch substituted partner-edge-upgrade.sh from release assets.
			# SHA256SUMS asset name is "partner-edge-upgrade.sh".
			fetch_url="$RELEASES_BASE/$tag/partner-edge-upgrade.sh"
			fetch_tmp="$tmpdir/partner-edge-upgrade.sh"
		else
			fetch_url="$REPO_RAW/$remote_name"
			fetch_tmp="$tmpdir/$(basename "$remote_name")"
		fi
		mode=$(_host_script_mode "$f")

		if ! curl -fsSL --max-time 30 "$fetch_url" -o "$fetch_tmp" 2>/dev/null; then
			warn "host-script sync: could not fetch $fetch_url — skipping $f"
			continue
		fi

		# Checksum guard: verify fetched file against SHA256SUMS if available.
		# asset_name in SHA256SUMS is the release-staged name (the basename, no lib/ prefix).
		local sha256_asset_name
		sha256_asset_name=$(basename "$remote_name")
		# Map installed names to SHA256SUMS asset names where they differ.
		case "$f" in
			oxpulse-partner-edge-upgrade)   sha256_asset_name="partner-edge-upgrade.sh" ;;
			oxpulse-partner-edge-hydrate)   sha256_asset_name="hydrate.sh" ;;
			# render-channel-lib.sh staged as render-channel-lib.sh (not lib/render-channel-lib.sh)
			render-channel-lib.sh)          sha256_asset_name="render-channel-lib.sh" ;;
			# xray-update and geoip-refresh: staged without scripts/ prefix
			oxpulse-xray-update.sh)        sha256_asset_name="oxpulse-xray-update.sh" ;;
			oxpulse-geoip-refresh)         sha256_asset_name="oxpulse-geoip-refresh.sh" ;;
			# healthcheck.sh staged as partner-edge-healthcheck.sh (edge-a incident fix).
			oxpulse-partner-edge-healthcheck) sha256_asset_name="partner-edge-healthcheck.sh" ;;
		esac

		expected_sha=$(_lookup_sha256 "$sha256_asset_name")
		if [[ -n "$expected_sha" ]]; then
			actual_sha=$(sha256sum "$fetch_tmp" | awk '{print $1}')
			if [[ "$actual_sha" != "$expected_sha" ]]; then
				warn "host-script sync: SHA256 MISMATCH for $f (expected=$expected_sha actual=$actual_sha) — skipping (possible MITM or stale CDN)"
				continue
			fi
		fi

		# Idempotency: skip if installed file already matches.
		local installed_path="$install_dir/$f"
		if [[ -f "$installed_path" ]]; then
			installed_sha=$(sha256sum "$installed_path" | awk '{print $1}')
			actual_sha=$(sha256sum "$fetch_tmp" | awk '{print $1}')
			if [[ "$installed_sha" == "$actual_sha" ]]; then
				log "  host-script: $f up-to-date (sha256 match)"
				continue
			fi
		fi

		# Atomic install: sibling temp + rename(2).
		install -d -m 0755 "$install_dir"
		local tmp_inst="$install_dir/$f.new.$$"
		install -m "$mode" "$fetch_tmp" "$tmp_inst"
		mv -f "$tmp_inst" "$installed_path"
		log "  host-script: installed $f (mode=$mode, dir=$install_dir)"
		_any_changed=1
	done

	# ------------------------------------------------------------------
	# Step 3: defaults.conf (sourced by channel-render-lib + health-report).
	# ------------------------------------------------------------------
	local defaults_url="$REPO_RAW/config/defaults.conf"
	local defaults_dst="$PREFIX_SHARE/oxpulse-partner-edge/config/defaults.conf"
	local defaults_tmp="$tmpdir/defaults.conf"
	if curl -fsSL --max-time 30 "$defaults_url" -o "$defaults_tmp" 2>/dev/null; then
		# SHA256 guard (staged as config-defaults.conf in release assets).
		expected_sha=$(_lookup_sha256 "config-defaults.conf")
		if [[ -n "$expected_sha" ]]; then
			actual_sha=$(sha256sum "$defaults_tmp" | awk '{print $1}')
			if [[ "$actual_sha" != "$expected_sha" ]]; then
				warn "host-script sync: SHA256 MISMATCH for defaults.conf — skipping"
				defaults_tmp=""
			fi
		fi
		if [[ -n "$defaults_tmp" && -f "$defaults_tmp" ]]; then
			install -d -m 0755 "$(dirname "$defaults_dst")"
			if [[ -f "$defaults_dst" ]]; then
				installed_sha=$(sha256sum "$defaults_dst" | awk '{print $1}')
				actual_sha=$(sha256sum "$defaults_tmp" | awk '{print $1}')
				if [[ "$installed_sha" == "$actual_sha" ]]; then
					log "  host-script: defaults.conf up-to-date"
				else
					install -m 0644 "$defaults_tmp" "$defaults_dst"
					log "  host-script: installed defaults.conf"
					_any_changed=1
				fi
			else
				install -m 0644 "$defaults_tmp" "$defaults_dst"
				log "  host-script: installed defaults.conf (new)"
				_any_changed=1
			fi
		fi
	else
		warn "host-script sync: could not fetch defaults.conf from $defaults_url — skipping"
	fi

	# ------------------------------------------------------------------
	# Step 3b: VERSION file — read by oxpulse-channels-health-report.sh:96 to
	# populate installer_version in the channel-health payload.  Without this
	# sync the field stays empty after upgrade (hydrate only runs on first boot).
	# ------------------------------------------------------------------
	local version_url="$REPO_RAW/VERSION"
	local version_dst="$PREFIX_SHARE/oxpulse-partner-edge/VERSION"
	local version_tmp="$tmpdir/VERSION"
	if curl -fsSL --max-time 30 "$version_url" -o "$version_tmp" 2>/dev/null; then
		expected_sha=$(_lookup_sha256 "VERSION")
		if [[ -n "$expected_sha" ]]; then
			actual_sha=$(sha256sum "$version_tmp" | awk '{print $1}')
			if [[ "$actual_sha" != "$expected_sha" ]]; then
				warn "host-script sync: SHA256 MISMATCH for VERSION — skipping"
				version_tmp=""
			fi
		fi
		if [[ -n "$version_tmp" && -f "$version_tmp" ]]; then
			install -d -m 0755 "$(dirname "$version_dst")"
			if [[ -f "$version_dst" ]]; then
				installed_sha=$(sha256sum "$version_dst" | awk '{print $1}')
				actual_sha=$(sha256sum "$version_tmp" | awk '{print $1}')
				if [[ "$installed_sha" == "$actual_sha" ]]; then
					log "  host-script: VERSION up-to-date"
				else
					install -m 0644 "$version_tmp" "$version_dst"
					log "  host-script: installed VERSION"
					_any_changed=1
				fi
			else
				install -m 0644 "$version_tmp" "$version_dst"
				log "  host-script: installed VERSION (new)"
				_any_changed=1
			fi
		fi
	else
		warn "host-script sync: could not fetch VERSION from $version_url — skipping"
	fi

	# ------------------------------------------------------------------
	# Step 4: render-channel-lib.sh also goes into PREFIX_LIBDIR (Bug 17 fix
	# mirroring install-systemd.sh — both PREFIX_SBIN and PREFIX_LIBDIR).
	# ------------------------------------------------------------------
	local rcl_sbin="$PREFIX_SBIN/render-channel-lib.sh"
	local rcl_libdir="$PREFIX_LIBDIR/render-channel-lib.sh"
	if [[ -f "$rcl_sbin" ]]; then
		if [[ ! -f "$rcl_libdir" ]] || ! diff -q "$rcl_sbin" "$rcl_libdir" >/dev/null 2>&1; then
			install -d -m 0755 "$PREFIX_LIBDIR"
			if [[ ! "$rcl_sbin" -ef "$rcl_libdir" ]]; then
				install -m 0644 "$rcl_sbin" "$rcl_libdir"
				log "  host-script: synced render-channel-lib.sh to $PREFIX_LIBDIR"
			fi
		fi
	fi

	# ------------------------------------------------------------------
	# Step 5: systemd units for affected services.
	# Driven by the top-level _HOST_SCRIPT_SYSTEMD_FILES constant — add new units
	# there, not here.
	# ------------------------------------------------------------------
	local unit unit_url unit_tmp unit_dst unit_expected_sha unit_actual_sha
	for unit in "${_HOST_SCRIPT_SYSTEMD_FILES[@]}"; do
		unit_url="$REPO_RAW/systemd/$unit"
		unit_tmp="$tmpdir/$unit"
		unit_dst="$SYSTEMD_DIR/$unit"
		if ! curl -fsSL --max-time 30 "$unit_url" -o "$unit_tmp" 2>/dev/null; then
			warn "host-script sync: could not fetch systemd/$unit — skipping"
			continue
		fi
		# Checksum guard: unit is staged as <unit-name> in SHA256SUMS (basename only).
		unit_expected_sha=$(_lookup_sha256 "$unit")
		if [[ -n "$unit_expected_sha" ]]; then
			unit_actual_sha=$(sha256sum "$unit_tmp" | awk '{print $1}')
			if [[ "$unit_actual_sha" != "$unit_expected_sha" ]]; then
				warn "host-script sync: SHA256 MISMATCH for systemd/$unit (expected=$unit_expected_sha actual=$unit_actual_sha) — skipping (possible MITM or stale CDN)"
				continue
			fi
		fi
		if [[ -f "$unit_dst" ]]; then
			installed_sha=$(sha256sum "$unit_dst" | awk '{print $1}')
			actual_sha=$(sha256sum "$unit_tmp" | awk '{print $1}')
			if [[ "$installed_sha" == "$actual_sha" ]]; then
				continue
			fi
		fi
		install -m 0644 "$unit_tmp" "$unit_dst"
		log "  host-script: installed systemd/$unit"
		_any_changed=1
	done

	# ------------------------------------------------------------------
	# Step 5b: TEMPLATED systemd units — render from STATE, then install.
	# Driven by _HOST_SCRIPT_SYSTEMD_TEMPLATED_FILES (see its header in
	# upgrade.sh for why these cannot ride the verbatim copy loop above).
	#
	# FAIL-CLOSED on an unresolved placeholder. A cert-watch .path whose
	# {{TURNS_SUBDOMAIN}} never got substituted installs cleanly, reads
	# `enabled` under systemctl, and watches a path ending in "..crt"
	# forever — an inert unit that every probe reports as converged. Leaving
	# it ABSENT is strictly better: absence is what the fleet fingerprint
	# already measures, and a silently-inert watcher is what it cannot see.
	# ------------------------------------------------------------------
	local _tpl_turns _tpl_domain
	_tpl_turns="${TURNS_SUBDOMAIN:-}"
	_tpl_domain="${PARTNER_DOMAIN:-}"
	if [[ ( -z "$_tpl_turns" || -z "$_tpl_domain" ) && -r "$STATE_FILE" ]]; then
		# shellcheck disable=SC1090
		[[ -z "$_tpl_turns" ]]  && _tpl_turns=$(. "$STATE_FILE" 2>/dev/null && printf '%s' "${TURNS_SUBDOMAIN:-}")
		# shellcheck disable=SC1090
		[[ -z "$_tpl_domain" ]] && _tpl_domain=$(. "$STATE_FILE" 2>/dev/null && printf '%s' "${PARTNER_DOMAIN:-}")
	fi

	local _tu _tu_rendered
	for _tu in "${_HOST_SCRIPT_SYSTEMD_TEMPLATED_FILES[@]}"; do
		if [[ -z "$_tpl_turns" || -z "$_tpl_domain" ]]; then
			warn "host-script sync: cannot render systemd/$_tu — TURNS_SUBDOMAIN and/or PARTNER_DOMAIN absent from $STATE_FILE. Leaving the unit ABSENT rather than installing one with unresolved {{placeholders}} (an inert watcher reads as converged; an absent one does not)."
			continue
		fi
		unit_url="$REPO_RAW/systemd/$_tu"
		unit_tmp="$tmpdir/$_tu"
		unit_dst="$SYSTEMD_DIR/$_tu"
		_tu_rendered="$tmpdir/$_tu.rendered"
		if ! curl -fsSL --max-time 30 "$unit_url" -o "$unit_tmp" 2>/dev/null; then
			warn "host-script sync: could not fetch systemd/$_tu — skipping"
			continue
		fi
		# Checksum guard runs on the TEMPLATE bytes as released — the rendered
		# output is per-node and has no entry in SHA256SUMS by construction.
		unit_expected_sha=$(_lookup_sha256 "$_tu")
		if [[ -n "$unit_expected_sha" ]]; then
			unit_actual_sha=$(sha256sum "$unit_tmp" | awk '{print $1}')
			if [[ "$unit_actual_sha" != "$unit_expected_sha" ]]; then
				warn "host-script sync: SHA256 MISMATCH for systemd/$_tu (expected=$unit_expected_sha actual=$unit_actual_sha) — skipping (possible MITM or stale CDN)"
				continue
			fi
		fi
		# Same substitution install.sh performs (_systemd_install_cert_watch_units).
		sed -e "s|{{TURNS_SUBDOMAIN}}|${_tpl_turns}|g" \
		    -e "s|{{PARTNER_DOMAIN}}|${_tpl_domain}|g" \
		    "$unit_tmp" > "$_tu_rendered"
		if grep -qF '{{' "$_tu_rendered"; then
			warn "host-script sync: systemd/$_tu still contains an unresolved {{placeholder}} after substitution — NOT installing (the template gained a placeholder this renderer does not know about)"
			continue
		fi
		if [[ -f "$unit_dst" ]]; then
			installed_sha=$(sha256sum "$unit_dst" | awk '{print $1}')
			actual_sha=$(sha256sum "$_tu_rendered" | awk '{print $1}')
			if [[ "$installed_sha" == "$actual_sha" ]]; then
				continue
			fi
		fi
		install -m 0644 "$_tu_rendered" "$unit_dst"
		log "  host-script: installed systemd/$_tu (rendered from STATE)"
		_any_changed=1
	done

	# ------------------------------------------------------------------
	# Step 5c: ENABLEMENT convergence.
	#
	# Delivery was never the whole job. sync_host_scripts has installed unit
	# FILES for as long as it has existed, but nothing on any apply path ever
	# ran `systemctl enable` — only install.sh does, in
	# _systemd_enable_units (lib/install-systemd.sh). So a node whose install
	# predates a unit, or whose operator ever disabled one, stays that way
	# through every subsequent upgrade forever.
	#
	# Measured on the fleet 2026-08-07: on rvpn-seed and
	# zvonilka-cc7cf842800b, oxpulse-partner-edge.service itself is DISABLED
	# — those two boxes do not bring their containers back after a reboot —
	# along with the xray-update and geoip-refresh timers. The other three
	# nodes have all seven enabled.
	#
	# ENABLE-ONLY, never disable. cheburator hand-enables split-routing and
	# ru-subnets-update for its RU profile; manifest.yaml declares those
	# `unmanaged`, and a converge-to-exact-set would rip them out on the next
	# upgrade. Enable-only is monotonic, so every unmanaged decision on every
	# node survives untouched.
	#
	# START policy is derived from the unit SUFFIX, never a second list:
	#   .timer / .path → enable + start. Arming a timer or a path watch has
	#     no data-path effect, and a newly-enabled timer does nothing at all
	#     until the next boot unless it is also started. A Persistent=true
	#     timer catching up can fire refresh.service, which may attempt a
	#     self-upgrade — upgrade.sh's own `flock -n` (FIX 5) makes that a
	#     clean die-and-retry, not a concurrent run.
	#   .service       → enable ONLY, never --now. oxpulse-partner-edge.service
	#     is `ExecStart=docker compose up -d`, and on BOTH apply paths this
	#     function runs AFTER the compose image tags are rewritten to the
	#     target but BEFORE ghcr_login_from_file and the pull. `enable --now`
	#     here would compose-up against tags that are not on the box yet,
	#     outside the zero-downtime recreate. The defect being fixed is
	#     "does not survive a reboot"; `enable` fixes exactly that, and the
	#     containers are already up under `restart: unless-stopped`.
	#
	# IR-5 lesson (lib/install-split-routing.sh:113): `systemctl enable`
	# exiting 0 is NOT sufficient evidence — verify with is-enabled after.
	#
	# A MASKED unit is left masked, deliberately. `enable` cannot lift a mask,
	# so the post-enable verification below fails and warns on every upgrade.
	# That noise is the correct outcome: masking is an explicit operator
	# action, force-unmasking it would break the enable-only contract above,
	# and a recurring warn is how an operator finds out their mask is now
	# fighting the managed set.
	# ------------------------------------------------------------------
	if [[ "$_any_changed" -eq 1 ]]; then
		# Units may have just landed on disk; let systemd see them before we
		# ask it to enable them. Step 7's reload stays — it is idempotent.
		"$SYSTEMCTL_BIN" daemon-reload 2>/dev/null || true
	fi

	local _eu _eu_state
	for _eu in "${_HOST_SCRIPT_ENABLE_UNITS[@]}"; do
		if [[ ! -f "$SYSTEMD_DIR/$_eu" ]]; then
			warn "unit-enable: $_eu is not installed at $SYSTEMD_DIR — cannot enable (see the Step 5/5b warnings above for why it is missing)"
			continue
		fi
		_eu_state=$("$SYSTEMCTL_BIN" is-enabled "$_eu" 2>/dev/null || true)
		# `static` and `indirect` units have no [Install] to enable; `enabled`
		# is already converged. All three are no-ops, not failures.
		case "$_eu_state" in
			enabled | enabled-runtime | static | indirect) continue ;;
		esac

		"$SYSTEMCTL_BIN" enable "$_eu" >/dev/null 2>&1 \
			|| warn "unit-enable: systemctl enable $_eu returned non-zero"

		_eu_state=$("$SYSTEMCTL_BIN" is-enabled "$_eu" 2>/dev/null || true)
		if [[ "$_eu_state" != "enabled" ]]; then
			warn "unit-enable: $_eu still reads is-enabled='${_eu_state:-<none>}' after enable — NOT converged; this node will not start it at boot"
			continue
		fi
		log "  unit-enable: $_eu enabled"
		_any_changed=1

		case "$_eu" in
			*.timer | *.path)
				"$SYSTEMCTL_BIN" start "$_eu" >/dev/null 2>&1 \
					|| warn "unit-enable: could not start $_eu now — it will arm at the next boot"
				;;
		esac
	done

	# ------------------------------------------------------------------
	# Step 5d: release-asset binaries (_HOST_SCRIPT_ASSET_FILES) — the third
	# delivery surface beside scripts (Step 2, from REPO_RAW) and units
	# (Step 5): compiled per-arch binaries that exist ONLY as release assets.
	#
	# WHY THIS LIVES HERE (strangler-fig, not a parallel pipeline): every link
	# in the fetch→verify→install→restart chain this step needs already exists
	# in this function — SHA256SUMS is fetched once per tag at Step 1 (this
	# step never re-fetches it), entries resolve via _lookup_sha256, the
	# fetch URL reuses the use_releases_asset polarity ($RELEASES_BASE/$tag,
	# which already encodes OXPULSE_MIRROR_BASE), and _any_changed drives the
	# Step 7 restart that already lists oxpulse-awg-params-agent.service. A
	# separate converge would be the THIRD fetch+verify implementation in a
	# repo that already recorded the two-resolver drift incident
	# (upgrade.sh:280-283 — _source_lib vs _stage_lib diverging on the
	# identical manifest lookup). The defect being closed is codified in
	# tests/test_restarted_units_are_delivered.sh: four distinct
	# agent-binary hashes across five edges, because every upgrade restarted
	# the unit and none ever refreshed the binary.
	#
	# GATE — env file present OR binary already installed: the env file
	# (rendered by the install path's awg_params_agent_run) marks "install
	# ran", and a pre-delivered binary marks "we own this". This is NOT an
	# AWG-channel gate — env renders on every install, so the fetch side
	# effectively always runs (same as the old unit-file gate); the
	# channel witness for ENABLE is awg0.conf, checked inside
	# _host_script_asset_enable.
	#
	# VERIFY — fail-CLOSED, deliberately stricter than the script class's
	# ALLOW_UNVERIFIED leniency: this is a root daemon that writes awg0.conf
	# and pipes it into `awg syncconf` — it carries HPK and must-match params
	# to the kernel. No per-tag SHA256SUMS entry → no install, period. The
	# unverified bytes this replaces came from releases/latest/download —
	# unpinned AND unverified.
	#
	# FAIL-SOFT — every failure below is warn+skip, never die: a delivery
	# failure on the optional AWG channel must not abort an upgrade that is
	# otherwise converging the managed set (the same contract
	# ensure_amneziawg keeps).
	# ------------------------------------------------------------------
	local _asset _arch _asset_rel _asset_dst _asset_unit _asset_env _asset_conf _asset_tmp_inst
	for _asset in "${_HOST_SCRIPT_ASSET_FILES[@]}"; do
		install_dir=$(_host_script_asset_install_dir "$_asset")
		_asset_dst="$install_dir/$_asset"
		_asset_unit="$SYSTEMD_DIR/${_asset}.service"
		_asset_env=$(_host_script_asset_env_file "$_asset")
		_asset_conf=$(_host_script_asset_conf_file "$_asset")
		# Gate: nothing-ours no-op — the env file is absent (install path
		# never rendered it) and no binary was ever delivered.
		if [[ -z "$_asset_env" || ! -f "$_asset_env" ]] && [[ ! -f "$_asset_dst" ]]; then
			log "  host-asset: $_asset — no env file and no installed binary (nothing ours to refresh) — skipping"
			continue
		fi
		if ! _arch=$(_host_script_asset_arch); then
			warn "  host-asset: $_asset — unsupported arch $(uname -m) — skipping (no release asset exists for it)"
			continue
		fi
		_asset_rel="${_asset}-${_arch}"
		# A root daemon is never installed unverified: without this tag's
		# SHA256SUMS (floating 'latest' tag, fetch failure tolerated by
		# --allow-unverified, or a release that predates the asset) there is
		# nothing to check the bytes against — skip rather than fetch.
		if [[ "$sha256sums_ok" -ne 1 ]]; then
			warn "  host-asset: $_asset — no SHA256SUMS for tag $tag — skipping (root-daemon bytes are never installed unverified)"
			continue
		fi
		expected_sha=$(_lookup_sha256 "$_asset_rel")
		if [[ -z "$expected_sha" ]]; then
			warn "  host-asset: no SHA256SUMS entry for $_asset_rel at tag $tag — skipping (possible MITM or a release that predates the asset)"
			continue
		fi
		fetch_url="$RELEASES_BASE/$tag/$_asset_rel"
		fetch_tmp="$tmpdir/$_asset_rel"
		if ! curl -fsSL --max-time 60 "$fetch_url" -o "$fetch_tmp" 2>/dev/null; then
			warn "  host-asset: could not fetch $fetch_url — skipping $_asset"
			continue
		fi
		actual_sha=$(sha256sum "$fetch_tmp" | awk '{print $1}')
		if [[ "$actual_sha" != "$expected_sha" ]]; then
			warn "  host-asset: SHA256 MISMATCH for $_asset_rel (expected=$expected_sha actual=$actual_sha) — skipping (possible MITM or stale CDN)"
			continue
		fi
		# Idempotency: same bytes already installed → no install, no restart.
		# The enable check still runs — a node whose binary landed earlier
		# without activation (pre-fix delivery, or an enable --now that
		# failed) heals here without needing a new download.
		if [[ -f "$_asset_dst" ]]; then
			installed_sha=$(sha256sum "$_asset_dst" | awk '{print $1}')
			if [[ "$installed_sha" == "$actual_sha" ]]; then
				log "  host-asset: $_asset up-to-date (sha256 match)"
				_host_script_asset_enable "$_asset" "$_asset_dst" "$_asset_unit" "$_asset_env" "$_asset_conf"
				continue
			fi
		fi
		# Atomic install: sibling temp + rename(2). Atomicity matters beyond
		# crash-consistency here: the daemon this replaces may be RUNNING —
		# rename swaps the path's inode without touching the live image,
		# where a truncate+write would ETXTBSY or corrupt it.
		install -d -m 0755 "$install_dir"
		_asset_tmp_inst="$_asset_dst.new.$$"
		install -m 0755 "$fetch_tmp" "$_asset_tmp_inst"
		mv -f "$_asset_tmp_inst" "$_asset_dst"
		log "  host-asset: installed $_asset ($_asset_rel @ $tag)"
		_any_changed=1
		_host_script_asset_enable "$_asset" "$_asset_dst" "$_asset_unit" "$_asset_env" "$_asset_conf"
	done

	# ------------------------------------------------------------------
	# Step 6: channel-health drop-in — set OXPULSE_BACKEND_API so the
	# health reporter reaches the central node (not the local edge IP).
	# Mirrors _systemd_render_channel_health_dropin() in install-systemd.sh.
	# ------------------------------------------------------------------
	local dropin_dir="$SYSTEMD_DIR/oxpulse-channels-health-report.service.d"
	local dropin_path="$dropin_dir/10-central-url.conf"
	local dropin_content
	dropin_content="$(printf '[Service]\nEnvironment=OXPULSE_BACKEND_API=%s\n' "$_backend_api")"
	mkdir -p "$dropin_dir"
	if [[ -f "$dropin_path" ]]; then
		local existing_content
		existing_content=$(cat "$dropin_path")
		if [[ "$existing_content" != "$dropin_content" ]]; then
			printf '%s\n' "$dropin_content" > "$dropin_dir/10-central-url.conf.new.$$"
			mv -f "$dropin_dir/10-central-url.conf.new.$$" "$dropin_path"
			log "  host-script: updated channel-health drop-in (BACKEND_API=$_backend_api)"
			_any_changed=1
		fi
	else
		printf '%s\n' "$dropin_content" > "$dropin_path"
		log "  host-script: installed channel-health drop-in (BACKEND_API=$_backend_api)"
		_any_changed=1
	fi

	# ------------------------------------------------------------------
	# Step 6.5: provision xray.env — required by oxpulse-xray-update.sh.
	# The watchtower script hard-fails without this file (line 64).
	# Idempotent: touch only if absent so operator env overrides are preserved.
	# ------------------------------------------------------------------
	local _xray_env_path="${PREFIX_ETC:-/etc/oxpulse-partner-edge}/xray.env"
	if [[ ! -f "$_xray_env_path" ]]; then
		install -d -m 0755 "${PREFIX_ETC:-/etc/oxpulse-partner-edge}"
		install -m 0644 /dev/null "$_xray_env_path"
		log "  host-script: provisioned xray.env at $_xray_env_path"
		_any_changed=1
	fi

	# ------------------------------------------------------------------
	# Step 7: daemon-reload + targeted restart of affected timers only.
	# Coturn/sfu/xray images are the image path's concern — never touched here.
	# ------------------------------------------------------------------
	if [[ "$_any_changed" -eq 1 ]]; then
		"$SYSTEMCTL_BIN" daemon-reload 2>/dev/null \
			|| warn "daemon-reload failed — units may not reflect latest changes"
		local timer
		for timer in "${_HOST_SCRIPT_RESTART_UNITS[@]}"; do
			if "$SYSTEMCTL_BIN" is-active --quiet "$timer" 2>/dev/null; then
				"$SYSTEMCTL_BIN" restart "$timer" 2>/dev/null \
					|| warn "could not restart $timer — it will pick up changes at next trigger"
			fi
		done
		log "host-script sync complete (tag=$tag)"
	else
		log "host-script sync: all files up-to-date for $tag (no-op)"
	fi
}
