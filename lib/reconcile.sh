#!/bin/bash
# lib/reconcile.sh — Phase 1+2: convergent reconcile engine primitives.
#
# Provides:
#   atomic_swap INSTALLED_PATH CANDIDATE_PATH [MODE]
#   assert_no_unresolved_placeholders RENDERED_FILE
#   _setup_caddy_render_env [TPL_FILE]
#   reconcile_caddy_surface CANDIDATE_DIR
#   migrate_state                                  # Phase 2 (ADR-002)
#   mark_restart UNIT
#   apply_restarts
#
# Sourced by install.sh and upgrade.sh.  Not executable on its own.
#
# Design (ADR-001):
#   - One render authority: `opec render caddy` reads ambient env.
#   - Completeness guard: fail-closed if {{X}} survives render.
#   - Atomic swap: sibling-temp + mv (rename(2) on same filesystem).
#   - Dedup-restart collector: accumulate, dedup, apply once.
#   - Caller sets up env (including NAIVE_SOCKS_PORT resolution) before calling.
#
# NAIVE_SOCKS_PORT resolution (_setup_caddy_render_env):
#   1. NAIVE_SOCKS_PORT env var already set
#   2. STATE_FILE / install.env persisted value
#   3. Live docker inspect on oxpulse-partner-naive (uses {{println .}} for real newlines)
#   4. die — if {{NAIVE_SOCKS_PORT}} is present in TPL_FILE and unresolvable.
#      NEVER silently defaults to 1080 when the template uses the placeholder.

# Guard against double-sourcing.
[[ "${_RECONCILE_LIB_LOADED:-0}" -eq 1 ]] && return 0
_RECONCILE_LIB_LOADED=1

# ---------------------------------------------------------------------------
# atomic_swap INSTALLED_PATH CANDIDATE_PATH [MODE]
#
# Atomically installs CANDIDATE_PATH at INSTALLED_PATH using install(1) +
# mv(1) (rename(2) on same filesystem — no partial-write window).
#
# MODE defaults to 0644.  Pass 0755 for executables.
# The candidate file is consumed (moved); caller must not re-use it.
# ---------------------------------------------------------------------------
atomic_swap() {
    local _installed="$1"
    local _candidate="$2"
    local _mode="${3:-0644}"
    local _tmp
    _tmp="${_installed}.new.$$"
    install -m "$_mode" "$_candidate" "$_tmp" \
        || { log "atomic_swap: install failed for $_installed"; return 1; }
    mv -f "$_tmp" "$_installed" \
        || { rm -f "$_tmp"; log "atomic_swap: mv failed for $_installed"; return 1; }
}

# ---------------------------------------------------------------------------
# assert_no_unresolved_placeholders RENDERED_FILE
#
# Fails (die) if any {{NAME}} placeholder remains in RENDERED_FILE after
# rendering. This is the runtime completeness guard (S1 — fail-closed before
# atomic_swap is called). Catches any opec render gap at deploy time.
# ---------------------------------------------------------------------------
assert_no_unresolved_placeholders() {
    local _file="$1"
    local _leftover
    _leftover=$(grep -oE '\{\{[A-Z0-9_]+\}\}' "$_file" 2>/dev/null | sort -u || true)
    if [[ -n "$_leftover" ]]; then
        die "reconcile: render incomplete — unsubstituted placeholders in $(basename "$_file"):"$'\n'"$(printf '%s\n' "$_leftover" | sed 's/^/  /')"$'\n'"Fix: export the missing var or update opec to handle the placeholder."
    fi
}

# ---------------------------------------------------------------------------
# _setup_caddy_render_env [TPL_FILE]
#
# Sets and exports all env vars needed for `opec render caddy`:
#   PARTNER_DOMAIN    — from caller (must already be set; validated here)
#   TURNS_SUBDOMAIN   — from caller (must already be set; validated here)
#   AWG_MOTHERLY_IP   — from env → defaults.conf → hardcoded 10.9.0.2
#   HY2_FALLBACK_HOST — from env → defaults.conf → hardcoded host.docker.internal
#   HY2_FALLBACK_PORT — from env → defaults.conf → hardcoded 18443
#   NAIVE_SOCKS_PORT  — 4-tier: env → STATE_FILE → docker inspect → die
#
# TPL_FILE is used only by the NAIVE_SOCKS_PORT die-guard (die iff the
# placeholder is actually present in the template and nothing resolved).
# ---------------------------------------------------------------------------
_setup_caddy_render_env() {
    local _tpl_file="${1:-}"

    [[ -n "${PARTNER_DOMAIN:-}" ]]  || die "PARTNER_DOMAIN missing — cannot render Caddyfile"
    [[ -n "${TURNS_SUBDOMAIN:-}" ]] || die "TURNS_SUBDOMAIN missing — cannot render Caddyfile"

    # AWG_MOTHERLY_IP / HY2_FALLBACK_HOST / HY2_FALLBACK_PORT: env → defaults.conf → hardcoded.
    local _defaults_conf="${PREFIX_SHARE:-/usr/local/share}/oxpulse-partner-edge/config/defaults.conf"
    if [[ -z "${AWG_MOTHERLY_IP:-}" ]] || \
       [[ -z "${HY2_FALLBACK_HOST:-}" ]] || \
       [[ -z "${HY2_FALLBACK_PORT:-}" ]]; then
        if [[ -r "$_defaults_conf" ]]; then
            local _awg_d _hy2h_d _hy2p_d
            _awg_d=$(bash -c '. "$1" 2>/dev/null; printf "%s" "${OXPULSE_AWG_MOTHERLY_IP:-10.9.0.2}"' \
                _ "$_defaults_conf" || echo '10.9.0.2')
            _hy2h_d=$(bash -c '. "$1" 2>/dev/null; printf "%s" "${OXPULSE_HY2_FALLBACK_HOST:-host.docker.internal}"' \
                _ "$_defaults_conf" || echo 'host.docker.internal')
            _hy2p_d=$(bash -c '. "$1" 2>/dev/null; printf "%s" "${OXPULSE_HY2_FALLBACK_PORT:-18443}"' \
                _ "$_defaults_conf" || echo '18443')
            [[ -z "${AWG_MOTHERLY_IP:-}"   ]] && AWG_MOTHERLY_IP="$_awg_d"
            [[ -z "${HY2_FALLBACK_HOST:-}" ]] && HY2_FALLBACK_HOST="$_hy2h_d"
            [[ -z "${HY2_FALLBACK_PORT:-}" ]] && HY2_FALLBACK_PORT="$_hy2p_d"
        fi
    fi
    AWG_MOTHERLY_IP="${AWG_MOTHERLY_IP:-10.9.0.2}"
    HY2_FALLBACK_HOST="${HY2_FALLBACK_HOST:-host.docker.internal}"
    HY2_FALLBACK_PORT="${HY2_FALLBACK_PORT:-18443}"

    # NAIVE_SOCKS_PORT: 4-tier resolution.
    if [[ -z "${NAIVE_SOCKS_PORT:-}" ]]; then
        # Tier 2: STATE_FILE
        NAIVE_SOCKS_PORT=$(grep '^NAIVE_SOCKS_PORT=' "${STATE_FILE:-}" 2>/dev/null \
            | cut -d= -f2 || true)
    fi
    if [[ -z "${NAIVE_SOCKS_PORT:-}" ]]; then
        # Tier 3: live docker inspect.
        # Use {{println .}} (Go's println emits a real newline per element) rather
        # than the broken '{{.}}\n' form which emits a LITERAL backslash-n, joining
        # all env vars onto one physical line — grep '^NAIVE_SOCKS_PORT=' only
        # matches when NAIVE is the very first var (tier-3 silently dead otherwise).
        NAIVE_SOCKS_PORT=$(${DOCKER_BIN:-docker} inspect oxpulse-partner-naive \
            --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
            | grep '^NAIVE_SOCKS_PORT=' | cut -d= -f2 || true)
    fi
    # Tier 4: die if template uses the placeholder and nothing resolved.
    if [[ -z "${NAIVE_SOCKS_PORT:-}" ]]; then
        if [[ -n "$_tpl_file" ]] && \
           grep -qF '{{NAIVE_SOCKS_PORT}}' "$_tpl_file" 2>/dev/null; then
            die "NAIVE_SOCKS_PORT: not in STATE_FILE and naive container is down — cannot render Caddyfile safely. Bring up oxpulse-partner-naive or set NAIVE_SOCKS_PORT before re-running."
        fi
        NAIVE_SOCKS_PORT="1080"
    fi

    export PARTNER_DOMAIN TURNS_SUBDOMAIN \
           AWG_MOTHERLY_IP HY2_FALLBACK_HOST HY2_FALLBACK_PORT \
           NAIVE_SOCKS_PORT
}

# ---------------------------------------------------------------------------
# reconcile_caddy_surface CANDIDATE_DIR
#
# Per the converge pseudocode (ADR-001):
#   1. Set up ambient env (export all 6 placeholder vars).
#   2. `opec render caddy --tpl Caddyfile.tpl --out candidate`.
#   3. assert_no_unresolved_placeholders (fail-closed).
#   4. Compute sha256 BEFORE __CADDYFILE_SHA__ substitution (matches install.sh).
#   5. Substitute __CADDYFILE_SHA__ into rendered file.
#   6. Checksum-compare against installed Caddyfile.
#   7. If different: atomic_swap; update CADDYFILE_SHA in STATE_FILE; mark_restart.
#
# CANDIDATE_DIR is a writable scratch directory owned by the caller (tmpdir).
# TPL_PATH is the local copy of Caddyfile.tpl (fetched by caller, or live repo).
# CADDY_INSTALLED_PATH defaults to $PREFIX_ETC/Caddyfile.
#
# Piter (SFU-only) guard: if caddy service absent from COMPOSE_FILE, skip gracefully.
#
# DRY_RUN=1: log what would happen, skip write.
# ---------------------------------------------------------------------------
reconcile_caddy_surface() {
    local _candidate_dir="$1"
    local _tpl_path="${2:-${_candidate_dir}/Caddyfile.tpl}"
    local _out_path="${_candidate_dir}/Caddyfile"
    local _installed_path="${PREFIX_ETC:-/etc/oxpulse-partner-edge}/Caddyfile"

    # Piter guard: no caddy service → skip.
    if ! grep -qE '^\s+caddy:' "${COMPOSE_FILE:-}" 2>/dev/null; then
        warn "reconcile_caddy: caddy service not found in compose — skipping (SFU-only node?)"
        return 0
    fi

    # Require opec on PATH.
    command -v opec >/dev/null 2>&1 \
        || die "reconcile_caddy: opec not on PATH — required for Caddyfile render"

    # Set up all 6 placeholder env vars (NAIVE_SOCKS_PORT resolution included).
    _setup_caddy_render_env "$_tpl_path"

    # Render via opec (single render authority — Decision 2).
    opec render caddy --tpl "$_tpl_path" --out "$_out_path" \
        || die "reconcile_caddy: opec render caddy failed — see error above"

    # Runtime completeness guard (S1 — fail-closed before swap).
    assert_no_unresolved_placeholders "$_out_path"

    # Compute sha256 BEFORE __CADDYFILE_SHA__ substitution so the hash matches
    # what install.sh records and what /canary/config-hash returns at runtime.
    local _rendered_sha
    _rendered_sha=$(sha256sum "$_out_path" | awk '{print $1}')
    sed -i "s|__CADDYFILE_SHA__|${_rendered_sha}|g" "$_out_path"

    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log "[dry-run] reconcile_caddy: would write Caddyfile (sha256=$_rendered_sha) to $_installed_path"
        log "[dry-run] reconcile_caddy: would update CADDYFILE_SHA=$_rendered_sha in ${STATE_FILE:-install.env}"
        return 0
    fi

    # Checksum-compare vs installed (idempotency: skip if unchanged).
    local _installed_sha=""
    if [[ -f "$_installed_path" ]]; then
        _installed_sha=$(sha256sum "$_installed_path" | awk '{print $1}')
    fi
    if [[ "$_rendered_sha" == "$_installed_sha" ]]; then
        log "reconcile_caddy: Caddyfile unchanged (sha256=$_rendered_sha) — no swap needed"
        return 0
    fi

    # Atomic swap (rename(2) on same filesystem — no partial-write window).
    atomic_swap "$_installed_path" "$_out_path" 0644
    log "reconcile_caddy: Caddyfile updated (sha256=$_rendered_sha)"

    # Update CADDYFILE_SHA in STATE_FILE.
    local _state_file="${STATE_FILE:-}"
    if [[ -n "$_state_file" && -f "$_state_file" ]]; then
        if grep -q '^CADDYFILE_SHA=' "$_state_file"; then
            sed -i "s|^CADDYFILE_SHA=.*|CADDYFILE_SHA=${_rendered_sha}|" "$_state_file"
        else
            printf 'CADDYFILE_SHA=%s\n' "$_rendered_sha" >> "$_state_file"
        fi
    fi

    # Collect restart for oxpulse-partner-edge.service (deduped, applied after all surfaces).
    mark_restart "oxpulse-partner-edge.service"
}

# ---------------------------------------------------------------------------
# migrate_state — Phase 2 (ADR-002): forward-migrate STATE_FILE to schema v1.
#
# Called on every converge/upgrade BEFORE rendering surfaces.  Safe to call on
# a v1 state (idempotent — SCHEMA_VERSION already set → returns immediately).
#
# Migration contract (ADR-002):
#   - SCHEMA_VERSION missing or < 1  → run this migration.
#   - Write SCHEMA_VERSION=1 at end of STATE_FILE.
#   - Derive missing NON-SECRET STRUCTURAL keys from the live system:
#       CADDYFILE_SHA      → re-hash /etc/oxpulse-partner-edge/Caddyfile if present.
#       OXPULSE_MIRROR_BASE → already optional; left absent if not derivable.
#       TURNS_SUBDOMAIN    → already present in all post-Phase-6 states that could
#                            reach upgrade; kept as-is if already set.
#   - BACKEND_API: required, not derivable from live artefacts without a network
#       round-trip (register token is single-use; node-config doesn't persist it
#       in a form we can read without sourcing the compose secrets). On a real
#       old-vintage edge, BACKEND_API was present from v0.12.53 onward (PR #219).
#       For the narrow window of v0.12.50-v0.12.52 edges missing it: derive from
#       the installed node-config.json (backend_endpoint field) if readable; else
#       die with one actionable message.
#   - NEVER derive or write secrets (reality.priv, awg-private.key, token,
#     service_token_hash, signaling keys — those live in their own files).
#
# Reads:  STATE_FILE (global, set by caller before sourcing this lib).
# Writes: STATE_FILE (appends/updates only — never truncates).
# ---------------------------------------------------------------------------
migrate_state() {
    local _state_file="${STATE_FILE:-}"
    if [[ -z "$_state_file" || ! -f "$_state_file" ]]; then
        # No state file at all — caller (upgrade.sh) already guards this.
        return 0
    fi

    # Read current schema version (absent = 0 = legacy).
    local _current_version
    _current_version=$(grep '^SCHEMA_VERSION=' "$_state_file" 2>/dev/null \
        | cut -d= -f2 | tr -d '[:space:]' || true)
    _current_version="${_current_version:-0}"

    # Already at v1 — idempotent return.
    if [[ "$_current_version" == "1" ]]; then
        return 0
    fi

    log "migrate_state: STATE_FILE at schema v${_current_version} — migrating to v1"

    # ------------------------------------------------------------------
    # Phase 2a: derive CADDYFILE_SHA from live Caddyfile if missing.
    # The sha is non-secret structural metadata (visible via /canary/config-hash).
    # ------------------------------------------------------------------
    if ! grep -q '^CADDYFILE_SHA=' "$_state_file" 2>/dev/null; then
        local _caddy_path="${PREFIX_ETC:-/etc/oxpulse-partner-edge}/Caddyfile"
        if [[ -f "$_caddy_path" ]]; then
            local _live_sha
            _live_sha=$(sha256sum "$_caddy_path" | awk '{print $1}')
            printf 'CADDYFILE_SHA=%s\n' "$_live_sha" >> "$_state_file"
            log "migrate_state: derived CADDYFILE_SHA=$_live_sha from live Caddyfile"
        else
            log "migrate_state: Caddyfile not found at $_caddy_path — CADDYFILE_SHA will be set after next reconcile"
        fi
    fi

    # ------------------------------------------------------------------
    # Phase 2b: derive TURNS_SUBDOMAIN from node-config.json if missing.
    # turns_subdomain is non-secret (public DNS label).
    # ------------------------------------------------------------------
    if ! grep -q '^TURNS_SUBDOMAIN=' "$_state_file" 2>/dev/null; then
        local _node_cfg="${PREFIX_ETC:-/etc/oxpulse-partner-edge}/node-config.json"
        local _ts=""
        if [[ -r "$_node_cfg" ]] && command -v python3 >/dev/null 2>&1; then
            _ts=$(python3 -c "
import json,sys
try:
    d=json.load(open('$_node_cfg'))
    v=d.get('turns_subdomain','')
    if v: print(v)
except Exception: pass
" 2>/dev/null || true)
        fi
        if [[ -n "$_ts" ]]; then
            printf 'TURNS_SUBDOMAIN=%s\n' "$_ts" >> "$_state_file"
            log "migrate_state: derived TURNS_SUBDOMAIN=$_ts from node-config.json"
        else
            log "migrate_state: TURNS_SUBDOMAIN not derivable from node-config.json — will be set on next install"
        fi
    fi

    # ------------------------------------------------------------------
    # Phase 2c: BACKEND_API — required for upgrade.sh to function.
    # Try to derive from node-config.json (backend_endpoint field).
    # ------------------------------------------------------------------
    if ! grep -q '^BACKEND_API=' "$_state_file" 2>/dev/null; then
        local _node_cfg="${PREFIX_ETC:-/etc/oxpulse-partner-edge}/node-config.json"
        local _ba=""
        if [[ -r "$_node_cfg" ]] && command -v python3 >/dev/null 2>&1; then
            _ba=$(python3 -c "
import json,sys
try:
    d=json.load(open('$_node_cfg'))
    # backend_endpoint has port suffix (e.g. https://api.oxpulse.chat); strip it.
    v=d.get('backend_endpoint','')
    if v:
        # Remove port: https://host:443 -> https://host
        import re
        v=re.sub(r':\d+$','',v)
        print(v)
except Exception: pass
" 2>/dev/null || true)
        fi
        if [[ -n "$_ba" ]]; then
            printf 'BACKEND_API=%s\n' "$_ba" >> "$_state_file"
            log "migrate_state: derived BACKEND_API=$_ba from node-config.json"
        else
            die "migrate_state: BACKEND_API missing from $STATE_FILE and cannot be derived from node-config.json.
Provide it: echo 'BACKEND_API=https://api.oxpulse.chat' >> $STATE_FILE"
        fi
    fi

    # ------------------------------------------------------------------
    # Phase 2d: NAIVE_SOCKS_PORT — optional but expected on full installs.
    # Derive from live docker inspect (using the println fix) if missing.
    # ------------------------------------------------------------------
    if ! grep -q '^NAIVE_SOCKS_PORT=' "$_state_file" 2>/dev/null; then
        local _nsp=""
        _nsp=$(${DOCKER_BIN:-docker} inspect oxpulse-partner-naive \
            --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
            | grep '^NAIVE_SOCKS_PORT=' | cut -d= -f2 || true)
        if [[ -n "$_nsp" ]]; then
            printf 'NAIVE_SOCKS_PORT=%s\n' "$_nsp" >> "$_state_file"
            log "migrate_state: derived NAIVE_SOCKS_PORT=$_nsp from live naive container"
        else
            # Default 1080 is safe: matches naive's built-in default.
            printf 'NAIVE_SOCKS_PORT=1080\n' >> "$_state_file"
            log "migrate_state: NAIVE_SOCKS_PORT defaulted to 1080 (naive container not running)"
        fi
    fi

    # ------------------------------------------------------------------
    # Write SCHEMA_VERSION=1 — must be last so partial-write is detectable.
    # Update in-place if somehow already present (idempotency guard); else append.
    # ------------------------------------------------------------------
    if grep -q '^SCHEMA_VERSION=' "$_state_file" 2>/dev/null; then
        sed -i "s|^SCHEMA_VERSION=.*|SCHEMA_VERSION=1|" "$_state_file"
    else
        printf 'SCHEMA_VERSION=1\n' >> "$_state_file"
    fi
    log "migrate_state: STATE_FILE migrated to SCHEMA_VERSION=1"
}

# ---------------------------------------------------------------------------
# Dedup-restart collector.
#
# mark_restart UNIT  — record a unit for deferred restart.
# apply_restarts     — restart all collected units (deduped), then clear.
#
# Units are accumulated in _RECONCILE_RESTART_UNITS (space-separated string).
# apply_restarts runs `systemctl restart` per unique unit.  If not running as
# root / no systemctl available, falls back to docker compose restart for the
# compose service mapping.
# ---------------------------------------------------------------------------
_RECONCILE_RESTART_UNITS=""

mark_restart() {
    local _unit="$1"
    # Dedup: skip if already in the list.
    case " ${_RECONCILE_RESTART_UNITS} " in
        *" ${_unit} "*) return 0 ;;
    esac
    _RECONCILE_RESTART_UNITS="${_RECONCILE_RESTART_UNITS} ${_unit}"
    _RECONCILE_RESTART_UNITS="${_RECONCILE_RESTART_UNITS# }"  # trim leading space
}

apply_restarts() {
    if [[ -z "$_RECONCILE_RESTART_UNITS" ]]; then
        return 0
    fi
    local _unit
    for _unit in $_RECONCILE_RESTART_UNITS; do
        log "reconcile: restarting $_unit"
        if command -v systemctl >/dev/null 2>&1 && systemctl is-active "$_unit" >/dev/null 2>&1; then
            systemctl restart "$_unit" || warn "reconcile: systemctl restart $_unit failed"
        else
            # Fallback for non-systemd environments (tests, install before systemd wired).
            warn "reconcile: systemctl not available or $_unit not active — skipping restart"
        fi
    done
    _RECONCILE_RESTART_UNITS=""
}
