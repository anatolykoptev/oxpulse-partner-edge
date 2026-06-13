#!/bin/bash
# oxpulse-xray-update.sh — single-container watchtower for partner-edge xray.
#
# Watches :stable channel on GHCR. Promotion to :stable is a manual gate
# in oxpulse-partner-edge release workflow (promote-stable.yml), so this
# timer only redeploys versions that an operator explicitly blessed.
#
# Pattern: clone of oxpulse-sfu-update.sh. Same alert/log/recovery shape so
# operators read both the same way.
#
# Recreate strategy: docker compose up --force-recreate is used instead of a
# hand-rolled `docker run`.  The argument to --force-recreate is the SERVICE
# name (OXPULSE_XRAY_SERVICE), not the container name — compose resolves the
# container from the service definition and always recreates from the single
# compose source of truth (network=edge, volume=xray-client.json, expose=3080).
# A hand-rolled `docker run` can silently drift from docker-compose.yml.tpl
# (wrong network, missing volume, etc.) and is non-idempotent; compose prevents
# that class of bug.
#
# OVERRIDES (for nodes that run a differently-named xray container, e.g. piter):
#   Create /etc/oxpulse-partner-edge/xray-update.env with:
#     OXPULSE_XRAY_SERVICE=xray-client          # compose service name
#     OXPULSE_XRAY_CONTAINER=xray-reality       # container name (for inspect)
#     OXPULSE_XRAY_IMAGE=teddysun/xray:26.4.25
#   The file is optional; bundle nodes don't need it (defaults are correct).
set -euo pipefail

# Load container/image overrides from env file if present.
# XRAY_UPDATE_ENV_FILE can be set in tests; production default is the standard path.
_XRAY_UPDATE_ENV="${XRAY_UPDATE_ENV_FILE:-/etc/oxpulse-partner-edge/xray-update.env}"
# shellcheck source=/dev/null
[ -f "$_XRAY_UPDATE_ENV" ] && source "$_XRAY_UPDATE_ENV"

LOG="${LOG:-/var/log/oxpulse-xray-update.log}"
# OXPULSE_XRAY_SERVICE is the compose service name; default matches docker-compose.yml.tpl.
SERVICE="${OXPULSE_XRAY_SERVICE:-xray-client}"
CONTAINER="${OXPULSE_XRAY_CONTAINER:-oxpulse-partner-xray}"
IMAGE="${OXPULSE_XRAY_IMAGE:-ghcr.io/anatolykoptev/partner-edge-xray:stable}"
COMPOSE_DIR="${OXPULSE_COMPOSE_DIR:-/etc/oxpulse-partner-edge}"
source /etc/piter-monitor.env 2>/dev/null || true

ts()    { date -Iseconds; }
log()   { echo "$(ts) $*" | tee -a "$LOG"; }
alert() {
    local msg="$1"
    curl -s --max-time 5 -X POST "http://10.8.0.2:8765/webhook/monitor/healthcheck" \
        -H "Content-Type: application/json" \
        -d "{\"message\":\"[$(hostname)] $msg\"}" >/dev/null 2>&1 \
    || curl -s --max-time 8 "https://api.telegram.org/bot${TG_TOKEN:-x}/sendMessage" \
       -d "chat_id=${TG_CHAT:-x}&text=[$(hostname)] $msg" >/dev/null 2>&1 || true
}

# 1) Resolve current running image digest
RUNNING_IMG=$(docker inspect "$CONTAINER" --format '{{.Image}}' 2>/dev/null || echo none)
if [ "$RUNNING_IMG" = "none" ]; then
    log "container $CONTAINER not running, skip"; exit 0
fi
log "running image: $RUNNING_IMG"

# 2) Pull stable channel, capture new image ID
log "pulling $IMAGE"
docker pull "$IMAGE" >> "$LOG" 2>&1
NEW_IMG=$(docker inspect "$IMAGE" --format '{{.Id}}' 2>/dev/null || echo none)
log "stable image: $NEW_IMG"

# 3) Compare
if [ "$NEW_IMG" = "$RUNNING_IMG" ]; then
    log "no update available, skip"
    exit 0
fi

OLD_VER=$(docker inspect "$CONTAINER" --format '{{index .Config.Labels "oxpulse.version"}}' 2>/dev/null || echo unknown)
log "update detected; recreating $CONTAINER via compose (current=$OLD_VER)"

# 4) Recreate via docker compose so network/volume/expose always match
# docker-compose.yml (single source of truth). This avoids drift that a
# hand-rolled `docker run` can introduce (wrong network, missing volume, etc.).
[ -f "$COMPOSE_DIR/docker-compose.yml" ] || {
    log "FAIL missing $COMPOSE_DIR/docker-compose.yml"
    alert "xray update FAILED: compose file not found"
    exit 1
}

( cd "$COMPOSE_DIR" && docker compose up -d --no-deps --force-recreate "$SERVICE" ) >> "$LOG" 2>&1

# 5) Smoke: container port 3080 must be reachable on the edge network within 12s.
# xray-client uses `expose: 3080` (not host-network), so probe inside the container.
ok=0
for _i in 1 2 3 4 5 6; do
    sleep 2
    if docker exec "$CONTAINER" sh -c 'ss -ltn 2>/dev/null | grep -q ":3080"' 2>/dev/null; then
        ok=1; break
    fi
done

if [ $ok -eq 1 ]; then
    NEW_VER=$(docker inspect "$CONTAINER" --format '{{index .Config.Labels "oxpulse.version"}}' 2>/dev/null || echo unknown)
    log "OK update: $OLD_VER → $NEW_VER"
    alert "xray updated: $OLD_VER → $NEW_VER"
else
    log "FAIL smoke (port 3080 not reachable in container after 12s)"
    docker logs "$CONTAINER" --tail 30 >> "$LOG" 2>&1
    alert "xray update FAILED — investigate (smoke timeout)"
    exit 1
fi
