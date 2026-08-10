#!/bin/bash
# lib/metric-sink-lib.sh — Prometheus textfile-collector metric/gauge sink for
# oxpulse-partner-edge-refresh.sh (P1 of the 2026-07-08
# refresh-lib-extraction-strangler plan).
#
# Provides:
#   emit_metric NAME LABELS DELTA                        # cumulative counter
#                                                         # (state-file model, PR #328 MED-4)
#   emit_gauge NAME LABELS VALUE                          # current-state gauge, ATOMIC
#   _emit_prom_gauge_file BASENAME METRIC VALUE [LABELS]  # shared atomic gauge-textfile primitive
#
# Requires (ambient globals read — the caller must provide them):
#   TEXTFILE_DIR              — node_exporter textfile-collector dir; read directly
#                                by emit_metric (byte-for-byte ported, unchanged contract).
#   PARTNER_EDGE_TEXTFILE_DIR — env override resolved directly by _emit_prom_gauge_file
#                                (independent of the caller's $TEXTFILE_DIR — same
#                                resolution lib/reconcile.sh's _reconcile_emit_prom_gauge
#                                wrapper uses, so both the counter sink and the gauge sink
#                                honor the same single knob without the caller wiring it
#                                through).
#
# Sourced by oxpulse-partner-edge-refresh.sh. `_emit_prom_gauge_file` below
# adopted lib/reconcile.sh's original `_reconcile_emit_prom_gauge` shape verbatim
# at P1 (own-file-per-gauge, tmp+mv, `# TYPE %s gauge` format) as the canonical
# atomic-gauge primitive. P1b (2026-07-08 refresh-lib-extraction-strangler,
# in-arc follow-up) retargeted lib/reconcile.sh's `_reconcile_emit_prom_gauge`
# onto THIS `_emit_prom_gauge_file` (lazy call-time source, same convention as
# reconcile.sh's other lib deps) so there is exactly one gauge-textfile-writer
# implementation repo-wide (fitness: `rg 'TYPE %s gauge' lib/*.sh *.sh` → one hit,
# see tests/test_gauge_writer_fitness.sh). Not executable on its own.

# Guard against double-sourcing.
[[ "${_METRIC_SINK_LIB_LOADED:-0}" -eq 1 ]] && return 0
_METRIC_SINK_LIB_LOADED=1

# ============================================================================
# emit_metric — ported byte-for-byte from oxpulse-partner-edge-refresh.sh
# (pre-extraction). Do NOT "improve" this function's logic here; it carries a
# load-bearing fix (PR #328 MED-4) with its own equivalence-oracle test
# (tests/test_refresh_emit_metric_idempotent.sh). Any behavioral change
# belongs in a separate, explicitly-reviewed change.
# ============================================================================

# emit_metric name labels delta — increments a persisted Prometheus textfile
# counter (node_exporter textfile collector) and rewrites partner_edge.prom
# from scratch, atomically.
#
# PR review MED-4 on #328: the prior implementation blindly `>>`-appended a
# fresh `# TYPE <name> counter` + sample line on EVERY call, forever. Two
# daily failures produce TWO `# TYPE partner_edge_keys_fetch_failure_total`
# lines in the same file — invalid Prometheus exposition format (a metric
# family's TYPE line must appear exactly once, with all its samples
# contiguous). node_exporter's textfile collector does not skip just the bad
# family on a parse error — it drops the ENTIRE .prom file, silently
# blackholing every counter this script emits, including ones unrelated to
# the failure that caused the duplicate.
#
# Fix: persist cumulative counter state (name, labels) -> value in a small
# tab-separated side file, then regenerate partner_edge.prom fresh from that
# state on every call — one `# TYPE` line per metric name, its samples
# grouped directly under it, written atomically (tmp+mv, same idiom as the
# secret writes elsewhere in this script). This also makes the counters
# real monotonic counters (increase()/rate() over the scrape window shows an
# actual delta) instead of a flat "1" re-written every failing day.
#
# T12 independently proposed a per-run truncate-then-append fix for the same
# duplicate-TYPE-line bug (reset_metrics_file() wiping partner_edge.prom once
# at script start); superseded by #328's state-file model above, which is
# strictly better — it also survives ACROSS runs as real monotonic counters,
# where a per-run truncate would reset every counter to 0 on each invocation.
emit_metric() {
    local name="$1" labels="$2" delta="$3"
    [[ -d "$TEXTFILE_DIR" ]] || mkdir -p "$TEXTFILE_DIR" 2>/dev/null || return 0
    local prom_file="$TEXTFILE_DIR/partner_edge.prom"
    local state_file="$TEXTFILE_DIR/partner_edge.prom.state"

    # ---- merge (name, labels) -> cumulative value into the state file ----
    local state_tmp found=0 _n _l _v
    state_tmp=$(mktemp "${state_file}.XXXXXX" 2>/dev/null) || return 0
    if [[ -f "$state_file" ]]; then
        while IFS=$'\t' read -r _n _l _v || [[ -n "$_n" ]]; do
            [[ -z "$_n" ]] && continue
            # Defensive (PR review round 2, council LOW): a hand-edited or
            # otherwise tampered state file could carry a non-numeric 3rd
            # field. Without this guard, `_v + delta` under `set -euo
            # pipefail` throws "value too great for base" / a syntax error
            # and takes the WHOLE script down via an uncaught arithmetic
            # failure — the exact class of bug HIGH-1 fixed for the write
            # path, just one line lower. Reset to 0 instead of trusting it.
            [[ "$_v" =~ ^[0-9]+$ ]] || _v=0
            if [[ "$_n" == "$name" && "$_l" == "$labels" ]]; then
                _v=$(( _v + delta )); found=1
            fi
            printf '%s\t%s\t%s\n' "$_n" "$_l" "$_v"
        done < "$state_file" > "$state_tmp"
    fi
    if [[ "$found" -eq 0 ]]; then
        printf '%s\t%s\t%s\n' "$name" "$labels" "$delta" >> "$state_tmp"
    fi
    mv -f "$state_tmp" "$state_file" 2>/dev/null || { rm -f "$state_tmp" 2>/dev/null || true; return 0; }

    # ---- regenerate partner_edge.prom fresh, grouped by metric name ----
    local prom_tmp
    prom_tmp=$(mktemp "${prom_file}.XXXXXX" 2>/dev/null) || return 0
    {
        local -A _samples=()
        local -a _order=()
        while IFS=$'\t' read -r _n _l _v || [[ -n "$_n" ]]; do
            [[ -z "$_n" ]] && continue
            [[ -z "${_samples[$_n]+x}" ]] && _order+=("$_n")
            _samples[$_n]+="${_n}{${_l}} ${_v}"$'\n'
        done < "$state_file"
        local _name
        for _name in "${_order[@]}"; do
            printf '# TYPE %s counter\n' "$_name"
            printf '%s' "${_samples[$_name]}"
        done
    } > "$prom_tmp" 2>/dev/null
    # T3 review round 3: mktemp creates $prom_tmp at mode 0600 (mkstemp,
    # umask-independent), and a bare mv carries that mode onto $prom_file — so
    # after the first emit the file drops to 0600 root:root and node_exporter's
    # textfile collector (an unprivileged system user) loses read access,
    # blacking out EVERY partner_edge_* metric on the node exactly like the
    # duplicate-TYPE-line bug this rewrite fixed. Restore the world-readable
    # 0644 the prior `>>` append produced under root's default umask 022.
    if mv -f "$prom_tmp" "$prom_file" 2>/dev/null; then
        chmod 0644 "$prom_file" 2>/dev/null || true
    else
        rm -f "$prom_tmp" 2>/dev/null || true
    fi
}

# metric_sink_discard_pre328_prom — one-shot migration for files the #328 fix
# cannot repair.
#
# #328 fixed emit_metric, but it did not clean up what the broken version had
# already written. Measured 2026-08-08 on all five production edges: every one
# carries a partner_edge.prom dated 2026-05-26 or 2026-06-17 with duplicate
# `# TYPE` lines and duplicate series — invalid exposition, exactly the format
# the fix exists to prevent.
#
# Nothing repairs them. emit_metric regenerates the file from its state side
# file, but these predate the state file (none of the five has one), and the
# only callers are FAILURE counters — keys-fetch and heartbeat. No failure, no
# call, no regeneration. Two of the five have sat untouched since May.
#
# That was harmless while nothing read the directory. It stops being harmless
# the moment the collector added in #570 reaches a node: the textfile collector
# rejects a duplicate series by discarding the WHOLE file and raising
# node_textfile_scrape_error, so the first thing the new collector would report
# is a parse error instead of data.
#
# The absence of a state file is what makes this safe to key on. partner_edge.prom
# is written by emit_metric alone (emit_gauge owns its own per-metric files), and
# emit_metric has written the state file beside it since #328. So .prom without
# .state means "written by the pre-#328 code and unrecoverable" — its counter
# values exist nowhere else and cannot be reconstructed. Deleting is strictly
# better than keeping: a missing file collects nothing, an invalid one collects
# nothing AND reports an error that will read as a broken collector.
#
# Self-limiting by construction: the next emit_metric writes both files, after
# which this is a single `[[ -f ]]` test that always returns early.
#
# Prints the discarded path on stdout, nothing when there was none, and always
# returns 0. It deliberately does not signal via exit code: every caller runs
# under `set -e`, and a "yes, I cleaned something" non-zero return would take
# the whole refresh down on the one run where it had work to do.
metric_sink_discard_pre328_prom() {
    local dir="${1:-$TEXTFILE_DIR}"
    local prom_file="$dir/partner_edge.prom"
    local state_file="$dir/partner_edge.prom.state"

    [[ -f "$prom_file" ]]  || return 0
    [[ -f "$state_file" ]] && return 0

    if rm -f "$prom_file" 2>/dev/null; then
        printf '%s' "$prom_file"
    fi
    return 0
}

# ============================================================================
# emit_gauge / _emit_prom_gauge_file — current-state GAUGE emission, ATOMIC.
#
# Pre-extraction, oxpulse-partner-edge-refresh.sh's emit_gauge wrote via a
# plain `printf ... > "$prom_file"` — no tmp+mv. A process crash or disk-full
# mid-write between truncation and the new content landing could leave a
# 0-byte or half-written .prom file, which node_exporter's textfile collector
# treats as a parse error and drops — the same blackholing class emit_metric's
# PR #328 fix already cured for counters, just left open on the gauge side.
# The architecture council flagged re-porting that duplicate-with-a-known-bug
# verbatim into a new fleet-distributed lib (ADR-7 of the extraction plan) —
# so this lib authors emit_gauge ATOMIC instead, adopting
# lib/reconcile.sh:1332-1352's `_reconcile_emit_prom_gauge` shape (own file
# per gauge, `_tmp="${_f}.tmp.$$"` + `mv -f`, same `# TYPE %s gauge` format).
# Output is observably IDENTICAL to the old emit_gauge on the happy path —
# just race-free.
# ============================================================================

# _emit_prom_gauge_file BASENAME METRIC VALUE [LABELS] — shared textfile-
# collector gauge writer. Each metric gets its OWN .prom file (never
# partner_edge.prom, which emit_metric owns and regenerates from its own
# state-file contract): interleaving a differently-typed metric into a file
# another writer truncates/regenerates would race and risk duplicate `# TYPE`
# lines, corrupting the whole file for node_exporter's textfile collector.
# Atomic tmp+mv — this IS lib/reconcile.sh's _reconcile_emit_prom_gauge,
# generalized to a shared name/location so P1b (in-arc follow-up) can
# retarget reconcile.sh onto it with a straight rename, zero argument-order
# change. Skips silently when the textfile dir is unwritable/absent
# (non-fatal), matching emit_metric's own failure posture.
_emit_prom_gauge_file() {
    local _basename="$1" _metric="$2" _value="$3" _labels="${4:-}"
    # Optional _labels (e.g. kind="real") - backward-compatible: 3-arg callers emit
    # the identical unlabeled line they always did.
    printf '%s\t%s\n' "$_labels" "$_value" | _emit_prom_gauge_series "$_basename" "$_metric"
}

# _emit_prom_gauge_series BASENAME METRIC — the MULTI-SAMPLE form, and the sole
# writer of the gauge textfile shape (_emit_prom_gauge_file above is its
# one-sample delegate, which is what keeps tests/test_gauge_writer_fitness.sh's
# single-implementation invariant true).
#
# Samples arrive on stdin, one per line, as "LABELS<TAB>VALUE"; an empty LABELS
# field emits an unlabeled sample.
#
# WHY THIS EXISTS (measured on the live fleet, 2026-08-11): every gauge here
# gets its OWN file, truncated on each write. A caller emitting one series PER
# SUBJECT — `partner_edge_container_unhealthy{container="..."}` across five
# containers — therefore wrote the same file five times and only the LAST
# subject survived. ruoxp and rvpn both carried exactly one sample,
# `container="oxpulse-partner-xray"` (alphabetically last), while the healer's
# own `..._containers_seen` said 5. Four of five containers had no health
# series at all, so a wedged coturn would have been invisible in a metric that
# looked present and healthy — a detector reading as coverage.
#
# One file, one `# TYPE` line, every sample, still atomic (tmp+mv).
_emit_prom_gauge_series() {
    local _basename="$1" _metric="$2"
    local _dir="${PARTNER_EDGE_TEXTFILE_DIR:-/var/lib/prometheus-node-exporter/textfile}"
    [[ -d "$_dir" ]] || mkdir -p "$_dir" 2>/dev/null || return 0
    local _f="$_dir/$_basename"
    local _tmp="${_f}.tmp.$$"
    { printf '# TYPE %s gauge\n' "$_metric"
      local _line _l _v
      # Split by hand rather than with `IFS=$'\t' read -r _l _v`: a TAB is IFS
      # WHITESPACE, so read strips a leading one and an UNLABELED sample
      # ("\tVALUE") arrives as _l=VALUE, _v='' — dropped. The file then carries
      # a `# TYPE` line and no sample at all, which is how an unlabeled gauge
      # silently disappears while every labelled one looks fine.
      while IFS= read -r _line; do
          _l="${_line%%$'\t'*}"; _v="${_line#*$'\t'}"
          [[ -n "$_v" ]] || continue
          if [[ -n "$_l" ]]; then
              printf '%s{%s} %s\n' "$_metric" "$_l" "$_v"
          else
              printf '%s %s\n' "$_metric" "$_v"
          fi
      done
    } >"$_tmp" 2>/dev/null && mv -f "$_tmp" "$_f" 2>/dev/null || rm -f "$_tmp" 2>/dev/null
    return 0
}

# emit_gauge NAME LABELS VALUE — emit a current-state GAUGE to its own
# textfile, TRUNCATED each run (via _emit_prom_gauge_file's atomic tmp+mv) so
# exactly one sample per series survives. A gauge must not share the
# append-only partner_edge.prom (emit_metric): re-emitting the same series
# every daily run would accumulate duplicate lines and node_exporter would
# reject the whole file. One file per gauge name keeps it idempotent.
# Convenience wrapper — the basename=NAME.prom case of _emit_prom_gauge_file
# above; argument order preserved from the pre-extraction emit_gauge so every
# existing call site (e.g. refresh.sh's _emit_sfu_applied_gauge) is unchanged.
emit_gauge() {
    local name="$1" labels="$2" value="$3"
    _emit_prom_gauge_file "${name}.prom" "$name" "$value" "$labels"
}
