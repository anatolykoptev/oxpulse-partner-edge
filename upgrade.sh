#!/usr/bin/env bash
# upgrade.sh — pull a newer image tag, recreate services, verify, optionally roll back.
#
# Usage:
#   oxpulse-partner-edge-upgrade                       # pull :latest
#   oxpulse-partner-edge-upgrade v0.2.0                # pin to specific tag
#   oxpulse-partner-edge-upgrade --check               # report pending upgrade, don't apply
#   oxpulse-partner-edge-upgrade --rollback            # restore previous tag
#   oxpulse-partner-edge-upgrade --templates-only      # re-render xray config from upstream template, no image pull
#   oxpulse-partner-edge-upgrade --with-templates      # re-render Caddyfile + healthcheck + pull new image (atomic)
#   oxpulse-partner-edge-upgrade --ghcr-token=ghp_xxx  # persist GHCR PAT before pull (one-time)
#   oxpulse-partner-edge-upgrade --dry-run             # print plan, skip docker and file writes
#   oxpulse-partner-edge-upgrade --dry-run --skip-check=1,3  # skip specific conflict checks (1-8)
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
COMPOSE_FILE="$PREFIX_ETC/docker-compose.yml"
STATE_FILE="$PREFIX_LIB/install.env"
PREV_STATE_FILE="$PREFIX_LIB/install.env.prev"
PREV_COMPOSE_FILE="$PREFIX_LIB/docker-compose.yml.prev"
PREV_CADDYFILE="$PREFIX_LIB/Caddyfile.prev"
PREV_HEALTHCHECK="$PREFIX_LIB/healthcheck.prev"
HEALTHCHECK="${OXPULSE_HEALTHCHECK:-/usr/local/sbin/oxpulse-partner-edge-healthcheck}"
REPO_RAW="${OXPULSE_REPO_RAW:-https://raw.githubusercontent.com/anatolykoptev/oxpulse-partner-edge/main}"
NODE_CFG="$PREFIX_ETC/node-config.json"
XRAY_CFG="$PREFIX_ETC/xray-client.json"
# Allow tests to override docker binary (e.g. DOCKER_BIN=true for dry-run).
DOCKER_BIN="${DOCKER_BIN:-docker}"

log()  { printf '\033[32m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[33m!!\033[0m  %s\n' "$*" >&2; }
die()  { while IFS= read -r _line; do printf '\033[31mERR\033[0m %s\n' "$_line" >&2; done <<< "$*"; exit 1; }

# Source shared channel render functions (re_render_xray, future re_render_awg, etc.)
# Prefer local checkout copy; fall back to installed sbin path.
_lib_local="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/channel-render-lib.sh"
_lib_installed="/usr/local/sbin/channel-render-lib.sh"
if [[ -f "$_lib_local" ]]; then
    # shellcheck source=channel-render-lib.sh
    source "$_lib_local"
elif [[ -f "$_lib_installed" ]]; then
    # shellcheck source=/dev/null
    source "$_lib_installed"
else
    die "channel-render-lib.sh not found (tried: $_lib_local and $_lib_installed)"
fi
unset _lib_local _lib_installed

# Source ghcr auth helpers (ghcr_save_token / ghcr_login_from_file /
# ghcr_pull_diagnose / ghcr_configure_token). Same lookup pattern as
# channel-render-lib.sh.
_ghcr_local="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/ghcr-auth-lib.sh"
_ghcr_installed="/usr/local/sbin/ghcr-auth-lib.sh"
if [[ -f "$_ghcr_local" ]]; then
    # shellcheck source=ghcr-auth-lib.sh
    source "$_ghcr_local"
elif [[ -f "$_ghcr_installed" ]]; then
    # shellcheck source=/dev/null
    source "$_ghcr_installed"
else
    die "ghcr-auth-lib.sh not found (tried: $_ghcr_local and $_ghcr_installed)"
fi
unset _ghcr_local _ghcr_installed

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
# GHCR PAT supplied via --ghcr-token=ghp_xxx flag OR OXPULSE_GHCR_TOKEN env.
# Flag wins over env. Empty string disables the auth path (anonymous pull).
GHCR_TOKEN_ARG="${OXPULSE_GHCR_TOKEN:-}"
for arg in "$@"; do
	case "$arg" in
		--check)          MODE=check ;;
		--rollback)       MODE=rollback ;;
		--templates-only) MODE=templates ;;
		--with-templates) MODE=with_templates ;;
		--dry-run)        DRY_RUN=1 ;;
		--skip-check=*)
			_sc=" ${arg#--skip-check=} "
			SKIPPED_CHECKS="${_sc//,/ }"
			unset _sc ;;
		--ghcr-token=*)   GHCR_TOKEN_ARG="${arg#--ghcr-token=}" ;;
		v*|latest)        TARGET="$arg" ;;
		-h|--help)
			sed -n '2,28p' "$0"; exit 0 ;;
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

	[[ "$_have_template_prev" -eq 1 || "$_have_image_prev" -eq 1 ]] \
		|| die "no previous version recorded — nothing to roll back to"

	log "rolling back to previous state"
	do_rollback_templates  # restores all .prev files it can find

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
	log "--with-templates: atomic Caddyfile + healthcheck + image upgrade (target=$TARGET)"

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

	# Step 1: backup current state before any mutation.
	[[ -f "$PREFIX_ETC/Caddyfile" ]]  && cp -a "$PREFIX_ETC/Caddyfile" "$PREV_CADDYFILE"
	[[ -f "$HEALTHCHECK" ]]           && cp -a "$HEALTHCHECK" "$PREV_HEALTHCHECK"
	cp -a "$STATE_FILE"   "$PREV_STATE_FILE"
	cp -a "$COMPOSE_FILE" "$PREV_COMPOSE_FILE"

	# Step 2+3: fetch + render templates. die()s on fetch failure — no state
	# has been mutated yet (backups exist but originals are untouched).
	re_render_caddy
	re_render_healthcheck

	# Step 4: patch image tags in compose (same as plain image upgrade).
	sed -i -E "s|(ghcr\.io/anatolykoptev/partner-edge-[a-z]+):[^\"[:space:]]+|\1:${TARGET}|g" \
		"$COMPOSE_FILE"
	sed -i -E "s|^IMAGE_VERSION=.*|IMAGE_VERSION=${TARGET}|" "$STATE_FILE"

	# Step 5: pull new images.
	ghcr_login_from_file || warn "ghcr: login from stored token failed; will attempt pull anyway"
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
		die "pull failed — rolled back to previous state"
	fi

	# Step 6: recreate services.
	log "recreating services"
	if ! (cd "$PREFIX_ETC" && $DOCKER_BIN compose up -d); then
		warn "compose up failed — rolling back"
		do_rollback_templates
		(ghcr_login_from_file || true; cd "$PREFIX_ETC" && $DOCKER_BIN compose pull) || true
		(cd "$PREFIX_ETC" && $DOCKER_BIN compose up -d) || true
		die "--with-templates upgrade rolled back due to compose up failure"
	fi

	# Step 7: verify.
	sleep 10
	if ! "$HEALTHCHECK" --local; then
		warn "healthcheck red after --with-templates upgrade — rolling back"
		do_rollback_templates
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
log "current=$CURRENT target=$TARGET"

if [[ "$CURRENT" == "$TARGET" && "$MODE" != rollback ]]; then
	log "already on $TARGET — nothing to do"
	exit 0
fi
if [[ "$MODE" == check ]]; then
	echo "UPGRADE_AVAILABLE current=$CURRENT target=$TARGET"
	exit 10
fi

# ---- Backup current config before mutating ----
cp -a "$COMPOSE_FILE" "$PREV_COMPOSE_FILE"
cp -a "$STATE_FILE"   "$PREV_STATE_FILE"

# Rewrite image tags in place.
sed -i -E "s|(ghcr\.io/anatolykoptev/partner-edge-[a-z]+):[^\"[:space:]]+|\1:${TARGET}|g" \
	"$COMPOSE_FILE"
sed -i -E "s|^IMAGE_VERSION=.*|IMAGE_VERSION=${TARGET}|" "$STATE_FILE"

# Refresh ghcr auth from stored token (no-op if file absent).
ghcr_login_from_file || warn "ghcr: login from stored token failed; will attempt pull anyway"

log "pulling new images"
pull_out=$(cd "$PREFIX_ETC" && $DOCKER_BIN compose pull 2>&1)
pull_rc=$?
if [[ $pull_rc -ne 0 ]]; then
	# Print pull output so operator can see context.
	printf '%s\n' "$pull_out" >&2
	# If denied pattern → friendly hint (prints suggestion to use --ghcr-token=).
	if ! ghcr_pull_diagnose "$pull_out"; then
		warn "ghcr: pull failed but not for an auth reason (see output above)"
	fi
	die "pull failed — previous config preserved at $PREV_COMPOSE_FILE"
fi

log "recreating services"
if ! (cd "$PREFIX_ETC" && $DOCKER_BIN compose up -d --force-recreate); then
	warn "up failed — rolling back to $CURRENT"
	cp -a "$PREV_COMPOSE_FILE" "$COMPOSE_FILE"
	cp -a "$PREV_STATE_FILE"   "$STATE_FILE"
	(cd "$PREFIX_ETC" && $DOCKER_BIN compose up -d --force-recreate) || true
	die "upgrade rolled back"
fi

# Wait for services to stabilize after container recreation.
# 10s instead of the previous 5s: xray 26.5.3 Reality tunnel establishment
# on first connection takes up to 8s, especially when the uTLS handshake
# performs per-connection cipher randomisation. 5s was too short and caused
# false-negative failures on check 10 (SPA GET /) during the v0.12.20 upgrade
# on rvpn (2026-05-09 rollback incident).
sleep 10
if ! "$HEALTHCHECK" --local; then
	warn "healthcheck red after upgrade — rolling back"
	cp -a "$PREV_COMPOSE_FILE" "$COMPOSE_FILE"
	cp -a "$PREV_STATE_FILE"   "$STATE_FILE"
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
