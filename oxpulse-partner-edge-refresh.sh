#!/usr/bin/env bash
# oxpulse-partner-edge-refresh.sh — daily auto-refresh of Reality keys.
#
# Phase 5.5 MAJOR 1 (PR feat/phase5-6-...): render_channel_soft + CHANNELS_FAILED
# + compose_strip_failed_channels sourced from lib/render-channel-lib.sh.
# channels_version re-render now uses render_channel_soft (fail-soft).
#
# Operator backend (hub) rotates Reality x25519 + ML-KEM-768 keypair
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
# Single source for the SFU container_name (docker-compose.yml.tpl `container_name:`).
# Used by the applied-gauge detector (docker ps filter + docker exec target) and as
# the `_docker_restart_if_sha_changed` state_container (docker inspect liveness). NOT the compose
# SERVICE key — that is the literal `sfu` (docker compose targets services, not
# container_names). Functions sourced in isolation by the tests set this themselves.
SFU_CONTAINER_NAME="oxpulse-partner-sfu"
TEXTFILE_DIR="${PARTNER_EDGE_TEXTFILE_DIR:-/var/lib/prometheus-node-exporter/textfile}"
LOG_FILE="${LOG_FILE:-/var/log/oxpulse-partner-edge-refresh.log}"
BACKEND_URL="${OXPULSE_BACKEND_URL:-https://oxpulse.chat}"
BACKEND_URL="${BACKEND_URL%/}"

ts()   { date -Iseconds; }
log()  { printf '%s %s\n' "$(ts)" "$*" | tee -a "$LOG_FILE"; }
die()  { log "ERR $*"; exit 1; }

# emit_metric / emit_gauge (Prometheus textfile-collector sink) — extracted to
# lib/metric-sink-lib.sh (P1 of the 2026-07-08 refresh-lib-extraction-
# strangler plan). emit_metric carries the load-bearing PR #328 MED-4 fix
# (cumulative state-file counter model, atomic mktemp+mv+chmod — see the lib's
# own header for the full duplicate-TYPE-line blackhole history); emit_gauge
# is now backed by the ATOMIC _emit_prom_gauge_file primitive (ADR-7).
#
# Sourced fail-closed: unlike render-channel-lib.sh's fail-soft degrade below
# (an optional fast-path optimization), there is no safe inline fallback for
# emit_metric's PR #328 fix — an inline duplicate here would be exactly the
# "known non-atomic/buggy duplicate re-ossified" mistake the council flagged
# for emit_gauge (ADR-7). Refuse to run rather than silently regress to the
# pre-#328 duplicate-TYPE-line blackhole bug.
_MSL_LOCAL="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/lib/metric-sink-lib.sh"
_MSL_SBIN="${PREFIX_SBIN:-/usr/local/sbin}/metric-sink-lib.sh"
if [[ -r "$_MSL_LOCAL" ]]; then
    # shellcheck source=lib/metric-sink-lib.sh
    source "$_MSL_LOCAL"
elif [[ -r "$_MSL_SBIN" ]]; then
    # shellcheck source=/dev/null
    source "$_MSL_SBIN"
else
    die "metric-sink-lib.sh not found (checked $_MSL_LOCAL and $_MSL_SBIN) — refusing to run without the metric sink (would silently regress emit_metric's PR #328 duplicate-TYPE-line fix)"
fi
unset _MSL_LOCAL _MSL_SBIN

# _docker_restart_if_sha_changed (sha-diff-gated docker compose restart/
# recreate mechanism) — extracted to lib/surgical-restart-lib.sh (P2 of the
# 2026-07-08 refresh-lib-extraction-strangler plan). PURE mechanism, zero
# channels-status.env knowledge (ADR-9) — see the lib's own header for the
# full boundary-split rationale and the caller-side gate wrapper
# (_channel_restart_if_changed) defined further below in this script.
#
# Sourced fail-closed for the same reason as metric-sink-lib.sh above: a
# missing lib here would leave channel/SFU config changes silently un-applied
# forever (the sha never advances, so nothing ever retries visibly) — refuse
# to run rather than silently regress to a stale-config fleet.
_SRL_LOCAL="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/lib/surgical-restart-lib.sh"
_SRL_SBIN="${PREFIX_SBIN:-/usr/local/sbin}/surgical-restart-lib.sh"
if [[ -r "$_SRL_LOCAL" ]]; then
    # shellcheck source=lib/surgical-restart-lib.sh
    source "$_SRL_LOCAL"
elif [[ -r "$_SRL_SBIN" ]]; then
    # shellcheck source=/dev/null
    source "$_SRL_SBIN"
else
    die "surgical-restart-lib.sh not found (checked $_SRL_LOCAL and $_SRL_SBIN) — refusing to run without the surgical-restart mechanism (would silently leave channel/SFU config changes un-applied)"
fi
unset _SRL_LOCAL _SRL_SBIN

# emit_xprb_failure / xprb_curl_get_with_retry / refresh_cross_probe_token
# (cross-probe bearer-token daily re-mint) — extracted to
# lib/xprb-refresh-lib.sh (P3 of the 2026-07-08 refresh-lib-extraction-
# strangler plan). Requires: lib/metric-sink-lib.sh (sourced above — MUST
# stay before this block; emit_xprb_failure calls emit_metric directly). See
# the lib's own header for the full trust-boundary-isolation rationale and
# the CROSS_PROBE_TOKEN_FILE cross-reference with lib/cross-probe-lib.sh.
#
# Sourced fail-closed for the same reason as the two libs above: a missing
# lib here would silently stop the daily xprb re-mint forever, and the fleet
# would eventually hit the exact MeshCrossProbeRejectionStorm this leg exists
# to prevent (see the lib's refresh_cross_probe_token header for the
# 2026-07-01 root cause).
_XRL_LOCAL="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/lib/xprb-refresh-lib.sh"
_XRL_SBIN="${PREFIX_SBIN:-/usr/local/sbin}/xprb-refresh-lib.sh"
if [[ -r "$_XRL_LOCAL" ]]; then
    # shellcheck source=lib/xprb-refresh-lib.sh
    source "$_XRL_LOCAL"
elif [[ -r "$_XRL_SBIN" ]]; then
    # shellcheck source=/dev/null
    source "$_XRL_SBIN"
else
    die "xprb-refresh-lib.sh not found (checked $_XRL_LOCAL and $_XRL_SBIN) — refusing to run without the cross-probe token refresh mechanism (would silently stop the daily xprb re-mint, eventually re-triggering MeshCrossProbeRejectionStorm)"
fi
unset _XRL_LOCAL _XRL_SBIN

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
# On edge-a1 (2026-05-09 incident): jq was absent from the systemd unit
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
    # write_secret_atomic — mirrors oxpulse-token-lib.sh's helper (see there
    # for the full rationale: every step guarded so a failure here can NEVER
    # take down a `set -euo pipefail` caller via an uncaught mktemp/chmod/mv
    # exit).
    write_secret_atomic() {
        local path="$1" content="$2" mode="$3"
        local tmp
        tmp=$(mktemp "${path}.XXXXXX" 2>&1) || { echo "mktemp failed: $tmp" >&2; return 1; }
        if ! printf '%s' "$content" > "$tmp" 2>/dev/null; then
            echo "write to tmp file failed" >&2
            rm -f "$tmp" 2>/dev/null || true
            return 1
        fi
        if ! chmod "$mode" "$tmp" 2>/dev/null; then
            echo "chmod $mode failed" >&2
            rm -f "$tmp" 2>/dev/null || true
            return 1
        fi
        # Durability (PR review round 2, MEDIUM) — see oxpulse-token-lib.sh
        # for the full rationale. Advisory only, never a `return 1`.
        if ! sync -f "$tmp" 2>/dev/null && ! sync 2>/dev/null; then
            echo "sync before rename failed (non-fatal, proceeding)" >&2
        fi
        if ! mv -f "$tmp" "$path" 2>/dev/null; then
            echo "mv into place failed" >&2
            rm -f "$tmp" 2>/dev/null || true
            return 1
        fi
        return 0
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
#
# Defense-in-depth (CWE-116/943): /api/partner/keys is unauthenticated
# ("no auth, returns version hash" — not a live-exploited path today, but
# its response is still untrusted input). The previous `printf ... >
# "$SFU_KEYS_ENV"` had two defects: (1) non-atomic — a crash/kill mid-write
# left a truncated/corrupt file the SFU container could source; (2)
# unescaped — an embedded newline in the value could inject an extra
# KEY=VALUE line into sfu-keys.env. Fixed by mirroring the SAME encoding
# opec already uses for this exact field (crates/opec/src/secrets/
# sfu_key.rs::fetch/write_env_file): encode any embedded newline/CR as a
# literal \n/\r escape (so the value can never span more than one physical
# line), single-quote the value with the canonical `'\''` shell-escape for
# embedded quotes, then persist via the same atomic mktemp+chmod+mv helper
# (write_secret_atomic, defined above / sourced from oxpulse-token-lib.sh)
# also used by refresh_cross_probe_token's CROSS_PROBE_TOKEN_FILE write
# (lib/xprb-refresh-lib.sh, called further below) — reusing it here instead
# of hand-rolling a second tmp+mv idiom.
if [[ "$KEYS_OK" -eq 1 ]]; then
    SFU_SIGNING_PUBKEY=$(printf '%s' "$RESP" | jq -r '.sfu_signing_public_key // empty')
    if [[ -n "$SFU_SIGNING_PUBKEY" ]]; then
        _sfu_key_encoded="${SFU_SIGNING_PUBKEY//$'\n'/\\n}"
        _sfu_key_encoded="${_sfu_key_encoded//$'\r'/\\r}"
        _sfu_key_escaped="${_sfu_key_encoded//\'/\'\\\'\'}"
        printf -v _sfu_key_line "SFU_SIGNING_PUBLIC_KEY='%s'\n" "$_sfu_key_escaped"
        install -d -m 0700 "$PREFIX_LIB"
        if _sfu_key_write_err=$(write_secret_atomic "$SFU_KEYS_ENV" "$_sfu_key_line" 0600 2>&1); then
            log "sfu_signing_public_key extracted and saved to $SFU_KEYS_ENV"
        else
            log "WARNING: sfu-keys.env write failed: $_sfu_key_write_err (existing file, if any, preserved)"
        fi
        unset _sfu_key_encoded _sfu_key_escaped _sfu_key_line _sfu_key_write_err
    else
        log "WARNING: sfu_signing_public_key not in /api/partner/keys response (signaling may need updating)"
    fi
fi

# Heartbeat — обновляет partner_nodes.last_seen_at. Без этого вызова
# relay-x видит нас "мёртвыми" и staleness canary срабатывает
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

# ── Central-driven self-upgrade (partner_nodes.desired_release) ─────────────
# The central sets a per-node target release (`partner-cli update`); the edge
# pulls it from the heartbeat response and self-upgrades. Pull model — no
# inbound path, no SSH. FAIL-SOFT: any problem logs + skips, NEVER aborts the
# refresh (the 2026-05-13 incident class). Defense-in-depth with partner-cli's
# set-time downgrade refusal (L1) and upgrade.sh's apply-path Check 3 (L3):
# here we also reject a non-bare-semver value and a downgrade vs the installed
# IMAGE_VERSION before invoking the (SHA256SUMS-verified) upgrade.
_self_upgrade_is_ge() {
    # bare-semver A >= B (MAJOR.MINOR.PATCH via sort -V)
    [[ "$1" == "$2" ]] && return 0
    [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" == "$1" ]]
}
_maybe_self_upgrade() {
    local hb_code="$1" hb_body="$2"
    [[ "$hb_code" == "200" ]] || return 0
    local _desired _installed
    _desired=$(printf '%s' "$hb_body" | jq -r '.desired_release // empty' 2>/dev/null || true)
    [[ -n "$_desired" ]] || return 0
    # FAIL-SOFT: a missing IMAGE_VERSION= line (grep exit 1) or unreadable file
    # must NOT abort the refresh under `set -euo pipefail` (2026-05-13 incident
    # class) — `|| true` on the whole pipeline.
    _installed=$(grep -E '^IMAGE_VERSION=' "$PREFIX_LIB/install.env" 2>/dev/null | head -1 | cut -d= -f2 || true)
    _installed="${_installed#v}"
    # desired must be a CONCRETE release semver — no pre-release/build suffix:
    # `sort -V` mis-orders pre-releases and rc-over-final is a downgrade in
    # disguise, so a fleet rollout only targets MAJOR.MINOR.PATCH.
    if [[ ! "$_desired" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log "self-upgrade: ignoring desired_release '$_desired' — not a concrete release semver"
        emit_metric "partner_edge_self_upgrade_rejected_total" "reason=\"format\"" "1"
        return 0
    fi
    # installed must be a concrete semver to rank — a default `IMAGE_VERSION=stable`
    # or unset value cannot be compared (`sort -V` ranks `stable` above any
    # number), so FAIL-CLOSED refuse rather than mis-rank it: bootstrap the node
    # to a concrete version via a manual upgrade first.
    if [[ ! "$_installed" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log "self-upgrade: installed version '${_installed:-unset}' not a concrete semver — refusing (bootstrap manually first)"
        emit_metric "partner_edge_self_upgrade_unknown_installed_total" "" "1"
        return 0
    fi
    if [[ "$_desired" == "$_installed" ]]; then
        return 0  # already converged — idempotent no-op
    fi
    if ! _self_upgrade_is_ge "$_desired" "$_installed"; then
        log "self-upgrade: refusing downgrade desired=$_desired installed=$_installed"
        emit_metric "partner_edge_self_upgrade_downgrade_refused_total" "" "1"
        return 0
    fi
    log "self-upgrade: desired_release=$_desired (installed=$_installed) — applying"
    emit_metric "partner_edge_self_upgrade_applied_total" "tag=\"$_desired\"" "1"
    local _upg_bin
    _upg_bin=$(command -v oxpulse-partner-edge-upgrade 2>/dev/null || echo /usr/local/sbin/oxpulse-partner-edge-upgrade)
    # timeout: a DPI-blocked docker pull must not block this refresh (and the
    # cross-probe-token re-mint after it) indefinitely. Fail-soft either way.
    if timeout 900 "$_upg_bin" "v${_desired}" >/dev/null 2>&1; then
        log "self-upgrade: applied v$_desired"
    else
        log "self-upgrade: $_upg_bin v$_desired FAILED/timed-out (non-fatal; retry next refresh)"
        emit_metric "partner_edge_self_upgrade_failure_total" "" "1"
    fi
}
_maybe_self_upgrade "$HB_CODE" "$HB_BODY"

# ---------- cross-probe token refresh (T2.4.c re-mint endpoint) ----------
# refresh_cross_probe_token (emit_xprb_failure / xprb_curl_get_with_retry) —
# extracted to lib/xprb-refresh-lib.sh (P3 of the 2026-07-08
# refresh-lib-extraction-strangler plan). See the lib's own header for the
# 2026-07-01 MeshCrossProbeRejectionStorm root cause, the age-gated cadence,
# the COALESCE-PRESERVE failure posture, and the CWE-214 bearer-off-argv fix
# (P-sec1, PR #371) this move carries over unmodified.
refresh_cross_probe_token

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

# _channel_restart_if_changed kind cfg_file sha_file compose_file container [apply_mode] [state_container]
#
# Thin CALLER-SIDE wrapper (ADR-9 of the 2026-07-08 refresh-lib-extraction-
# strangler plan): consults channels-status.env — the channel-provisioning
# surface's status vocabulary (written by the backend for xray/naive/
# hysteria2/…) — and skips non-active channels, BEFORE delegating to the PURE
# `_docker_restart_if_sha_changed` mechanism (lib/surgical-restart-lib.sh,
# sourced fail-closed above). Channel callers below go through this wrapper.
#
# The SFU key-apply caller (further below) has no channels-status.env
# vocabulary for `sfu` — a stray `sfu=` line there must NOT silently suppress
# a signing-key recreate — so it calls `_docker_restart_if_sha_changed`
# directly, SKIPPING this wrapper entirely, rather than the prior
# `_restart_if_changed`'s 8th `skip_channel_status` bypass-flag arg (the
# Fowler flag-argument smell the architecture council flagged: domain policy
# leaking into what should be a pure infrastructure primitive).
#
# MAJOR 6 review-fix note (unchanged from pre-extraction): the channels_version
# path uses `docker compose restart` (not `up --force-recreate`). This is
# intentional: the channels_version path re-renders only channel config files
# (xray-client.json, etc.) — it does NOT re-render docker-compose.yml. The
# compose service definitions are invariant under channels_version changes;
# only the mounted config files change. `restart` is therefore correct here.
# If compose.yml drift is detected via `install.sh --check`, the operator must
# run a full re-install. This assumption is CI-verified via test_install_sh_check_drift.sh.
#
# See lib/surgical-restart-lib.sh's header for apply_mode / state_container
# semantics (unchanged by this split).
_channel_restart_if_changed() {
    local kind="$1"
    local _ch_status=""
    local _chs_env="${PREFIX_LIB}/channels-status.env"
    if [[ -f "$_chs_env" ]]; then
        _ch_status=$(grep "^${kind}=" "$_chs_env" 2>/dev/null | cut -d= -f2 || true)
    fi
    if [[ -n "$_ch_status" && "$_ch_status" != "active" ]]; then
        log "  [surgical] channel $kind status=$_ch_status — skipping restart"
        return 0
    fi
    _docker_restart_if_sha_changed "$@"
}

# _rederive_channels_status — re-evaluate channels-status.env from live state.
#
# oxpulse-partner-edge#505: channels-status.env was frozen at install time — a
# channel marked "skipped" (because HYSTERIA2_SERVER was empty at install) stayed
# skipped forever, even after the inputs appeared and the container was running.
# _channel_restart_if_changed then skipped every restart for that channel, so
# config re-renders never reached the container (rvpn-seed ran May's config for
# two months, reporting healthy the entire time).
#
# This function re-derives each channel's status from currently-available inputs
# + live container/interface state, and writes the result back atomically. It
# runs on every refresh, BEFORE the channels_version restart block, so the gate
# sees fresh state.
#
# Transition rules (only skipped→active is promoted; failures are sticky):
#   skipped → active   when the channel's required inputs are now present AND
#                      its container/interface is running.
#   skipped → skipped  when inputs are still absent (nothing to try with).
#   failed_at_*  → unchanged. "We tried and it broke" is a different state from
#                  "we had nothing to try with" — collapsing them repeats the
#                  liveness≠authorization mistake that took rvpn-seed down.
#   active → active    (no downward transition; a running channel stays active).
#
# Inputs per channel:
#   xray       — always active (install.sh always attempts it; ch1 is the
#                primary signaling channel, never skipped).
#   hysteria2  — node-config .hysteria2_server present AND
#                /etc/.../hysteria2-client.yaml exists AND
#                container oxpulse-partner-hysteria2 is running.
#   naive      — /etc/.../naive-client.json exists AND
#                container oxpulse-partner-naive is running.
#   awg        — node-config .awg_ip present AND
#                systemctl is-active awg-quick@awg0 == active.
#
# Container liveness is checked via `docker inspect --format '{{.State.Running}}'`
# (same primitive as lib/surgical-restart-lib.sh). A missing/failed docker call
# is treated as "not running" (fail-closed: no false active promotion).
_rederive_channels_status() {
    local _chs_env="${PREFIX_LIB}/channels-status.env"
    [[ -f "$_chs_env" ]] || return 0

    # Read current statuses into an associative array.
    declare -A _cur=()
    local _name _val
    while IFS='=' read -r _name _val || [[ -n "$_name" ]]; do
        [[ -z "$_name" || "$_name" =~ ^# ]] && continue
        _cur["$_name"]="$_val"
    done < "$_chs_env"

    # Helper: is a docker container running? Fail-closed (false on any error).
    _rdcs_container_running() {
        local _ctr="$1"
        [[ -n "$_ctr" ]] || return 1
        local _running
        _running=$(docker inspect --format '{{.State.Running}}' "$_ctr" 2>/dev/null || echo false)
        [[ "$_running" == "true" ]]
    }

    # Helper: is a systemd unit active? Fail-closed.
    _rdcs_unit_active() {
        local _unit="$1"
        [[ -n "$_unit" ]] || return 1
        local _state
        _state=$(systemctl is-active "$_unit" 2>/dev/null || echo inactive)
        [[ "$_state" == "active" ]]
    }

    local _changed=0

    # hysteria2: skipped → active when hysteria2_server in node-config +
    # config file exists + container running.
    if [[ "${_cur[hysteria2]:-}" == "skipped" ]]; then
        local _hy2_server
        _hy2_server=$(jq -r '.hysteria2_server // empty' "$NODE_CFG" 2>/dev/null || true)
        if [[ -n "$_hy2_server" && -f "${PREFIX_ETC}/hysteria2-client.yaml" ]] && \
           _rdcs_container_running oxpulse-partner-hysteria2; then
            log "  [rederive] hysteria2: skipped → active (server=$_hy2_server, config+container present)"
            _cur[hysteria2]=active
            _changed=1
        fi
    fi

    # naive: skipped → active when config file exists + container running.
    if [[ "${_cur[naive]:-}" == "skipped" || \
          "${_cur[naive]:-}" == "skipped_no_server" || \
          "${_cur[naive]:-}" == "skipped_fixture_host" ]]; then
        if [[ -f "${PREFIX_ETC}/naive-client.json" ]] && \
           _rdcs_container_running oxpulse-partner-naive; then
            log "  [rederive] naive: ${_cur[naive]} → active (config+container present)"
            _cur[naive]=active
            _changed=1
        fi
    fi

    # awg: skipped → active when awg_ip in node-config + awg-quick@awg0 active.
    if [[ "${_cur[awg]:-}" == "skipped" ]]; then
        local _awg_ip
        _awg_ip=$(jq -r '.awg_ip // empty' "$NODE_CFG" 2>/dev/null || true)
        if [[ -n "$_awg_ip" ]] && _rdcs_unit_active awg-quick@awg0; then
            log "  [rederive] awg: skipped → active (awg_ip=$_awg_ip, awg0 up)"
            _cur[awg]=active
            _changed=1
        fi
    fi

    # Write back atomically only if something changed.
    if [[ $_changed -eq 1 ]]; then
        local _tmp
        _tmp=$(mktemp "$PREFIX_LIB/.channels-status-XXXXXX.tmp")
        {
            printf '# Generated by oxpulse-partner-edge-refresh.sh — DO NOT EDIT\n'
            # Preserve original key order: xray, hysteria2, naive, awg
            # (install.sh writes in this order; healthcheck.sh reads in
            # file order for display, so keeping order stable avoids
            # spurious snapshot diffs).
            for _k in xray hysteria2 naive awg; do
                [[ -n "${_cur[$_k]:-}" ]] && printf '%s=%s\n' "$_k" "${_cur[$_k]}"
            done
        } > "$_tmp"
        chmod 0640 "$_tmp"
        mv -f "$_tmp" "$_chs_env"
        log "  [rederive] channels-status.env updated"
    fi

    unset -f _rdcs_container_running _rdcs_unit_active
}

# _sfu_env_file_wired COMPOSE_FILE — true iff the live compose's `sfu` service
# already reads the signing key via `env_file: … sfu-keys.env`. Guards the recreate
# below: upgrade.sh syncs a NEW refresh.sh on every run but NEVER re-renders the
# on-disk compose to add the env_file stanza (it only sed-patches image tags — no
# `env_file` reference exists anywhere in upgrade.sh), so an already-deployed node
# can run this new refresh against an OLD compose that still bakes the key under
# `environment:`. A `--force-recreate sfu` there would drop live WebRTC media for
# ZERO benefit (the baked literal wins over the absent env_file). The check
# anchors the sfu-keys.env match to the actual `env_file:` directive INSIDE the
# `sfu:` service block (scalar form on the directive line, or a list entry within
# its sub-block), so neither a stray comment mentioning sfu-keys.env nor another
# service's env_file stanza can produce a false wired=true.
_sfu_env_file_wired() {
    local compose_file="$1"
    awk '
        /^  sfu:/               { insfu=1; next }   # enter sfu service block
        insfu && /^  [A-Za-z]/  { insfu=0 }         # next 2-space sibling service ends it
        insfu {
            # env_file: is a 4-space key under the service. Anchor the sfu-keys.env
            # match to it (scalar form on the same line, or a list entry inside its
            # sub-block) so a stray comment or a different service cannot false-match.
            if ($0 ~ /^    env_file:/) {
                inenv=1
                if ($0 ~ /sfu-keys\.env/) found=1
                next
            }
            if (inenv && $0 ~ /^    [A-Za-z]/) inenv=0   # next 4-space key ends env_file:
            if (inenv && $0 ~ /sfu-keys\.env/) found=1   # short/object list entry
        }
        END { exit(found ? 0 : 1) }
    ' "$compose_file" 2>/dev/null
}

# Detector: compare the SFU signing pubkey WRITTEN to sfu-keys.env (what should
# be running) against the SFU container's LIVE env (what is running), and emit
# partner_edge_sfu_pubkey_applied{partner_id} (1=applied, 0=mismatch). A 0 is the
# epoch_apply_gap this task closes: the daily write landed but the container was
# never recreated, so the running SFU still verifies relay JWTs with a stale key.
# Skipped (no emit) when the container is not running / docker is unavailable, or
# when the live read itself fails (docker exec non-zero, e.g. container mid-startup
# right after a force-recreate), so neither a stopped SFU nor a transient exec
# failure can emit a misleading 0.
_emit_sfu_applied_gauge() {
    # $1 (default 1): whether the live compose has env_file wired for sfu. Drives
    # only the WARNING wording on a mismatch — the gauge value stays a pure
    # written-vs-live detector so an unwired node still reports the gap as 0.
    local _wired="${1:-1}"
    [[ -f "$SFU_KEYS_ENV" ]] || return 0
    local _written _live
    # Strip one layer of surrounding quotes (opec writes single-quoted; refresh
    # writes bare) so the comparison is representation-independent.
    _written=$(sed -n 's/^SFU_SIGNING_PUBLIC_KEY=//p' "$SFU_KEYS_ENV" | tail -n1)
    _written="${_written%\"}"; _written="${_written#\"}"
    _written="${_written%\'}"; _written="${_written#\'}"
    [[ -n "$_written" ]] || return 0
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$SFU_CONTAINER_NAME" || return 0
    # Read the running value via the exec's EXIT STATUS, not just its output. A
    # non-zero exit means docker exec / printenv failed (container mid-startup after
    # a force-recreate, daemon hiccup, or var unset). In every production compose
    # shape the key is injected (env_file when wired, the baked literal otherwise),
    # so a non-zero read here is a transient exec failure — skip emission rather than
    # let an empty _live compare unequal and fire a false gauge=0 + stale-key WARNING.
    if ! _live=$(docker exec "$SFU_CONTAINER_NAME" printenv SFU_SIGNING_PUBLIC_KEY 2>/dev/null); then
        log "  [sfu] could not read live SFU_SIGNING_PUBLIC_KEY from $SFU_CONTAINER_NAME (docker exec returned non-zero) — skipping applied gauge this cycle"
        return 0
    fi
    if [[ "$_written" == "$_live" ]]; then
        emit_gauge partner_edge_sfu_pubkey_applied "partner_id=\"${NODE_ID}\"" "1"
    else
        emit_gauge partner_edge_sfu_pubkey_applied "partner_id=\"${NODE_ID}\"" "0"
        if [[ "$_wired" -eq 0 ]]; then
            log "WARNING: [sfu] signing-pubkey NOT applied — live compose lacks env_file wiring for sfu-keys.env (run install.sh to re-render); running SFU verifies relay JWTs with the stale key (HS256 fallback)"
        else
            log "WARNING: [sfu] signing-pubkey applied-vs-written MISMATCH despite env_file wiring — running SFU has a stale key (relay JWTs fall back to HS256); check the last recreate"
        fi
    fi
}

# ── Phase 2: apply the refreshed SFU signing pubkey ─────────────────────────
# sfu-keys.env is rewritten above on every run, but the sfu service reads it via
# env_file, which docker compose evaluates only at container (re)creation. Mirror
# the surgical channel-restart pattern (sha-gated) but with apply_mode=recreate
# so `up -d --force-recreate sfu` actually re-reads the new key — a plain restart
# would keep the old baked env and the write would be a dead producer. `sfu` is
# the compose SERVICE name (docker compose targets services, not container_name).
# Runs on EVERY cycle (self-gated by the sha diff) and BEFORE the no-rotation
# early-exit below: the SFU key rotates independently of the Reality key version.
if [[ "$KEYS_OK" -eq 1 ]]; then
    _sfu_compose="${PREFIX_ETC}/docker-compose.yml"
    _sfu_wired=0
    if [[ -f "$_sfu_compose" ]] && _sfu_env_file_wired "$_sfu_compose"; then
        _sfu_wired=1
    fi
    if [[ ! -f "$_sfu_compose" ]]; then
        log "  [sfu] docker-compose.yml not found at $_sfu_compose — skipping SFU key apply (custom stack node)"
    elif [[ ! -f "$SFU_KEYS_ENV" ]]; then
        # Compose present but the key file was never written (opec install-time
        # fetch failed, or no /api/partner/keys response has carried a key yet).
        # Surface it — otherwise this node is invisible to both logs and the gauge.
        log "WARNING: [sfu] sfu-keys.env not found at $SFU_KEYS_ENV — SFU signing key not yet provisioned; skipping apply (opec install / a /api/partner/keys response carrying the key must write it first)"
    elif [[ "$_sfu_wired" -eq 0 ]]; then
        # Review HIGH (epoch_apply_gap reachability): upgrade.sh ships THIS refresh
        # script on every run but never re-renders the on-disk compose to add the
        # env_file stanza, so an already-deployed node can pair the new refresh with
        # an OLD compose that still bakes the key under `environment:`. A recreate
        # there drops live WebRTC media for ZERO benefit. Skip until a full re-install
        # (install.sh) renders env_file; the gauge below still reports 0 so the gap
        # stays visible and alertable.
        log "WARNING: [sfu] live docker-compose.yml has no env_file wiring for sfu-keys.env — SFU signing-key refresh cannot apply on this node; run install.sh to re-render compose. Skipping recreate to avoid dropping live media"
    else
        # ADR-9: calls the PURE mechanism directly, bypassing
        # _channel_restart_if_changed's channels-status.env gate entirely
        # (that file has no `sfu` vocabulary — see the wrapper's own header).
        _docker_restart_if_sha_changed sfu \
            "$SFU_KEYS_ENV" \
            "${PREFIX_LIB}/sfu-keys.sha" \
            "$_sfu_compose" \
            sfu \
            recreate \
            "$SFU_CONTAINER_NAME"
    fi
    _emit_sfu_applied_gauge "$_sfu_wired"
    unset _sfu_compose _sfu_wired
fi

# oxpulse-partner-edge#505: re-derive channels-status.env from live state
# BEFORE the restart gate runs. A channel marked "skipped" at install time
# that now has its inputs present + container running becomes "active", so
# _channel_restart_if_changed acts on it instead of skipping. Runs on every
# refresh (not just channels_version change) — inputs can appear via a
# node-config update without a channels_version bump.
_rederive_channels_status

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
        _channel_restart_if_changed xray \
            "${PREFIX_ETC}/xray-client.json" \
            "${PREFIX_LIB}/xray-config.sha" \
            "$_compose" \
            xray-client restart oxpulse-partner-xray
        # Naive channel (CH5) — skip when not deployed
        if [[ -f "${PREFIX_ETC}/naive-client.json" ]]; then
            _channel_restart_if_changed naive \
                "${PREFIX_ETC}/naive-client.json" \
                "${PREFIX_LIB}/naive-config.sha" \
                "$_compose" \
                naive restart oxpulse-partner-naive
        fi
        # Hysteria2 channel (CH3) — restart existing or bootstrap from node-config
        _hy2_server=$(jq -r ".hysteria2_server // empty" "$NODE_CFG" 2>/dev/null || true)
        if [[ -f "${PREFIX_ETC}/hysteria2-client.yaml" ]]; then
            _channel_restart_if_changed hysteria2 \
                "${PREFIX_ETC}/hysteria2-client.yaml" \
                "${PREFIX_LIB}/hysteria2-config.sha" \
                "$_compose" \
                hysteria2-client restart oxpulse-partner-hysteria2
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
# Custom-stack nodes (e.g. relay-x: own xray-reality + coturn + SFU compose)
# do NOT install oxpulse-partner-edge.service — skip gracefully so the
# script exits 0 and rotation is still committed to VERSION_FILE.
if systemctl list-unit-files oxpulse-partner-edge.service --no-legend 2>/dev/null \
        | grep -q oxpulse-partner-edge; then
    # epoch_apply_gap FIX (T3): re-render xray-client.json — the file the xray
    # container actually mounts — from the freshly patched node-config.json
    # BEFORE the reload/recreate. Without this the container remounts the STALE
    # pubkey and every Reality handshake fails until a manual upgrade.sh.
    #
    # Renderer seam (reuse, per spec): render_channel_soft (opec, reads reality_*
    # from node-config) with the re_render_xray fallback — the same chain the
    # channels_version block above uses.
    #
    # Path resolution — which renderer actually runs on a live edge:
    # a normally installed node carries NO on-disk *.tpl (install.sh renders from
    # an ephemeral staging dir; upgrade.sh's sbin sync list _HOST_SCRIPT_SBIN_FILES
    # ships no *.tpl — only defaults.conf + VERSION land under PREFIX_SHARE). So on
    # a running node opec render SrcMisses and the OPERATIVE renderer is
    # re_render_xray, which self-fetches the template from REPO_RAW. That fetch is
    # BOUNDED (curl --max-time 15 in channel-render-lib.sh), so the added work
    # stays well within the unit's TimeoutStartSec=120. opec only wins on a
    # checkout / reconcile node that carries a template at the canonical
    # PREFIX_SHARE location — which is why we resolve there (the way hydrate.sh and
    # reconcile.sh do), NOT ${PREFIX_SBIN} (which never holds a *.tpl). Either path
    # is gated on the on-disk OUTCOME below, never on the render's swallowed exit.
    #
    # Noted (adjacent, pre-existing — do NOT fix in this task): the
    # channels_version block above still passes the never-populated
    # ${PREFIX_SBIN}/xray-client.json.tpl path (~refresh.sh:295) and has the same
    # dead-opec / curl-fallback behavior — track as a separate follow-up.
    _rot_share="${OXPULSE_PREFIX_SHARE:-${PREFIX_SHARE:-/usr/local/share}}/oxpulse-partner-edge"
    _rot_tpl="${_rot_share}/xray-client.json.tpl"
    _rot_lib="${PREFIX_SBIN:-/usr/local/sbin}/channel-render-lib.sh"
    # shellcheck source=/dev/null
    [[ -f "$_rot_lib" ]] && source "$_rot_lib"   # provides re_render_xray fallback
    unset _rot_lib
    _rot_xray_cfg="${PREFIX_ETC}/xray-client.json"
    # shellcheck disable=SC2034  # CHANNELS_FAILED consumed by render_channel_soft internals
    CHANNELS_FAILED=()
    # Pre-render backup of the live xray-client.json. re_render_xray (the OPERATIVE
    # renderer on a normal node, per the path-resolution note above) OVERWRITES this
    # file with the rotated pubkey AND `docker compose restart xray-client`s the live
    # container (channel-render-lib.sh:206) — BEFORE the reload/verify gate below. If
    # that gate then fails and we roll back node-config.json alone, the live container
    # + xray-client.json are left on the NEW key while node-config.json (the source of
    # truth) is back on OLD — an INVERTED epoch_apply_gap, and the "keys NOT applied"
    # rollback log would be a lie. We capture our OWN deterministic backup here (not
    # re_render_xray's timestamped .bak, whose exact name we cannot predict) so the
    # rollback paths can restore both the file and the running container.
    XRAY_ROT_BACKUP=""
    if [[ -f "$_rot_xray_cfg" ]]; then
        XRAY_ROT_BACKUP="${_rot_xray_cfg}.rotbak.$$.$(date +%s)"
        cp -a "$_rot_xray_cfg" "$XRAY_ROT_BACKUP" 2>/dev/null || XRAY_ROT_BACKUP=""
    fi
    # Rollback helper — restore xray-client.json from the pre-render backup, and
    # (arg "restart") re-restart the xray container so the LIVE container matches the
    # restored OLD config, undoing re_render_xray's restart-with-the-new-key. Mirrors
    # re_render_xray's own restart command exactly (cd "$PREFIX_ETC" && docker compose
    # restart xray-client) so both renderers converge on the OLD config. Uses the
    # literal path (not $_rot_xray_cfg, which is unset on the success path before these
    # rollback sites run) and consumes XRAY_ROT_BACKUP once (single rollback per run).
    # Honest message for a rollback whose OWN restore mv failed (the "rollback of a
    # rollback" case). Repeated at all three rollback call sites — defined once.
    _ROT_ROLLBACK_INCOMPLETE_MSG="rollback INCOMPLETE — could not restore xray-client.json from backup (see partner_edge_reality_rollback_failure_total); node left in inverted state, MANUAL upgrade.sh required; new keys NOT applied"
    _rot_rollback_xray() {
        local _do_restart="${1:-}"
        local _xray="${PREFIX_ETC}/xray-client.json"
        [[ -n "${XRAY_ROT_BACKUP:-}" && -f "$XRAY_ROT_BACKUP" ]] || return 0
        # Finding 2 (MEDIUM): do NOT swallow an mv failure. A cross-device rename
        # (mount change), full disk, or perms error here leaves xray-client.json on
        # the BAD (new / half-rendered) pubkey while node-config.json is reverted to
        # OLD — an inverted epoch_apply_gap. Returning 0 (as before) let the caller
        # print "rollback complete" over a node that was NOT recovered. Emit a metric
        # + ERROR log and return non-zero so the failure is LOUD and the caller dies
        # with the honest message instead of a false success.
        if ! mv -f "$XRAY_ROT_BACKUP" "$_xray" 2>/dev/null; then
            log "ERROR: rollback FAILED to restore xray-client.json from $XRAY_ROT_BACKUP (mv failed — cross-device / disk-full / perms); xray-client.json left in BAD state"
            emit_metric "partner_edge_reality_rollback_failure_total" \
                "partner_id=\"${NODE_ID}\"" "1"
            XRAY_ROT_BACKUP=""
            return 1
        fi
        XRAY_ROT_BACKUP=""
        log "  rollback: restored xray-client.json from pre-render backup"
        if [[ "$_do_restart" == "restart" ]]; then
            ( cd "$PREFIX_ETC" && docker compose restart xray-client 2>>"$LOG_FILE" || true )
            log "  rollback: re-restarted xray container onto restored config"
        fi
        return 0
    }
    # Best-effort render, CONTAINED in a subshell. We neither trust nor propagate
    # its exit status, for TWO distinct reasons:
    #  1. Soft-fail: re_render_xray's soft paths (template fetch failure, missing
    #     node-config fields/file) warn and `return 0` WITHOUT writing a new config,
    #     and the render_channel_soft "lib not found" fallback returns that code too
    #     — so a 0 exit does NOT prove the pubkey landed.
    #  2. Hard die (Finding 1, HIGH): re_render_xray ALSO has a hard `die`
    #     (channel-render-lib.sh:196, "jq xmux strip failed — refusing to install
    #     half-stripped config") that `exit 1`s the CURRENT process. Called inline,
    #     that die would abort mid-rotation — leaving node-config.json patched to the
    #     NEW pubkey while xray-client.json stays STALE, and SKIPPING both the rollback
    #     and the VERSION_FILE-not-persisted guard below (an inverted epoch_apply_gap,
    #     the exact class this task closes). The subshell confines that exit to the
    #     subshell, so control ALWAYS reaches the on-disk OUTCOME gate below — which
    #     then drives the SAME rollback path (restore node-config.json + _rot_rollback_xray
    #     + no VERSION_FILE) as a reload failure. Atomic: node-config.json and
    #     xray-client.json both advance to the new pubkey, or NEITHER does.
    (
        render_channel_soft xray "$_rot_tpl" "$_rot_xray_cfg" 2>/dev/null \
            || { declare -f re_render_xray >/dev/null 2>&1 && re_render_xray; }
    ) || true
    unset _rot_tpl _rot_share
    # Outcome verification: the rotated pubkey MUST now be on disk in the file
    # the xray container mounts. This is the SAME comparison the applied-vs-written
    # detector performs — gating rollback on the outcome (not the render function's
    # exit code) closes the epoch_apply_gap even when the renderer swallows its
    # own failure and returns 0.
    _rot_applied_pub=$(jq -r '.outbounds[0].streamSettings.realitySettings.publicKey // empty' "$_rot_xray_cfg" 2>/dev/null || true)
    if [[ -n "$_rot_applied_pub" && "$_rot_applied_pub" == "$NEW_PUB" ]]; then
        log "xray-client.json re-rendered with rotated Reality pubkey"
    else
        # Hard-fail: mirror the reload-failure rollback. Do NOT persist the new
        # version — else tomorrow's run sees version==NEW and never retries the
        # broken render, leaving handshakes down until a manual upgrade.sh.
        log "xray re-render did NOT apply rotated pubkey (on-disk=${_rot_applied_pub:0:16}... expected=${NEW_PUB:0:16}...) — restoring $BACKUP, version NOT persisted"
        mv "$BACKUP" "$NODE_CFG"
        # Restore the file only — the render did not land the new pubkey, so on this
        # path the container was never restarted with a new key (re_render_xray's
        # restart is after its write; opec never restarts). No container restart needed.
        _rot_rollback_xray || die "$_ROT_ROLLBACK_INCOMPLETE_MSG"
        die "rollback complete; new keys NOT applied (xray render did not land new pubkey)"
    fi
    unset _rot_applied_pub _rot_xray_cfg

    log "reloading oxpulse-partner-edge.service"
    if systemctl reload oxpulse-partner-edge.service 2>>"$LOG_FILE"; then
        log "reload OK"
    else
        log "reload FAILED — restoring $BACKUP"
        mv "$BACKUP" "$NODE_CFG"
        # Render SUCCEEDED before this point (verified above), so re_render_xray has
        # already written the new pubkey to xray-client.json and restarted the live
        # container onto it. Restore the file AND re-restart so the container tracks
        # the rolled-back node-config.json — otherwise the "keys NOT applied" claim
        # below is false and the node runs an inverted epoch_apply_gap.
        _rot_rollback_xray restart || die "$_ROT_ROLLBACK_INCOMPLETE_MSG"
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
        # Same as the reload-failure path: the render already landed the new pubkey and
        # restarted the container. Restore the file AND re-restart onto the OLD config
        # so on-disk + live state agree with the rolled-back node-config.json.
        _rot_rollback_xray restart || die "$_ROT_ROLLBACK_INCOMPLETE_MSG"
        systemctl reload oxpulse-partner-edge.service 2>>"$LOG_FILE" || true
        die "rollback complete after failed verify"
    fi

    # Detector (T3 observability): applied-vs-written gauge. After the reload the
    # live xray-client.json pubkey MUST equal node-config.json's. A mismatch means
    # the container is (or will be) mounting a stale config — the epoch_apply_gap
    # class this fix closes. Gated to managed nodes (inside the systemctl branch)
    # so custom-stack nodes — which do NOT install this service and may keep an
    # xray-client.json with a different schema — never emit a spurious gauge=0.
    _det_xray="${PREFIX_ETC}/xray-client.json"
    if [[ -f "$_det_xray" ]]; then
        _live_pub=$(jq -r '.outbounds[0].streamSettings.realitySettings.publicKey // empty' "$_det_xray" 2>/dev/null || true)
        _cfg_pub=$(jq -r '.reality_public_key // empty' "$NODE_CFG" 2>/dev/null || true)
        if [[ -n "$_live_pub" && "$_live_pub" == "$_cfg_pub" ]]; then
            emit_metric "partner_edge_reality_pubkey_applied" "partner_id=\"${NODE_ID}\"" "1"
        else
            emit_metric "partner_edge_reality_pubkey_applied" "partner_id=\"${NODE_ID}\"" "0"
            log "WARNING: reality pubkey mismatch after rotation — xray-client.json=${_live_pub:0:16}... node-config=${_cfg_pub:0:16}... (stale mount / render regression)"
        fi
        unset _live_pub _cfg_pub
    fi
    unset _det_xray
    # Rotation committed (render + reload + verify all passed) — drop the pre-render
    # xray backup so we do not accumulate .rotbak files across quarterly rotations.
    [[ -n "${XRAY_ROT_BACKUP:-}" ]] && { rm -f "$XRAY_ROT_BACKUP" 2>/dev/null || true; XRAY_ROT_BACKUP=""; }
else
    log "rotation: oxpulse-partner-edge.service not installed — skipping reload (custom stack node)"
fi

# Persist new version
echo "$NEW_VERSION" > "$VERSION_FILE"
log "OK rotation applied: pub=${NEW_PUB:0:16}... version=$NEW_VERSION"

# Belt-and-suspenders re-assert of split-routing.
# PRIMARY fix (durable, event-driven): awg-params-agent post-apply hook via
# OXPULSE_RESTART_UNIT_AFTER_APPLY fires immediately after every awg syncconf,
# regardless of time of day.  The daily refresh timer is NOT the primary trigger.
# This block is kept as a cheap safety net: upgrade lag (agent running before
# the env var was wired), or any future scenario where the primary hook is not
# configured.
#
# Timing note: epoch changes fire at any hour (operator key rotations), NOT on
# the daily refresh cadence.  The daily restart here closes a window of UP TO
# 24h when the agent hook is absent; it is not a substitute for the hook.
#
# Idempotent: split-routing script is safe to call multiple times.
# Skip gracefully on nodes where split-routing is not installed.
# timeout 60: split-routing is Type=oneshot with live awg/ip ops; cap the wait
# so a wedged netlink socket cannot block the daily refresh indefinitely.
_sr_svc="oxpulse-partner-edge-split-routing.service"
if systemctl list-unit-files "$_sr_svc" --no-legend 2>/dev/null | grep -q "$_sr_svc"; then
    log "re-asserting split-routing (daily belt-and-suspenders)"
    if timeout 60 systemctl restart "$_sr_svc" 2>>"$LOG_FILE"; then
        log "split-routing re-assert OK"
    else
        log "WARN split-routing re-assert failed (non-fatal) — check: systemctl status $_sr_svc"
    fi
else
    log "split-routing: $_sr_svc not installed — skipping re-assert"
fi
