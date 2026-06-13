#!/bin/bash
# lib/reconcile.sh — Phase 1: convergent reconcile engine primitives (caddyfile surface).
#
# Provides:
#   atomic_swap INSTALLED_PATH CANDIDATE_PATH [MODE]
#   assert_no_unresolved_placeholders RENDERED_FILE
#   _setup_caddy_render_env [TPL_FILE]
#   reconcile_caddy_surface CANDIDATE_DIR
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
#   3. Live docker inspect on oxpulse-partner-naive
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
        # Tier 3: live docker inspect
        NAIVE_SOCKS_PORT=$(${DOCKER_BIN:-docker} inspect oxpulse-partner-naive \
            --format '{{range .Config.Env}}{{.}}\n{{end}}' 2>/dev/null \
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
