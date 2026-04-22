#!/usr/bin/env bash
# oxpulse-partner-edge-refresh.sh — daily auto-refresh of Reality keys.
#
# Operator backend (krolik) rotates Reality x25519 + ML-KEM-768 keypair
# quarterly via rotate-reality-keys.timer. Without auto-refresh, partner
# edges installed before the rotation keep running with old keys and
# their xray-client TLS handshakes fail until manual re-registration.
#
# This script:
#   1. GET ${BACKEND_URL}/api/partner/keys (no auth, returns version hash)
#   2. Compare returned `version` with stored value
#   3. If different:
#      a. Patch /etc/oxpulse-partner-edge/node-config.json with new
#         reality_public_key + reality_encryption + reality_server_names
#      b. systemctl reload oxpulse-partner-edge.service (compose recreate)
#      c. Persist new version hash
#   4. Else: no-op (cheap — daily run with constant headers, ~200B response)
set -euo pipefail

PREFIX_ETC=/etc/oxpulse-partner-edge
PREFIX_LIB=/var/lib/oxpulse-partner-edge
NODE_CFG="$PREFIX_ETC/node-config.json"
VERSION_FILE="$PREFIX_LIB/keys-version"
LOG_FILE=/var/log/oxpulse-partner-edge-refresh.log
BACKEND_URL="${OXPULSE_BACKEND_URL:-https://oxpulse.chat}"
BACKEND_URL="${BACKEND_URL%/}"

ts()   { date -Iseconds; }
log()  { printf '%s %s\n' "$(ts)" "$*" | tee -a "$LOG_FILE"; }
die()  { log "ERR $*"; exit 1; }

[[ -f "$NODE_CFG" ]] || die "node-config.json not found at $NODE_CFG"

# Fetch fresh keys
RESP=$(curl -sS --max-time 10 -fL "$BACKEND_URL/api/partner/keys" 2>&1) \
    || die "fetch keys failed: $RESP"

NEW_VERSION=$(printf '%s' "$RESP" | jq -r '.version' 2>/dev/null) \
    || die "parse version failed: $RESP"
[[ -n "$NEW_VERSION" && "$NEW_VERSION" != "null" ]] \
    || die "empty version in response: $RESP"

CURRENT_VERSION=$(cat "$VERSION_FILE" 2>/dev/null || echo "none")

if [[ "$NEW_VERSION" == "$CURRENT_VERSION" ]]; then
    log "no rotation: version=$NEW_VERSION"
    exit 0
fi

log "rotation detected: $CURRENT_VERSION → $NEW_VERSION ; updating node-config.json"

# Backup
BACKUP="${NODE_CFG}.bak.$(date +%s)"
cp "$NODE_CFG" "$BACKUP"

# Merge new reality fields into node-config.json
NEW_PUB=$(printf '%s' "$RESP"     | jq -r '.reality_public_key')
NEW_ENC=$(printf '%s' "$RESP"     | jq -r '.reality_encryption')
NEW_NAMES=$(printf '%s' "$RESP"   | jq -c '.reality_server_names')

jq \
    --arg pub "$NEW_PUB" \
    --arg enc "$NEW_ENC" \
    --argjson names "$NEW_NAMES" \
    '.reality_public_key = $pub | .reality_encryption = $enc | .reality_server_names = $names' \
    "$BACKUP" > "$NODE_CFG"

# Reload services so xray-client picks up new keys
log "reloading oxpulse-partner-edge.service"
if systemctl reload oxpulse-partner-edge.service 2>>"$LOG_FILE"; then
    log "reload OK"
else
    log "reload FAILED — restoring $BACKUP"
    mv "$BACKUP" "$NODE_CFG"
    systemctl reload oxpulse-partner-edge.service 2>>"$LOG_FILE" || true
    die "rollback complete; new keys NOT applied"
fi

# Verify xray-client + caddy are healthy after reload
sleep 5
if systemctl is-active --quiet oxpulse-partner-edge.service; then
    log "post-reload: oxpulse-partner-edge active"
else
    log "post-reload: service NOT active — restoring backup"
    mv "$BACKUP" "$NODE_CFG"
    systemctl reload oxpulse-partner-edge.service 2>>"$LOG_FILE" || true
    die "rollback complete after failed verify"
fi

# Persist new version
echo "$NEW_VERSION" > "$VERSION_FILE"
log "OK rotation applied: pub=${NEW_PUB:0:16}... version=$NEW_VERSION"
