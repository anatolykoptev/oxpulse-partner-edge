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
#
# GHCR auth: ghcr.io/anatolykoptev/partner-edge-* images are private. Provide
# a token via --ghcr-token=ghp_xxx (saved to /etc/oxpulse-partner-edge/ghcr.token
# mode 0600) or OXPULSE_GHCR_TOKEN env (one-shot, not persisted). Once saved,
# the token is reused on every subsequent run; rotate with --ghcr-token=<new>.
# See ghcr-auth-lib.sh for the full auth flow.
set -euo pipefail

PREFIX_ETC=/etc/oxpulse-partner-edge
PREFIX_LIB=/var/lib/oxpulse-partner-edge
COMPOSE_FILE="$PREFIX_ETC/docker-compose.yml"
STATE_FILE="$PREFIX_LIB/install.env"
PREV_STATE_FILE="$PREFIX_LIB/install.env.prev"
PREV_COMPOSE_FILE="$PREFIX_LIB/docker-compose.yml.prev"
PREV_CADDYFILE="$PREFIX_LIB/Caddyfile.prev"
PREV_HEALTHCHECK="$PREFIX_LIB/healthcheck.prev"
HEALTHCHECK="/usr/local/sbin/oxpulse-partner-edge-healthcheck"
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

[[ $EUID -eq 0 ]] || die "must run as root"
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
		--ghcr-token=*)   GHCR_TOKEN_ARG="${arg#--ghcr-token=}" ;;
		v*|latest)        TARGET="$arg" ;;
		-h|--help)
			sed -n '2,17p' "$0"; exit 0 ;;
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

# --templates-only: re-render xray config from upstream template, skip image ops.
if [[ "$MODE" == templates ]]; then
	log "--templates-only: refreshing xray-client.json from upstream template"
	re_render_xray
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

	# Atomic install: write to temp path, rename into place.
	install -m 0644 "$out_caddy" "$PREFIX_ETC/Caddyfile"
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

	install -m 0755 "$out_hc" "$HEALTHCHECK"
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

# ---- --with-templates mode ----
if [[ "$MODE" == with_templates ]]; then
	[[ -z "$TARGET" ]] && TARGET=latest
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
		# Still run render functions (they are no-ops in dry-run mode).
		re_render_caddy
		re_render_healthcheck
		exit 0
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

[[ -z "$TARGET" ]] && TARGET=latest
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
