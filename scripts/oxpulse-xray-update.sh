#!/bin/bash
# oxpulse-xray-update.sh — single-container watchtower for partner-edge xray.
#
# Watches :stable channel on GHCR. Promotion to :stable is a manual gate
# in oxpulse-partner-edge release workflow (promote-stable.yml), so this
# timer only redeploys versions that an operator explicitly blessed.
#
# Pattern: clone of oxpulse-sfu-update.sh. Same alert/log/recovery shape so
# operators read both the same way.
set -euo pipefail

LOG=/var/log/oxpulse-xray-update.log
CONTAINER=oxpulse-partner-xray
IMAGE=ghcr.io/anatolykoptev/partner-edge-xray:stable
ENV_FILE=/etc/oxpulse-partner-edge/xray.env
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
log "update detected; recreating $CONTAINER (current=$OLD_VER)"

# 4) Recreate. Keep flags in sync with how the container was originally created.
[ -r "$ENV_FILE" ] || { log "FAIL missing $ENV_FILE"; alert "xray update FAILED: missing env file"; exit 1; }

docker rm -f "$CONTAINER" >> "$LOG" 2>&1
docker run -d --name "$CONTAINER" \
    --restart unless-stopped \
    --network host \
    --env-file "$ENV_FILE" \
    "$IMAGE" >> "$LOG" 2>&1

# 5) Smoke: port 3080 must be listening within 12s.
ok=0
for _i in 1 2 3 4 5 6; do
    sleep 2
    if ss -ltn 2>/dev/null | grep -q ':3080 '; then
        ok=1; break
    fi
done

if [ $ok -eq 1 ]; then
    NEW_VER=$(docker inspect "$CONTAINER" --format '{{index .Config.Labels "oxpulse.version"}}' 2>/dev/null || echo unknown)
    log "OK update: $OLD_VER → $NEW_VER"
    alert "xray updated: $OLD_VER → $NEW_VER"
else
    log "FAIL smoke (port 3080 not listening after 12s)"
    docker logs "$CONTAINER" --tail 30 >> "$LOG" 2>&1
    alert "xray update FAILED — investigate (smoke timeout)"
    exit 1
fi
