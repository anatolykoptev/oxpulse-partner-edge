#!/usr/bin/env bash
# upgrade.sh — pull a newer image tag, recreate services, verify, optionally roll back.
#
# Usage:
#   oxpulse-partner-edge-upgrade                  # pull :latest
#   oxpulse-partner-edge-upgrade v0.2.0           # pin to specific tag
#   oxpulse-partner-edge-upgrade --check          # report pending upgrade, don't apply
#   oxpulse-partner-edge-upgrade --rollback       # restore previous tag
#   oxpulse-partner-edge-upgrade --templates-only # re-render xray config from upstream template, no image pull
set -euo pipefail

PREFIX_ETC=/etc/oxpulse-partner-edge
PREFIX_LIB=/var/lib/oxpulse-partner-edge
COMPOSE_FILE="$PREFIX_ETC/docker-compose.yml"
STATE_FILE="$PREFIX_LIB/install.env"
PREV_STATE_FILE="$PREFIX_LIB/install.env.prev"
PREV_COMPOSE_FILE="$PREFIX_LIB/docker-compose.yml.prev"
HEALTHCHECK="/usr/local/sbin/oxpulse-partner-edge-healthcheck"
REPO_RAW="${OXPULSE_REPO_RAW:-https://raw.githubusercontent.com/anatolykoptev/oxpulse-partner-edge/main}"
NODE_CFG="$PREFIX_ETC/node-config.json"
XRAY_CFG="$PREFIX_ETC/xray-client.json"

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
for arg in "$@"; do
	case "$arg" in
		--check)          MODE=check ;;
		--rollback)       MODE=rollback ;;
		--templates-only) MODE=templates ;;
		v*|latest)        TARGET="$arg" ;;
		-h|--help)
			sed -n '2,9p' "$0"; exit 0 ;;
		*) die "unknown arg: $arg" ;;
	esac
done

V01_TO_V02=0

# --templates-only: re-render xray config from upstream template, skip image ops.
if [[ "$MODE" == templates ]]; then
	log "--templates-only: refreshing xray-client.json from upstream template"
	re_render_xray
	log "done"
	exit 0
fi

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

if [[ "$MODE" == rollback ]]; then
	[[ -r "$PREV_STATE_FILE" && -r "$PREV_COMPOSE_FILE" ]] \
		|| die "no previous version recorded — nothing to roll back to"
	log "rolling back using previous compose file"
	cp -a "$PREV_COMPOSE_FILE" "$COMPOSE_FILE"
	cp -a "$PREV_STATE_FILE"   "$STATE_FILE"
	(cd "$PREFIX_ETC" && docker compose pull)
	(cd "$PREFIX_ETC" && docker compose up -d --force-recreate)
	sleep 5
	if "$HEALTHCHECK" --local; then
		log "rollback complete"
		exit 0
	else
		die "rollback applied but healthcheck still failing — manual recovery required"
	fi
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

log "pulling new images"
(cd "$PREFIX_ETC" && docker compose pull) || die "pull failed — previous config preserved at $PREV_COMPOSE_FILE"

log "recreating services"
if ! (cd "$PREFIX_ETC" && docker compose up -d --force-recreate); then
	warn "up failed — rolling back to $CURRENT"
	cp -a "$PREV_COMPOSE_FILE" "$COMPOSE_FILE"
	cp -a "$PREV_STATE_FILE"   "$STATE_FILE"
	(cd "$PREFIX_ETC" && docker compose up -d --force-recreate) || true
	die "upgrade rolled back"
fi

sleep 5
if ! "$HEALTHCHECK" --local; then
	warn "healthcheck red after upgrade — rolling back"
	cp -a "$PREV_COMPOSE_FILE" "$COMPOSE_FILE"
	cp -a "$PREV_STATE_FILE"   "$STATE_FILE"
	(cd "$PREFIX_ETC" && docker compose pull)
	(cd "$PREFIX_ETC" && docker compose up -d --force-recreate) || true
	die "upgrade rolled back due to post-upgrade healthcheck failure"
fi

log "upgraded to $TARGET successfully"

re_render_xray

if [[ "$V01_TO_V02" -eq 1 ]]; then
	log "v0.1→v0.2: re-seeding templates via hydrate --reseed"
	/usr/local/sbin/oxpulse-partner-edge-hydrate --reseed \
		|| warn "hydrate --reseed exited non-zero — upgrade succeeded, but re-run 'oxpulse-partner-edge-hydrate --reseed' manually to ensure templates are current"
fi
