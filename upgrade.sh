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
die()  { printf '\033[31mERR\033[0m %s\n' "$*" >&2; exit 1; }

# Re-render xray-client.json from the upstream template, preserving secrets
# from node-config.json. Called on every upgrade so structural changes
# (e.g. flow, mode, padding) are applied without requiring reinstall.
re_render_xray() {
    [[ -f "$NODE_CFG" ]] || { warn "node-config.json not found — skipping xray template refresh"; return 0; }
    log "re-rendering xray-client.json from updated template"

    local tpl
    tpl=$(mktemp)
    if ! curl -fsSL --max-time 15 "$REPO_RAW/xray-client.json.tpl" -o "$tpl" 2>/dev/null; then
        warn "could not fetch xray-client.json.tpl — xray config left unchanged"
        rm -f "$tpl"; return 0
    fi

    # Read secrets from node-config.json.
    # Prefers channels[0].xray.* (future schema) with fallback to flat reality_* fields
    # (current schema) for backwards compat with nodes registered before channels[] landed.
    local uuid enc pub_key short_id server_name backend
    uuid=$(python3 -c "
import json,sys; d=json.load(open(sys.argv[1]))
ch=d.get('channels',[])
x=ch[0].get('xray',{}) if ch and ch[0].get('protocol','')=='vless-reality' else {}
print(x.get('uuid','') or d.get('reality_uuid',''))" "$NODE_CFG")
    enc=$(python3 -c "
import json,sys; d=json.load(open(sys.argv[1]))
ch=d.get('channels',[])
x=ch[0].get('xray',{}) if ch and ch[0].get('protocol','')=='vless-reality' else {}
print(x.get('encryption','') or d.get('reality_encryption','') or '')" "$NODE_CFG")
    pub_key=$(python3 -c "
import json,sys; d=json.load(open(sys.argv[1]))
ch=d.get('channels',[])
x=ch[0].get('xray',{}) if ch and ch[0].get('protocol','')=='vless-reality' else {}
print(x.get('public_key','') or d.get('reality_public_key',''))" "$NODE_CFG")
    short_id=$(python3 -c "
import json,sys; d=json.load(open(sys.argv[1]))
ch=d.get('channels',[])
x=ch[0].get('xray',{}) if ch and ch[0].get('protocol','')=='vless-reality' else {}
print(x.get('short_id','') or d.get('reality_short_id',''))" "$NODE_CFG")
    server_name=$(python3 -c "
import json,sys; d=json.load(open(sys.argv[1]))
ch=d.get('channels',[])
x=ch[0].get('xray',{}) if ch and ch[0].get('protocol','')=='vless-reality' else {}
names=x.get('server_names') or d.get('reality_server_names')
print((names[0] if names else None) or x.get('server_name','') or d.get('reality_server_name','www.samsung.com'))" "$NODE_CFG")
    backend=$(python3 -c "
import json,sys; d=json.load(open(sys.argv[1]))
ch=d.get('channels',[])
if ch and ch[0].get('protocol','')=='vless-reality':
    c0=ch[0]; print('{}:{}'.format(c0.get('host',''),c0.get('port','')))
else:
    print(d.get('backend_endpoint',''))" "$NODE_CFG")

    if [[ -z "$uuid" || -z "$pub_key" || -z "$backend" ]]; then
        warn "node-config.json missing required fields — skipping xray template refresh"
        rm -f "$tpl"; return 0
    fi

    # Fallback: if node-config.json has empty encryption (pre-PQ nodes),
    # read it from the live xray-client.json so we don't downgrade to "none".
    if [[ -z "$enc" && -f "$XRAY_CFG" ]]; then
        enc=$(python3 -c "
import json,sys
try:
    c=json.load(open(sys.argv[1]))
    u=c['outbounds'][0]['settings']['vnext'][0]['users'][0]
    print(u.get('encryption',''))
except Exception:
    print('')
" "$XRAY_CFG" 2>/dev/null || true)
    fi
    [[ -z "$enc" ]] && enc="none"

    local backend_host="${backend%:*}"
    local backend_port="${backend##*:}"

    # Escape sed replacement metacharacters (|, &, \).
    _esc() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

    local out
    out=$(mktemp)
    sed \
        -e "s|{{REALITY_UUID}}|$(_esc "$uuid")|g" \
        -e "s|{{REALITY_ENCRYPTION}}|$(_esc "$enc")|g" \
        -e "s|{{REALITY_PUBLIC_KEY}}|$(_esc "$pub_key")|g" \
        -e "s|{{REALITY_SHORT_ID}}|$(_esc "$short_id")|g" \
        -e "s|{{REALITY_SERVER_NAME}}|$(_esc "$server_name")|g" \
        -e "s|{{BACKEND_HOST}}|$(_esc "$backend_host")|g" \
        -e "s|{{BACKEND_PORT}}|$(_esc "$backend_port")|g" \
        -e "s|{{BACKEND_ENDPOINT}}|$(_esc "$backend")|g" \
        "$tpl" > "$out"
    rm -f "$tpl"

    # Backup old config, install new one (0600 — contains secrets).
    cp -a "$XRAY_CFG" "${XRAY_CFG}.bak.$(date +%s)" 2>/dev/null || true
    install -m 0600 "$out" "$XRAY_CFG"
    rm -f "$out"

    log "xray-client.json refreshed from template"
    (cd "$PREFIX_ETC" && docker compose restart xray-client 2>/dev/null || true)
    log "xray-client restarted"
}

[[ $EUID -eq 0 ]] || die "must run as root"
[[ -r "$COMPOSE_FILE" ]] || die "no installed bundle at $COMPOSE_FILE"
[[ -r "$STATE_FILE" ]]   || die "missing $STATE_FILE — reinstall instead of upgrade"

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
sed -i -E "s|(ghcr\.io/anatolykoptev/oxpulse-partner-edge-[a-z]+):[^\"[:space:]]+|\1:${TARGET}|g" \
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
