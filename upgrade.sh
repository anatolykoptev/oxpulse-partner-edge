#!/usr/bin/env bash
# upgrade.sh — pull a newer image tag, sync host-scripts, recreate services,
# verify, optionally roll back.
#
# Every apply (plain or --with-templates) now atomically upgrades BOTH:
#   • Docker image tags (caddy, sfu, xray containers via compose pull+up)
#   • Host-level scripts (oxpulse-channels-health-report, upgrade.sh, refresh,
#     sni-rotate, lib scripts, systemd units) fetched from the release tag
#
# This closes the gap where host-script changes (e.g. ch4 coturn probe in
# oxpulse-channels-health-report.sh, new systemd drop-ins) were silently skipped
# by upgrade.sh and only reached an edge via a full installer re-run.
# Example: v0.12.57 bundled BOTH sfu-siege-transport image change (#255) AND
# ch4 health-report change; old upgrade.sh deployed only the image.
#
# Usage:
#   oxpulse-partner-edge-upgrade                       # pull :latest + sync host-scripts
#   oxpulse-partner-edge-upgrade v0.2.0                # pin to specific tag
#   oxpulse-partner-edge-upgrade --check               # report pending upgrade, don't apply
#   oxpulse-partner-edge-upgrade --rollback            # restore previous tag + host-scripts
#   oxpulse-partner-edge-upgrade --templates-only      # re-render xray config from upstream template, no image pull
#   oxpulse-partner-edge-upgrade --with-templates      # re-render Caddyfile + healthcheck + pull new image (atomic)
#   oxpulse-partner-edge-upgrade --host-scripts-only   # sync host-scripts only; NO image pull/recreate
#   oxpulse-partner-edge-upgrade --ghcr-token=ghp_xxx  # persist GHCR PAT before pull (one-time)
#   oxpulse-partner-edge-upgrade --dry-run             # print plan, skip docker and file writes
#   oxpulse-partner-edge-upgrade --dry-run --skip-check=1,3  # skip specific conflict checks (1-8)
#   oxpulse-partner-edge-upgrade --allow-unverified    # skip SHA256SUMS check (dev/test only, NEVER on relay)
#
# Tag-form note: starting with v0.12.60, git tags, GitHub release tags, and GHCR
# image tags ALL use the same vX.Y.Z form — no component prefix. release-please-config.json
# has no "component" key, so release-please no longer prepends "partner-edge-".
# Releases ≤v0.12.59 used partner-edge-vX.Y.Z; upgrade.sh handles that old form
# gracefully via normalize_target() so edges mid-flight are not broken.
#
# --dry-run conflict checks (--with-templates only):
#   1 [CATASTROPHIC] Caddyfile validates against currently-running image
#   2 [WARNING]      docker-compose.yml structural drift (ports, env keys, services)
#   3 [CATASTROPHIC] Image tag direction (downgrade detection)
#   4 [INFO]         healthcheck.sh check-line diff
#   5 [INFO]         CADDYFILE_SHA before/after
#   6 [WARNING]      Unsubstituted placeholders in rendered Caddyfile
#   7 [CATASTROPHIC] GHCR token availability
#   8 [WARNING]      Disk space on /var/lib/docker
#
# GHCR auth: ghcr.io/anatolykoptev/partner-edge-* images are private. Provide
# a token via --ghcr-token=ghp_xxx (saved to /etc/oxpulse-partner-edge/ghcr.token
# mode 0600) or OXPULSE_GHCR_TOKEN env (one-shot, not persisted). Once saved,
# the token is reused on every subsequent run; rotate with --ghcr-token=<new>.
# See ghcr-auth-lib.sh for the full auth flow.
set -euo pipefail

PREFIX_ETC="${OXPULSE_PREFIX_ETC:-/etc/oxpulse-partner-edge}"
PREFIX_LIB="${OXPULSE_PREFIX_LIB:-/var/lib/oxpulse-partner-edge}"
PREFIX_SBIN="${OXPULSE_PREFIX_SBIN:-/usr/local/sbin}"
PREFIX_BIN="${OXPULSE_PREFIX_BIN:-/usr/local/bin}"
PREFIX_LIBDIR="${OXPULSE_PREFIX_LIBDIR:-/usr/local/lib/partner-edge}"
PREFIX_SHARE="${OXPULSE_PREFIX_SHARE:-/usr/local/share}"
SYSTEMD_DIR="${OXPULSE_SYSTEMD_DIR:-/etc/systemd/system}"
COMPOSE_FILE="$PREFIX_ETC/docker-compose.yml"
STATE_FILE="$PREFIX_LIB/install.env"
PREV_STATE_FILE="$PREFIX_LIB/install.env.prev"
PREV_COMPOSE_FILE="$PREFIX_LIB/docker-compose.yml.prev"
PREV_CADDYFILE="$PREFIX_LIB/Caddyfile.prev"
PREV_HEALTHCHECK="$PREFIX_LIB/healthcheck.prev"
# Directory where pre-upgrade host-script snapshots are stored for rollback.
PREV_HOST_SCRIPTS_DIR="$PREFIX_LIB/host-scripts.prev"
HEALTHCHECK="${OXPULSE_HEALTHCHECK:-/usr/local/sbin/oxpulse-partner-edge-healthcheck}"
# @RELEASE_TAG_PLACEHOLDER@ in the default below is substituted by release.yml to the release tag
# (vX.Y.Z starting at v0.12.60) so REPO_RAW fetches are pinned to the exact release
# ref, not main HEAD. Without this pin the bytes fetched from raw.githubusercontent.com
# do not match the SHA256SUMS released for that tag (main is always ahead of any tag).
# Tests and operator overrides can still use OXPULSE_REPO_RAW to point at a fixture.
OXPULSE_UPGRADE_TAG="${OXPULSE_UPGRADE_TAG:-@RELEASE_TAG@}"
# Initialize OXPULSE_MIRROR_BASE to empty string so the strip at line 92 and
# the -n checks below are safe under set -u on edges with no mirror configured
# (e.g. zvonilka GitHub-direct edges where install.env lacks OXPULSE_MIRROR_BASE).
OXPULSE_MIRROR_BASE="${OXPULSE_MIRROR_BASE:-}"

# Mirror awareness: OXPULSE_MIRROR_BASE is the plain-TLS mirror used by edges
# DPI-blocked from GitHub (e.g. zvonilka RU relays).  install.sh sets
# REPO_RAW=$MIRROR_BASE/raw when the mirror is set; upgrade.sh reads the
# persisted OXPULSE_MIRROR_BASE from install.env (written at install time) and
# applies the same polarity so that all host-script fetches work on mirror-
# installed edges without requiring operator env injection on every upgrade run.
#
# Resolution order (highest → lowest priority):
#   1. OXPULSE_REPO_RAW env  — operator/test override, wins unconditionally
#   2. OXPULSE_MIRROR_BASE env  — explicit mirror override for this run
#   3. OXPULSE_MIRROR_BASE from install.env  — persisted at install time
#   4. raw.githubusercontent.com pinned to OXPULSE_UPGRADE_TAG (or main for dev)
#
# RELEASES_BASE follows the same polarity: mirror serves release assets under
# the same path structure as GitHub releases ($MIRROR_BASE/$tag/<asset>).
# If only OXPULSE_RELEASES_BASE is set (test override), it wins over mirror.

# Load OXPULSE_MIRROR_BASE from install.env if not already in env.
# We do this before resolving REPO_RAW so the state file overrides the default.
if [[ -z "${OXPULSE_MIRROR_BASE:-}" && -r "${OXPULSE_PREFIX_LIB:-/var/lib/oxpulse-partner-edge}/install.env" ]]; then
    _state_mirror=$(grep '^OXPULSE_MIRROR_BASE=' \
        "${OXPULSE_PREFIX_LIB:-/var/lib/oxpulse-partner-edge}/install.env" \
        2>/dev/null | cut -d= -f2- | tr -d '"' || true)
    [[ -n "$_state_mirror" ]] && OXPULSE_MIRROR_BASE="$_state_mirror"
    unset _state_mirror
fi
OXPULSE_MIRROR_BASE="${OXPULSE_MIRROR_BASE%/}"

if [[ -n "${OXPULSE_REPO_RAW:-}" ]]; then
    REPO_RAW="$OXPULSE_REPO_RAW"
elif [[ -n "${OXPULSE_MIRROR_BASE:-}" ]]; then
    # Mirror installed: raw files come from $MIRROR_BASE/raw (same as install.sh).
    REPO_RAW="$OXPULSE_MIRROR_BASE/raw"
elif [[ ! "${OXPULSE_UPGRADE_TAG}" =~ ^v[0-9]+\. ]]; then
    # Placeholder not substituted or not a real vX.Y.Z tag. Fall back to main
    # so developer/test runs still work. Released upgrade.sh has OXPULSE_UPGRADE_TAG
    # set to the real tag (vX.Y.Z form) by release.yml sed substitution.
    REPO_RAW="https://raw.githubusercontent.com/anatolykoptev/oxpulse-partner-edge/main"
else
    REPO_RAW="https://raw.githubusercontent.com/anatolykoptev/oxpulse-partner-edge/${OXPULSE_UPGRADE_TAG}"
fi

# GitHub releases download base for the target tag.  Tests can override via
# OXPULSE_RELEASES_BASE to point at a local fixture server.
# Mirror polarity: if OXPULSE_MIRROR_BASE is set, releases are served from
# $MIRROR_BASE/<tag>/<asset> (operator must mirror the GitHub release layout).
# OXPULSE_RELEASES_BASE env wins unconditionally (test/operator override).
if [[ -n "${OXPULSE_RELEASES_BASE:-}" ]]; then
    RELEASES_BASE="$OXPULSE_RELEASES_BASE"
elif [[ -n "${OXPULSE_MIRROR_BASE:-}" ]]; then
    RELEASES_BASE="$OXPULSE_MIRROR_BASE"
else
    RELEASES_BASE="https://github.com/anatolykoptev/oxpulse-partner-edge/releases/download"
fi
# shellcheck disable=SC2034  # NODE_CFG + XRAY_CFG used by channel-render-lib.sh (sourced via _source_lib)
NODE_CFG="$PREFIX_ETC/node-config.json"
# shellcheck disable=SC2034
XRAY_CFG="$PREFIX_ETC/xray-client.json"
# Allow tests to override docker binary (e.g. DOCKER_BIN=true for dry-run).
DOCKER_BIN="${DOCKER_BIN:-docker}"
# Allow tests to override systemctl (e.g. SYSTEMCTL_BIN=true to no-op).
SYSTEMCTL_BIN="${SYSTEMCTL_BIN:-systemctl}"

log()  { printf '\033[32m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[33m!!\033[0m  %s\n' "$*" >&2; }
die()  { while IFS= read -r _line; do printf '\033[31mERR\033[0m %s\n' "$_line" >&2; done <<< "$*"; exit 1; }

# _source_lib NAME LOCAL_PATH INSTALLED_PATH REPO_RAW_PATH — source a shared library.
# Resolution order:
#   1. Adjacent to upgrade.sh (local checkout / same-dir download)
#   2. Installed sbin path (/usr/local/sbin/<name>)
#   3. Fetch from REPO_RAW (standalone upgrade.sh downloaded without adjacent libs)
# Tier 3 requires curl and a reachable REPO_RAW.  Fetched file is written to a
# temp dir and sourced from there; it is NOT installed to disk (sync_host_scripts
# handles the verified install later in the run).
# Note: when OXPULSE_UPGRADE_TAG is the real tag (not the @RELEASE_TAG_UNSUBSTITUTED@ sentinel),
# REPO_RAW already points at the pinned release ref — fetched bytes match the
# tag snapshot, not main HEAD.
_source_lib() {
    local name="$1" local_path="$2" installed_path="$3" raw_path="$4"
    if [[ -f "$local_path" ]]; then
        # shellcheck source=/dev/null
        source "$local_path"
        return 0
    elif [[ -f "$installed_path" ]]; then
        # shellcheck source=/dev/null
        source "$installed_path"
        return 0
    fi
    # Tier 3: fetch from REPO_RAW for standalone operator-download runs.
    local _fetch_tmp
    _fetch_tmp=$(mktemp "/tmp/oxpulse-lib-${name}-XXXXXX.sh")
    # shellcheck disable=SC2064
    trap "rm -f '$_fetch_tmp'" RETURN
    if curl -fsSL --max-time 30 "$raw_path" -o "$_fetch_tmp" 2>/dev/null; then
        warn "$name not found locally; fetched from $raw_path (standalone run)"
        warn "For verified install run 'oxpulse-partner-edge-upgrade' after the sync completes"
        # shellcheck source=/dev/null
        source "$_fetch_tmp"
        return 0
    fi
    die "$name not found (tried: $local_path, $installed_path, $raw_path).
On a standalone upgrade.sh download ensure network access to REPO_RAW or stage
the lib files adjacent to upgrade.sh."
}

# Source shared channel render functions (re_render_xray, future re_render_awg, etc.)
# shellcheck source=channel-render-lib.sh
_source_lib "channel-render-lib.sh" \
    "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/channel-render-lib.sh" \
    "${PREFIX_SBIN:-/usr/local/sbin}/channel-render-lib.sh" \
    "$REPO_RAW/channel-render-lib.sh"

# Source ghcr auth helpers (ghcr_save_token / ghcr_login_from_file /
# ghcr_pull_diagnose / ghcr_configure_token).
_source_lib "ghcr-auth-lib.sh" \
    "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/ghcr-auth-lib.sh" \
    "${PREFIX_SBIN:-/usr/local/sbin}/ghcr-auth-lib.sh" \
    "$REPO_RAW/ghcr-auth-lib.sh"

[[ $EUID -eq 0 || "${OXPULSE_SKIP_ROOT_CHECK:-0}" == "1" ]] || die "must run as root"
[[ -r "$COMPOSE_FILE" ]] || die "no installed bundle at $COMPOSE_FILE"
[[ -r "$STATE_FILE" ]]   || die "missing $STATE_FILE — reinstall instead of upgrade"

# Postcondition for pre-2026-05-06 deployments: install.sh used to render
# docker-compose.yml with SIGNALING_SFU_SECRET="" when /api/partner/register
# returned an empty signaling_sfu_secret (warn-and-continue). The SFU's
# /sfu/ws/{room_id} stays disabled in that state and group calls silently
# fail end-to-end. install.sh now dies in that case, but upgrade.sh runs
# on already-installed edges where the broken compose is on disk — refuse
# to upgrade those without operator intervention. /api/partner/register is
# not re-fetched on upgrade, so we cannot self-heal in place.
check_signaling_sfu_secret() {
	local secret_line
	secret_line=$(grep -E '^[[:space:]]*SIGNALING_SFU_SECRET:' "$COMPOSE_FILE" || true)
	if [[ -z "$secret_line" ]]; then
		die "$COMPOSE_FILE has no SIGNALING_SFU_SECRET line.
The SFU's browser WebSocket API is disabled — group calls silently fail
end-to-end. This installation pre-dates the 2026-05-06 fix. Resolve:
  1. On the central (motherly), confirm SIGNALING_SFU_SECRET is set,
     redeploy oxpulse-chat.
  2. Wipe ${PREFIX_ETC} and re-run install.sh on this host to fetch
     a fresh /api/partner/register response.
upgrade.sh cannot heal this in place because /api/partner/register
is not re-fetched on upgrade."
	fi
	# Match: SIGNALING_SFU_SECRET: ""  or  SIGNALING_SFU_SECRET:    (no value)
	if grep -qE '^[[:space:]]*SIGNALING_SFU_SECRET:[[:space:]]*("")?[[:space:]]*$' "$COMPOSE_FILE"; then
		die "$COMPOSE_FILE has empty SIGNALING_SFU_SECRET. The SFU's browser
WebSocket API is disabled — group calls silently fail end-to-end.
This installation pre-dates the 2026-05-06 fix. Resolve:
  1. On the central (motherly), confirm SIGNALING_SFU_SECRET is set,
     redeploy oxpulse-chat.
  2. Wipe ${PREFIX_ETC} and re-run install.sh on this host to fetch
     a fresh /api/partner/register response.
upgrade.sh cannot heal this in place because /api/partner/register
is not re-fetched on upgrade."
	fi
}

check_signaling_sfu_secret

# shellcheck disable=SC1090
. "$STATE_FILE"
CURRENT="${IMAGE_VERSION:-unknown}"

MODE=apply
TARGET=""
DRY_RUN=0
SKIPPED_CHECKS=""
ALLOW_UNVERIFIED=0
# GHCR PAT supplied via --ghcr-token=ghp_xxx flag OR OXPULSE_GHCR_TOKEN env.
# Flag wins over env. Empty string disables the auth path (anonymous pull).
GHCR_TOKEN_ARG="${OXPULSE_GHCR_TOKEN:-}"
for arg in "$@"; do
	case "$arg" in
		--check)              MODE=check ;;
		--rollback)           MODE=rollback ;;
		--templates-only)     MODE=templates ;;
		--with-templates)     MODE=with_templates ;;
		--host-scripts-only)  MODE=host_scripts_only ;;
		--dry-run)            DRY_RUN=1 ;;
		--allow-unverified)   ALLOW_UNVERIFIED=1 ;;
		--skip-check=*)
			_sc=" ${arg#--skip-check=} "
			SKIPPED_CHECKS="${_sc//,/ }"
			unset _sc ;;
		--ghcr-token=*)   GHCR_TOKEN_ARG="${arg#--ghcr-token=}" ;;
		v*|latest)        TARGET="$arg" ;;
		-h|--help)
			sed -n '2,29p' "$0"; exit 0 ;;
		*) die "unknown arg: $arg" ;;
	esac
done

# If operator supplied a fresh token, persist + login NOW. Catches the
# "PAT expired between releases" class of failure before we even try pull.
if [[ -n "$GHCR_TOKEN_ARG" ]]; then
	ghcr_configure_token "$GHCR_TOKEN_ARG" || die "failed to save/login with supplied --ghcr-token (see warning above)"
	unset GHCR_TOKEN_ARG  # don't keep secret in env longer than necessary
fi

V01_TO_V02=0

# FIX 5: exclusive lock to prevent two concurrent upgrade.sh invocations from
# corrupting the .prev backup chain. Both operators writing .prev simultaneously
# would interleave state and leave rollback pointing at partially-applied config.

# Helper: resolve_default_target sets TARGET if empty, preferring VERSION file
# over 'latest' to keep upgrade target deterministic with the installer release.
# Audit 2026-05-22 F2 — operator may invoke `oxpulse-partner-edge-upgrade`
# without args; without this helper, that pulled :latest from GHCR even when
# the installer pinned to a specific tag. Now we honor the same pin unless
# the operator explicitly types `latest`.
resolve_default_target() {
	if [[ -n "$TARGET" ]]; then return 0; fi
	local version_file
	version_file="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/VERSION"
	if [[ -r "$version_file" ]]; then
		TARGET=$(awk '{print $1; exit}' "$version_file")
		log "TARGET defaulted to $TARGET from VERSION file"
		return 0
	fi
	warn "TARGET unspecified and VERSION file missing — defaulting to 'latest' (floating tag, not recommended)"
	TARGET=latest
}

# Helper: normalize_target handles the tag-form transition.
#
# Starting with v0.12.60, git/release/image tags are ALL vX.Y.Z — one form,
# no component prefix.  release-please-config.json has no "component" key.
#
# Edges running a pre-v0.12.60 installer may call upgrade.sh with an old-form
# target (partner-edge-vX.Y.Z).  Strip the prefix so those edges can upgrade
# cleanly to the new tag format without operator intervention.
#
# Resolution order:
#   partner-edge-vX.Y.Z → strip prefix → vX.Y.Z (transition: old-form input)
#   vX.Y.Z              → unchanged             (canonical new form)
#   latest              → unchanged             (floating; SHA256SUMS guard skipped)
#
# Sets RELEASE_TAG = TARGET (same value; no dual forms post-v0.12.60).
# Always called after resolve_default_target.
normalize_target() {
	case "$TARGET" in
		partner-edge-v*)
			# Transition: old-form input from pre-v0.12.60 installer. Strip prefix.
			TARGET="${TARGET#partner-edge-}"
			warn "old tag form detected — treating as $TARGET (releases ≥v0.12.60 use vX.Y.Z)"
			;;
	esac
	# One-form world: RELEASE_TAG = TARGET (git tag = image tag = release tag).
	RELEASE_TAG="$TARGET"
}

# Alias kept for callers that still use the old name (host-scripts-only path etc.)
derive_release_tag() { normalize_target; }

# Skip for read-only modes: --dry-run and --check never mutate state.
if [[ "$DRY_RUN" -eq 0 && "$MODE" != check ]]; then
	LOCK_FILE="$PREFIX_LIB/upgrade.lock"
	exec 9>"$LOCK_FILE"
	flock -n 9 || die "another upgrade.sh is running (lock: $LOCK_FILE). If stuck, check the pid and remove the lock file."
fi

# --templates-only: re-render channel client configs from upstream templates, skip image ops.
if [[ "$MODE" == templates ]]; then
	log "--templates-only: refreshing channel client configs from upstream templates"
	re_render_xray
	# Phase 1.7 — render hy2 too if creds available
	if [[ -n "${HY2_AUTH_PASS:-${OXPULSE_HY2_AUTH_PASS:-}}" \
	   && -n "${HY2_OBFS_PASS:-${OXPULSE_HY2_OBFS_PASS:-}}" ]]; then
		HY2_AUTH_PASS="${HY2_AUTH_PASS:-$OXPULSE_HY2_AUTH_PASS}"
		HY2_OBFS_PASS="${HY2_OBFS_PASS:-$OXPULSE_HY2_OBFS_PASS}"
		export HY2_AUTH_PASS HY2_OBFS_PASS
		re_render_hysteria2
		log "hy2 channel refreshed"
	else
		log "hy2 credentials not in env — skipping (set OXPULSE_HY2_AUTH_PASS + OXPULSE_HY2_OBFS_PASS)"
	fi
	log "done"
	exit 0
fi

# ---------------------------------------------------------------------------
# re_render_caddy — fetch Caddyfile.tpl, render with install.env values,
# compute and embed the sha256 (__CADDYFILE_SHA__ logic matching install.sh),
# update CADDYFILE_SHA in install.env.
#
# Design constraint: docker-compose.yml has 20+ placeholders (TURN_SECRET,
# REALITY_* secrets, SFU secrets, etc.) that live only in the baked-in live
# compose file; install.env does NOT persist them. Re-rendering compose from
# template would silently wipe those secrets. Therefore --with-templates
# re-renders Caddyfile only and patch-updates image tags in compose (same as
# the plain image-upgrade path). See PR body for full rationale.
#
# Piter node: caddy service absent — Caddyfile render is skipped gracefully.
# ---------------------------------------------------------------------------
re_render_caddy() {
	local tmpdir out_tpl out_caddy rendered_sha

	# Detect piter (SFU-only): no caddy service in live compose.
	if ! grep -qE '^\s+caddy:' "$COMPOSE_FILE" 2>/dev/null; then
		warn "caddy service not found in $COMPOSE_FILE — skipping Caddyfile re-render (SFU-only node?)"
		return 0
	fi

	[[ -n "${PARTNER_DOMAIN:-}" ]]   || die "PARTNER_DOMAIN missing from $STATE_FILE — cannot render Caddyfile"
	[[ -n "${TURNS_SUBDOMAIN:-}" ]]  || die "TURNS_SUBDOMAIN missing from $STATE_FILE — cannot render Caddyfile"

	tmpdir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	out_tpl="$tmpdir/Caddyfile.tpl"
	out_caddy="$tmpdir/Caddyfile"

	log "fetching Caddyfile.tpl from $REPO_RAW"
	if ! curl -fsSL --max-time 30 "$REPO_RAW/Caddyfile.tpl" -o "$out_tpl" 2>/dev/null; then
		die "could not fetch Caddyfile.tpl from $REPO_RAW — aborting (no changes applied)"
	fi

	# Escape sed replacement metacharacters (same helper as channel-render-lib.sh).
	_esc() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

	# Render placeholders. Only PARTNER_DOMAIN and TURNS_SUBDOMAIN are in
	# Caddyfile.tpl — confirmed by grep of the template.
	sed \
		-e "s|{{PARTNER_DOMAIN}}|$(_esc "$PARTNER_DOMAIN")|g" \
		-e "s|{{TURNS_SUBDOMAIN}}|$(_esc "$TURNS_SUBDOMAIN")|g" \
		"$out_tpl" > "$out_caddy"

	# Phase 1: compute sha256 of the rendered file BEFORE substituting
	# __CADDYFILE_SHA__ — this matches install.sh exactly so that
	# /canary/config-hash returns the recorded hash and check 15 stays green.
	rendered_sha=$(sha256sum "$out_caddy" | awk '{print $1}')
	sed -i "s|__CADDYFILE_SHA__|${rendered_sha}|g" "$out_caddy"

	if [[ "$DRY_RUN" -eq 1 ]]; then
		log "[dry-run] would write Caddyfile (sha256=$rendered_sha) to $PREFIX_ETC/Caddyfile"
		log "[dry-run] would update CADDYFILE_SHA=$rendered_sha in $STATE_FILE"
		return 0
	fi

	# FIX 3: atomic install via sibling temp + mv (rename(2) on same filesystem).
	# Direct install -m 0644 does O_WRONLY|O_TRUNC — caddy reading during the
	# write window sees truncated content → crashloop (cheburator morning incident).
	local tmp_caddy="$PREFIX_ETC/Caddyfile.new.$$"
	install -m 0644 "$out_caddy" "$tmp_caddy"
	mv -f "$tmp_caddy" "$PREFIX_ETC/Caddyfile"
	log "Caddyfile rendered (sha256=$rendered_sha)"

	# Update CADDYFILE_SHA in install.env (replace existing line or append).
	if grep -q '^CADDYFILE_SHA=' "$STATE_FILE"; then
		sed -i "s|^CADDYFILE_SHA=.*|CADDYFILE_SHA=${rendered_sha}|" "$STATE_FILE"
	else
		printf 'CADDYFILE_SHA=%s\n' "$rendered_sha" >> "$STATE_FILE"
	fi
}

# ---------------------------------------------------------------------------
# re_render_healthcheck — fetch fresh healthcheck.sh, install atomically.
# healthcheck.sh has no template placeholders — straight copy.
# ---------------------------------------------------------------------------
re_render_healthcheck() {
	local tmpdir out_hc

	tmpdir=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$tmpdir'" RETURN

	out_hc="$tmpdir/healthcheck.sh"

	log "fetching healthcheck.sh from $REPO_RAW"
	if ! curl -fsSL --max-time 30 "$REPO_RAW/healthcheck.sh" -o "$out_hc" 2>/dev/null; then
		die "could not fetch healthcheck.sh from $REPO_RAW — aborting (no changes applied)"
	fi

	if [[ "$DRY_RUN" -eq 1 ]]; then
		log "[dry-run] would install healthcheck.sh to $HEALTHCHECK"
		return 0
	fi

	# FIX 3: atomic install — sibling temp + mv (same filesystem → rename(2)).
	local tmp_hc
	tmp_hc="$(dirname "$HEALTHCHECK")/healthcheck.sh.new.$$"
	install -m 0755 "$out_hc" "$tmp_hc"
	mv -f "$tmp_hc" "$HEALTHCHECK"
	log "healthcheck.sh updated"
}

# ---------------------------------------------------------------------------
# HOST-SCRIPT SYNC — fetch sbin scripts + systemd units for the target tag,
# verify against SHA256SUMS from the GitHub release, install atomically, and
# daemon-reload + restart only the affected timer/service units.
#
# Design constraints:
#   • Never regenerate identity (reality.*, AWG, service token) — scripts and
#     units only, never config files under PREFIX_ETC.
#   • Idempotent: sha256 match → skip (no restart, no daemon-reload noise).
#   • Mirrors install-systemd.sh install logic; reuses its path conventions.
#   • DOES NOT restart coturn/sfu/xray — those are the image path's concern.
# ---------------------------------------------------------------------------

# Sbin files managed by the host-script sync.  This mirrors EXPECTED_SBIN_FILES
# in install-systemd.sh and must be kept in sync when scripts are added/removed.
#
# NOTE on path variants:
#   • Most files → $PREFIX_SBIN (/usr/local/sbin)
#   • oxpulse-xray-update.sh → $PREFIX_BIN (/usr/local/bin) per install-systemd.sh:265
#     (ExecStart=/usr/local/bin/oxpulse-xray-update.sh in oxpulse-xray-update.service)
#
# Both are synced here so that oxpulse-xray-update.timer and
# oxpulse-geoip-refresh.timer, which are restarted by _HOST_SCRIPT_RESTART_UNITS,
# fire up-to-date script bodies (not stale pre-upgrade copies).
_HOST_SCRIPT_SBIN_FILES=(
	oxpulse-partner-edge-upgrade
	oxpulse-partner-edge-hydrate
	oxpulse-partner-edge-refresh
	oxpulse-partner-edge-sni-rotate
	oxpulse-channels-health-report
	oxpulse-geoip-refresh
	oxpulse-xray-update.sh
	channel-render-lib.sh
	ghcr-auth-lib.sh
	render-channel-lib.sh
	oxpulse-token-lib.sh
	telegram-alert-lib.sh
	# Split-routing scripts (PR #280; RU profile only, ship to all edges for idempotency).
	oxpulse-partner-edge-split-routing
	oxpulse-partner-edge-split-disable
	oxpulse-partner-edge-ru-subnets-update
	# Hysteria2 CH3 activation helper (Phase 1.7 standalone entry point).
	oxpulse-partner-edge-enable-hy2
)

# Remote path in the release bundle for each sbin file.  Maps installed name →
# REPO_RAW-relative fetch path (the name under which the file lives in the repo
# and is published to raw.githubusercontent.com).
_host_script_remote_name() {
	local installed_name="$1"
	case "$installed_name" in
		oxpulse-partner-edge-upgrade)    echo "upgrade.sh" ;;
		oxpulse-partner-edge-hydrate)    echo "hydrate.sh" ;;
		oxpulse-partner-edge-refresh)    echo "oxpulse-partner-edge-refresh.sh" ;;
		oxpulse-partner-edge-sni-rotate) echo "oxpulse-partner-edge-sni-rotate.sh" ;;
		oxpulse-channels-health-report)  echo "oxpulse-channels-health-report.sh" ;;
		oxpulse-geoip-refresh)           echo "scripts/oxpulse-geoip-refresh.sh" ;;
		oxpulse-xray-update.sh)          echo "scripts/oxpulse-xray-update.sh" ;;
		channel-render-lib.sh)           echo "channel-render-lib.sh" ;;
		ghcr-auth-lib.sh)                echo "ghcr-auth-lib.sh" ;;
		render-channel-lib.sh)           echo "lib/render-channel-lib.sh" ;;
		oxpulse-token-lib.sh)            echo "oxpulse-token-lib.sh" ;;
		telegram-alert-lib.sh)           echo "lib/telegram-alert-lib.sh" ;;
		oxpulse-partner-edge-split-routing)    echo "oxpulse-partner-edge-split-routing.sh" ;;
		oxpulse-partner-edge-split-disable)    echo "oxpulse-partner-edge-split-disable.sh" ;;
		oxpulse-partner-edge-ru-subnets-update) echo "oxpulse-partner-edge-ru-subnets-update" ;;
		oxpulse-partner-edge-enable-hy2)        echo "oxpulse-partner-edge-enable-hy2" ;;
		*)                               echo "$installed_name" ;;
	esac
}

# Installation directory for each sbin file.  Most go to PREFIX_SBIN;
# oxpulse-xray-update.sh goes to PREFIX_BIN (/usr/local/bin) because its
# systemd unit has ExecStart=/usr/local/bin/oxpulse-xray-update.sh.
_host_script_install_dir() {
	local installed_name="$1"
	case "$installed_name" in
		oxpulse-xray-update.sh) echo "$PREFIX_BIN" ;;
		*)                       echo "$PREFIX_SBIN" ;;
	esac
}

# Permissions for each sbin file (executable scripts vs sourced libs).
_host_script_mode() {
	local installed_name="$1"
	case "$installed_name" in
		channel-render-lib.sh|ghcr-auth-lib.sh|render-channel-lib.sh|oxpulse-token-lib.sh)
			echo "0644" ;;
		*)  echo "0755" ;;
	esac
}

# Systemd units that must be restarted after a host-script change.
# We restart only the units that exec the scripts we sync — NOT coturn/sfu/xray.
_HOST_SCRIPT_RESTART_UNITS=(
	oxpulse-channels-health-report.timer
	oxpulse-partner-edge-refresh.timer
	oxpulse-partner-edge-sni-rotate.timer
	oxpulse-xray-update.timer
	oxpulse-geoip-refresh.timer
	# Split-routing (PR #280): restart timer + re-apply oneshot on script update.
	oxpulse-partner-edge-ru-subnets-update.timer
	oxpulse-partner-edge-split-routing.service
)

# Systemd unit files synced by sync_host_scripts (Step 5).
# Adding a unit here is sufficient to have it fetched, checksum-verified, and installed
# on every upgrade.  No need to touch sync_host_scripts internals.
_HOST_SCRIPT_SYSTEMD_FILES=(
	oxpulse-partner-edge.service
	oxpulse-partner-edge-hydrate.service
	oxpulse-partner-edge-refresh.service
	oxpulse-partner-edge-refresh.timer
	oxpulse-partner-edge-sni-rotate.service
	oxpulse-partner-edge-sni-rotate.timer
	oxpulse-xray-update.service
	oxpulse-xray-update.timer
	oxpulse-geoip-refresh.service
	oxpulse-geoip-refresh.timer
	oxpulse-channels-health-report.service
	oxpulse-channels-health-report.timer
	# Split-routing (PR #280).
	oxpulse-partner-edge-split-routing.service
	oxpulse-partner-edge-ru-subnets-update.service
	oxpulse-partner-edge-ru-subnets-update.timer
)

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

# ---------------------------------------------------------------------------
# PER-CONTAINER DIGEST-SKIP — zero-downtime recreate
#
# capture_running_digests — snapshot the imageID (sha256:...) of every
# currently-running container managed by compose.  Stores in a bash
# associative array passed by name.
#
# Usage:
#   declare -A before_digests
#   capture_running_digests before_digests
#
# Each key is the compose service name; value is the running imageID or ""
# if the container is absent / not running (first-pull or stopped).
# ---------------------------------------------------------------------------
capture_running_digests() {
	local -n _crd_map="$1"
	local svc container_name image_id
	# List service names from the compose file.
	local services
	services=$(cd "$PREFIX_ETC" && $DOCKER_BIN compose config --services 2>/dev/null || true)
	[[ -n "$services" ]] || return 0

	while IFS= read -r svc; do
		[[ -n "$svc" ]] || continue
		# docker compose ps --quiet returns container IDs for the service.
		container_name=$(cd "$PREFIX_ETC" && $DOCKER_BIN compose ps --quiet "$svc" 2>/dev/null | head -1 || true)
		if [[ -n "$container_name" ]]; then
			image_id=$($DOCKER_BIN inspect --format '{{.Image}}' "$container_name" 2>/dev/null || true)
		else
			image_id=""
		fi
		_crd_map["$svc"]="$image_id"
	done <<< "$services"
}

# resolve_pulled_digests — after compose pull, resolve the imageID for the
# currently configured image of each service (what compose would use on up).
# Stores in a bash associative array passed by name.
#
# Fail-safe: if a service's image digest cannot be resolved, stores "" which
# causes the caller to fall back to recreating that service.
resolve_pulled_digests() {
	local -n _rpd_map="$1"
	local svc image_ref image_id
	local services
	services=$(cd "$PREFIX_ETC" && $DOCKER_BIN compose config --services 2>/dev/null || true)
	[[ -n "$services" ]] || return 0

	while IFS= read -r svc; do
		[[ -n "$svc" ]] || continue
		# Resolve the image reference for this service from compose config output.
		image_ref=$(cd "$PREFIX_ETC" && $DOCKER_BIN compose config 2>/dev/null \
			| awk -v svc="$svc" '
				/^services:/{in_services=1; next}
				in_services && /^  [^ ]/{
					gsub(/:$/,""); current_svc=$0; gsub(/^  /,"",current_svc)
					next
				}
				in_services && current_svc==svc && /image:/{
					sub(/.*image:[[:space:]]*/,""); print; exit
				}
			' || true)
		if [[ -n "$image_ref" ]]; then
			image_id=$($DOCKER_BIN inspect --format '{{.Id}}' "$image_ref" 2>/dev/null || true)
		else
			image_id=""
		fi
		_rpd_map["$svc"]="$image_id"
	done <<< "$services"
}

# recreate_changed_services BEFORE_MAP_NAME AFTER_MAP_NAME
#
# Compares before/after digests per service.  Services whose imageID changed
# (or whose before digest was empty — first pull, container absent) are
# recreated with `docker compose up -d --no-deps <svc>`.
# If ALL services are unchanged, exits 0 without calling compose up at all
# (true zero-downtime for no-op version bumps).
#
# Returns: 0 = success (all changed services restarted), non-zero = compose failure.
# On failure the caller is responsible for rollback; this function does NOT roll back.
recreate_changed_services() {
	local -n _rcs_before="$1"
	local -n _rcs_after="$2"

	local changed_services=()
	local svc

	# Union of all service names from both maps.
	local all_svcs=()
	for svc in "${!_rcs_before[@]}"; do all_svcs+=("$svc"); done
	for svc in "${!_rcs_after[@]}"; do
		# Add only if not already present.
		local found=0
		local s
		for s in "${all_svcs[@]}"; do [[ "$s" == "$svc" ]] && found=1 && break; done
		[[ "$found" -eq 0 ]] && all_svcs+=("$svc")
	done

	for svc in "${all_svcs[@]}"; do
		local before="${_rcs_before[$svc]:-}"
		local after="${_rcs_after[$svc]:-}"

		if [[ -z "$before" || -z "$after" || "$before" != "$after" ]]; then
			# Empty digest (first pull / missing container / resolve failure) → fail-safe: recreate.
			if [[ -z "$after" ]]; then
				warn "digest-skip: could not resolve post-pull digest for '$svc' — recreating (fail-safe)"
			elif [[ -z "$before" ]]; then
				log "digest-skip: '$svc' has no running container before pull — recreating"
			else
				log "digest-skip: '$svc' digest changed ($before → $after) — recreating"
			fi
			changed_services+=("$svc")
		else
			log "digest-skip: '$svc' digest unchanged ($after) — skipping recreate (zero-downtime)"
		fi
	done

	if [[ "${#changed_services[@]}" -eq 0 ]]; then
		log "digest-skip: no service image changed — zero-downtime, no recreate"
		return 0
	fi

	log "recreating changed services: ${changed_services[*]}"
	(cd "$PREFIX_ETC" && $DOCKER_BIN compose up -d --no-deps "${changed_services[@]}")
}

# settle_healthcheck_with_retry — poll healthcheck after container recreation.
#
# Background: xray Reality tunnel establishment on first connection takes up to
# 8s (uTLS cipher randomisation per connection, measured on rvpn during the
# v0.12.20 upgrade incident 2026-05-09).  A single `sleep 10` leaves only a 2s
# slack margin, which is exceeded on a loaded edge, producing a false-negative
# healthcheck failure and an automatic rollback.
#
# This function polls healthcheck.sh --local every POLL_INTERVAL seconds, up to
# MAX_ATTEMPTS times (total budget ≈ MAX_ATTEMPTS × POLL_INTERVAL).
#
# Defaults (env-configurable via OXPULSE_UPGRADE_HEALTH_TIMEOUT):
#   OXPULSE_UPGRADE_HEALTH_TIMEOUT=30  — total poll budget in seconds
#   POLL_INTERVAL=3                    — seconds between attempts
#   MAX_ATTEMPTS=10                    — budget/interval (rounded up); at
#                                        3s × 10 = 30s we have 4× the observed
#                                        worst-case (8s) plus a 6s margin for a
#                                        loaded edge — safe for production.
#
# Returns 0 as soon as healthcheck passes; non-zero if ALL attempts exhausted.
settle_healthcheck_with_retry() {
	local label="${1:-post-upgrade}"  # context for log messages
	local budget="${OXPULSE_UPGRADE_HEALTH_TIMEOUT:-30}"
	local interval=3
	local max_attempts=$(( (budget + interval - 1) / interval ))  # ceil(budget/interval)

	local attempt=1
	while [[ "$attempt" -le "$max_attempts" ]]; do
		log "healthcheck attempt $attempt/$max_attempts (${label})…"
		if "$HEALTHCHECK" --local; then
			log "healthcheck passed on attempt $attempt/$max_attempts (${label})"
			return 0
		fi
		if [[ "$attempt" -lt "$max_attempts" ]]; then
			log "healthcheck not yet passing — retrying in ${interval}s"
			sleep "$interval"
		fi
		attempt=$(( attempt + 1 ))
	done
	warn "healthcheck still failing after $max_attempts attempt(s) (budget=${budget}s) — ${label}"
	return 1
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

# ---------------------------------------------------------------------------
# do_rollback_templates — restore Caddyfile, healthcheck, and install.env
# from .prev backups. Called by --rollback when template backups exist, and
# auto-triggered after --with-templates healthcheck failure.
# ---------------------------------------------------------------------------
do_rollback_templates() {
	local restored=0

	if [[ -f "$PREV_CADDYFILE" ]]; then
		install -m 0644 "$PREV_CADDYFILE" "$PREFIX_ETC/Caddyfile"
		log "restored Caddyfile from backup"
		restored=1
	fi
	if [[ -f "$PREV_HEALTHCHECK" ]]; then
		install -m 0755 "$PREV_HEALTHCHECK" "$HEALTHCHECK"
		log "restored healthcheck from backup"
		restored=1
	fi
	if [[ -f "$PREV_STATE_FILE" ]]; then
		cp -a "$PREV_STATE_FILE" "$STATE_FILE"
		log "restored install.env from backup"
		restored=1
	fi
	if [[ -f "$PREV_COMPOSE_FILE" ]]; then
		cp -a "$PREV_COMPOSE_FILE" "$COMPOSE_FILE"
		log "restored docker-compose.yml from backup"
		restored=1
	fi

	[[ "$restored" -eq 1 ]] || die "no .prev backup files found — nothing to restore"

	# FIX 4: ensure the previous image is in local cache before the caller does
	# compose up. If the previous tag was a floating tag that has since been
	# evicted from the local cache, compose up would use whatever is cached —
	# possibly stale or wrong. Pull is best-effort; failure is non-fatal because
	# the image may still be present from the original pull.
	log "rollback: ensuring previous image is in local cache"
	(cd "$PREFIX_ETC" && ghcr_login_from_file || true; $DOCKER_BIN compose pull) \
		|| warn "rollback pull failed — proceeding with cached image"
}

maybe_v01_to_v02_preflight() {
	[[ "$CURRENT" =~ ^v0\.1($|\.) ]] || return 0
	[[ "$TARGET"  =~ ^v0\.2($|\.) ]] || return 0

	log "detected v0.1.x → v0.2.x migration — running DNS preflight"

	[[ -n "${TURNS_SUBDOMAIN:-}" ]] || die "TURNS_SUBDOMAIN missing from $STATE_FILE — state file is from a pre-Phase-6 build, re-run install.sh to populate it"
	[[ -n "${PARTNER_DOMAIN:-}"  ]] || die "PARTNER_DOMAIN missing from $STATE_FILE — state file is from a pre-Phase-6 build, re-run install.sh to populate it"

	PUBLIC_IP=$(curl -fsS --max-time 5 https://ifconfig.me 2>/dev/null || curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
	[[ -n "$PUBLIC_IP" ]] || die "could not determine public IP (both ifconfig.me and api.ipify.org failed)"

	command -v dig >/dev/null 2>&1 || die "'dig' is not installed — install dnsutils (Debian/Ubuntu: 'apt-get install dnsutils'; RHEL/Rocky/Alma/CentOS: 'dnf install bind-utils') and retry"
	DIG_IPS=$(dig +short +time=3 +tries=1 "${TURNS_SUBDOMAIN}.${PARTNER_DOMAIN}" A | grep -E '^[0-9.]+$' | sort -u)
	if ! grep -Fxq "$PUBLIC_IP" <<< "$DIG_IPS"; then
		die "DNS preflight failed:
  expected A-record for ${TURNS_SUBDOMAIN}.${PARTNER_DOMAIN} to include ${PUBLIC_IP}
  got: ${DIG_IPS:-<no record>}
  fix: add A-record '${TURNS_SUBDOMAIN}.${PARTNER_DOMAIN} -> ${PUBLIC_IP}' at your DNS provider, then re-run upgrade"
	fi

	V01_TO_V02=1
}

maybe_v01_to_v02_preflight

# ---- --rollback mode ----
if [[ "$MODE" == rollback ]]; then
	# Template rollback: restore Caddyfile/healthcheck if .prev files exist.
	_have_template_prev=0
	[[ -f "$PREV_CADDYFILE" || -f "$PREV_HEALTHCHECK" ]] && _have_template_prev=1

	# Image rollback: compose.prev + state.prev must exist.
	_have_image_prev=0
	[[ -r "$PREV_STATE_FILE" && -r "$PREV_COMPOSE_FILE" ]] && _have_image_prev=1

	_have_host_scripts_prev=0
	[[ -d "$PREV_HOST_SCRIPTS_DIR/sbin" ]] && _have_host_scripts_prev=1

	[[ "$_have_template_prev" -eq 1 || "$_have_image_prev" -eq 1 || "$_have_host_scripts_prev" -eq 1 ]] \
		|| die "no previous version recorded — nothing to roll back to"

	log "rolling back to previous state"
	do_rollback_templates  # restores Caddyfile, healthcheck, compose, install.env .prev files
	restore_host_scripts   # restores sbin scripts + systemd units from snapshot

	if [[ "$DRY_RUN" -eq 0 ]]; then
		(ghcr_login_from_file || true; cd "$PREFIX_ETC" && $DOCKER_BIN compose pull)
		(cd "$PREFIX_ETC" && $DOCKER_BIN compose up -d --force-recreate)
		sleep 10
		if "$HEALTHCHECK" --local; then
			log "rollback complete"
			exit 0
		else
			die "rollback applied but healthcheck still failing — manual recovery required"
		fi
	else
		log "[dry-run] would docker compose pull + up -d after rollback"
		exit 0
	fi
fi

# ---- --host-scripts-only mode ----
# Sync sbin scripts + systemd units for the target tag and restart affected
# timers.  Does NOT pull images or recreate containers — guaranteed zero-
# downtime.  Use for host-script-only releases (e.g. ch4 coturn probe) on
# edges where the container image is pinned and must not be disturbed.
if [[ "$MODE" == host_scripts_only ]]; then
	resolve_default_target
	derive_release_tag
	log "--host-scripts-only: syncing host-scripts to $RELEASE_TAG (containers untouched)"
	if [[ "$DRY_RUN" -eq 1 ]]; then
		log "[dry-run] would call sync_host_scripts $RELEASE_TAG"
		log "[dry-run] would restart: ${_HOST_SCRIPT_RESTART_UNITS[*]}"
		log "[dry-run] image pull and container recreate: not performed (--host-scripts-only)"
		exit 0
	fi
	sync_host_scripts "$RELEASE_TAG"
	log "--host-scripts-only complete (release_tag=$RELEASE_TAG target=$TARGET); no image pull or container recreate"
	exit 0
fi

# ---------------------------------------------------------------------------
# Conflict detection helpers — used only by run_conflict_checks().
# Each _check_N function sets CHECK_STATUS[N] and appends to CHECK_DETAIL[N].
# Severity: CATASTROPHIC | WARNING | INFO | PASS | SKIP
# ---------------------------------------------------------------------------

# _check_skip N — returns 0 (true = skip) if check N is in SKIPPED_CHECKS
_check_skip() {
	[[ " $SKIPPED_CHECKS " == *" $1 "* ]]
}

# Check 1: Caddyfile validates against currently-running caddy image.
_conflict_check_1() {
	CHECK_STATUS[1]="PASS"
	CHECK_DETAIL[1]=""

	local rendered_caddy="$1"

	# If caddy container is not running, treat as INFO (not catastrophic — e.g. fresh install).
	local current_image
	current_image=$($DOCKER_BIN inspect oxpulse-partner-caddy \
		--format '{{.Config.Image}}' 2>/dev/null || true)
	if [[ -z "$current_image" ]]; then
		CHECK_STATUS[1]="INFO"
		CHECK_DETAIL[1]="  Container oxpulse-partner-caddy not running — validation skipped (INFO only)."
		return
	fi

	if [[ ! -f "$rendered_caddy" ]]; then
		CHECK_STATUS[1]="INFO"
		CHECK_DETAIL[1]="  Rendered Caddyfile not available — caddy not in live compose (SFU-only node?)."
		return
	fi

	# Locate cover dir from live compose for the volume mount.
	# FIX 1: extract the HOST-side path (left of ':') not the container path.
	# Repro: echo '      - ./cover:/srv/cover:ro' | grep -oP 'cover:\s*\K[^[:space:]]+'
	#        outputs /srv/cover:ro (container path) — causes docker: invalid volume spec.
	local cover_dir
	cover_dir=$(grep -oP '^\s*-\s*\K[^[:space:]:]+(?=:/srv/cover)' "$COMPOSE_FILE" 2>/dev/null | head -1 || true)
	# Resolve relative paths against the compose file directory.
	if [[ -n "$cover_dir" && "$cover_dir" =~ ^\./ ]]; then
		cover_dir="$(dirname "$COMPOSE_FILE")/${cover_dir#./}"
	fi
	# FIX 2: use an empty tmpdir fallback rather than /tmp (which would mount
	# unrelated host content over /srv/cover, giving false caddy validate results).
	if [[ -z "$cover_dir" || ! -d "$cover_dir" ]]; then
		cover_dir=$(mktemp -d)
		# shellcheck disable=SC2064
		trap "rm -rf '$cover_dir'" RETURN
	fi

	local validate_out validate_rc
	validate_rc=0
	validate_out=$($DOCKER_BIN run --rm \
		-v "${rendered_caddy}:/etc/caddy/Caddyfile:ro" \
		-v "${cover_dir}:/srv/cover:ro" \
		"$current_image" \
		caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1) || validate_rc=$?

	if [[ $validate_rc -ne 0 ]]; then
		CHECK_STATUS[1]="CATASTROPHIC"
		local err_line
		err_line=$(printf '%s' "$validate_out" | grep -m1 'Error\|error\|unrecognized' || echo "$validate_out" | tail -1)
		CHECK_DETAIL[1]="  Image: $current_image
  Error: $err_line
  Hint:  This would crashloop caddy on apply. Either upgrade image first
         (oxpulse-partner-edge-upgrade --image-only) or pin to compatible Caddyfile."
	fi
}

# Check 2: docker-compose.yml structural drift (ports, env keys, services).
_conflict_check_2() {
	CHECK_STATUS[2]="PASS"
	CHECK_DETAIL[2]=""

	local compose_tpl="$1"

	[[ -f "$compose_tpl" ]] || { CHECK_STATUS[2]="INFO"; CHECK_DETAIL[2]="  Compose template not fetched — skipped."; return; }
	[[ -f "$COMPOSE_FILE"  ]] || { CHECK_STATUS[2]="INFO"; CHECK_DETAIL[2]="  Live compose not found — skipped."; return; }

	local issues
	issues=$(python3 - "$COMPOSE_FILE" "$compose_tpl" << 'PYEOF'
import sys, re

def load_yaml_simple(path):
    """Minimal YAML structural parser — only extracts service names, port lists, and env keys."""
    import subprocess
    result = subprocess.run(
        ['python3', '-c', '''
import sys, yaml, json
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)
svcs = data.get("services", {}) or {}
out = {}
for svc, cfg in svcs.items():
    cfg = cfg or {}
    ports = [str(p) for p in (cfg.get("ports") or [])]
    env = cfg.get("environment") or {}
    if isinstance(env, list):
        keys = sorted(e.split("=")[0] for e in env)
    else:
        keys = sorted(env.keys())
    out[svc] = {"ports": sorted(ports), "env_keys": keys}
print(json.dumps(out))
''', sys.argv[1]],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        return None, result.stderr.strip()
    import json
    return json.loads(result.stdout), None

import json, subprocess, sys

live_path = sys.argv[1]
tpl_path  = sys.argv[2]

live_data, live_err = load_yaml_simple(live_path)
tpl_data,  tpl_err  = load_yaml_simple(tpl_path)

if live_err:
    print(f"WARN: cannot parse live compose: {live_err}")
    sys.exit(0)
if tpl_err:
    print(f"WARN: cannot parse template compose: {tpl_err}")
    sys.exit(0)

issues = []
# New services in template
for svc in sorted(tpl_data):
    if svc not in live_data:
        issues.append(f"  Service '{svc}' in template but NOT in live compose (new service added by template).")

# Structural drift per existing service
for svc in sorted(tpl_data):
    if svc not in live_data:
        continue
    live = live_data[svc]
    tmpl = tpl_data[svc]

    live_ports = set(live["ports"])
    tmpl_ports = set(tmpl["ports"])
    # Filter out placeholder-bearing ports (not substituted in template)
    tmpl_ports_real = {p for p in tmpl_ports if "{{" not in p and "__" not in p}
    new_ports = tmpl_ports_real - live_ports
    if new_ports:
        for p in sorted(new_ports):
            remediation = f'sudo sed -i \'/- "{list(live_ports)[0] if live_ports else "443:443"}"/a\\\\      - "{p}"\' /etc/oxpulse-partner-edge/docker-compose.yml'
            issues.append(
                f"  Service '{svc}': template adds port {p!r} not in live compose.\n"
                f"  Will NOT propagate via --with-templates. Manual remediation:\n"
                f"    {remediation}"
            )

    live_keys = set(live["env_keys"])
    tmpl_keys = {k for k in tmpl["env_keys"] if "{{" not in k and "__" not in k}
    new_keys = tmpl_keys - live_keys
    if new_keys:
        issues.append(
            f"  Service '{svc}': template adds env keys {sorted(new_keys)!r} not in live compose.\n"
            f"  Will NOT propagate via --with-templates. Requires manual patch or full reinstall."
        )

for i in issues:
    print(i)
PYEOF
)
	if [[ -n "$issues" ]]; then
		CHECK_STATUS[2]="WARNING"
		CHECK_DETAIL[2]="$issues"
	fi
}

# Check 3: Image tag direction — detect downgrade.
_conflict_check_3() {
	CHECK_STATUS[3]="PASS"
	CHECK_DETAIL[3]=""

	local proposed="$1"

	# If proposed is latest, we can't compare meaningfully.
	if [[ "$proposed" == "latest" ]]; then
		if [[ "$CURRENT" =~ ^v[0-9] ]]; then
			CHECK_STATUS[3]="WARNING"
			CHECK_DETAIL[3]="  Proposed tag is 'latest'; current is '$CURRENT'. Cannot compare — manual review recommended."
		fi
		return
	fi

	# Both must match vMAJOR.MINOR.PATCH for semver comparison.
	local _semver_re='^v([0-9]+)\.([0-9]+)\.([0-9]+)'
	if [[ "$CURRENT" =~ $_semver_re ]] && [[ "$proposed" =~ $_semver_re ]]; then
		local cur_maj cur_min cur_pat prop_maj prop_min prop_pat
		[[ "$CURRENT"  =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+) ]]; cur_maj=${BASH_REMATCH[1]}; cur_min=${BASH_REMATCH[2]}; cur_pat=${BASH_REMATCH[3]}
		[[ "$proposed" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+) ]]; prop_maj=${BASH_REMATCH[1]}; prop_min=${BASH_REMATCH[2]}; prop_pat=${BASH_REMATCH[3]}

		local cur_int prop_int
		cur_int=$(( cur_maj * 1000000 + cur_min * 1000 + cur_pat ))
		prop_int=$(( prop_maj * 1000000 + prop_min * 1000 + prop_pat ))

		if (( prop_int < cur_int )); then
			CHECK_STATUS[3]="CATASTROPHIC"
			CHECK_DETAIL[3]="  Proposed $proposed < current $CURRENT — this is a DOWNGRADE.
  Downgrades may break persisted state or replay incompatible config.
  If intentional, use --skip-check=3."
		fi
	else
		CHECK_STATUS[3]="WARNING"
		CHECK_DETAIL[3]="  Cannot parse versions for semver comparison: current='$CURRENT' proposed='$proposed'.
  Manual review recommended."
	fi
}

# Check 4: healthcheck.sh check-count diff.
_conflict_check_4() {
	CHECK_STATUS[4]="INFO"
	CHECK_DETAIL[4]=""

	local proposed_hc="$1"

	[[ -f "$proposed_hc" ]] || { CHECK_DETAIL[4]="  Proposed healthcheck not fetched — skipped."; return; }
	[[ -f "$HEALTHCHECK"  ]] || { CHECK_DETAIL[4]="  Live healthcheck not found — skipped."; return; }

	local live_checks proposed_checks
	live_checks=$(grep -cE '^check ' "$HEALTHCHECK" 2>/dev/null || true)
	live_checks=${live_checks:-0}
	proposed_checks=$(grep -cE '^check ' "$proposed_hc" 2>/dev/null || true)
	proposed_checks=${proposed_checks:-0}

	local added removed
	if (( proposed_checks >= live_checks )); then
		added=$(( proposed_checks - live_checks ))
		removed=0
	else
		added=0
		removed=$(( live_checks - proposed_checks ))
	fi

	CHECK_DETAIL[4]="  live=$live_checks proposed=$proposed_checks (+${added} added, -${removed} removed)"
}

# Check 5: CADDYFILE_SHA drift.
_conflict_check_5() {
	CHECK_STATUS[5]="INFO"
	local current_sha proposed_sha
	current_sha="${CADDYFILE_SHA:-unknown}"
	proposed_sha="$1"
	if [[ "$current_sha" == "$proposed_sha" ]]; then
		CHECK_DETAIL[5]="  SHA unchanged: $current_sha"
	else
		CHECK_DETAIL[5]="  Current SHA: $current_sha
  Proposed SHA: $proposed_sha
  Change: yes — apply will update install.env"
	fi
}

# Check 6: Unsubstituted placeholders in rendered Caddyfile.
_conflict_check_6() {
	CHECK_STATUS[6]="PASS"
	CHECK_DETAIL[6]=""

	local rendered_caddy="$1"
	[[ -f "$rendered_caddy" ]] || { CHECK_STATUS[6]="INFO"; CHECK_DETAIL[6]="  Rendered Caddyfile not available — skipped."; return; }

	local placeholders
	placeholders=$(grep -oE '\{\{[A-Z_]+\}\}|__[A-Z_]+__' "$rendered_caddy" 2>/dev/null | sort -u || true)
	if [[ -n "$placeholders" ]]; then
		CHECK_STATUS[6]="WARNING"
		local items
		items=$(printf '%s\n' "$placeholders" | sed 's/^/  Unsubstituted: /')
		CHECK_DETAIL[6]="$items
  Each placeholder above was not found in install.env — render incomplete."
	fi
}

# Check 7: GHCR token availability.
_conflict_check_7() {
	CHECK_STATUS[7]="PASS"
	CHECK_DETAIL[7]=""

	if [[ ! -r "$PREFIX_ETC/ghcr.token" ]]; then
		CHECK_STATUS[7]="CATASTROPHIC"
		CHECK_DETAIL[7]="  No GHCR token at $PREFIX_ETC/ghcr.token.
  docker compose pull will 401 for private images.
  Provide via: oxpulse-partner-edge-upgrade --ghcr-token=ghp_..."
	fi
}

# Check 8: Disk space on /var/lib/docker.
_conflict_check_8() {
	CHECK_STATUS[8]="PASS"
	CHECK_DETAIL[8]=""

	local avail_kb avail_gb
	avail_kb=$(df /var/lib/docker 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)
	avail_gb=$(( avail_kb / 1024 / 1024 ))

	if (( avail_gb < 2 )); then
		CHECK_STATUS[8]="WARNING"
		CHECK_DETAIL[8]="  Only ${avail_gb}GB free on /var/lib/docker (need ≥2GB for image pull).
  Free space: docker system prune -f"
	else
		CHECK_DETAIL[8]="  ${avail_gb}GB free on /var/lib/docker"
	fi
}

# ---------------------------------------------------------------------------
# run_conflict_checks — run all 8 checks, print structured report, exit with
# appropriate code: 1=catastrophic, 2=warning-only, 0=clean.
#
# Arguments:
#   $1 = rendered Caddyfile path (from re_render_caddy dry-run)
#   $2 = proposed compose template path (fetched but not applied)
#   $3 = proposed healthcheck path (fetched but not applied)
#   $4 = proposed Caddyfile SHA (computed by re_render_caddy in dry-run)
#   $5 = proposed image tag (TARGET)
# ---------------------------------------------------------------------------
run_conflict_checks() {
	local rendered_caddy="$1"
	local proposed_compose="$2"
	local proposed_hc="$3"
	local proposed_sha="$4"
	local proposed_tag="$5"

	declare -a CHECK_STATUS
	declare -a CHECK_DETAIL

	# Run all checks, skip if requested.
	if _check_skip 1; then CHECK_STATUS[1]="SKIP"; CHECK_DETAIL[1]="  (skipped via --skip-check)";
	else _conflict_check_1 "$rendered_caddy"; fi

	if _check_skip 2; then CHECK_STATUS[2]="SKIP"; CHECK_DETAIL[2]="  (skipped via --skip-check)";
	else _conflict_check_2 "$proposed_compose"; fi

	if _check_skip 3; then CHECK_STATUS[3]="SKIP"; CHECK_DETAIL[3]="  (skipped via --skip-check)";
	else _conflict_check_3 "$proposed_tag"; fi

	if _check_skip 4; then CHECK_STATUS[4]="SKIP"; CHECK_DETAIL[4]="  (skipped via --skip-check)";
	else _conflict_check_4 "$proposed_hc"; fi

	if _check_skip 5; then CHECK_STATUS[5]="SKIP"; CHECK_DETAIL[5]="  (skipped via --skip-check)";
	else _conflict_check_5 "$proposed_sha"; fi

	if _check_skip 6; then CHECK_STATUS[6]="SKIP"; CHECK_DETAIL[6]="  (skipped via --skip-check)";
	else _conflict_check_6 "$rendered_caddy"; fi

	if _check_skip 7; then CHECK_STATUS[7]="SKIP"; CHECK_DETAIL[7]="  (skipped via --skip-check)";
	else _conflict_check_7; fi

	if _check_skip 8; then CHECK_STATUS[8]="SKIP"; CHECK_DETAIL[8]="  (skipped via --skip-check)";
	else _conflict_check_8; fi

	# Print summary table.
	printf '\n=== upgrade --dry-run: conflict report ===\n'
	printf 'Mode: --with-templates\n'
	printf 'Repo: %s\n' "$REPO_RAW"
	printf '\n'

	local label
	local -A LABEL_MAP=(
		[1]="Caddyfile validation vs current image"
		[2]="Compose structural drift              "
		[3]="Image tag direction                   "
		[4]="healthcheck.sh diff                   "
		[5]="CADDYFILE_SHA drift                   "
		[6]="Env var coverage                      "
		[7]="GHCR token                            "
		[8]="Disk space                            "
	)

	for i in 1 2 3 4 5 6 7 8; do
		label="${LABEL_MAP[$i]}"
		local status="${CHECK_STATUS[$i]}"
		case "$status" in
			CATASTROPHIC) printf '[CHECK %d] %s  \033[31mCATASTROPHIC\033[0m\n' "$i" "$label" ;;
			WARNING)      printf '[CHECK %d] %s  \033[33mWARNING\033[0m\n'      "$i" "$label" ;;
			INFO)         printf '[CHECK %d] %s  INFO\n'                         "$i" "$label" ;;
			PASS)         printf '[CHECK %d] %s  \033[32mPASS\033[0m\n'         "$i" "$label" ;;
			SKIP)         printf '[CHECK %d] %s  SKIP\n'                         "$i" "$label" ;;
		esac
	done

	# Print detail blocks for non-PASS/SKIP checks.
	local has_details=0
	for i in 1 2 3 4 5 6 7 8; do
		local st="${CHECK_STATUS[$i]}"
		local det="${CHECK_DETAIL[$i]}"
		if [[ -n "$det" && "$st" != "PASS" ]]; then
			if [[ "$has_details" -eq 0 ]]; then
				printf '\n--- Details ---\n'
				has_details=1
			fi
			printf '\n[CHECK %d - %s]\n' "$i" "$st"
			printf '%s\n' "$det"
		fi
	done

	# Count severities.
	local catastrophic_count=0 warning_count=0
	for i in 1 2 3 4 5 6 7 8; do
		case "${CHECK_STATUS[$i]}" in
			CATASTROPHIC) (( catastrophic_count += 1 )) || true ;;
			WARNING)      (( warning_count += 1 ))      || true ;;
		esac
	done

	printf '\n=== summary ===\n'
	if [[ $catastrophic_count -gt 0 ]]; then
		printf '%d catastrophic, %d warnings. Exit code: 1.\n' "$catastrophic_count" "$warning_count"
		return 1
	elif [[ $warning_count -gt 0 ]]; then
		printf '0 catastrophic, %d warnings. Exit code: 2.\n' "$warning_count"
		return 2
	else
		printf '0 catastrophic, 0 warnings. Exit code: 0.\n'
		return 0
	fi
}

# ---- --with-templates mode ----
if [[ "$MODE" == with_templates ]]; then
	resolve_default_target
	derive_release_tag
	log "--with-templates: atomic Caddyfile + healthcheck + image upgrade (target=$TARGET release_tag=$RELEASE_TAG)"

	if [[ "$DRY_RUN" -eq 1 ]]; then
		log "[dry-run] plan:"
		log "  1. backup Caddyfile, healthcheck.sh, install.env, docker-compose.yml"
		log "  2. fetch + render Caddyfile.tpl → $PREFIX_ETC/Caddyfile"
		log "  3. fetch healthcheck.sh → $HEALTHCHECK"
		log "  4. patch image tags to $TARGET in $COMPOSE_FILE"
		log "  5. docker compose pull"
		log "  6. docker compose up -d"
		log "  7. healthcheck; auto-rollback on failure"

		# ------ Conflict detection ------
		# Fetch compose template and healthcheck into a temp dir for structural analysis.
		# re_render_caddy in dry-run mode writes rendered Caddyfile to a tmpdir internally
		# and logs "[dry-run] would write Caddyfile (sha256=...)". We need to capture the
		# rendered file and sha separately for conflict checks.
		_conflict_tmpdir=$(mktemp -d)
		# shellcheck disable=SC2064
		trap "rm -rf '$_conflict_tmpdir'" EXIT

		# Fetch healthcheck for Check 4.
		_proposed_hc="$_conflict_tmpdir/healthcheck.sh"
		curl -fsSL --max-time 30 "$REPO_RAW/healthcheck.sh" -o "$_proposed_hc" 2>/dev/null || true

		# Fetch compose template for Check 2.
		_proposed_compose="$_conflict_tmpdir/docker-compose.yml.tpl"
		curl -fsSL --max-time 30 "$REPO_RAW/docker-compose.yml.tpl" -o "$_proposed_compose" 2>/dev/null || true

		# Render Caddyfile directly for Check 1 and Check 6 (re-implementing the
		# render inline so we get the actual file path, not just a log message).
		_rendered_caddy="$_conflict_tmpdir/Caddyfile"
		_proposed_sha="unknown"
		if grep -qE '^\s+caddy:' "$COMPOSE_FILE" 2>/dev/null && \
		   [[ -n "${PARTNER_DOMAIN:-}" ]] && [[ -n "${TURNS_SUBDOMAIN:-}" ]]; then
			_caddyfile_tpl="$_conflict_tmpdir/Caddyfile.tpl"
			if curl -fsSL --max-time 30 "$REPO_RAW/Caddyfile.tpl" -o "$_caddyfile_tpl" 2>/dev/null; then
				_esc() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }
				sed \
					-e "s|{{PARTNER_DOMAIN}}|$(_esc "$PARTNER_DOMAIN")|g" \
					-e "s|{{TURNS_SUBDOMAIN}}|$(_esc "$TURNS_SUBDOMAIN")|g" \
					"$_caddyfile_tpl" > "$_rendered_caddy"
				_proposed_sha=$(sha256sum "$_rendered_caddy" | awk '{print $1}')
				sed -i "s|__CADDYFILE_SHA__|${_proposed_sha}|g" "$_rendered_caddy"
			fi
		fi

		# Run all conflict checks; capture exit code without triggering set -e.
		_conflict_exit=0
		run_conflict_checks \
			"$_rendered_caddy" \
			"$_proposed_compose" \
			"$_proposed_hc" \
			"$_proposed_sha" \
			"$TARGET" || _conflict_exit=$?

		exit "$_conflict_exit"
	fi

	# Step 1: backup current state before any mutation (images + templates + host-scripts).
	[[ -f "$PREFIX_ETC/Caddyfile" ]]  && cp -a "$PREFIX_ETC/Caddyfile" "$PREV_CADDYFILE"
	[[ -f "$HEALTHCHECK" ]]           && cp -a "$HEALTHCHECK" "$PREV_HEALTHCHECK"
	cp -a "$STATE_FILE"   "$PREV_STATE_FILE"
	cp -a "$COMPOSE_FILE" "$PREV_COMPOSE_FILE"
	snapshot_host_scripts "$CURRENT"

	# Step 2+3: fetch + render templates. die()s on fetch failure — no state
	# has been mutated yet (backups exist but originals are untouched).
	re_render_caddy
	re_render_healthcheck

	# Step 4: patch image tags in compose (same as plain image upgrade).
	sed -i -E "s|(ghcr\.io/anatolykoptev/partner-edge-[a-z]+):[^\"[:space:]]+|\1:${TARGET}|g" \
		"$COMPOSE_FILE"
	sed -i -E "s|^IMAGE_VERSION=.*|IMAGE_VERSION=${TARGET}|" "$STATE_FILE"

	# Step 5: sync host-scripts for the release tag (health-report, sbin libs, units).
	log "syncing host-scripts to $RELEASE_TAG (image tag=$TARGET)"
	sync_host_scripts "$RELEASE_TAG"

	# Step 6: pull new images (with per-service digest capture for zero-downtime recreate).
	ghcr_login_from_file || warn "ghcr: login from stored token failed; will attempt pull anyway"
	declare -A _wt_before_digests
	capture_running_digests _wt_before_digests
	log "pulling images (tag=$TARGET)"
	pull_out=$(cd "$PREFIX_ETC" && $DOCKER_BIN compose pull 2>&1)
	pull_rc=$?
	if [[ $pull_rc -ne 0 ]]; then
		printf '%s\n' "$pull_out" >&2
		if ! ghcr_pull_diagnose "$pull_out"; then
			warn "ghcr: pull failed but not for an auth reason (see output above)"
		fi
		warn "pull failed — rolling back"
		do_rollback_templates
		restore_host_scripts
		die "pull failed — rolled back to previous state"
	fi

	# Step 7: recreate only services whose image digest changed (zero-downtime).
	declare -A _wt_after_digests
	resolve_pulled_digests _wt_after_digests
	if ! recreate_changed_services _wt_before_digests _wt_after_digests; then
		warn "compose up failed — rolling back"
		do_rollback_templates
		restore_host_scripts
		(ghcr_login_from_file || true; cd "$PREFIX_ETC" && $DOCKER_BIN compose pull) || true
		(cd "$PREFIX_ETC" && $DOCKER_BIN compose up -d) || true
		die "--with-templates upgrade rolled back due to compose up failure"
	fi

	# Step 8: verify with retry (same settle_healthcheck_with_retry as plain path).
	if ! settle_healthcheck_with_retry "with-templates-upgrade"; then
		warn "healthcheck red after --with-templates upgrade — rolling back"
		do_rollback_templates
		restore_host_scripts
		(ghcr_login_from_file || true; cd "$PREFIX_ETC" && $DOCKER_BIN compose pull) || true
		(cd "$PREFIX_ETC" && $DOCKER_BIN compose up -d) || true
		if ! "$HEALTHCHECK" --local; then
			die "--with-templates rolled back but healthcheck still failing — manual recovery required"
		fi
		die "--with-templates upgrade rolled back due to post-upgrade healthcheck failure"
	fi

	log "--with-templates upgrade to $TARGET complete"
	re_render_xray
	exit 0
fi

resolve_default_target
derive_release_tag
log "current=$CURRENT target=$TARGET release_tag=$RELEASE_TAG"

if [[ "$CURRENT" == "$TARGET" && "$MODE" != rollback ]]; then
	log "already on $TARGET — nothing to do"
	exit 0
fi
if [[ "$MODE" == check ]]; then
	echo "UPGRADE_AVAILABLE current=$CURRENT target=$TARGET"
	exit 10
fi

# ---- --dry-run gate for the full image upgrade path ----
# BUG FIX: The plain apply path previously ran every mutating operation
# (compose tag rewrite, host-script sync, compose pull, container recreate,
# healthcheck, rollback) unconditionally even with --dry-run, causing a real
# prod recreate + rollback cycle on ruoxp during a dry-run upgrade v0.12.45→v0.12.61
# (~49s downtime). The --with-templates path already exited early at its own
# dry-run block above; this gate covers the plain apply path.
#
# In dry-run: read-only inspection (capture_running_digests calls docker inspect,
# which is safe) is intentionally skipped too — printing the plan is sufficient.
if [[ "$DRY_RUN" -eq 1 ]]; then
	log "[dry-run] plan for full image upgrade $CURRENT → $TARGET:"
	log "  1. backup $COMPOSE_FILE → $PREV_COMPOSE_FILE"
	log "  2. backup $STATE_FILE → $PREV_STATE_FILE"
	log "  3. snapshot host-scripts ($CURRENT)"
	log "  4. rewrite compose image tags: *:$CURRENT → *:$TARGET"
	log "     (sed -E 's|(ghcr.io/anatolykoptev/partner-edge-[a-z]+):[^\"[:space:]]+|\\1:$TARGET|g')"
	log "  5. update IMAGE_VERSION=$TARGET in $STATE_FILE"
	log "  6. sync host-scripts to $RELEASE_TAG"
	log "  7. docker compose pull (images rewritten to $TARGET before pull)"
	log "  8. recreate services whose digest changed (running → $TARGET)"
	log "  9. settle-retry healthcheck (poll ${OXPULSE_UPGRADE_HEALTH_TIMEOUT:-30}s budget, 3s interval)"
	log "  10. on failure: rollback compose + host-scripts + compose pull + up"
	log "[dry-run] no docker pull, no container recreate, no rollback performed"
	exit 0
fi

# ---- Backup current config + host-scripts before mutating ----
cp -a "$COMPOSE_FILE" "$PREV_COMPOSE_FILE"
cp -a "$STATE_FILE"   "$PREV_STATE_FILE"
snapshot_host_scripts "$CURRENT"

# BUG FIX (tag-rewrite): rewrite image tags to TARGET in the compose file
# BEFORE docker compose pull so that pull fetches the correct target images.
# The regex captures the full image name up to the colon and replaces the
# tag portion with TARGET. This must happen before any pull invocation so
# that both the pull and the subsequent `compose up` use the target tag, not
# the currently-running tag.
sed -i -E "s|(ghcr\.io/anatolykoptev/partner-edge-[a-z]+):[^\"[:space:]]+|\1:${TARGET}|g" \
	"$COMPOSE_FILE"
sed -i -E "s|^IMAGE_VERSION=.*|IMAGE_VERSION=${TARGET}|" "$STATE_FILE"
log "compose image tags rewritten to $TARGET (pre-pull)"

# Sync host-scripts for the release tag before pulling images so that a
# failed image pull leaves the host-scripts already at the new version —
# rollback restores both atomically from the snapshot taken above.
# RELEASE_TAG = TARGET = vX.Y.Z (single tag form starting at v0.12.60).
log "syncing host-scripts to $RELEASE_TAG (image tag=$TARGET)"
sync_host_scripts "$RELEASE_TAG"

# Refresh ghcr auth from stored token (no-op if file absent).
ghcr_login_from_file || warn "ghcr: login from stored token failed; will attempt pull anyway"

# Capture per-service image digests BEFORE pull so we can skip recreating
# services whose image did not actually change (e.g. no-op version bump where
# the sfu image is byte-for-byte identical across tags).
# NOTE: capture uses `docker inspect` on running containers — read-only, safe.
declare -A _before_digests
capture_running_digests _before_digests

log "pulling new images (tag=$TARGET)"
pull_out=$(cd "$PREFIX_ETC" && $DOCKER_BIN compose pull 2>&1)
pull_rc=$?
if [[ $pull_rc -ne 0 ]]; then
	# Print pull output so operator can see context.
	printf '%s\n' "$pull_out" >&2
	# If denied pattern → friendly hint (prints suggestion to use --ghcr-token=).
	if ! ghcr_pull_diagnose "$pull_out"; then
		warn "ghcr: pull failed but not for an auth reason (see output above)"
	fi
	# Restore host-scripts to pre-upgrade state since image pull failed.
	restore_host_scripts
	cp -a "$PREV_COMPOSE_FILE" "$COMPOSE_FILE"
	cp -a "$PREV_STATE_FILE"   "$STATE_FILE"
	die "pull failed — previous config and host-scripts restored"
fi

# Resolve post-pull digests and recreate only services that changed.
# resolve_pulled_digests reads the (already-rewritten) compose file to get
# the TARGET image references, then inspects local Docker state after pull.
# This correctly compares running-digest (before_digests) vs TARGET-digest
# (after_digests), so only services whose TARGET image differs from what is
# currently running are recreated (zero-downtime for no-op version bumps).
# fail-safe: if digest resolution fails for a service, recreate_changed_services
# treats an empty after-digest as "unknown → recreate" (not "skip").
declare -A _after_digests
resolve_pulled_digests _after_digests

if ! recreate_changed_services _before_digests _after_digests; then
	warn "up failed — rolling back to $CURRENT"
	cp -a "$PREV_COMPOSE_FILE" "$COMPOSE_FILE"
	cp -a "$PREV_STATE_FILE"   "$STATE_FILE"
	restore_host_scripts
	(cd "$PREFIX_ETC" && $DOCKER_BIN compose up -d --force-recreate) || true
	die "upgrade rolled back"
fi

# Wait for services to stabilize after container recreation, with retry.
# settle_healthcheck_with_retry polls every 3s up to OXPULSE_UPGRADE_HEALTH_TIMEOUT
# seconds (default 30s = 10 attempts × 3s).  The budget is 4× the documented
# worst-case xray Reality establishment time (~8s on rvpn v0.12.20 incident),
# with added margin for a loaded edge.  A single sleep 10 was replaced because
# the 2s slack was insufficient on loaded edges (see function definition comment).
if ! settle_healthcheck_with_retry "plain-upgrade"; then
	warn "healthcheck red after upgrade — rolling back"
	cp -a "$PREV_COMPOSE_FILE" "$COMPOSE_FILE"
	cp -a "$PREV_STATE_FILE"   "$STATE_FILE"
	restore_host_scripts
	(ghcr_login_from_file || true; cd "$PREFIX_ETC" && $DOCKER_BIN compose pull)
	(cd "$PREFIX_ETC" && $DOCKER_BIN compose up -d --force-recreate) || true
	die "upgrade rolled back due to post-upgrade healthcheck failure"
fi

log "upgraded to $TARGET successfully"

re_render_xray

if [[ "$V01_TO_V02" -eq 1 ]]; then
	log "v0.1→v0.2: re-seeding templates via hydrate --reseed"
	/usr/local/sbin/oxpulse-partner-edge-hydrate --reseed \
		|| warn "hydrate --reseed exited non-zero — upgrade succeeded, but re-run 'oxpulse-partner-edge-hydrate --reseed' manually to ensure templates are current"
fi
