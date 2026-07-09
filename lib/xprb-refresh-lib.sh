#!/bin/bash
# lib/xprb-refresh-lib.sh — cross-probe (xprb_) bearer-token daily re-mint
# leg for oxpulse-partner-edge-refresh.sh (P3 of the 2026-07-08
# refresh-lib-extraction-strangler plan).
#
# Provides:
#   emit_xprb_failure REASON                    # centralizes the failure-counter call
#   xprb_curl_get_with_retry URL BEARER          # 3-attempt GET, 2s/5s backoff,
#                                                 # retry-on-transport-failure-or-5xx only
#   refresh_cross_probe_token                    # wrapper: age-gated fetch + persist
#
# Requires: lib/metric-sink-lib.sh (emit_metric — emit_xprb_failure calls it
# directly). The orchestrator MUST source metric-sink-lib.sh BEFORE this
# lib — oxpulse-partner-edge-refresh.sh does so (see its own header); this is
# a source-order contract, not a runtime check, so a caller that violates it
# fails at CALL time (emit_xprb_failure: command not found) rather than at
# source time.
#
# Requires (ambient globals/functions read — the caller must provide them):
#   PREFIX_ETC                       — token file lives at $PREFIX_ETC/cross-probe-token
#   BACKEND_URL                      — central base URL (GET target)
#   NODE_ID                          — this node's id (failure-counter label)
#   OXPULSE_CROSS_PROBE_TOKEN_TTL_SECS — TTL override (default 604800s/7d)
#   log                               — orchestrator logging function
#   read_service_token                — oxpulse-token-lib.sh (bearer source)
#   write_secret_atomic                — oxpulse-token-lib.sh (atomic mktemp+chmod+mv persist)
#   emit_metric                        — lib/metric-sink-lib.sh (see Requires above)
#
# Sourced by oxpulse-partner-edge-refresh.sh. Not executable on its own.
#
# ============================================================================
# Why this earns its own lib (single caller, unlike the near-zero-reuse
# Reality-key rotation block that stays inline per ADR-3 of the extraction
# plan): this is a distinct TRUST-BOUNDARY concern — bearer-token handling on
# a hostile-network-facing relay host (no hidepid; any local user can read
# /proc/<pid>/cmdline) — that reuses the metric-sink retry/failure
# primitives and benefits from file-level isolation for future security
# review (crypto-security-reviewer / CWE-214-class sweeps can scope to this
# one file instead of the whole 1000-line orchestrator). Boundary isolation,
# not code-reuse, is the justification.
#
# CROSS-REFERENCE (council LOW4, undeclared file contract): this lib WRITES
# $PREFIX_ETC/cross-probe-token (refresh_cross_probe_token, via
# write_secret_atomic). lib/cross-probe-lib.sh's _read_cross_probe_token
# READS the same physical path (there resolved from its own host script's
# ${_PREFIX_ETC}/cross-probe-token — a distinct variable name, same file-path
# convention) — a cross-repo-file contract between two DIFFERENT daily/60s
# processes, not a runtime function call, so nothing statically ties them
# together. Keep the 0600 perms + raw-token-string (no trailing newline,
# no JSON envelope) contract stable across both if either side changes it.
#
# CWE-214 (bearer-on-argv): xprb_curl_get_with_retry was hardened in P-sec1
# (PR #371, mirrors the merged bafb45e fix already applied to
# lib/cross-probe-lib.sh's _post_channel/_post_cross_probe) BEFORE this
# extraction — the `-K -`/here-string config-on-stdin form below is carried
# over verbatim, not re-mutated by this move. See
# tests/test_refresh_cross_probe_token.sh test13 for the regression guard
# (asserts the token never appears in the curl child's own argv).
# ============================================================================

# Guard against double-sourcing.
[[ "${_XPRB_REFRESH_LIB_LOADED:-0}" -eq 1 ]] && return 0
_XPRB_REFRESH_LIB_LOADED=1

# emit_xprb_failure reason — centralizes the metric call so every failure
# branch in refresh_cross_probe_token stays a one-liner.
emit_xprb_failure() {
    emit_metric "partner_edge_cross_probe_token_refresh_failure_total" \
        "partner_id=\"${NODE_ID}\",reason=\"$1\"" "1"
}

# xprb_curl_get_with_retry url bearer — mirrors opec's get_with_retry
# semantics (PR review round 2, gating MEDIUM): up to 3 attempts, short
# backoff (2s, then 5s), retry ONLY on a curl transport failure (DNS,
# connect, TLS, timeout) or an HTTP 5xx — a transient backend blip must not
# defer re-mint by a full day (the next daily tick). A 4xx is NEVER
# retried: auth/permission errors are deterministic, and burning the retry
# budget on one just delays surfacing a real misconfiguration.
#
# --max-time 15 per attempt (unchanged budget per try). On success (any
# transfer that completes, including a 4xx/5xx the caller still needs to
# see) prints "body\n%{http_code}" to stdout exactly like a single curl -w
# call, so the caller's existing tail/sed parsing is untouched. Returns 0
# when a transfer completed (any status); returns the last curl exit code
# when every attempt was a transport failure. This function does not know
# about log()/emit_metric() — same two-state-primitive contract as
# write_secret_atomic — the caller decides how to report the outcome.
xprb_curl_get_with_retry() {
    local url="$1" bearer="$2"
    local attempt out rc code delays=(2 5)
    for attempt in 1 2 3; do
        rc=0
        # CWE-214 hardening (2026-07-08 P-sec1, PR #371, mirrors the same fix
        # already applied to _post_channel/_post_cross_probe in lib/*.sh,
        # bafb45e): the Bearer token goes via `-K -` (curl config on stdin, a
        # bash here-string — no separate process ever holds the token as its
        # own argv) instead of `-H "Authorization: Bearer $bearer"`, which was
        # ps/proc-visible to any local user on the relay host for curl's
        # whole lifetime.
        out=$(curl -sS --max-time 15 -L \
            -K - \
            "$url" -w '\n%{http_code}' 2>&1 <<< "header = \"Authorization: Bearer ${bearer}\"") || rc=$?

        if [[ "$rc" -ne 0 ]]; then
            if [[ "$attempt" -lt 3 ]]; then
                sleep "${delays[$((attempt - 1))]}"
                continue
            fi
            printf '%s' "$out"
            return "$rc"
        fi

        code=$(printf '%s' "$out" | tail -n1)
        if [[ "$code" =~ ^5[0-9][0-9]$ && "$attempt" -lt 3 ]]; then
            sleep "${delays[$((attempt - 1))]}"
            continue
        fi

        # Transfer completed: success, a non-retryable 4xx, or a 5xx that
        # survived all retries — hand back to the caller as-is either way.
        printf '%s' "$out"
        return 0
    done
}

# refresh_cross_probe_token — age-gated daily re-mint of the xprb_ cross-probe
# bearer token (T2.4.c re-mint endpoint).
#
# Root cause 2026-07-01: the central mints cross_probe_token (xprb_) ONLY in
# the /api/partner/register response (persisted by hydrate.sh / install.sh),
# which runs once at first boot. TTL=7d → all 5 fleet edges (registered
# ~06-24 05:36) expired their tokens together, firing
# MeshCrossProbeRejectionStorm (stale_token 0.29/s) from 07-01 05:46 — the
# central's GET /api/partner/cross-probe-token re-mint endpoint (built for
# exactly this) had zero consumers anywhere in this repo. This function is
# that consumer: refresh the token daily, well before it expires.
#
# Cadence: refresh once the file is older than half the TTL (default
# 302400s = 3.5d of a 604800s/7d TTL) — cheap file-mtime check, no network
# call on the common "still fresh" path.
#
# COALESCE-PRESERVE (mirrors hydrate.sh MAJOR 2 / install.sh's cross-probe
# write site): ANY failure — curl non-2xx/timeout, missing/malformed token,
# no service token available — warns and leaves the existing file untouched.
# Never rm/truncate a working token on a transient failure; a revoked token
# simply 4xx's on the prober-report POST and is ignored there.
#
# NON-FATAL: no `die` in this function. Mirrors the 2026-05-13 heartbeat
# lesson (decoupled from keys-fetch, see refresh.sh) — this step must not be
# able to abort the script before later refresh work runs. Call as a plain
# statement (not `... || true`) — every internal branch already returns 0.
refresh_cross_probe_token() {
    local token_file="$PREFIX_ETC/cross-probe-token"
    local ttl_secs="${OXPULSE_CROSS_PROBE_TOKEN_TTL_SECS:-604800}"
    local refresh_after_secs=$(( ttl_secs / 2 ))

    local needs_refresh=1
    if [[ -f "$token_file" ]]; then
        local mtime age
        mtime=$(stat -c '%Y' "$token_file" 2>/dev/null \
            || stat -f '%m' "$token_file" 2>/dev/null || echo 0)
        age=$(( $(date +%s) - mtime ))
        if [[ "$age" -lt "$refresh_after_secs" ]]; then
            needs_refresh=0
            log "cross-probe token: age=${age}s < refresh threshold ${refresh_after_secs}s — skipping"
        fi
    fi

    [[ "$needs_refresh" -eq 1 ]] || return 0

    local svc_token
    svc_token=$(read_service_token 2>/dev/null || true)
    if [[ -z "$svc_token" ]]; then
        log "WARN cross-probe token refresh: no service token available — skipping (existing file, if any, preserved)"
        emit_xprb_failure "no_service_token"
        return 0
    fi

    # No `-f`: we want the HTTP status explicitly (below) rather than
    # having curl fold a 4xx/5xx into its own exit code — that lets us
    # log the status without ever touching the response BODY (HIGH-2:
    # this is a credential-issuing endpoint; a token-shaped-but-
    # unexpected body must never reach the log verbatim).
    local curl_rc=0 curl_out
    curl_out=$(xprb_curl_get_with_retry \
        "${BACKEND_URL}/api/partner/cross-probe-token" "${svc_token}") \
        || curl_rc=$?

    if [[ "$curl_rc" -ne 0 ]]; then
        log "WARN cross-probe token fetch failed (curl exit=${curl_rc}; existing file, if any, preserved)"
        emit_xprb_failure "fetch_failed"
        return 0
    fi

    local code body
    code=$(printf '%s' "$curl_out" | tail -n1)
    body=$(printf '%s' "$curl_out" | sed '$d')

    if [[ "$code" != "200" ]]; then
        # Status only — never the body (HIGH-2).
        log "WARN cross-probe token refresh: HTTP ${code} (existing file, if any, preserved)"
        emit_xprb_failure "http_${code}"
        return 0
    fi

    if [[ -z "$body" ]]; then
        # MED-3: an empty 200 body previously matched neither the success arm
        # nor the "malformed" arm — silently invisible.
        log "WARN cross-probe token refresh: empty response body on HTTP 200 (existing file, if any, preserved)"
        emit_xprb_failure "empty_response"
        return 0
    fi

    local new_token
    new_token=$(printf '%s' "$body" | jq -r '.cross_probe_token // empty' 2>/dev/null || true)

    if [[ -n "$new_token" && "$new_token" == xprb_* ]]; then
        # HIGH-1 / MED-5: the guarded shared helper (write_secret_atomic,
        # sourced from oxpulse-token-lib.sh) — every step of the
        # mktemp/write/chmod/mv sequence is explicitly checked inside it, so
        # a missing/unwritable $PREFIX_ETC can NEVER kill this `set -euo
        # pipefail` script via an uncaught mktemp failure. Called as an `if`
        # condition, so even without that internal guarding a nonzero return
        # would not trip `set -e` here either — belt-and-suspenders.
        local write_err
        if write_err=$(write_secret_atomic "$token_file" "$new_token" 0600 2>&1); then
            log "cross-probe token refreshed → $token_file (raw value redacted)"
        else
            log "WARN cross-probe token persist failed: $write_err (existing file, if any, preserved)"
            emit_xprb_failure "write_failed"
        fi
        return 0
    fi

    # HIGH-2: never log $body verbatim — it may contain a token-shaped
    # string from a misbehaving/misauthed response. A fixed-length sha256
    # prefix is enough to correlate/dedup without leaking a credential to
    # logs.
    local body_sha
    body_sha=$(printf '%s' "$body" | sha256sum 2>/dev/null | cut -c1-16)
    log "WARN cross-probe token refresh: missing/malformed cross_probe_token in response (body sha256=${body_sha:-unknown}...; existing file, if any, preserved)"
    emit_xprb_failure "malformed_response"
    return 0
}
