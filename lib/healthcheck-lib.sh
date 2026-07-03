#!/usr/bin/env bash
# lib/healthcheck-lib.sh — shared healthcheck primitives (Phase 2 strangler-harden).
#
# Provides:
#   health_snapshot HEALTHCHECK_BIN SNAPSHOT_FILE   # Phase 3 (Decision 4)
#   health_regressions BASELINE_FILE POST_FILE      # Phase 3 (Decision 4)
#   healthcheck_poll_until TIMEOUT INTERVAL CMD...  # generic poll-until-pass loop
#
# Extracted from lib/reconcile.sh (health_snapshot / health_regressions) and
# lib/install-healthcheck.sh (the _healthcheck_poll loop shape, generalized as
# healthcheck_poll_until) — this repo's "3rd duplicate → extract" trigger: the
# poll-until-predicate-or-deadline shape appeared in lib/install-healthcheck.sh
# AND (inlined, pinned — see upgrade.sh's settle_healthcheck_with_retry header
# comment) twice more in upgrade.sh. upgrade.sh's inline
# _settle_hc_snapshot / _settle_hc_regressions are a DELIBERATE, DOCUMENTED
# 2-way pinned duplicate of health_snapshot/health_regressions below (#318:
# settle_healthcheck_with_retry must stay a single awk-extractable, self-
# contained function for tests/test_upgrade_zero_downtime.sh's Section F
# isolation tests) — do NOT collapse that pin into this lib.
#
# Sourced by lib/reconcile.sh and lib/install-healthcheck.sh. Not executable
# on its own.

# Guard against double-sourcing.
[[ "${_HEALTHCHECK_LIB_LOADED:-0}" -eq 1 ]] && return 0
_HEALTHCHECK_LIB_LOADED=1

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
# healthcheck_poll_until TIMEOUT INTERVAL CMD [ARGS...]
#
# Runs CMD (with ARGS) repeatedly (stdout/stderr discarded) until it exits 0,
# or until TIMEOUT seconds have elapsed since the first attempt — whichever
# comes first. Sleeps INTERVAL seconds between attempts (no sleep after a
# final failed attempt).
#
# Returns 0 as soon as CMD succeeds; 1 if the deadline is reached first.
#
# Generalizes the poll-until-predicate-or-deadline loop shape that appeared a
# 3rd time in lib/install-healthcheck.sh's _healthcheck_poll (the other two —
# upgrade.sh's settle_healthcheck_with_retry absolute-gate loop and its
# --snapshot-gate loop — stay inlined/pinned; see the file header).
#
# To pass env vars to CMD, prefix with `env VAR=val` (a real command, so `env`
# sets it for that exec) — a bare `VAR=val CMD` prefix would not survive being
# forwarded through "$@".
# ---------------------------------------------------------------------------
healthcheck_poll_until() {
    local _timeout="$1"
    local _interval="$2"
    shift 2
    local _deadline
    _deadline=$(( $(date +%s) + _timeout ))
    while :; do
        if "$@" >/dev/null 2>&1; then
            return 0
        fi
        if (( $(date +%s) > _deadline )); then
            return 1
        fi
        sleep "$_interval"
    done
}
