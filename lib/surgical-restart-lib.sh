#!/bin/bash
# lib/surgical-restart-lib.sh — sha-diff-gated docker compose restart/recreate
# mechanism for oxpulse-partner-edge-refresh.sh (P2 of the 2026-07-08
# refresh-lib-extraction-strangler plan).
#
# Provides:
#   _docker_restart_if_sha_changed KIND CFG_FILE SHA_FILE COMPOSE_FILE \
#       CONTAINER [APPLY_MODE] [STATE_CONTAINER]
#
# Requires (ambient globals/functions read — the caller must provide them):
#   log       — orchestrator logging function (oxpulse-partner-edge-refresh.sh)
#   LOG_FILE  — path docker's stderr is appended to on apply
#
# Sourced by oxpulse-partner-edge-refresh.sh. Not executable on its own.
#
# ============================================================================
# ADR-9 (architecture council, 2026-07-08 plan): PURE mechanism, ZERO
# domain-policy knowledge — in particular, this file must never reference the
# channel-provisioning status file the caller-side gate consults (see
# oxpulse-partner-edge-refresh.sh's `_channel_restart_if_changed` wrapper for
# that file's name and semantics). Fitness function (enforced by
# tests/test_surgical_restart_lib.sh): a grep for that filename against this
# lib returns zero matches — its NAME must not even appear here in a comment,
# let alone in code.
#
# Pre-extraction, `_restart_if_changed` took an 8th `skip_channel_status` flag
# argument that bypassed that gate check EMBEDDED INSIDE the function. The
# gate file is written by the backend's channel-provisioning surface
# (xray/naive/hysteria2/…) and has no `sfu` vocabulary, so the SFU key-apply
# caller set that flag to decouple its lifecycle from a status file that was
# never designed for it — a stray `sfu=` line there must not silently
# suppress a signing-key recreate.
#
# The council flagged this as a Fowler flag-argument smell: domain policy
# leaking into what should be a pure infrastructure primitive.
# `_docker_restart_if_sha_changed` below carries NO skip flag and never reads
# (or names) that gate file.
#
# The gate now lives as a THIN CALLER-SIDE WRAPPER
# (`_channel_restart_if_changed`) in oxpulse-partner-edge-refresh.sh itself:
# channel callers (xray/naive/hysteria2) go through that wrapper; the SFU
# caller calls this pure function directly, simply OMITTING the gate check
# rather than passing a bypass flag through it.
# ============================================================================

# Guard against double-sourcing.
[[ "${_SURGICAL_RESTART_LIB_LOADED:-0}" -eq 1 ]] && return 0
_SURGICAL_RESTART_LIB_LOADED=1

# _docker_restart_if_sha_changed kind cfg_file sha_file compose_file container [apply_mode] [state_container]
#
# Restarts (or recreates) a single docker compose service only when its config
# file hash differs from the last persisted hash. Updates the sha file on
# success.
#
# apply_mode (6th arg, default "restart"):
#   restart  — `docker compose restart SVC`. Correct for BIND-MOUNTED config
#              files (xray/naive/hy2): the container re-reads the mounted file
#              on restart. `container` is the service name compose knows.
#   recreate — `docker compose up -d --no-deps --force-recreate SVC`. Required
#              for env_file consumers (sfu): env_file is injected at container
#              CREATION, so a plain `restart` keeps the OLD environment — the
#              new key would never take effect. --no-deps keeps the blast
#              radius to the one service.
#
# state_container (7th arg, default = `container`): the CONTAINER NAME to
#   verify post-apply via `docker inspect --format '{{.State.Running}}'`. Kept
#   separate from `container` because compose targets a SERVICE name (`sfu`)
#   while inspect needs the fixed container_name (`oxpulse-partner-sfu`).
#   `docker inspect`'s `{{.State.Running}}` template is evaluated by the
#   daemon and its output shape (`true`/`false`) is stable across
#   Docker/Compose versions — unlike parsing `docker compose ps --format
#   json`, whose object/array/JSONL shape has drifted between Compose
#   releases. A fragile parse here would fall back to "not running" on a
#   healthy container, never advance the sha, and re-trigger a live-media
#   `force-recreate` on every daily cycle.
#
# MAJOR 3 (pre-extraction review-fix, preserved): writes the sha only after
# verifying the container is actually running. If the container is in
# CrashLoopBackOff / restarting state, writing the sha would suppress the
# next refresh cycle from retrying — leaving the container stuck on stale
# config. Allow ~5s for Docker to transition the state post-restart.
_docker_restart_if_sha_changed() {
    local kind="$1" cfg_file="$2" sha_file="$3" compose_file="$4" container="$5"
    local apply_mode="${6:-restart}"
    local state_container="${7:-$container}"

    [[ -f "$cfg_file" ]] || return 0
    local _new_sha
    _new_sha=$(sha256sum "$cfg_file" | awk '{print $1}')
    local _old_sha
    _old_sha=$(cat "$sha_file" 2>/dev/null || printf '')
    if [[ "$_new_sha" != "$_old_sha" ]]; then
        local _apply_ok=1
        if [[ "$apply_mode" == "recreate" ]]; then
            log "  [surgical] $kind config changed — recreating $container (env_file re-read)"
            docker compose -f "$compose_file" up -d --no-deps --force-recreate "$container" \
                2>>"$LOG_FILE" || _apply_ok=0
        else
            log "  [surgical] channel $kind config changed — restarting $container"
            docker compose -f "$compose_file" restart "$container" 2>>"$LOG_FILE" || _apply_ok=0
        fi
        if [[ "$_apply_ok" -eq 1 ]]; then
            sleep 5
            local _running
            _running=$(docker inspect --format '{{.State.Running}}' "$state_container" \
                2>/dev/null || printf 'false')
            if [[ "$_running" == "true" ]]; then
                printf '%s\n' "$_new_sha" > "$sha_file"
                log "  [surgical] $container restarted OK ($state_container running)"
            else
                log "WARNING: [surgical] $state_container State.Running=$_running after restart — sha not updated, next refresh will retry"
            fi
        elif [[ "$apply_mode" == "recreate" ]]; then
            log "WARNING: [surgical] docker compose up -d --force-recreate $container failed — container may use stale config"
        else
            log "WARNING: [surgical] docker compose restart $container failed — container may use stale config"
        fi
    else
        log "  [surgical] channel $kind unchanged — no restart"
    fi
}
