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
# the cheburator phantom-regression that tests/test_baseline_before_reconcile.sh
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
# PREV_HOST_SCRIPTS_DIR, PREFIX_SHARE/PREFIX_LIBDIR/PREFIX_SBIN/PREFIX_ETC,
# SYSTEMD_DIR, SYSTEMCTL_BIN, REPO_RAW, RELEASES_BASE, STATE_FILE, DRY_RUN,
# ALLOW_UNVERIFIED) deliberately STAYS in upgrade.sh, resolved dynamically at
# CALL time against the sourcing script's function/variable table — the same
# established convention lib/reconcile.sh and lib/compose-lib.sh already use
# (their functions likewise call log()/warn()/die()/DOCKER_BIN, defined by
# whichever script sources them, never redefined locally in the lib).
#
# Not executable on its own.

# Guard against double-sourcing.
[[ "${_HOST_SCRIPTS_LIB_LOADED:-0}" -eq 1 ]] && return 0
_HOST_SCRIPTS_LIB_LOADED=1

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
	# Driven by _HOST_SCRIPT_SYSTEMD_FILES — same set as sync_host_scripts installs.
	local unit
	for unit in "${_HOST_SCRIPT_SYSTEMD_FILES[@]}"; do
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
			# healthcheck.sh staged as partner-edge-healthcheck.sh (cheburator incident fix).
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
