#!/usr/bin/env bash
# oxpulse-partner-edge-refresh.sh — daily auto-refresh of Reality keys.
#
# Phase 5.5 MAJOR 1 (PR feat/phase5-6-...): render_channel_soft + CHANNELS_FAILED
# + compose_strip_failed_channels sourced from lib/render-channel-lib.sh.
# channels_version re-render now uses render_channel_soft (fail-soft).
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

# Phase 5.5 MAJOR 1: load fail-soft render helpers (render_channel_soft,
# CHANNELS_FAILED, compose_strip_failed_channels).
_rl_sbin="${PREFIX_SBIN:-/usr/local/sbin}/render-channel-lib.sh"
_rl_local="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/lib/render-channel-lib.sh"
if [[ -f "$_rl_local" ]]; then
    # shellcheck source=lib/render-channel-lib.sh
    source "$_rl_local"
elif [[ -f "$_rl_sbin" ]]; then
    # shellcheck source=/dev/null
    source "$_rl_sbin"
else
    # Graceful degradation — render_channel_soft is not available; channels_version
    # re-render will fall back to re_render_xray (original behaviour, no fail-soft).
    render_channel_soft() { warn "render_channel_soft: lib not found — using re_render_xray fallback"; re_render_xray; }
    # shellcheck disable=SC2034
    CHANNELS_FAILED=()
fi
unset _rl_local _rl_sbin

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
# Phase 5.5 MAJOR 1: uses render_channel_soft (fail-soft) so a single
# failing channel does not abort the entire refresh cycle.
#
# Phase 5.7 Item 4: surgical per-channel restart after re-render.
# Only containers whose rendered config actually changed (SHA256 diff) are
# restarted. Healthy unchanged containers are left running. Failed channels
# (from channels-status.env) are skipped entirely.

# _restart_if_changed kind cfg_file sha_file compose_file container
# Restarts a single docker compose service only when its config file hash
# differs from the last persisted hash. Updates the sha file on success.
# Consults channels-status.env: skips channels that are not active.
#
# MAJOR 6 review-fix note: uses `docker compose restart` (not `up --force-recreate`).
# This is intentional: the channels_version path re-renders only channel config
# files (xray-client.json, etc.) — it does NOT re-render docker-compose.yml.
# The compose service definitions are invariant under channels_version changes;
# only the mounted config files change. `restart` is therefore correct here.
# If compose.yml drift is detected via `install.sh --check`, the operator must
# run a full re-install. This assumption is CI-verified via test_install_sh_check_drift.sh.
_restart_if_changed() {
    local kind="$1" cfg_file="$2" sha_file="$3" compose_file="$4" container="$5"

    # Consult channels-status.env: skip non-active channels
    local _ch_status=""
    local _chs_env="${PREFIX_LIB}/channels-status.env"
    if [[ -f "$_chs_env" ]]; then
        _ch_status=$(grep "^${kind}=" "$_chs_env" 2>/dev/null | cut -d= -f2 || true)
    fi
    if [[ -n "$_ch_status" && "$_ch_status" != "active" ]]; then
        log "  [surgical] channel $kind status=$_ch_status — skipping restart"
        return 0
    fi

    [[ -f "$cfg_file" ]] || return 0
    local _new_sha
    _new_sha=$(sha256sum "$cfg_file" | awk '{print $1}')
    local _old_sha
    _old_sha=$(cat "$sha_file" 2>/dev/null || printf '')
    if [[ "$_new_sha" != "$_old_sha" ]]; then
        log "  [surgical] channel $kind config changed — restarting $container"
        if docker compose -f "$compose_file" restart "$container" 2>>"$LOG_FILE"; then
            # MAJOR 3 review-fix: write sha only after verifying the container
            # is actually running. If the container is in CrashLoopBackOff /
            # restarting state, writing the sha would suppress the next refresh
            # cycle from retrying — leaving the container stuck on stale config.
            # Allow ~5s for Docker to transition the state post-restart.
            sleep 5
            local _state
            _state=$(docker compose -f "$compose_file" ps "$container" \
                --format json 2>/dev/null \
                | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("State","unknown"))' \
                2>/dev/null || printf 'unknown')
            if [[ "$_state" == "running" ]]; then
                printf '%s\n' "$_new_sha" > "$sha_file"
                log "  [surgical] $container restarted OK"
            else
                log "WARNING: [surgical] $container state=$_state after restart — sha not updated, next refresh will retry"
            fi
        else
            log "WARNING: [surgical] docker restart $container failed — container may use stale config"
        fi
    else
        log "  [surgical] channel $kind unchanged — no restart"
    fi
}

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
        # Use render_channel_soft so a single failing channel does not abort
        # the entire refresh. Failures are non-fatal — channels_version is
        # updated so we do not retry the same broken config tomorrow.
        _xray_cfg="${PREFIX_ETC}/xray-client.json"
        # shellcheck disable=SC2034  # CHANNELS_FAILED consumed by render_channel_soft internals
        CHANNELS_FAILED=()
        render_channel_soft xray \
            "${PREFIX_SBIN:-/usr/local/sbin}/xray-client.json.tpl" \
            "$_xray_cfg" 2>/dev/null \
            || re_render_xray \
            || log "WARNING: xray channel re-render failed — xray may use stale config"
        unset _xray_cfg
        echo "$NEW_CHANNELS_VERSION" > "$CHANNELS_VERSION_FILE"
        log "channels_version updated to $NEW_CHANNELS_VERSION"
    fi

    # Phase 5.7 Item 4: surgical restart — only restart containers whose
    # rendered config file actually changed vs. the persisted sha.
    _compose="${PREFIX_ETC}/docker-compose.yml"
    if [[ -f "$_compose" ]]; then
        _restart_if_changed xray \
            "${PREFIX_ETC}/xray-client.json" \
            "${PREFIX_LIB}/xray-config.sha" \
            "$_compose" \
            oxpulse-partner-xray
        # Naive channel (CH5) — skip when not deployed
        if [[ -f "${PREFIX_ETC}/naive-client.json" ]]; then
            _restart_if_changed naive \
                "${PREFIX_ETC}/naive-client.json" \
                "${PREFIX_LIB}/naive-config.sha" \
                "$_compose" \
                oxpulse-partner-naive
        fi
        # Hysteria2 channel (CH3) — restart existing or bootstrap from node-config
        _hy2_server=$(jq -r ".hysteria2_server // empty" "$NODE_CFG" 2>/dev/null || true)
        if [[ -f "${PREFIX_ETC}/hysteria2-client.yaml" ]]; then
            _restart_if_changed hysteria2 \
                "${PREFIX_ETC}/hysteria2-client.yaml" \
                "${PREFIX_LIB}/hysteria2-config.sha" \
                "$_compose" \
                oxpulse-partner-hysteria2
        elif [[ -n "${_hy2_server:-}" ]]; then
            # Bootstrap path: node-config returns hysteria2_server but channel was
            # never activated on this edge (installed before Phase 1.7).
            # enable-hy2 is idempotent — safe to retry on every channels_version tick
            # until the file exists.
            log "  hy2 channel: bootstrap (node-config has hysteria2_server=${_hy2_server}; local config absent)"
            if [[ -x "${PREFIX_SBIN:-/usr/local/sbin}/oxpulse-partner-edge-enable-hy2" ]]; then
                "${PREFIX_SBIN:-/usr/local/sbin}/oxpulse-partner-edge-enable-hy2" \
                    --server "$_hy2_server" \
                    2>&1 | sed "s/^/    [enable-hy2] /" || \
                    log "WARNING: hy2 bootstrap failed (non-fatal); next channels_version tick will retry"
            else
                log "WARNING: hy2 bootstrap requested but enable-hy2 not installed at ${PREFIX_SBIN:-/usr/local/sbin}/oxpulse-partner-edge-enable-hy2 — run upgrade.sh --host-scripts-only"
            fi
        fi
        unset _hy2_server
    else
        log "WARNING: docker-compose.yml not found at $_compose — skipping surgical restart"
    fi
    unset _compose
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

# Re-assert split-routing after AWG param sync.
# The awg-params-agent may reset the hub peer's AllowedIPs from 0.0.0.0/0
# back to /32 when applying a new epoch. refresh.service runs daily and
# coincides with param-agent syncs, so we re-assert as the final step.
# Idempotent: split-routing script is safe to call multiple times.
# Skip gracefully on nodes where split-routing is not installed.
_sr_svc="oxpulse-partner-edge-split-routing.service"
if systemctl list-unit-files "$_sr_svc" --no-legend 2>/dev/null | grep -q "$_sr_svc"; then
    log "re-asserting split-routing after AWG param sync"
    if systemctl restart "$_sr_svc" 2>>"$LOG_FILE"; then
        log "split-routing re-assert OK"
    else
        log "WARN split-routing re-assert failed (non-fatal) — check: systemctl status $_sr_svc"
    fi
else
    log "split-routing: $_sr_svc not installed — skipping re-assert"
fi
