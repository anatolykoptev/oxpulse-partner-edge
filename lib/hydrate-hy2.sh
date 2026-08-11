#!/usr/bin/env bash
# lib/hydrate-hy2.sh — hy2 channel render for hydrate.sh first-boot.
#
# Extracted from hydrate.sh's inline hy2 block so the render path is
# behaviourally testable (tests/test_hydrate_hy2_render.sh sources this
# file and exercises the real re_render_hysteria2 + compose_strip path).
#
# Sources nothing; caller must already provide:
#   channel-render-lib.sh  (re_render_hysteria2, _esc, log/warn)
#   render-channel-lib.sh  (CHANNELS_FAILED, compose_strip_failed_channels)
#   oxpulse-token-lib.sh   (read_service_token) — optional, for API fetch
#
# Globals read:  HYSTERIA2_SERVER, BACKEND_URL, TPL_DIR,
#                HY2_AUTH_PASS, HY2_OBFS_PASS (env override),
#                OXPULSE_HY2_AUTH_PASS, OXPULSE_HY2_OBFS_PASS (env fallback),
#                OXPULSE_SERVICE_TOKEN (env fallback for service token)
# Globals set:   HY2_AUTH_PASS, HY2_OBFS_PASS (from API response or env)
# Globals mutated: CHANNELS_FAILED (appended on failure)
#
# No shebang execution — this file is only ever sourced, never run directly.

# hydrate_render_hy2 — render the hysteria2 channel on first boot.
#
# The register response does NOT carry hy2 channel credentials. The backend's
# RegistrationOk (crates/server/src/partner_registry/types.rs) has a
# hysteria2_server field (the endpoint) but no hysteria2_auth or hysteria2_obfs
# — those names are read by hydrate.sh:188-189 but are always empty. The actual
# channel credentials (auth_pass / obfs_pass) are fleet-shared and come from
# GET /api/partner/hy2-credentials, the same authenticated endpoint install.sh
# uses (install.sh:1410-1415). This function fetches them the same way, with an
# env fallback for offline hydrate / pre-API-deploy.
#
# On render failure the channel is appended to CHANNELS_FAILED so
# compose_strip_failed_channels removes the hysteria2 service block from
# docker-compose.yml — without this, the service survives with a bind mount
# pointing at a file that does not exist, and docker mounts an empty directory
# as config.yaml (the compose-strip gap the prior inline block had).
hydrate_render_hy2() {
    [[ -n "${HYSTERIA2_SERVER:-}" ]] || return 0

    # Fetch hy2 credentials if not already provided by env.
    if [[ -z "${HY2_AUTH_PASS:-}" || -z "${HY2_OBFS_PASS:-}" ]]; then
        _hrh_url="${BACKEND_URL%/}/api/partner/hy2-credentials"
        _hrh_token=""
        if command -v read_service_token >/dev/null 2>&1; then
            _hrh_token=$(read_service_token 2>/dev/null || echo '')
        elif [[ -n "${OXPULSE_SERVICE_TOKEN:-}" ]]; then
            _hrh_token="$OXPULSE_SERVICE_TOKEN"
        fi
        if [[ -n "$_hrh_token" ]]; then
            _hrh_json=$(curl -fsS --max-time 10 \
                -H "Authorization: Bearer $_hrh_token" \
                "$_hrh_url" 2>/dev/null || echo '{}')
            HY2_AUTH_PASS=$(printf '%s' "$_hrh_json" | jq -r '.auth_pass // empty' 2>/dev/null || true)
            HY2_OBFS_PASS=$(printf '%s' "$_hrh_json" | jq -r '.obfs_pass // empty' 2>/dev/null || true)
        fi
        unset _hrh_url _hrh_token _hrh_json
        # Fallback: env vars (for offline hydrate / pre-API-deploy).
        HY2_AUTH_PASS="${HY2_AUTH_PASS:-${OXPULSE_HY2_AUTH_PASS:-}}"
        HY2_OBFS_PASS="${HY2_OBFS_PASS:-${OXPULSE_HY2_OBFS_PASS:-}}"
    fi

    export HY2_AUTH_PASS HY2_OBFS_PASS
    export OXPULSE_REPO_DIR="${OXPULSE_REPO_DIR:-$TPL_DIR}"

    if re_render_hysteria2; then
        log "  hysteria2-client.yaml rendered"
        return 0
    else
        warn "  hysteria2-client.yaml render failed — continuing without hy2 channel"
        # Append the docker-compose SERVICE name (hysteria2-client), not the
        # channel kind (hysteria2) — compose_strip_failed_channels pops by
        # exact service name, so the name must match the key in
        # docker-compose.yml's services: block.  Without this, the service
        # survives with a bind mount pointing at a file that does not exist,
        # and docker mounts an empty directory as config.yaml.
        CHANNELS_FAILED+=("hysteria2-client")
        return 1
    fi
}
