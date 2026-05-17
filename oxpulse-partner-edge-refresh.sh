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
#   2. Extract sfu_signing_public_key (Phase 2: Ed25519 asymmetric JWT verification)
#      and persist it to sfu-keys.env on EVERY run (so the SFU container always
#      has the current key, not just on rotation days).
#   3. Compare returned `version` with stored value
#   4. If different:
#      a. Patch /etc/oxpulse-partner-edge/node-config.json with new
#         reality_public_key + reality_encryption + reality_server_names
#      b. systemctl reload oxpulse-partner-edge.service (compose recreate)
#      c. Persist new version hash
#   5. Else: no-op for Reality rotation (cheap — daily run, ~200B response)
set -euo pipefail

PREFIX_ETC="${PARTNER_EDGE_PREFIX_ETC:-/etc/oxpulse-partner-edge}"
PREFIX_LIB="${PARTNER_EDGE_PREFIX_LIB:-/var/lib/oxpulse-partner-edge}"
NODE_CFG="$PREFIX_ETC/node-config.json"
VERSION_FILE="$PREFIX_LIB/keys-version"
CHANNELS_VERSION_FILE="$PREFIX_LIB/channels-version"
SFU_KEYS_ENV="$PREFIX_LIB/sfu-keys.env"
TEXTFILE_DIR="${PARTNER_EDGE_TEXTFILE_DIR:-/var/lib/prometheus-node-exporter/textfile}"
LOG_FILE="${LOG_FILE:-/var/log/oxpulse-partner-edge-refresh.log}"
BACKEND_URL="${OXPULSE_BACKEND_URL:-https://oxpulse.chat}"
BACKEND_URL="${BACKEND_URL%/}"

ts()   { date -Iseconds; }
log()  { printf '%s %s\n' "$(ts)" "$*" | tee -a "$LOG_FILE"; }
die()  { log "ERR $*"; exit 1; }
# Append or create a Prometheus textfile metric (node_exporter textfile collector).
# Idempotent: overwrites the file on every run so stale gauges do not accumulate.
# Skips silently when TEXTFILE_DIR is unwritable or absent (non-fatal).
emit_metric() {
    local name="$1" labels="$2" value="$3"
    [[ -d "$TEXTFILE_DIR" ]] || mkdir -p "$TEXTFILE_DIR" 2>/dev/null || return 0
    local prom_file="$TEXTFILE_DIR/partner_edge.prom"
    # Append metric line; node_exporter accumulates all lines per scrape.
    printf '# TYPE %s counter\n%s{%s} %s\n' \
        "$name" "$name" "$labels" "$value" >> "$prom_file" 2>/dev/null || true
}

# OS-aware install hint: returns the appropriate install command for the host PM.
suggest_install() {
    local pkg="$1"
    if command -v dnf >/dev/null 2>&1; then
        echo "dnf install -y $pkg"
    elif command -v apt-get >/dev/null 2>&1; then
        echo "apt-get install -y $pkg"
    elif command -v apk >/dev/null 2>&1; then
        echo "apk add $pkg"
    else
        echo "install via your package manager"
    fi
}

# Dependency check: jq is required for JSON parsing throughout this script.
# On cheburator1 (2026-05-09 incident): jq was absent from the systemd unit
# PATH, causing set -euo pipefail to exit at line 39 (NODE_ID extraction)
# silently — the heartbeat POST was never reached, leaving last_seen_at stale
# for 1 week. Die here with a clear message so systemd logs are actionable.
command -v jq >/dev/null 2>&1 \
    || die "jq required but not installed — fix: $(suggest_install jq)"
command -v curl >/dev/null 2>&1 \
    || die "curl required but not installed — fix: $(suggest_install curl)"

# Service token helper — used for any authenticated /api/partner/* calls.
# Source the shared lib if present; fall back to inline definition so the
# script degrades gracefully on nodes that haven't re-run install.sh yet.
_TOKEN_LIB="${PREFIX_SBIN:-/usr/local/sbin}/oxpulse-token-lib.sh"
if [[ -r "$_TOKEN_LIB" ]]; then
    # shellcheck source=/dev/null
    source "$_TOKEN_LIB"
else
    # Inline fallback (matches lib definition; remove once all nodes upgraded).
    read_service_token() {
        if [[ -n "${OXPULSE_SERVICE_TOKEN:-}" ]]; then
            printf '%s' "$OXPULSE_SERVICE_TOKEN"; return 0
        fi
        if [[ -r "${PREFIX_ETC}/token" ]]; then
            cat "${PREFIX_ETC}/token"; return 0
        fi
        return 1
    }
fi
unset _TOKEN_LIB

[[ -f "$NODE_CFG" ]] || die "node-config.json not found at $NODE_CFG"

NODE_ID=$(jq -r '.node_id // .partner_id // empty' "$NODE_CFG")
[[ -n "$NODE_ID" ]] || die "node_id not found in $NODE_CFG"

# Fetch fresh keys — non-fatal. DNS or network failure must not suppress
# the heartbeat POST below (observability liveness must survive key-rotation
# transient failures). Production incident 2026-05-13: all 3 partner edges
# fired PartnerEdgeStaleHeartbeat >24h because `|| die` here aborted the
# script before heartbeat was reached on every DNS-failing daily run.
KEYS_OK=1
RESP=$(curl -sS --max-time 10 -fL "$BACKEND_URL/api/partner/keys" 2>&1) \
    || { log "WARN fetch keys failed (will retry tomorrow): $RESP"; KEYS_OK=0; }

if [[ "$KEYS_OK" -eq 1 ]]; then
    NEW_VERSION=$(printf '%s' "$RESP" | jq -r '.version' 2>/dev/null) \
        || { log "WARN parse version failed: $RESP"; KEYS_OK=0; }
fi

if [[ "$KEYS_OK" -eq 1 ]]; then
    [[ -n "$NEW_VERSION" && "$NEW_VERSION" != "null" ]] \
        || { log "WARN empty version in response: $RESP"; KEYS_OK=0; }
fi

if [[ "$KEYS_OK" -eq 0 ]]; then
    emit_metric "partner_edge_keys_fetch_failure_total" \
        "partner_id=\"${NODE_ID}\"" "1"
    log "WARN keys fetch failed — skipping rotation, proceeding to heartbeat"
fi

CURRENT_VERSION=$(cat "$VERSION_FILE" 2>/dev/null || echo "none")

NEW_CHANNELS_VERSION=""
CURRENT_CHANNELS_VERSION=$(cat "$CHANNELS_VERSION_FILE" 2>/dev/null || echo "none")
if [[ "$KEYS_OK" -eq 1 ]]; then
    NEW_CHANNELS_VERSION=$(printf '%s' "$RESP" | jq -r '.channels_version // empty' 2>/dev/null || true)
fi

# Phase 2: Extract Ed25519 SFU signing public key on EVERY run.
# Written before the early-exit so the SFU container always has the current
# key even when Reality hasn't rotated. Ed25519 pubkeys are single-line
# base64 (~44 chars) — no heredoc needed.
if [[ "$KEYS_OK" -eq 1 ]]; then
    SFU_SIGNING_PUBKEY=$(printf '%s' "$RESP" | jq -r '.sfu_signing_public_key // empty')
    if [[ -n "$SFU_SIGNING_PUBKEY" ]]; then
        install -d -m 0700 "$PREFIX_LIB"
        printf 'SFU_SIGNING_PUBLIC_KEY=%s\n' "$SFU_SIGNING_PUBKEY" > "$SFU_KEYS_ENV"
        chmod 0600 "$SFU_KEYS_ENV"
        log "sfu_signing_public_key extracted and saved to $SFU_KEYS_ENV"
    else
        log "WARNING: sfu_signing_public_key not in /api/partner/keys response (signaling may need updating)"
    fi
fi

# Heartbeat — обновляет partner_nodes.last_seen_at. Без этого вызова
# piter-server видит нас "мёртвыми" и staleness canary срабатывает
# ложно (инцидент 2026-04-23, root cause: last_seen_at был только
# registration timestamp, не liveness). Endpoint публичный без auth,
# единственная запись — last_seen_at = NOW(). Идемпотентный.
HB_RESP=$(curl -sS -X POST \
  -H 'Content-Type: application/json' \
  -d "{\"node_id\":\"${NODE_ID}\"}" \
  --max-time 10 \
  "${BACKEND_URL}/api/partner/heartbeat" \
  -w '\n%{http_code}' 2>/dev/null || printf '\n000')
HB_CODE=$(printf '%s' "$HB_RESP" | tail -n1)
HB_BODY=$(printf '%s' "$HB_RESP" | sed '$d')
if [[ "$HB_CODE" != "200" ]]; then
    log "heartbeat failed: http=$HB_CODE body=$HB_BODY"
    emit_metric "partner_edge_heartbeat_failure_total" \
        "partner_id=\"${NODE_ID}\"" "1"
    # Non-fatal: heartbeat помогает observability, но не критичен
    # для функциональности ноды. Продолжаем refresh.
else
    log "heartbeat ok: $HB_BODY"
fi

# channels_version check — independent of Reality key rotation.
# Skip when keys fetch failed (NEW_CHANNELS_VERSION will be empty).
# Re-renders all channel configs when operator updates channel settings.
if [[ "$KEYS_OK" -eq 1 && -n "$NEW_CHANNELS_VERSION" && "$NEW_CHANNELS_VERSION" != "none" && \
      "$NEW_CHANNELS_VERSION" != "$CURRENT_CHANNELS_VERSION" ]]; then
    log "channels_version changed: $CURRENT_CHANNELS_VERSION → $NEW_CHANNELS_VERSION"
    _lib="/usr/local/sbin/channel-render-lib.sh"
    if [[ ! -f "$_lib" ]]; then
        log "WARNING: channel-render-lib.sh not found at $_lib — skip re-render"
        unset _lib
    else
        # shellcheck source=/dev/null
        source "$_lib"
        unset _lib
        if re_render_xray; then
            echo "$NEW_CHANNELS_VERSION" > "$CHANNELS_VERSION_FILE"
            log "channels_version updated to $NEW_CHANNELS_VERSION"
        else
            log "WARNING: re_render_xray failed — channels_version NOT updated (will retry tomorrow)"
        fi
    fi
fi

if [[ "$KEYS_OK" -eq 0 ]]; then
    log "keys fetch failed — skipping rotation check, exiting 0"
    exit 0
fi

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

# Reload services so xray-client picks up new keys.
# Custom-stack nodes (e.g. piter: own xray-reality + coturn + SFU compose)
# do NOT install oxpulse-partner-edge.service — skip gracefully so the
# script exits 0 and rotation is still committed to VERSION_FILE.
if systemctl list-unit-files oxpulse-partner-edge.service --no-legend 2>/dev/null \
        | grep -q oxpulse-partner-edge; then
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
else
    log "rotation: oxpulse-partner-edge.service not installed — skipping reload (custom stack node)"
fi

# Persist new version
echo "$NEW_VERSION" > "$VERSION_FILE"
log "OK rotation applied: pub=${NEW_PUB:0:16}... version=$NEW_VERSION"
