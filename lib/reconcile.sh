#!/bin/bash
# lib/reconcile.sh — Phases 1-4a: convergent reconcile engine.
#
# Provides:
#   atomic_swap INSTALLED_PATH CANDIDATE_PATH [MODE]
#   assert_no_unresolved_placeholders RENDERED_FILE
#   _setup_caddy_render_env [TPL_FILE]
#   reconcile_caddy_surface CANDIDATE_DIR           # Phase 1 (ADR-001)
#   migrate_state                                   # Phase 2 (ADR-002)
#   mark_restart UNIT                               # Phase 1 collector
#   apply_restarts                                  # Phase 1 collector (wired P4a)
#   mark_caddy_reload                               # Phase 4a: targeted caddy reload flag
#   apply_caddy_reloads                             # Phase 4a: hot-reload caddy (no peer down)
#   health_snapshot HEALTHCHECK_BIN SNAPSHOT_FILE   # Phase 3 (Decision 4)
#   health_regressions BASELINE_FILE POST_FILE      # Phase 3 (Decision 4)
#   _MANIFEST_PARSER_B64 (constant)                 # Phase 4a (ADR-003)
#   manifest_surfaces MANIFEST_PATH                 # Phase 4a manifest reader
#   manifest_field SURFACE_RECORD FIELD_INDEX       # Phase 4a field accessor
#   reconcile_all [MANIFEST_PATH]                   # Phase 4a engine entry point
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
# Fails (die) if any {{...}} placeholder remains in RENDERED_FILE after
# rendering (any inner chars — not only [A-Z0-9_] — so lowercase/hyphenated
# placeholders are caught too). This is the runtime completeness guard (S1 —
# fail-closed before atomic_swap is called). Catches any opec render gap at
# deploy time.
# ---------------------------------------------------------------------------
assert_no_unresolved_placeholders() {
    local _file="$1"
    local _leftover
    _leftover=$(grep -oE '\{\{[^}]+\}\}' "$_file" 2>/dev/null | sort -u || true)
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
#   4. Compute sha256 BEFORE __CADDYFILE_SHA__ substitution (pre-sub hash).
#   5. Compare pre-sub hash vs STATE CADDYFILE_SHA (last-installed pre-sub hash).
#   6. If equal: no-op (S2 idempotency).
#   7. If different: substitute sha into candidate, atomic_swap, update STATE, mark_caddy_reload.
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

    # Compute sha256 BEFORE __CADDYFILE_SHA__ substitution.
    # This pre-substitution hash is what install.sh records in STATE (CADDYFILE_SHA)
    # and what /canary/config-hash returns at runtime.
    #
    # Change-detection (BLOCKER-1 fix, ADR-003 sha_key):
    #   Compare the NEW candidate's pre-sub hash against the LAST-INSTALLED pre-sub
    #   hash stored in STATE_FILE key CADDYFILE_SHA.  Both sides are pre-substitution,
    #   so a no-change render yields equal hashes: no swap, no reload (S2 idempotency).
    #   The prior approach compared pre-sub vs post-sub-on-disk: always unequal when
    #   __CADDYFILE_SHA__ is in the template, causing atomic_swap every run.
    local _rendered_sha
    _rendered_sha=$(sha256sum "$_out_path" | awk '{print $1}')

    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log "[dry-run] reconcile_caddy: would write Caddyfile (sha256=$_rendered_sha) to $_installed_path"
        log "[dry-run] reconcile_caddy: would update CADDYFILE_SHA=$_rendered_sha in ${STATE_FILE:-install.env}"
        return 0
    fi

    # Read the STATE-recorded pre-sub hash of the last successful install.
    local _state_sha=""
    local _state_file="${STATE_FILE:-}"
    if [[ -n "$_state_file" && -f "$_state_file" ]]; then
        _state_sha=$(grep '^CADDYFILE_SHA=' "$_state_file" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]' || true)
    fi

    # If hashes match — same template + same env vars — no-op (S2 idempotency).
    if [[ -n "$_state_sha" && "$_rendered_sha" == "$_state_sha" ]]; then
        log "reconcile_caddy: Caddyfile unchanged (sha256=$_rendered_sha matches STATE CADDYFILE_SHA) — no swap needed"
        return 0
    fi

    # Hashes differ (or first install with no STATE sha): perform the update.
    # Substitute the self-referential config-hash into the rendered file NOW
    # (after change-detection so the substituted value does not affect comparison).
    sed -i "s|__CADDYFILE_SHA__|${_rendered_sha}|g" "$_out_path"

    # Atomic swap (rename(2) on same filesystem — no partial-write window).
    atomic_swap "$_installed_path" "$_out_path" 0644
    log "reconcile_caddy: Caddyfile updated (sha256=$_rendered_sha)"

    # Persist the new pre-sub hash to STATE so the next run is idempotent.
    if [[ -n "$_state_file" && -f "$_state_file" ]]; then
        if grep -q '^CADDYFILE_SHA=' "$_state_file"; then
            sed -i "s|^CADDYFILE_SHA=.*|CADDYFILE_SHA=${_rendered_sha}|" "$_state_file"
        else
            printf 'CADDYFILE_SHA=%s\n' "$_rendered_sha" >> "$_state_file"
        fi
    fi

    # Collect caddy reload (targeted — does NOT restart peer containers).
    # apply_caddy_reloads (called from reconcile_all) hot-reloads caddy in-place.
    mark_caddy_reload
}

# ---------------------------------------------------------------------------
# migrate_state — Phase 2 (ADR-002): forward-migrate STATE_FILE to schema v1.
#
# Called by upgrade.sh immediately after sourcing STATE_FILE.  The future
# converge entrypoint (Phase 4) will also call it.  Safe to call on a v1 state
# (idempotent — SCHEMA_VERSION already set → returns immediately).
#
# Migration contract (ADR-002):
#   - SCHEMA_VERSION missing or < 1  → run this migration.
#   - Write SCHEMA_VERSION=1 at end of STATE_FILE.
#   - Derive missing NON-SECRET STRUCTURAL keys from the live system:
#       CADDYFILE_SHA      → re-hash /etc/oxpulse-partner-edge/Caddyfile if present.
#       OXPULSE_MIRROR_BASE → optional; absent on non-mirror installs is correct.
#                            Not derived here — left absent if missing.
#       TURNS_SUBDOMAIN    → turns_subdomain field in node-config.json.
#   - BACKEND_API: fleet constant = https://api.oxpulse.chat (install.sh:58).
#       NOT derived from node-config backend_endpoint (that is the scheme-less
#       host:port TURN/SFU endpoint, e.g. krolik.oxpulse.chat:5349 — completely
#       different field).  If missing from state, default to the fleet constant.
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
            # Derive the PRE-substitution hash to match reconcile_caddy_surface's
            # comparison basis. The live on-disk Caddyfile has __CADDYFILE_SHA__
            # already substituted with the real hex SHA. reconcile hashes the rendered
            # candidate BEFORE that substitution (pre-sub hash) and install.sh records
            # that same pre-sub hash in STATE. If we hash the post-sub file directly,
            # the recorded hash will never equal reconcile's pre-sub candidate hash —
            # causing one spurious extra swap+reload on the first post-migration run.
            #
            # Reverse the substitution: replace any 64-char hex value inside
            # respond "..." back to the __CADDYFILE_SHA__ placeholder, then hash.
            # This produces the pre-sub hash that reconcile would compute for the same
            # Caddyfile content, so the first --with-templates run after migration
            # detects "unchanged" and produces zero swaps (Fix 2 invariant).
            local _live_sha
            _live_sha=$(sed 's/respond "[0-9a-f]\{64\}"/respond "__CADDYFILE_SHA__"/g' "$_caddy_path" \
                | sha256sum | awk '{print $1}')
            printf 'CADDYFILE_SHA=%s\n' "$_live_sha" >> "$_state_file"
            log "migrate_state: derived CADDYFILE_SHA=$_live_sha from live Caddyfile (pre-sub normalised)"
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
    # Phase 2c: BACKEND_API — fleet constant, NOT derived from node-config.
    #
    # IMPORTANT: node-config.json's backend_endpoint is the scheme-less
    # host:port TURN/SFU endpoint (e.g. krolik.oxpulse.chat:5349 or
    # api.oxpulse.chat:443).  It is NOT the registration API base URL.
    # Stripping the port from that field produces a wrong, scheme-less
    # value (e.g. "krolik.oxpulse.chat") — not a valid BACKEND_API.
    #
    # BACKEND_API is a fleet constant: every production edge uses
    # https://api.oxpulse.chat (mirrors are handled via OXPULSE_MIRROR_BASE,
    # not via a different BACKEND_API value).  Matches install.sh:58 default.
    if ! grep -q '^BACKEND_API=' "$_state_file" 2>/dev/null; then
        # Default to the install.sh:58 fleet constant.  Every production edge uses
        # this value; mirrored installs use OXPULSE_MIRROR_BASE separately —
        # BACKEND_API stays api.oxpulse.chat regardless.
        local _ba="https://api.oxpulse.chat"
        printf 'BACKEND_API=%s\n' "$_ba" >> "$_state_file"
        log "migrate_state: BACKEND_API defaulted to fleet constant $_ba (not derived from node-config backend_endpoint)"
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
# mark_restart UNIT  — record a systemd unit for deferred restart.
# apply_restarts     — restart all collected units (deduped), then clear.
#
# Units are accumulated in _RECONCILE_RESTART_UNITS (space-separated string).
# apply_restarts runs `systemctl restart` per unique unit.  If not running as
# root / no systemctl available, logs a warning (no-op in test environments).
#
# Caddy-specific reload (MAJOR-1 fix, targeted blast radius):
#   mark_caddy_reload   — set deduped flag indicating caddy needs reloading.
#   apply_caddy_reloads — hot-reload caddy via admin API (no peer containers down).
#                          Falls back to force-recreate caddy only if hot-reload fails.
#                          SFU/coturn/xray/naive are NEVER touched by a caddy change.
# ---------------------------------------------------------------------------
_RECONCILE_RESTART_UNITS=""
_RECONCILE_CADDY_RELOAD=0

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

mark_caddy_reload() {
    _RECONCILE_CADDY_RELOAD=1
}

# apply_caddy_reloads — hot-reload caddy via admin API; no peer containers down.
#
# Caddy's global block configures `admin localhost:2019`.  The reload command
# sends the new config over the admin socket — zero connection drops to peers.
# If the admin API is unavailable (e.g. caddy not running), falls back to
# `docker compose up -d --force-recreate caddy` which recreates ONLY caddy.
# Both paths leave SFU, coturn, xray, and naive containers untouched.
apply_caddy_reloads() {
    if [[ "${_RECONCILE_CADDY_RELOAD:-0}" -ne 1 ]]; then
        return 0
    fi
    _RECONCILE_CADDY_RELOAD=0

    local _compose_file="${COMPOSE_FILE:-${PREFIX_ETC:-/etc/oxpulse-partner-edge}/docker-compose.yml}"
    local _docker="${DOCKER_BIN:-docker}"

    log "reconcile: caddy hot-reload via admin API (peers untouched)"
    # -T: non-TTY exec (required in scripts; safe with admin API).
    if "$_docker" compose -f "$_compose_file" exec -T caddy \
            caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile 2>/dev/null; then
        log "reconcile: caddy reload successful (SFU/coturn/xray/naive untouched)"
        return 0
    fi

    warn "reconcile: caddy admin reload failed — falling back to force-recreate caddy only"
    # Recreate ONLY caddy. `--force-recreate caddy` with an explicit service name
    # does not recreate sibling services in the compose project.
    if "$_docker" compose -f "$_compose_file" up -d --force-recreate caddy 2>/dev/null; then
        log "reconcile: caddy container recreated (peers untouched)"
        return 0
    fi

    warn "reconcile: caddy force-recreate also failed — check: $_docker compose -f $_compose_file logs caddy"
    # Both reload paths failed: the new Caddyfile is NOT live.
    # Return non-zero so reconcile_all (and callers like upgrade.sh) see a hard error
    # rather than a silent rc=0 while caddy continues serving the stale config.
    return 1
}

# ---------------------------------------------------------------------------
# Phase 3 — Baseline-aware health gate (Decision 4).
#
# health_snapshot HEALTHCHECK_BIN SNAPSHOT_FILE
#
# Runs HEALTHCHECK_BIN with --snapshot and writes the output to SNAPSHOT_FILE.
# Returns 0 on success, 1 if healthcheck bin is not executable or snapshot
# fails to write.
#
# The snapshot format (defined by healthcheck.sh --snapshot):
#   check_01_containers=GREEN
#   check_02_api=RED
#   ...
# One line per check, deterministic identifier, no ANSI codes.
# ---------------------------------------------------------------------------
health_snapshot() {
    local _hc_bin="$1"
    local _snap_file="$2"

    if [[ ! -x "$_hc_bin" ]]; then
        warn "health_snapshot: healthcheck binary not executable: $_hc_bin"
        return 1
    fi

    # Run --snapshot and KEEP the output regardless of the process exit code.
    # A healthcheck whose --snapshot emits valid per-check lines but exits
    # non-zero when a check is RED (an older deployed healthcheck, or the
    # exit 1/exit 2 edge paths in healthcheck.sh) still produced a usable
    # snapshot. The authoritative "did we get a snapshot" signal is the OUTPUT
    # CONTENT (validated below), NOT the exit code — gating on the exit code
    # treats a valid-but-red baseline as a failed/empty capture, which cascades
    # into a FALSE rollback via the caller's absolute-gate fallback (BUG3).
    "$_hc_bin" --snapshot > "$_snap_file" 2>/dev/null || true

    # Content gate: a legacy binary with no --snapshot support writes nothing to
    # stdout (its error goes to stderr) → empty file → genuinely no snapshot.
    if [[ ! -s "$_snap_file" ]]; then
        warn "health_snapshot: snapshot file is empty after run: $_snap_file"
        return 1
    fi
    # Require at least one parseable name=GREEN|RED line so a legacy binary that
    # prints a non-snapshot blob to stdout is still classified as "no snapshot".
    if ! grep -qE '^[A-Za-z0-9_]+=GREEN$|^[A-Za-z0-9_]+=RED$' "$_snap_file" 2>/dev/null; then
        warn "health_snapshot: no parseable name=GREEN|RED lines in snapshot: $_snap_file"
        return 1
    fi

    log "health_snapshot: captured $(wc -l < "$_snap_file") check(s) to $( basename "$_snap_file")"
    return 0
}

# ---------------------------------------------------------------------------
# health_regressions BASELINE_FILE POST_FILE
#
# Compares two snapshot files and detects regressions: checks that were GREEN
# in BASELINE_FILE and are RED in POST_FILE.
#
# Returns:
#   0  — no regressions (gate passes; pre-existing reds are NOT counted)
#   1  — at least one regression found (gate triggers rollback)
#
# Special cases:
#   - BASELINE_FILE absent or empty: fresh-install path → return 0 (skip diff).
#   - A check present in baseline but absent in post: treated as no-regression
#     (check may have been removed; conservative — don't false-positive).
#   - A check GREEN in baseline, RED in post: regression → return 1 + log names.
#   - A check RED in baseline, RED in post: pre-existing drift → logged as DRIFT.
#   - A check RED in baseline, GREEN in post: healed → no regression.
# ---------------------------------------------------------------------------
health_regressions() {
    local _baseline="$1"
    local _post="$2"

    # Fresh install: no baseline → skip diff entirely.
    if [[ ! -f "$_baseline" || ! -s "$_baseline" ]]; then
        log "health_regressions: no baseline snapshot (fresh install) — skipping diff"
        return 0
    fi

    local _regression_count=0
    local _drift_count=0
    local _healed_count=0

    # For each check in baseline, look it up in post and classify.
    while IFS='=' read -r _check_id _baseline_status || [[ -n "$_check_id" ]]; do
        [[ -z "$_check_id" ]] && continue
        # Skip malformed lines (must match name=GREEN or name=RED).
        [[ "$_baseline_status" != "GREEN" && "$_baseline_status" != "RED" ]] && continue

        # Look up same check in post snapshot.
        _post_status=$(grep "^${_check_id}=" "$_post" 2>/dev/null \
            | head -1 | cut -d= -f2 || true)

        if [[ -z "$_post_status" ]]; then
            # Check absent from post: conservative — treat as no-regression.
            continue
        fi

        if [[ "$_baseline_status" == "GREEN" && "$_post_status" == "RED" ]]; then
            log "health_regressions: REGRESSION — ${_check_id} was GREEN, now RED"
            _regression_count=$((_regression_count + 1))
        elif [[ "$_baseline_status" == "RED" && "$_post_status" == "RED" ]]; then
            log "health_regressions: DRIFT (pre-existing) — ${_check_id} RED in both baseline and post"
            _drift_count=$((_drift_count + 1))
        elif [[ "$_baseline_status" == "RED" && "$_post_status" == "GREEN" ]]; then
            log "health_regressions: HEALED — ${_check_id} was RED, now GREEN"
            _healed_count=$((_healed_count + 1))
        fi
        # GREEN→GREEN: no action needed.
    done < "$_baseline"

    if [[ "$_regression_count" -gt 0 ]]; then
        warn "health_regressions: ${_regression_count} regression(s) detected — rollback required"
        [[ "$_drift_count" -gt 0 ]] && \
            log "health_regressions: ${_drift_count} pre-existing red(s) (drift — not blocking)"
        [[ "$_healed_count" -gt 0 ]] && \
            log "health_regressions: ${_healed_count} healed check(s)"
        return 1
    fi

    [[ "$_drift_count" -gt 0 ]] && \
        warn "health_regressions: ${_drift_count} pre-existing red(s) (drift findings — not blocking upgrade)"
    [[ "$_healed_count" -gt 0 ]] && \
        log "health_regressions: ${_healed_count} healed check(s) — improvement"
    log "health_regressions: no regressions detected"
    return 0
}
# ---------------------------------------------------------------------------
# Phase 4a - Manifest reader.
#
# manifest_surfaces MANIFEST_PATH
#
# Reads manifest.yaml and emits one line per surface, tab-separated:
#   id<TAB>kind<TAB>wired<TAB>template<TAB>out<TAB>renderer<TAB>restart_unit<TAB>sha_key<TAB>placeholder_completeness<TAB>fail_soft<TAB>restart_signal<TAB>restart_unit_compose_service
# Phase 4b: added fail_soft(10), restart_signal(11), restart_unit_compose_service(12).
# field() moved outside loop (cosmetic fix — was redefined per-iteration; no runtime change).
#
# wired is "true" unless surface block contains "wired: false".
# Uses python3 (de-facto dep, used 9x in channel-render-lib.sh); awk fallback.
# The python code is stored as a base64 constant to avoid heredoc-in-sourced-
# function issues (bash heredocs read stdin at call time in sourced files).
# ---------------------------------------------------------------------------

# Base64-encoded python3 manifest parser.
_MANIFEST_PARSER_B64="aW1wb3J0IHN5cywgcmUKbWFuaWZlc3RfcGF0aCA9IHN5cy5hcmd2WzFdCnRyeToKICAgIGNvbnRlbnQgPSBvcGVuKG1hbmlmZXN0X3BhdGgpLnJlYWQoKQpleGNlcHQgRXhjZXB0aW9uOgogICAgc3lzLmV4aXQoMCkKc3VyZmFjZXNfbWF0Y2ggPSByZS5zZWFyY2gocidec3VyZmFjZXM6XHMqXG4oLio/KSg/PV5cd3xcWiknLCBjb250ZW50LCByZS5NVUxUSUxJTkUgfCByZS5ET1RBTEwpCmlmIG5vdCBzdXJmYWNlc19tYXRjaDoKICAgIHN5cy5leGl0KDApCnN1cmZhY2VzX2Jsb2NrID0gc3VyZmFjZXNfbWF0Y2guZ3JvdXAoMSkKc3VyZmFjZV9lbnRyaWVzID0gcmUuc3BsaXQocidcbig/PSAgLSBpZDopJywgc3VyZmFjZXNfYmxvY2spCgpkZWYgZmllbGQoZW50cnksIGtleSwgZGVmYXVsdD0iLSIpOgogICAgbSA9IHJlLnNlYXJjaChyJ15ccysnICsgcmUuZXNjYXBlKGtleSkgKyByJzpccyooLispJCcsIGVudHJ5LCByZS5NVUxUSUxJTkUpCiAgICBpZiBtOgogICAgICAgIHJhdyA9IG0uZ3JvdXAoMSkKICAgICAgICB2YWwgPSByZS5zdWIocidccysjLiokJywgJycsIHJhdykuc3RyaXAoKS5zdHJpcCgnIicpLnN0cmlwKCInIikKICAgICAgICByZXR1cm4gdmFsIGlmIHZhbCBlbHNlIGRlZmF1bHQKICAgIHJldHVybiBkZWZhdWx0Cgpmb3IgZW50cnkgaW4gc3VyZmFjZV9lbnRyaWVzOgogICAgZW50cnkgPSBlbnRyeS5zdHJpcCgpCiAgICBpZiBub3QgZW50cnk6CiAgICAgICAgY29udGludWUKICAgIGlkX20gPSByZS5zZWFyY2gocideLVxzK2lkOlxzKihcUyspJywgZW50cnksIHJlLk1VTFRJTElORSkKICAgIGlmIG5vdCBpZF9tOgogICAgICAgIGNvbnRpbnVlCiAgICBzaWQgPSBpZF9tLmdyb3VwKDEpLnN0cmlwKCkKICAgIGlmIG5vdCBzaWQgb3Igc2lkID09ICItIjoKICAgICAgICBjb250aW51ZQogICAga2luZCAgICAgICAgPSBmaWVsZChlbnRyeSwgImtpbmQiKQogICAgd2lyZWRfcmF3ICAgPSBmaWVsZChlbnRyeSwgIndpcmVkIiwgInRydWUiKQogICAgd2lyZWQgICAgICAgPSAiZmFsc2UiIGlmIHdpcmVkX3Jhdy5sb3dlcigpID09ICJmYWxzZSIgZWxzZSAidHJ1ZSIKICAgIHRtcGwgICAgICAgID0gZmllbGQoZW50cnksICJ0ZW1wbGF0ZSIpCiAgICBvdXQgICAgICAgICA9IGZpZWxkKGVudHJ5LCAib3V0IikKICAgIHJlbmRlcmVyICAgID0gZmllbGQoZW50cnksICJyZW5kZXJlciIpCiAgICBydSAgICAgICAgICA9IGZpZWxkKGVudHJ5LCAicmVzdGFydF91bml0IikKICAgIHNrICAgICAgICAgID0gZmllbGQoZW50cnksICJzaGFfa2V5IikKICAgIHBoICAgICAgICAgID0gZmllbGQoZW50cnksICJwbGFjZWhvbGRlcl9jb21wbGV0ZW5lc3MiLCAiZmFsc2UiKQogICAgZnMgICAgICAgICAgPSBmaWVsZChlbnRyeSwgImZhaWxfc29mdCIsICJmYWxzZSIpCiAgICByc2lnICAgICAgICA9IGZpZWxkKGVudHJ5LCAicmVzdGFydF9zaWduYWwiKQogICAgcnVjcyAgICAgICAgPSBmaWVsZChlbnRyeSwgInJlc3RhcnRfdW5pdF9jb21wb3NlX3NlcnZpY2UiKQogICAgcHJpbnQoZiJ7c2lkfVx0e2tpbmR9XHR7d2lyZWR9XHR7dG1wbH1cdHtvdXR9XHR7cmVuZGVyZXJ9XHR7cnV9XHR7c2t9XHR7cGh9XHR7ZnN9XHR7cnNpZ31cdHtydWNzfSIpCg=="

manifest_surfaces() {
    local _manifest="$1"
    if [[ ! -f "$_manifest" ]]; then
        die "manifest_surfaces: manifest not found: $_manifest"
    fi

    if command -v python3 >/dev/null 2>&1 && command -v base64 >/dev/null 2>&1; then
        local _py_tmp
        _py_tmp=$(mktemp /tmp/mfst_parse_XXXXXX.py)
        # shellcheck disable=SC2064
        trap "rm -f '$_py_tmp'" RETURN
        printf '%s' "$_MANIFEST_PARSER_B64" | base64 -d > "$_py_tmp"
        python3 "$_py_tmp" "$_manifest"
    else
        # Minimal awk fallback when python3 or base64 absent.
        awk '
        /^  - id:/ {
            if (id != "") flush()
            id=$NF; kind="-"; wired="true"; template="-"; out="-"
            renderer="-"; restart_unit="-"; sha_key="-"; ph_complete="false"
            next
        }
        id!="" && /^[a-z]/ && !/^surfaces/ { flush(); id="" }
        id!="" && /^\s+kind:/         { kind=$NF }
        id!="" && /^\s+wired:/        { if ($NF=="false") wired="false" }
        id!="" && /^\s+template:/     { template=$NF }
        id!="" && /^\s+out:/          { out=$NF }
        id!="" && /^\s+restart_unit:/ { restart_unit=$NF }
        id!="" && /^\s+sha_key:/      { sha_key=$NF }
        id!="" && /^\s+placeholder_completeness:/ { ph_complete=$NF }
        function flush() {
            printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
                id,kind,wired,template,out,renderer,restart_unit,sha_key,ph_complete
        }
        END { if (id!="") flush() }
        ' "$_manifest"
    fi
}


# ---------------------------------------------------------------------------
# manifest_field SURFACE_RECORD FIELD_INDEX
#
# Extracts a tab-separated field from a manifest_surfaces record.
# Indices (1-based):
#   1=id  2=kind  3=wired  4=template  5=out  6=renderer
#   7=restart_unit  8=sha_key  9=placeholder_completeness
# ---------------------------------------------------------------------------
manifest_field() {
    local _record="$1"
    local _idx="$2"
    echo "$_record" | cut -f"$_idx"
}

# ---------------------------------------------------------------------------
# Phase 4a - reconcile_all [MANIFEST_PATH]
#
# Manifest-driven reconcile engine (ADR-003).
#
# Iterates declared surfaces in topological order.
# Wired surfaces are reconciled; wired:false surfaces are logged and skipped.
# After all surfaces: apply_restarts() fires (P1 dead-code fix - key P4a deliverable).
#
# P4a wired:  caddyfile (render_from_state).
# P4b wires:  coturn, xray_client, compose, node_config, firewall,
#             xray_env, host_scripts, systemd_units.
#
# Caller must source STATE_FILE and call migrate_state() before this.
# RECONCILE_TMPDIR: scratch dir; auto-created if unset (cleaned on RETURN).
# DRY_RUN=1: forwarded to reconcile_caddy_surface.
# ---------------------------------------------------------------------------
reconcile_all() {
    local _manifest="${1:-}"
    if [[ -z "$_manifest" ]]; then
        local _script_dir
        _script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-}")/." || exit; cd ..; pwd)"
        _manifest="${_script_dir}/manifest.yaml"
    fi

    if [[ ! -f "$_manifest" ]]; then
        die "reconcile_all: manifest.yaml not found at $_manifest"
    fi

    log "reconcile_all: reading manifest $_manifest"

    # Local scope: RECONCILE_TMPDIR is auto-managed per-call.
    # Declaring local prevents the deleted-dir bug on repeated reconcile_all calls.
    local RECONCILE_TMPDIR="${RECONCILE_TMPDIR:-}"
    local _own_tmpdir=0
    if [[ -z "$RECONCILE_TMPDIR" ]]; then
        RECONCILE_TMPDIR=$(mktemp -d)
        _own_tmpdir=1
    fi
    # shellcheck disable=SC2064
    [[ "$_own_tmpdir" -eq 1 ]] && trap "rm -rf '${RECONCILE_TMPDIR}'" RETURN

    # Reset per-surface CHANGED flags so a second reconcile_all in the same process
    # starts from a clean slate (the flags are module-level, init once at source
    # time). The before/after delta below stays correct either way, but a stale
    # raw-flag read (1 from a prior run) would mislead any future direct reader.
    _reset_surface_flags

    local _surface_count=0 _wired_count=0 _skipped_count=0 _changed_count=0

    while IFS=$'\t' read -r _sid _kind _wired _template _out \
                              _renderer _restart_unit _sha_key _ph_complete \
                              _fail_soft _restart_signal _restart_unit_compose_service; do
        [[ -z "$_sid" ]] && continue
        _surface_count=$((_surface_count + 1))

        if [[ "$_wired" == "false" ]]; then
            log "reconcile_all: surface '$_sid' (kind=$_kind) — declared, not yet wired (Phase 4b)"
            _skipped_count=$((_skipped_count + 1))
            continue
        fi

        _wired_count=$((_wired_count + 1))
        log "reconcile_all: processing surface '$_sid' (kind=$_kind)"

        case "$_kind" in
            render_from_state)
                case "$_sid" in
                    caddyfile)
                        local _tpl_src="${RECONCILE_TMPDIR}/Caddyfile.tpl"
                        if [[ ! -f "$_tpl_src" ]]; then
                            local _repo_dir="${REPO_DIR:-}"
                            local _repo_raw="${REPO_RAW:-}"
                            if [[ -n "$_repo_dir" && -f "${_repo_dir}/Caddyfile.tpl" ]]; then
                                cp "${_repo_dir}/Caddyfile.tpl" "$_tpl_src"
                            elif [[ -n "$_repo_raw" ]]; then
                                curl -fsSL --max-time 30 \
                                    "${_repo_raw}/Caddyfile.tpl" \
                                    -o "$_tpl_src" 2>/dev/null \
                                    || die "reconcile_all: could not fetch Caddyfile.tpl from $_repo_raw"
                            else
                                die "reconcile_all: Caddyfile.tpl not available (set REPO_DIR or REPO_RAW)"
                            fi
                        fi
                        # Per-surface change flag (CC1 fix: sound multi-surface tracking).
                        # _RECONCILE_CADDY_RELOAD is a boolean flag set by reconcile_caddy_surface;
                        # dedup does not interfere (unlike _RECONCILE_RESTART_UNITS list delta).
                        local _before_caddy_reload="${_RECONCILE_CADDY_RELOAD:-0}"
                        reconcile_caddy_surface "$RECONCILE_TMPDIR" "$_tpl_src"
                        if [[ "${_RECONCILE_CADDY_RELOAD:-0}" -ne "$_before_caddy_reload" ]]; then
                            _changed_count=$((_changed_count + 1))
                        fi
                        ;;
                    coturn)
                        # Phase 4b: coturn render_from_state.
                        # Reload: SIGUSR2 → coturn reload_ssl_certs (no session drop).
                        local _tpl_coturn="${RECONCILE_TMPDIR}/coturn.conf.tpl"
                        if [[ ! -f "$_tpl_coturn" ]]; then
                            local _repo_dir_c="${REPO_DIR:-}"
                            local _repo_raw_c="${REPO_RAW:-}"
                            if [[ -n "$_repo_dir_c" && -f "${_repo_dir_c}/coturn.conf.tpl" ]]; then
                                cp "${_repo_dir_c}/coturn.conf.tpl" "$_tpl_coturn"
                            elif [[ -n "$_repo_raw_c" ]]; then
                                curl -fsSL --max-time 30 "${_repo_raw_c}/coturn.conf.tpl" \
                                    -o "$_tpl_coturn" 2>/dev/null \
                                    || die "reconcile_all: could not fetch coturn.conf.tpl from $_repo_raw_c"
                            else
                                die "reconcile_all: coturn.conf.tpl not available (set REPO_DIR or REPO_RAW)"
                            fi
                        fi
                        local _before_coturn="${_RECONCILE_COTURN_CHANGED:-0}"
                        reconcile_coturn_surface "${PREFIX_ETC:-/etc/oxpulse-partner-edge}" "$_tpl_coturn"
                        if [[ "${_RECONCILE_COTURN_CHANGED:-0}" -ne "$_before_coturn" ]]; then
                            _changed_count=$((_changed_count + 1))
                        fi
                        ;;
                    xray_client)
                        # Phase 4b: xray_client render_from_state — fail_soft (bypass channel).
                        # Reload: force-recreate xray-client ONLY (peers untouched — PI2 invariant).
                        local _tpl_xray="${RECONCILE_TMPDIR}/xray-client.json.tpl"
                        local _tpl_xray_avail=1
                        if [[ ! -f "$_tpl_xray" ]]; then
                            local _repo_dir_x="${REPO_DIR:-}"
                            local _repo_raw_x="${REPO_RAW:-}"
                            if [[ -n "$_repo_dir_x" && -f "${_repo_dir_x}/xray-client.json.tpl" ]]; then
                                cp "${_repo_dir_x}/xray-client.json.tpl" "$_tpl_xray"
                            elif [[ -n "$_repo_raw_x" ]]; then
                                curl -fsSL --max-time 30 "${_repo_raw_x}/xray-client.json.tpl" \
                                    -o "$_tpl_xray" 2>/dev/null || {
                                    warn "reconcile_all: could not fetch xray-client.json.tpl — skipping (fail_soft)"
                                    _tpl_xray_avail=0
                                }
                            else
                                warn "reconcile_all: xray-client.json.tpl not available (REPO_DIR/REPO_RAW unset) — skipping (fail_soft)"
                                _tpl_xray_avail=0
                            fi
                        fi
                        if [[ "$_tpl_xray_avail" -eq 1 ]]; then
                            local _before_xray_client="${_RECONCILE_XRAY_CLIENT_CHANGED:-0}"
                            reconcile_xray_client_surface "${PREFIX_ETC:-/etc/oxpulse-partner-edge}" "$_tpl_xray"
                            if [[ "${_RECONCILE_XRAY_CLIENT_CHANGED:-0}" -ne "$_before_xray_client" ]]; then
                                _changed_count=$((_changed_count + 1))
                            fi
                        fi
                        ;;
                    *)
                        warn "reconcile_all: surface '$_sid' render_from_state — no handler (skipping)"
                        ;;
                esac
                ;;
            network_apply)
                case "$_sid" in
                    firewall)
                        # Phase 4b: firewall network_apply — re-asserted every converge.
                        # Canon §6: oxpulse-owned nft only — NEVER docker ip nat / firewalld.
                        # Re-assert is idempotent; do NOT increment _changed_count for network_apply
                        # (it is not a file-swap, it is a live state assertion).
                        reconcile_firewall_surface
                        ;;
                    *)
                        warn "reconcile_all: surface '$_sid' network_apply — no handler (skipping)"
                        ;;
                esac
                ;;
            sync_verified)
                case "$_sid" in
                    xray_env)
                        # Phase 4b: xray_env sync_verified — provision if absent (closes #5).
                        local _before_xray_env="${_RECONCILE_XRAY_ENV_CHANGED:-0}"
                        reconcile_xray_env_surface "${PREFIX_ETC:-/etc/oxpulse-partner-edge}"
                        if [[ "${_RECONCILE_XRAY_ENV_CHANGED:-0}" -ne "$_before_xray_env" ]]; then
                            _changed_count=$((_changed_count + 1))
                        fi
                        ;;
                    *)
                        warn "reconcile_all: surface '$_sid' sync_verified — no handler (Phase 5+, skipping)"
                        ;;
                esac
                ;;
            persist_rendered)
                warn "reconcile_all: surface '$_sid' persist_rendered — not yet wired (Phase 5+, skipping)"
                ;;
            *)
                warn "reconcile_all: surface '$_sid' unknown kind '$_kind' — skipping"
                ;;
        esac
    done < <(manifest_surfaces "$_manifest")

    # Fail-closed guard (LIKELY fix): a present manifest that yields zero surfaces
    # means the parser failed silently (malformed YAML, missing surfaces: block,
    # or parser exception). Silently skipping all surfaces would leave caddy
    # unmanaged on every run — a stealth misconfiguration. Die loudly instead.
    # (Absent manifest already die()s above; this covers present-but-unparseable.)
    if [[ "$_surface_count" -eq 0 ]]; then
        die "reconcile_all: manifest parsed zero surfaces from $_manifest — malformed manifest or parser failure; refusing to proceed (caddy would be silently unmanaged)"
    fi

    # Phase 4a invariant: caddyfile surface must be wired. If _surface_count>0 but
    # _wired_count==0 every surface is unwired, which means the caddyfile entry is
    # missing or explicitly wired:false — a configuration error.
    if [[ "$_wired_count" -eq 0 ]]; then
        die "reconcile_all: manifest has $_surface_count surface(s) but none are wired — expected caddyfile (wired:true); refusing to proceed"
    fi

    log "reconcile_all: ${_surface_count} declared, ${_wired_count} wired, ${_skipped_count} skipped (not-yet-wired), ${_changed_count} changed"

    # KEY DELIVERABLE (Phase 4a): apply_caddy_reloads + apply_restarts fire after the loop.
    # Caddy changes use targeted hot-reload (no peer containers down).
    # Other unit restarts (Phase 4b surfaces) use apply_restarts.
    #
    # Fix 1 (engine reliability): apply_caddy_reloads returns non-zero on double-failure
    # (both hot-reload and force-recreate paths failed). Capture rc and propagate so the
    # caller sees a hard error, not a silent success with stale caddy config live.
    local _caddy_reload_rc=0
    apply_caddy_reloads || _caddy_reload_rc=$?
    apply_restarts
    if [[ "$_caddy_reload_rc" -ne 0 ]]; then
        # Fail AFTER apply_restarts so other deferred restarts still fire first.
        die "reconcile_all: caddy reload double-failure (hot-reload and force-recreate both failed) — new Caddyfile NOT live; check caddy container logs"
    fi
}
# ---------------------------------------------------------------------------
# Phase 4b — Surface handlers for coturn, xray_client, firewall, xray_env.
#
# Per-surface change flags (CC1 fix: sound multi-surface _changed_count).
# Each surface sets its own flag on change; reconcile_all counts flags, not
# _RECONCILE_RESTART_UNITS delta (which is unsound under dedup).
# ---------------------------------------------------------------------------

_RECONCILE_COTURN_CHANGED=0
_RECONCILE_XRAY_CLIENT_CHANGED=0
_RECONCILE_FIREWALL_APPLIED=0   # always re-asserted; not "changed" per se
_RECONCILE_XRAY_ENV_CHANGED=0

_reset_surface_flags() {
    _RECONCILE_COTURN_CHANGED=0
    _RECONCILE_XRAY_CLIENT_CHANGED=0
    _RECONCILE_XRAY_ENV_CHANGED=0
    # _RECONCILE_FIREWALL_APPLIED not reset: firewall runs every converge, value unused in count
}

# ---------------------------------------------------------------------------
# _setup_coturn_render_env PREFIX_ETC
#
# Exports env vars required for `opec render coturn`:
#   PARTNER_DOMAIN  — from caller (STATE_FILE; validated)
#   TURNS_SUBDOMAIN — from caller (STATE_FILE; validated)
#   TURN_SECRET     — from live docker-compose.yml TURN_SECRET env var
#   PUBLIC_IP       — env override → STATE_FILE → installed coturn.conf external-ip
#   PRIVATE_IP      — env override → STATE_FILE → installed coturn.conf external-ip
#   EXTERNAL_IP_LINE— "PUBLIC_IP/PRIVATE_IP" behind NAT, else "PUBLIC_IP"
#
# Die on: PARTNER_DOMAIN/TURNS_SUBDOMAIN missing (non-derivable).
# Die on: TURN_SECRET unresolvable (it's in compose only — required, not derivable).
#
# CRITICAL (idempotency / fail-closed): the steady-state converge MUST NOT live-
# probe the network for PUBLIC_IP. On a DPI-blocked edge (RU / ТСПУ) outbound
# HTTPS to ipify/ifconfig.me can be throttled/blocked → empty external-ip → a
# DEGRADED coturn.conf swapped live on a converge with ZERO real state change.
# So the resolution order is deterministic and last-known-good biased:
#   1. PUBLIC_IP/PRIVATE_IP already in env (explicit install/bootstrap override).
#   2. STATE_FILE (persisted at install — the authority for steady state).
#   3. The external-ip currently in the INSTALLED coturn.conf (last-known-good)
#      — reuse it so the render is a deterministic no-op swap.
# If NONE of those yield an external-ip, return 2 (SKIP signal): the caller leaves
# the live coturn.conf untouched (no swap, no SIGUSR2). We NEVER render an empty
# external-ip= and swap it live. The live network probe lives only on the
# install/bootstrap path (lib/install-network.sh network_run), never here.
# ---------------------------------------------------------------------------
_setup_coturn_render_env() {
    local _prefix_etc="${1:-${PREFIX_ETC:-/etc/oxpulse-partner-edge}}"
    local _compose="${COMPOSE_FILE:-${_prefix_etc}/docker-compose.yml}"

    [[ -n "${PARTNER_DOMAIN:-}" ]]   || die "reconcile_coturn: PARTNER_DOMAIN missing — cannot render coturn.conf"
    [[ -n "${TURNS_SUBDOMAIN:-}" ]]  || die "reconcile_coturn: TURNS_SUBDOMAIN missing — cannot render coturn.conf"

    # TURN_SECRET: extract from live compose file (it lives there, not in STATE).
    if [[ -z "${TURN_SECRET:-}" ]]; then
        if [[ -r "$_compose" ]]; then
            TURN_SECRET=$(grep -E '^\s*TURN_SECRET[=:]' "$_compose" 2>/dev/null \
                | head -1 | sed 's/.*TURN_SECRET[=:]\s*//' | tr -d '"'"'"' ' | tr -d '[:space:]' || true)
        fi
    fi
    # Also try docker inspect on the coturn container.
    if [[ -z "${TURN_SECRET:-}" ]]; then
        TURN_SECRET=$(${DOCKER_BIN:-docker} inspect oxpulse-partner-coturn \
            --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
            | grep '^TURN_SECRET=' | cut -d= -f2 | head -1 || true)
    fi
    [[ -n "${TURN_SECRET:-}" ]] \
        || die "reconcile_coturn: TURN_SECRET not found in compose or coturn container — cannot render coturn.conf safely"

    # PUBLIC_IP: env override (already set) → STATE_FILE. NO live network probe in
    # the steady-state converge (see header — DPI edges would swap a degraded conf).
    if [[ -z "${PUBLIC_IP:-}" ]]; then
        PUBLIC_IP=$(grep '^PUBLIC_IP=' "${STATE_FILE:-}" 2>/dev/null | cut -d= -f2 | head -1 || true)
    fi

    # PRIVATE_IP: env override (already set) → STATE_FILE. No ip-addr heuristic in
    # the hot path — last-known-good comes from the installed coturn.conf below.
    if [[ -z "${PRIVATE_IP:-}" ]]; then
        PRIVATE_IP=$(grep '^PRIVATE_IP=' "${STATE_FILE:-}" 2>/dev/null | cut -d= -f2 | head -1 || true)
    fi

    # Last-known-good fallback: if STATE gave nothing, reuse the external-ip already
    # in the INSTALLED coturn.conf so the render is a deterministic no-op swap
    # rather than a degraded (empty external-ip) live swap.
    if [[ -z "${PUBLIC_IP:-}" ]]; then
        local _installed_conf="${_prefix_etc}/coturn.conf"
        if [[ -r "$_installed_conf" ]]; then
            local _installed_ext
            _installed_ext=$(grep -E '^external-ip=' "$_installed_conf" 2>/dev/null \
                | head -1 | sed 's/^external-ip=//' | tr -d '[:space:]' || true)
            if [[ -n "$_installed_ext" ]]; then
                # Format is "PUBLIC/PRIVATE" behind NAT, else "PUBLIC".
                PUBLIC_IP="${_installed_ext%%/*}"
                if [[ "$_installed_ext" == */* ]]; then
                    PRIVATE_IP="${_installed_ext#*/}"
                fi
                log "reconcile_coturn: PUBLIC_IP not in STATE — reusing last-known-good external-ip from installed coturn.conf"
            fi
        fi
    fi

    # If STILL no PUBLIC_IP, SKIP the coturn surface this cycle. Return 2 (SKIP):
    # caller leaves the live coturn.conf untouched (no swap, no SIGUSR2). NEVER
    # render an empty external-ip= and swap it into a degraded config live.
    if [[ -z "${PUBLIC_IP:-}" ]]; then
        warn "reconcile_coturn: no PUBLIC_IP from env/STATE/installed coturn.conf — SKIPPING coturn render this converge (live config left untouched). Fix: persist PUBLIC_IP in $STATE_FILE or set OXPULSE_PUBLIC_IP and re-run install."
        return 2
    fi

    # EXTERNAL_IP_LINE: "public/private" if behind NAT (different IPs), else "public".
    if [[ -n "${PUBLIC_IP:-}" && -n "${PRIVATE_IP:-}" && "$PUBLIC_IP" != "$PRIVATE_IP" ]]; then
        EXTERNAL_IP_LINE="${PUBLIC_IP}/${PRIVATE_IP}"
    else
        EXTERNAL_IP_LINE="${PUBLIC_IP:-}"
    fi

    export PARTNER_DOMAIN TURNS_SUBDOMAIN TURN_SECRET PUBLIC_IP PRIVATE_IP EXTERNAL_IP_LINE
}

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# _write_coturn_skip_count COUNT [STATE_DIR]
#
# Atomically writes (or resets) the consecutive-coturn-skip counter to the
# durable state file COTURN_SKIP_COUNT_FILE under STATE_DIR.
# Pattern based on _write_probe_mode_state in oxpulse-channels-health-report.sh.
#
# Fields:
#   COTURN_SKIP_CONSECUTIVE — number of converge cycles that hit the SKIP path
#                              since the last successful render; 0 = all clear.
#   COTURN_SKIP_UPDATED_AT  — unix timestamp of the last write.
#
# Callers read the file via `grep '^COTURN_SKIP_CONSECUTIVE=' ... | cut -d= -f2`.
# The file is world-readable (0644) so any health-check or operator script can
# inspect it without elevated privileges.
# ---------------------------------------------------------------------------
_COTURN_SKIP_COUNT_FILE_NAME="coturn-skip-count.env"
_STATE_DIR_DEFAULT="/var/lib/oxpulse-partner-edge"

_write_coturn_skip_count() {
    local _count="$1"
    local _state_dir="${2:-${STATE_DIR:-${_STATE_DIR_DEFAULT}}}"
    local _state_file="${_COTURN_SKIP_COUNT_FILE:-${_state_dir}/${_COTURN_SKIP_COUNT_FILE_NAME}}"
    mkdir -p "$_state_dir" 2>/dev/null || return 0
    local _tmp
    _tmp=$(mktemp -p "$_state_dir" coturn-skip-count.XXXXXX 2>/dev/null) || return 0
    {
        echo "# Generated by lib/reconcile.sh — do not edit"
        printf 'COTURN_SKIP_CONSECUTIVE=%s\n' "$_count"
        printf 'COTURN_SKIP_UPDATED_AT=%s\n'  "$(date +%s)"
    } > "$_tmp"
    chmod 0644 "$_tmp" 2>/dev/null || true
    mv -f "$_tmp" "$_state_file" 2>/dev/null || rm -f "$_tmp" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# reconcile_coturn_surface PREFIX_ETC [TPL_PATH]
#
# Phase 4b render_from_state handler for coturn.conf.
#
# Change-detection: sha256 of rendered candidate vs sha256 of installed file.
# (No __COTURN_SHA__ self-reference like Caddyfile; plain file-vs-file compare.)
#
# On change:
#   1. atomic_swap installed coturn.conf
#   2. Send SIGUSR2 to the coturn container (reload_ssl_certs, no session drop).
#      NEVER full-restart the container — that drops all TURN allocations.
#
# fail-closed: render failure or placeholder residue = die (coturn is NOT fail_soft).
#
# Observability: on every SKIP (external-ip unresolvable) the consecutive-skip
# counter in STATE_DIR/coturn-skip-count.env is incremented.  On any path where
# external-ip WAS resolved (no-op render or actual swap) the counter is reset to 0.
# A central scraper that reads COTURN_SKIP_CONSECUTIVE ≥ threshold can surface a
# stuck edge before an operator intervention.
# ---------------------------------------------------------------------------
reconcile_coturn_surface() {
    local _prefix_etc="${1:-${PREFIX_ETC:-/etc/oxpulse-partner-edge}}"
    local _tpl_path="${2:-}"
    local _out_path; _out_path=$(mktemp "${TMPDIR:-/tmp}/coturn.conf.XXXXXX")
    local _installed_path="${_prefix_etc}/coturn.conf"

    # Resolve template from REPO_DIR if not passed.
    if [[ -z "$_tpl_path" ]]; then
        if [[ -n "${REPO_DIR:-}" && -f "${REPO_DIR}/coturn.conf.tpl" ]]; then
            _tpl_path="${REPO_DIR}/coturn.conf.tpl"
        elif [[ -n "${RECONCILE_TMPDIR:-}" && -f "${RECONCILE_TMPDIR}/coturn.conf.tpl" ]]; then
            _tpl_path="${RECONCILE_TMPDIR}/coturn.conf.tpl"
        else
            die "reconcile_coturn: coturn.conf.tpl not available (set REPO_DIR or pre-populate RECONCILE_TMPDIR)"
        fi
    fi

    command -v opec >/dev/null 2>&1 \
        || die "reconcile_coturn: opec not on PATH — required for coturn.conf render"

    # Set up all placeholder env vars. Return code 2 = SKIP signal: no PUBLIC_IP
    # from env/STATE/installed coturn.conf → leave the live config untouched
    # (no swap, no SIGUSR2). NEVER swap a degraded (empty external-ip) config live.
    local _env_rc=0
    _setup_coturn_render_env "$_prefix_etc" || _env_rc=$?
    if [[ "$_env_rc" -eq 2 ]]; then
        rm -f "$_out_path"
        log "reconcile_coturn: SKIP — external-ip unresolvable; live coturn.conf left untouched (no swap)"
        # Increment durable consecutive-skip counter so a stuck edge is detectable
        # by health-report scrapers without relying on transient log lines.
        local _state_dir="${STATE_DIR:-${_STATE_DIR_DEFAULT}}"
        local _skip_file="${_COTURN_SKIP_COUNT_FILE:-${_state_dir}/${_COTURN_SKIP_COUNT_FILE_NAME}}"
        local _prev_count=0
        _prev_count=$(grep '^COTURN_SKIP_CONSECUTIVE=' "$_skip_file" 2>/dev/null \
            | head -1 | cut -d= -f2 || true)
        _prev_count=$(( ${_prev_count:-0} + 1 ))
        warn "reconcile_coturn: consecutive SKIP count is now ${_prev_count} — fix: persist PUBLIC_IP in STATE_FILE or set OXPULSE_PUBLIC_IP"
        _write_coturn_skip_count "$_prev_count" "$_state_dir"
        return 0
    fi

    # Render via opec (single render authority — Decision 2).
    opec render coturn --tpl "$_tpl_path" --out "$_out_path" \
        || die "reconcile_coturn: opec render coturn failed — see error above"

    # Runtime completeness guard (S1 — fail-closed before swap).
    assert_no_unresolved_placeholders "$_out_path"

    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        local _dry_sha
        _dry_sha=$(sha256sum "$_out_path" | awk '{print $1}')
        rm -f "$_out_path"
        log "[dry-run] reconcile_coturn: would write coturn.conf (sha256=$_dry_sha) to $_installed_path"
        # Render succeeded (external-ip resolved, dry-run) — reset skip counter.
        _write_coturn_skip_count 0 "${STATE_DIR:-${_STATE_DIR_DEFAULT}}"
        return 0
    fi

    # Checksum-compare vs installed (idempotency: skip if unchanged).
    local _rendered_sha _installed_sha=""
    _rendered_sha=$(sha256sum "$_out_path" | awk '{print $1}')
    if [[ -f "$_installed_path" ]]; then
        _installed_sha=$(sha256sum "$_installed_path" | awk '{print $1}')
    fi
    if [[ "$_rendered_sha" == "$_installed_sha" ]]; then
        rm -f "$_out_path"
        log "reconcile_coturn: coturn.conf unchanged (sha256=$_rendered_sha) — no swap needed"
        # Render succeeded (external-ip resolved, no-op) — reset skip counter.
        _write_coturn_skip_count 0 "${STATE_DIR:-${_STATE_DIR_DEFAULT}}"
        return 0
    fi

    # Atomic swap.
    atomic_swap "$_installed_path" "$_out_path" 0644
    log "reconcile_coturn: coturn.conf updated (sha256=$_rendered_sha)"
    # Render succeeded (new config) — reset skip counter.
    _write_coturn_skip_count 0 "${STATE_DIR:-${_STATE_DIR_DEFAULT}}"

    # Set per-surface change flag (CC1 fix: sound multi-surface _changed_count).
    _RECONCILE_COTURN_CHANGED=1

    # Signal SIGUSR2 to the coturn container — reload_ssl_certs, no session drop.
    # Peer containers (SFU/caddy/xray/naive) are NOT touched.
    local _docker="${DOCKER_BIN:-docker}"
    local _compose_file="${COMPOSE_FILE:-${_prefix_etc}/docker-compose.yml}"
    log "reconcile_coturn: sending SIGUSR2 to coturn container (reload_ssl_certs, no session drop)"
    # Try docker kill first (direct signal to container).
    if "$_docker" kill --signal SIGUSR2 oxpulse-partner-coturn 2>/dev/null; then
        log "reconcile_coturn: SIGUSR2 delivered to oxpulse-partner-coturn"
    elif "$_docker" compose -f "$_compose_file" kill --signal SIGUSR2 coturn 2>/dev/null; then
        log "reconcile_coturn: SIGUSR2 delivered via compose kill"
    else
        warn "reconcile_coturn: could not send SIGUSR2 — coturn may not have reloaded certs (container down?)"
    fi
}

# ---------------------------------------------------------------------------
# _setup_xray_client_render_env PREFIX_ETC
#
# Exports XRAY_XHTTP_* vars needed by `opec render xray`.
# These live in node-config.json (channels[0].xray.xhttp), not in STATE.
# Matches install.sh python3 blocks; defaults mirror channel-render-lib.sh.
# ---------------------------------------------------------------------------
_setup_xray_client_render_env() {
    local _prefix_etc="${1:-${PREFIX_ETC:-/etc/oxpulse-partner-edge}}"
    local _node_cfg="${_prefix_etc}/node-config.json"

    if [[ -r "$_node_cfg" ]] && command -v python3 >/dev/null 2>&1; then
        local _py_tmp
        _py_tmp=$(mktemp /tmp/xray_env_XXXXXX.py)
        # shellcheck disable=SC2064
        trap "rm -f '$_py_tmp'" RETURN
        cat > "$_py_tmp" << 'PYEOF'
import json, sys
path = sys.argv[1]
try:
    d = json.load(open(path))
    ch = d.get("channels", []) or [{}]
    x = ch[0].get("xray", {}) if ch[0].get("protocol", "") == "vless-reality" else {}
    xhttp = x.get("xhttp", {})
    xmux  = xhttp.get("xmux") or x.get("xmux") or {}
    print("XRAY_XHTTP_MODE="          + (xhttp.get("mode") or x.get("mode") or "stream-one"))
    print("XRAY_XHTTP_PATH="          + (x.get("xhttp", {}).get("path") or "/xh"))
    print("XRAY_XHTTP_XMUX_MAX_CONCURRENCY=" + str(xmux.get("maxConcurrency", 1)))
    print("XRAY_XHTTP_XMUX_C_MAX_REUSE_TIMES=" + str(xmux.get("cMaxReuseTimes", 64)))
    print("XRAY_XHTTP_XMUX_C_MAX_LIFETIME_MS=" + str(xmux.get("cMaxLifetimeMs", 15000)))
    print("XRAY_XHTTP_X_PADDING_BYTES=" + str(x.get("xhttp", {}).get("extra", {}).get("xPaddingBytes") or "100-1000"))
    # Reality / backend render vars — the SAME flat register-response keys
    # install.sh json_get's from node-config.json (install.sh:665-668,1058-1059).
    # These are NOT in install.env; without them opec render xray emits
    # {{REALITY_*}}/{{BACKEND_*}} placeholders and the completeness guard
    # fail_soft-skips on every edge (BUG2). Always printed (even when empty) so a
    # stale ambient value is cleared and the surface's fail-closed guard fires.
    print("REALITY_UUID="        + str(d.get("reality_uuid", "") or ""))
    print("REALITY_PUBLIC_KEY="  + str(d.get("reality_public_key", "") or ""))
    print("REALITY_SHORT_ID="    + str(d.get("reality_short_id", "") or ""))
    print("REALITY_SERVER_NAME=" + str(d.get("reality_server_name", "") or ""))
    print("REALITY_ENCRYPTION="  + str(d.get("reality_encryption", "") or ""))
    _be = str(d.get("backend_endpoint", "") or "")
    if ":" in _be:
        _h, _, _p = _be.rpartition(":")
        print("BACKEND_HOST=" + _h)
        print("BACKEND_PORT=" + _p)
    else:
        print("BACKEND_HOST=")
        print("BACKEND_PORT=")
except Exception:
    print("XRAY_XHTTP_MODE=stream-one")
    print("XRAY_XHTTP_PATH=/xh")
    print("XRAY_XHTTP_XMUX_MAX_CONCURRENCY=1")
    print("XRAY_XHTTP_XMUX_C_MAX_REUSE_TIMES=64")
    print("XRAY_XHTTP_XMUX_C_MAX_LIFETIME_MS=15000")
    print("XRAY_XHTTP_X_PADDING_BYTES=100-1000")
PYEOF
        local _envout
        _envout=$(python3 "$_py_tmp" "$_node_cfg" 2>/dev/null || true)
        while IFS='=' read -r _k _v; do
            [[ -z "${_k:-}" ]] && continue
            export "${_k}=${_v}"
        done <<< "$_envout"
    else
        # node-config absent or no python3 — use defaults (matches channel-render-lib.sh).
        export XRAY_XHTTP_MODE="${XRAY_XHTTP_MODE:-stream-one}"
        export XRAY_XHTTP_PATH="${XRAY_XHTTP_PATH:-/xh}"
        export XRAY_XHTTP_XMUX_MAX_CONCURRENCY="${XRAY_XHTTP_XMUX_MAX_CONCURRENCY:-1}"
        export XRAY_XHTTP_XMUX_C_MAX_REUSE_TIMES="${XRAY_XHTTP_XMUX_C_MAX_REUSE_TIMES:-64}"
        export XRAY_XHTTP_XMUX_C_MAX_LIFETIME_MS="${XRAY_XHTTP_XMUX_C_MAX_LIFETIME_MS:-15000}"
        export XRAY_XHTTP_X_PADDING_BYTES="${XRAY_XHTTP_X_PADDING_BYTES:-100-1000}"
    fi
}

# ---------------------------------------------------------------------------
# _reconcile_xray_emit_gauge UNRESOLVED
#
# Standing signal for the BUG2 fail-closed skip: a Prometheus textfile-collector
# gauge so a probe/dashboard can tell when the xray_client surface could NOT
# resolve its Reality/backend creds from node-config.json and skipped the render
# (the Reality re-render silently not happening — the exact class BUG2 cured).
#
# Deliberate parallel of _reconcile_firewall_emit_gauge below: OWN file
# (partner_edge_xray.prom) distinct from partner_edge.prom / partner_edge_firewall.prom
# so a differently-typed metric never races another writer's truncation and
# corrupts node_exporter's textfile collector with duplicate `# TYPE` lines.
#
# UNRESOLVED: "1" when creds were unresolvable this converge (surface skipped),
# "0" when they resolved (render path reached). Atomic tmp+mv; skips silently
# when the textfile dir is unwritable/absent (non-fatal).
# ---------------------------------------------------------------------------
_reconcile_xray_emit_gauge() {
    local _unresolved="$1"
    local _dir="${PARTNER_EDGE_TEXTFILE_DIR:-/var/lib/prometheus-node-exporter/textfile}"
    [[ -d "$_dir" ]] || mkdir -p "$_dir" 2>/dev/null || return 0
    local _f="$_dir/partner_edge_xray.prom"
    local _tmp="${_f}.tmp.$$"
    { printf '# TYPE partner_edge_xray_creds_unresolved gauge\n'
      printf 'partner_edge_xray_creds_unresolved %s\n' "$_unresolved"
    } >"$_tmp" 2>/dev/null && mv -f "$_tmp" "$_f" 2>/dev/null || rm -f "$_tmp" 2>/dev/null
    return 0
}

# ---------------------------------------------------------------------------
# reconcile_xray_client_surface PREFIX_ETC [TPL_PATH]
#
# Phase 4b render_from_state handler for xray-client.json.
#
# FAIL_SOFT: xray is a bypass channel — render failure = warn+continue, NOT die.
# (This mirrors install.sh's render_channel_soft for xray.)
#
# On change:
#   docker compose up -d --force-recreate xray-client
#   (ONLY xray-client service; caddy/coturn/SFU/naive untouched — PI2 invariant.)
#
# Change-detection: sha256 rendered vs sha256 installed.
# ---------------------------------------------------------------------------
reconcile_xray_client_surface() {
    local _prefix_etc="${1:-${PREFIX_ETC:-/etc/oxpulse-partner-edge}}"
    local _tpl_path="${2:-}"
    local _out_path; _out_path=$(mktemp "${TMPDIR:-/tmp}/xray-client.json.XXXXXX")
    local _installed_path="${_prefix_etc}/xray-client.json"

    # Resolve template.
    if [[ -z "$_tpl_path" ]]; then
        if [[ -n "${REPO_DIR:-}" && -f "${REPO_DIR}/xray-client.json.tpl" ]]; then
            _tpl_path="${REPO_DIR}/xray-client.json.tpl"
        elif [[ -n "${RECONCILE_TMPDIR:-}" && -f "${RECONCILE_TMPDIR}/xray-client.json.tpl" ]]; then
            _tpl_path="${RECONCILE_TMPDIR}/xray-client.json.tpl"
        else
            warn "reconcile_xray_client: xray-client.json.tpl not available (set REPO_DIR or pre-populate RECONCILE_TMPDIR) — skipping (fail_soft)"
            return 0
        fi
    fi

    if ! command -v opec >/dev/null 2>&1; then
        warn "reconcile_xray_client: opec not on PATH — skipping xray-client.json render (fail_soft)"
        return 0
    fi

    # Set up XRAY_XHTTP_* + REALITY_*/BACKEND_* env vars from node-config.json.
    _setup_xray_client_render_env "$_prefix_etc"

    # Fail-closed (coturn TURN_SECRET landmine class): if the Reality creds or the
    # backend endpoint could not be resolved from node-config.json, SKIP the render
    # entirely (fail_soft) — NEVER render a blank publicKey/backend and swap it
    # live, which would zero the VLESS tunnel. opec substitutes an EMPTY value (not
    # a {{placeholder}}), so the completeness guard below would NOT catch it; this
    # guard must fire first, leaving the last-known-good config untouched.
    if [[ -z "${REALITY_PUBLIC_KEY:-}" || -z "${REALITY_UUID:-}" \
          || -z "${BACKEND_HOST:-}" || -z "${BACKEND_PORT:-}" ]]; then
        rm -f "$_out_path"
        warn "reconcile_xray_client: reality/backend creds unresolved from ${_prefix_etc}/node-config.json (REALITY_PUBLIC_KEY/UUID or BACKEND_HOST/PORT empty) — skipping xray-client render (fail_soft; live config left untouched, tunnel not zeroed)"
        _reconcile_xray_emit_gauge 1
        return 0
    fi
    _reconcile_xray_emit_gauge 0

    # Render — fail_soft: warn on failure, do NOT die.
    if ! opec render xray --tpl "$_tpl_path" --out "$_out_path" 2>/dev/null; then
        rm -f "$_out_path"
        warn "reconcile_xray_client: opec render xray failed — skipping (fail_soft; xray is a bypass channel)"
        return 0
    fi

    # Completeness guard — fail_soft: warn on residue, skip swap.
    # Match any {{...}} placeholder (not only [A-Z0-9_]) so a future lowercase /
    # hyphenated placeholder cannot slip an unresolved value into a live swap.
    if grep -qE '\{\{[^}]+\}\}' "$_out_path" 2>/dev/null; then
        local _leftover
        _leftover=$(grep -oE '\{\{[^}]+\}\}' "$_out_path" | sort -u | tr '\n' ' ')
        rm -f "$_out_path"
        warn "reconcile_xray_client: unresolved placeholders (${_leftover}) — skipping (fail_soft)"
        return 0
    fi

    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        local _dry_sha
        _dry_sha=$(sha256sum "$_out_path" | awk '{print $1}')
        rm -f "$_out_path"
        log "[dry-run] reconcile_xray_client: would write xray-client.json (sha256=$_dry_sha) to $_installed_path"
        return 0
    fi

    # Checksum-compare vs installed.
    local _rendered_sha _installed_sha=""
    _rendered_sha=$(sha256sum "$_out_path" | awk '{print $1}')
    if [[ -f "$_installed_path" ]]; then
        _installed_sha=$(sha256sum "$_installed_path" | awk '{print $1}')
    fi
    if [[ "$_rendered_sha" == "$_installed_sha" ]]; then
        rm -f "$_out_path"
        log "reconcile_xray_client: xray-client.json unchanged (sha256=$_rendered_sha) — no recreate needed"
        return 0
    fi

    # Atomic swap.
    atomic_swap "$_installed_path" "$_out_path" 0644
    log "reconcile_xray_client: xray-client.json updated (sha256=$_rendered_sha)"

    # Set per-surface change flag.
    _RECONCILE_XRAY_CLIENT_CHANGED=1

    # Recreate ONLY the xray-client compose service (PI2 invariant: no peer services).
    local _docker="${DOCKER_BIN:-docker}"
    local _compose_file="${COMPOSE_FILE:-${_prefix_etc}/docker-compose.yml}"
    log "reconcile_xray_client: force-recreating xray-client service (peers untouched)"
    if "$_docker" compose -f "$_compose_file" up -d --force-recreate xray-client 2>/dev/null; then
        log "reconcile_xray_client: xray-client recreated (caddy/coturn/SFU/naive untouched)"
    else
        # fail_soft: do not die. But the config was ALREADY swapped above, so the
        # container is now running the OLD config — a silent partial-apply. Emit a
        # DISTINCT, scrapeable marker so a healthcheck/operator can detect the drift
        # (config-on-disk newer than the running container).
        warn "reconcile_xray_client: STALE_CONFIG xray-client config swapped on disk but recreate FAILED — container running STALE config; check: $_docker compose -f $_compose_file logs xray-client"
    fi
}

# ---------------------------------------------------------------------------
# _reconcile_firewall_emit_gauge UNMANAGED
#
# Standing-signal companion to _reconcile_firewall_escalate below: a
# Prometheus textfile-collector gauge so a probe/dashboard can key on
# firewall coverage even if the alert itself is missed or rate-limited.
#
# Owns its own file (partner_edge_firewall.prom) distinct from
# oxpulse-partner-edge-refresh.sh's partner_edge.prom — that script resets
# (truncates) its file once per ITS OWN run; appending a differently-typed
# metric into the same file from this (separate systemd unit / process)
# would race that truncation and risk duplicate `# TYPE` lines, which
# corrupts the whole file for node_exporter's textfile collector.
#
# UNMANAGED: "1" when firewall_apply could not enforce the whitelist this
# converge, "0" when it succeeded. Atomic tmp+mv write (mirrors atomic_swap
# above). Skips silently when the textfile dir is unwritable/absent
# (non-fatal — matches the refresh script's emit_metric).
# ---------------------------------------------------------------------------
_reconcile_firewall_emit_gauge() {
    local _unmanaged="$1"
    local _dir="${PARTNER_EDGE_TEXTFILE_DIR:-/var/lib/prometheus-node-exporter/textfile}"
    [[ -d "$_dir" ]] || mkdir -p "$_dir" 2>/dev/null || return 0
    local _f="$_dir/partner_edge_firewall.prom"
    local _tmp="${_f}.tmp.$$"
    { printf '# TYPE partner_edge_firewall_unmanaged gauge\n'
      printf 'partner_edge_firewall_unmanaged %s\n' "$_unmanaged"
    } >"$_tmp" 2>/dev/null && mv -f "$_tmp" "$_f" 2>/dev/null || rm -f "$_tmp" 2>/dev/null
    return 0
}

# ---------------------------------------------------------------------------
# _reconcile_firewall_escalate RC
#
# Escalates a firewall_apply failure via the shared dozor AM-webhook notify
# path — lib/telegram-alert-lib.sh's tg_alert(), the repo-wide notify
# primitive (also used by oxpulse-channels-health-report.sh). NEVER curls
# Telegram directly and NEVER invents a second alert channel.
#
# Severity vocab = critical|warning|info ONLY. dozor's monitor/healthcheck
# receiver classifies severity by lexical match on the message text
# (classifyMonitorMessage) — the message below includes "CRITICAL" and
# "failed" so it lands as critical, not the silent-default warning.
# force="force" bypasses tg_alert's 600s rate-limit floor: an unenforced
# host firewall must alert every converge cycle it recurs, not just once.
#
# Non-fatal by design (warn + return, never die): reconcile_firewall_surface
# must still let the rest of reconcile_all's surfaces converge even when the
# firewall escalation itself cannot be delivered.
# ---------------------------------------------------------------------------
_reconcile_firewall_escalate() {
    local _rc="$1"
    local _tg_lib="${TELEGRAM_ALERT_LIB:-${LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-}")" && pwd)}/telegram-alert-lib.sh}"

    if [[ ! -f "$_tg_lib" ]]; then
        warn "reconcile_firewall: telegram-alert-lib.sh not found at $_tg_lib — cannot escalate (rc=$_rc)"
        return 0
    fi
    if ! declare -f tg_alert >/dev/null 2>&1; then
        # shellcheck source=lib/telegram-alert-lib.sh
        . "$_tg_lib"
    fi

    local _host
    _host=$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo "unknown-host")
    tg_alert "[oxpulse-partner-edge] CRITICAL firewall_apply failed (rc=${_rc}) on ${_host} — no supported firewall tool (ufw/firewalld) or apply error; SFU mesh-only ports (9317,8912/tcp) and the public whitelist are NOT enforced. Apply the whitelist manually or install ufw/firewalld." \
        "force"
}

# ---------------------------------------------------------------------------
# reconcile_firewall_surface
#
# Phase 4b network_apply handler.
# Re-asserts oxpulse-owned nft rules on EVERY converge (idempotent re-assert;
# live re-assert is the authority — not checksum-based skip).
#
# Scope: ONLY oxpulse-owned nft table/chains + ufw/firewalld rules.
# NEVER touches docker ip nat, firewalld zones docker manages, or iptables
# chains owned by Docker. (Canon §6 invariant.)
#
# network_apply surfaces are re-asserted on every converge — their "changed"
# count is not incremented because re-assert is the intended behavior, not a
# deviation. Callers should not interpret firewall output as "changed" in the
# idempotency sense.
#
# t14 fix: firewall_apply returning non-zero (no supported tool, or an apply
# error) used to be swallowed by a buried `warn` while
# _RECONCILE_FIREWALL_APPLIED was set to 1 regardless — the converge cycle
# logged green with SFU/coturn ports left publicly reachable. Now: a non-zero
# rc leaves _RECONCILE_FIREWALL_APPLIED unset (reflects the true state) and
# escalates via a critical AM-webhook alert instead of a warn line nobody
# reads. Supported-tool (ufw/firewalld) success path is unchanged.
#
# Requires: lib/install-firewall.sh sourced (provides firewall_apply).
# ---------------------------------------------------------------------------
reconcile_firewall_surface() {
    local _fw_lib="${FIREWALL_LIB:-${LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-}")" && pwd)}/install-firewall.sh}"

    if [[ ! -f "$_fw_lib" ]]; then
        die "reconcile_firewall: lib/install-firewall.sh not found at $_fw_lib — cannot apply firewall"
    fi

    # Source firewall lib if firewall_apply is not yet in scope.
    if ! declare -f firewall_apply >/dev/null 2>&1; then
        # shellcheck source=lib/install-firewall.sh
        . "$_fw_lib"
    fi

    log "reconcile_firewall: re-asserting oxpulse-owned nft rules (idempotent, every converge)"
    # firewall_apply: idempotent (ufw --force reset+rules or firewalld --permanent+reload).
    # Non-zero (e.g. 2 = no supported tool) is now propagated, not swallowed —
    # see t14 fix note above.
    # Canon §6: only oxpulse-owned nft — NOT docker ip nat / firewalld zones docker owns.
    local _fw_rc=0
    firewall_apply || _fw_rc=$?
    if [[ "$_fw_rc" -eq 0 ]]; then
        _RECONCILE_FIREWALL_APPLIED=1
        _reconcile_firewall_emit_gauge 0
    else
        warn "reconcile_firewall: firewall_apply FAILED (rc=$_fw_rc) — host firewall NOT enforced this converge; SFU mesh-only ports (9317,8912) and the public whitelist may be publicly reachable"
        _reconcile_firewall_escalate "$_fw_rc"
        _reconcile_firewall_emit_gauge 1
        # Do NOT set _RECONCILE_FIREWALL_APPLIED=1 — reflect the true state.
    fi
}

# ---------------------------------------------------------------------------
# reconcile_xray_env_surface PREFIX_ETC
#
# Phase 4b sync_verified handler for xray.env.
# Closes failure class #5 (silent xray-update death — xray.env never provisioned).
#
# Contract:
#   - If /etc/oxpulse-partner-edge/xray.env absent: create empty file (0644).
#   - If already present: no-op (idempotent; operator or another path may have
#     populated it — we never overwrite content).
#   - Records change via _RECONCILE_XRAY_ENV_CHANGED.
#
# No-double-provision: upgrade.sh's inline `[[ ! -f xray.env ]]` touch-if-absent
# is idempotent with this surface. Both paths converge: whichever fires first
# creates the file; the other sees it present and skips. The manifest surface
# IS the authority for ongoing converge runs; the upgrade.sh path remains for
# backward compat during Phase 4b transition (Phase 6 will clean up).
# ---------------------------------------------------------------------------
reconcile_xray_env_surface() {
    local _prefix_etc="${1:-${PREFIX_ETC:-/etc/oxpulse-partner-edge}}"
    local _xray_env_path="${_prefix_etc}/xray.env"

    if [[ -f "$_xray_env_path" ]]; then
        log "reconcile_xray_env: $_xray_env_path already present — no-op (idempotent)"
        return 0
    fi

    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log "[dry-run] reconcile_xray_env: would create empty $_xray_env_path (required by oxpulse-xray-update.service)"
        return 0
    fi

    install -d -m 0755 "$_prefix_etc" 2>/dev/null || true
    install -m 0644 /dev/null "$_xray_env_path" \
        || { warn "reconcile_xray_env: could not create $_xray_env_path"; return 0; }
    log "reconcile_xray_env: provisioned $_xray_env_path (empty; required by oxpulse-xray-update.service)"
    _RECONCILE_XRAY_ENV_CHANGED=1
}
