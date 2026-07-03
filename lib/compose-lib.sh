#!/usr/bin/env bash
# lib/compose-lib.sh — shared compose digest-diff/recreate primitives
# (Phase 3 strangler-harden, task p3).
#
# Provides:
#   compose_diff_recreate_capture_running_digests EDGE_SVCS_ARRAY_NAME MAP_NAME
#   compose_diff_recreate_resolve_pulled_digests   EDGE_SVCS_ARRAY_NAME MAP_NAME
#
# Extracted from upgrade.sh's capture_running_digests / resolve_pulled_digests
# (the "PER-CONTAINER DIGEST-SKIP — zero-downtime recreate" primitives) —
# this repo's lib/healthcheck-lib.sh (Phase 2) precedent for a call-time
# extraction. upgrade.sh keeps thin forwarders under the ORIGINAL names
# (capture_running_digests / resolve_pulled_digests, same nameref-param
# signature) so every existing call site AND structural test —
# tests/test_upgrade_pull_scope_and_rollback.sh B1a/B1b/B1d/B1f/B1g,
# tests/test_upgrade_zero_downtime.sh B1a/B1b/B2a/B2b — stays green
# unmodified. See the forwarders' own header comments in upgrade.sh.
#
# fetch_compose_config() and _parse_compose_config_images() deliberately
# STAY in upgrade.sh, NOT moved here: tests/test_upgrade_pull_scope_and_rollback.sh
# C3b asserts EXACTLY ONE raw '$DOCKER_BIN compose config' invocation exists
# in the whole of upgrade.sh (a literal scan of that file's text, not the
# runtime function table), and C3c/C4 awk-extract _parse_compose_config_images's
# body straight out of upgrade.sh to check its quote-strip content. Moving
# either function would fail those pre-existing, already-green checks in a
# file outside this task's edit scope (upgrade.sh / lib/compose-lib.sh /
# tests/test_upgrade_zero_downtime.sh only). compose_diff_recreate_resolve_pulled_digests
# below therefore calls fetch_compose_config()/_parse_compose_config_images()
# BY NAME — resolved dynamically against the sourcing script's function table
# at CALL time, not at source time. This is this repo's established
# convention, not a layering shortcut: lib/reconcile.sh's own functions
# likewise call log()/warn()/die(), which are defined by whichever script
# sources it, never redefined locally in the lib.
#
# recreate_changed_services is NOT extracted here either — it stays fully
# self-contained in upgrade.sh so tests/test_upgrade_zero_downtime.sh's
# Section B3-B5 can awk-extract just that one function into an isolated
# subshell driven with only log()/warn() stubs (no lib sourced at all) —
# see that function's own header comment in upgrade.sh.
#
# Sourced LAZILY, at call time, by the capture_running_digests /
# resolve_pulled_digests forwarders in upgrade.sh — via
# _upgrade_resolve_compose_lib / _upgrade_source_compose_lib, in the spirit
# of lib/reconcile.sh's _reconcile_resolve_healthcheck_lib for
# lib/healthcheck-lib.sh, with the SAME co-located-vs-LIB_DIR priority
# inversion (co-located with upgrade.sh wins over ${LIB_DIR:-...}: a trusted
# local dev checkout is preferred over the network-staged copy). Sourcing
# stays lazy rather than an eager `_source_lib "compose-lib.sh"` call
# alongside reconcile.sh's, so callers who never call
# capture_running_digests/resolve_pulled_digests are not forced to co-locate
# the lib at source time. This file IS, however, a `_stage_lib` target now
# (upgrade.sh's BUG1-cure block stages it — see that block's header comment):
# the delivery half of the fitness check in tests/test_install_lib_checksum.sh
# (every _stage_lib/_source_lib target must be in the release-pipeline regen
# block + lib/lib-checksums.txt — Makefile / .github/workflows/release.yml)
# is satisfied by that staging call, closing the synthetic_green gap where
# this lib was never delivered to an installed/curl|bash box — previously
# _upgrade_source_compose_lib's die() hard-aborted every such upgrade at the
# digest-diff step (same fix applied to lib/healthcheck-lib.sh and
# lib/host-scripts-lib.sh).
#
# Not executable on its own.

# Guard against double-sourcing.
[[ "${_COMPOSE_LIB_LOADED:-0}" -eq 1 ]] && return 0
_COMPOSE_LIB_LOADED=1

# ---------------------------------------------------------------------------
# compose_diff_recreate_capture_running_digests EDGE_SVCS_ARRAY_NAME MAP_NAME
#
# Snapshot the imageID (sha256:...) of every currently-running container for
# the CALLER-SUPPLIED service list (already scoped to partner-edge-* by
# upgrade.sh's resolve_edge_service_scope). Does not touch compose config at
# all — only queries running containers by name.
#
# Usage:
#   declare -A before_digests
#   capture_running_digests _edge_svcs before_digests   # via upgrade.sh forwarder
#
# Each key is the compose service name; value is the running imageID or ""
# if the container is absent / not running (first-pull or stopped).
# ---------------------------------------------------------------------------
compose_diff_recreate_capture_running_digests() {
    # Nameref locals here are DELIBERATELY named differently from the
    # upgrade.sh forwarder's own _crd_svcs/_crd_map locals (which pass their
    # names straight through as $1/$2): reusing the identical name on both
    # sides of the call makes bash treat it as a self-referential ("circular
    # name reference") nameref — it silently resolves empty instead of
    # erroring, which broke resolve_pulled_digests/capture_running_digests
    # data flow end-to-end (caught by tests/test_upgrade_syncs_host_scripts.sh
    # 10a-10c during this extraction).
    local -n _dcap_svcs="$1"
    local -n _dcap_map="$2"
    local svc container_name image_id
    for svc in "${_dcap_svcs[@]}"; do
        # docker compose ps --quiet returns container IDs for the service.
        container_name=$(cd "$PREFIX_ETC" && $DOCKER_BIN compose ps --quiet "$svc" 2>/dev/null | head -1 || true)
        if [[ -n "$container_name" ]]; then
            image_id=$($DOCKER_BIN inspect --format '{{.Image}}' "$container_name" 2>/dev/null || true)
        else
            image_id=""
        fi
        _dcap_map["$svc"]="$image_id"
    done
}

# ---------------------------------------------------------------------------
# compose_diff_recreate_resolve_pulled_digests EDGE_SVCS_ARRAY_NAME MAP_NAME
#
# After compose pull, resolve the imageID for the currently configured image
# of each CALLER-SUPPLIED service (partner-edge-* only). Fetches ONE fresh
# `docker compose config` via upgrade.sh's fetch_compose_config — the file's
# tags changed since the early-guard snapshot, so a fresh read is
# structurally unavoidable here — and parses ALL images in a single pass via
# upgrade.sh's _parse_compose_config_images.
#
# Fail-safe: if an individual service's image digest cannot be resolved,
# stores "" which causes the caller to fall back to recreating that service.
# Because the service list itself is already scoped to ours, this fail-safe
# can no longer recreate a foreign service.
#
# Returns 1 if the fresh compose-config fetch itself fails. The caller is a
# POST-MUTATION call site (compose + host-scripts are already rewritten by
# the time this runs) — it MUST restore host-scripts + compose/state before
# dying, mirroring the pull-failure branch, not just die outright.
# ---------------------------------------------------------------------------
compose_diff_recreate_resolve_pulled_digests() {
    # See compose_diff_recreate_capture_running_digests above for why these
    # nameref locals are named _dres_* rather than reusing the upgrade.sh
    # forwarder's _rpd_svcs/_rpd_map (identical names on both sides of the
    # call create a circular nameref that silently resolves empty).
    local -n _dres_svcs="$1"
    local -n _dres_map="$2"
    local _cfg
    if ! _cfg=$(fetch_compose_config); then
        printf '%s\n' "$_cfg" >&2
        return 1
    fi
    local -A _images
    _parse_compose_config_images "$_cfg" _images
    local svc image_ref image_id
    for svc in "${_dres_svcs[@]}"; do
        image_ref="${_images[$svc]:-}"
        if [[ -n "$image_ref" ]]; then
            image_id=$($DOCKER_BIN inspect --format '{{.Id}}' "$image_ref" 2>/dev/null || true)
        else
            image_id=""
        fi
        _dres_map["$svc"]="$image_id"
    done
    return 0
}
