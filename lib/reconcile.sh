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

    # Run --snapshot; always exits 0 per healthcheck.sh contract.
    if ! "$_hc_bin" --snapshot > "$_snap_file" 2>/dev/null; then
        warn "health_snapshot: healthcheck --snapshot exited non-zero (unexpected)"
        return 1
    fi

    if [[ ! -s "$_snap_file" ]]; then
        warn "health_snapshot: snapshot file is empty after run: $_snap_file"
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
#   id<TAB>kind<TAB>wired<TAB>template<TAB>out<TAB>renderer<TAB>restart_unit<TAB>sha_key<TAB>placeholder_completeness
#
# wired is "true" unless surface block contains "wired: false".
# Uses python3 (de-facto dep, used 9x in channel-render-lib.sh); awk fallback.
# The python code is stored as a base64 constant to avoid heredoc-in-sourced-
# function issues (bash heredocs read stdin at call time in sourced files).
# ---------------------------------------------------------------------------

# Base64-encoded python3 manifest parser.
_MANIFEST_PARSER_B64="aW1wb3J0IHN5cywgcmUKbWFuaWZlc3RfcGF0aCA9IHN5cy5hcmd2WzFdCnRyeToKICAgIGNvbnRlbnQgPSBvcGVuKG1hbmlmZXN0X3BhdGgpLnJlYWQoKQpleGNlcHQgRXhjZXB0aW9uOgogICAgc3lzLmV4aXQoMCkKc3VyZmFjZXNfbWF0Y2ggPSByZS5zZWFyY2gocidec3VyZmFjZXM6XHMqXG4oLio/KSg/PV5cd3xcWiknLCBjb250ZW50LCByZS5NVUxUSUxJTkUgfCByZS5ET1RBTEwpCmlmIG5vdCBzdXJmYWNlc19tYXRjaDoKICAgIHN5cy5leGl0KDApCnN1cmZhY2VzX2Jsb2NrID0gc3VyZmFjZXNfbWF0Y2guZ3JvdXAoMSkKc3VyZmFjZV9lbnRyaWVzID0gcmUuc3BsaXQocidcbig/PSAgLSBpZDopJywgc3VyZmFjZXNfYmxvY2spCmZvciBlbnRyeSBpbiBzdXJmYWNlX2VudHJpZXM6CiAgICBlbnRyeSA9IGVudHJ5LnN0cmlwKCkKICAgIGlmIG5vdCBlbnRyeToKICAgICAgICBjb250aW51ZQogICAgaWRfbSA9IHJlLnNlYXJjaChyJ14tXHMraWQ6XHMqKFxTKyknLCBlbnRyeSwgcmUuTVVMVElMSU5FKQogICAgaWYgbm90IGlkX206CiAgICAgICAgY29udGludWUKICAgIHNpZCA9IGlkX20uZ3JvdXAoMSkuc3RyaXAoKQogICAgaWYgbm90IHNpZCBvciBzaWQgPT0gIi0iOgogICAgICAgIGNvbnRpbnVlCiAgICBkZWYgZmllbGQoa2V5LCBkZWZhdWx0PSItIik6CiAgICAgICAgbSA9IHJlLnNlYXJjaChyJ15ccysnICsgcmUuZXNjYXBlKGtleSkgKyByJzpccyooLispJCcsIGVudHJ5LCByZS5NVUxUSUxJTkUpCiAgICAgICAgaWYgbToKICAgICAgICAgICAgIyBTdHJpcCB0cmFpbGluZyBZQU1MIGlubGluZSBjb21tZW50ICgjIC4uLikgYW5kIHdoaXRlc3BhY2UKICAgICAgICAgICAgcmF3ID0gbS5ncm91cCgxKQogICAgICAgICAgICAjIFJlbW92ZSBpbmxpbmUgY29tbWVudDogc3BsaXQgb24gIiAjIiBidXQgbm90IGluc2lkZSBxdW90ZWQgc3RyaW5ncwogICAgICAgICAgICAjIFNpbXBsZSBoZXVyaXN0aWM6IHN0cmlwIGZyb20gZmlyc3QgIiAjIiB0aGF0IGFwcGVhcnMgYWZ0ZXIgYSBzcGFjZQogICAgICAgICAgICB2YWwgPSByZS5zdWIocidccysjLiokJywgJycsIHJhdykuc3RyaXAoKS5zdHJpcCgnIicpLnN0cmlwKCInIikKICAgICAgICAgICAgcmV0dXJuIHZhbCBpZiB2YWwgZWxzZSBkZWZhdWx0CiAgICAgICAgcmV0dXJuIGRlZmF1bHQKICAgIGtpbmQgICAgICAgICA9IGZpZWxkKCJraW5kIikKICAgIHdpcmVkX3JhdyAgICA9IGZpZWxkKCJ3aXJlZCIsICJ0cnVlIikKICAgIHdpcmVkICAgICAgICA9ICJmYWxzZSIgaWYgd2lyZWRfcmF3Lmxvd2VyKCkgPT0gImZhbHNlIiBlbHNlICJ0cnVlIgogICAgdG1wbCAgICAgICAgID0gZmllbGQoInRlbXBsYXRlIikKICAgIG91dCAgICAgICAgICA9IGZpZWxkKCJvdXQiKQogICAgcmVuZGVyZXIgICAgID0gZmllbGQoInJlbmRlcmVyIikKICAgIHJ1ICAgICAgICAgICA9IGZpZWxkKCJyZXN0YXJ0X3VuaXQiKQogICAgc2sgICAgICAgICAgID0gZmllbGQoInNoYV9rZXkiKQogICAgcGggICAgICAgICAgID0gZmllbGQoInBsYWNlaG9sZGVyX2NvbXBsZXRlbmVzcyIsICJmYWxzZSIpCiAgICBwcmludChmIntzaWR9XHR7a2luZH1cdHt3aXJlZH1cdHt0bXBsfVx0e291dH1cdHtyZW5kZXJlcn1cdHtydX1cdHtza31cdHtwaH0iKQo="

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

    local _surface_count=0 _wired_count=0 _skipped_count=0 _changed_count=0

    while IFS=$'\t' read -r _sid _kind _wired _template _out \
                              _renderer _restart_unit _sha_key _ph_complete; do
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
                        # Use _RECONCILE_CADDY_RELOAD flag for per-surface change tracking.
                        # The old before/after _RECONCILE_RESTART_UNITS size delta was unsound:
                        # dedup means a real change to a unit already in the list yields
                        # zero delta — silently undercounting changes (impacts P4b multi-surface).
                        local _before_caddy_reload="${_RECONCILE_CADDY_RELOAD:-0}"
                        reconcile_caddy_surface "$RECONCILE_TMPDIR" "$_tpl_src"
                        if [[ "${_RECONCILE_CADDY_RELOAD:-0}" -ne "$_before_caddy_reload" ]]; then
                            _changed_count=$((_changed_count + 1))
                        fi
                        ;;
                    *)
                        warn "reconcile_all: surface '$_sid' render_from_state — no handler yet (Phase 4b)"
                        ;;
                esac
                ;;
            persist_rendered|sync_verified|network_apply)
                warn "reconcile_all: surface '$_sid' kind=$_kind — not yet wired (Phase 4b)"
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
