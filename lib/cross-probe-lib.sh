#!/bin/bash
# lib/cross-probe-lib.sh — P3b edge cross-probe (peer-mesh) loop.
#
# Extracted verbatim from oxpulse-channels-health-report.sh (strangler-fig, no
# behaviour change). Probes each roster peer's TURNS:443 relay + STUN/UDP port
# and reports a prober-attributed channel-health verdict to the central via
# POST /api/partner/channel-health, authenticated by the scoped xprb_
# cross-probe bearer token.
#
# Provides:
#   _read_cross_probe_token                                  # stdout: token; exit 1 if none
#   _peer_roster_file                                        # stdout: roster path
#   _read_peer_probe_offset                                  # stdout: rotation offset (int)
#   _write_peer_probe_state MODE [PROBED OK REJECTED POST_4XX OFFSET DROPPED]
#   _probe_peer_coturn  TURNS_HOST TURNS_PORT TURN_SECRET(unused) [DIAL_IP]
#   _probe_peer_udp_stun STUN_HOST STUN_PORT [DIAL_IP]
#   _post_cross_probe   TARGET_NODE_ID HANDSHAKE_OK RTT_MS TOKEN [CHANNEL_NAME]
#   _run_peer_probe_loop                                     # call as `_run_peer_probe_loop || true`
#
# Requires (ambient globals read — the orchestrator must provide them):
#   NODE_ID               — this prober's node id (_post_cross_probe body)
#   DRY_RUN               — 1 = print body, skip POST (_post_cross_probe)
#   CURL_TRACE            — 1 = (dry-run only) print Authorization header to stderr
#   STATE_DIR             — state dir for peer-roster.json / peer-probe-mode.env
#   _PREFIX_ETC           — etc prefix (cross-probe-token file default location)
#   OXPULSE_BACKEND_API   — central base URL (POST target)
#   OXPULSE_CROSS_PROBE_TOKEN / _CROSS_PROBE_TOKEN_FILE   — token override / file path
#   _PEER_ROSTER_FILE     — roster path override
#   OXPULSE_PEER_PROBE_OFFSET                             — offset override (tests)
#   OXPULSE_TURN_SECRET   — shared TURN secret override (else docker exec read)
#   OXPULSE_PEER_PROBE_MAX / OXPULSE_PEER_PROBE_REJECT_HEADROOM
#   OXPULSE_PEER_PROBE_TIMEOUT / OXPULSE_PEER_PROBE_POST_TIMEOUT
#   OXPULSE_PEER_UDP_STUN_TIMEOUT / OXPULSE_COTURN_STUN_PORT
#   OXPULSE_OPENSSL_BIN   — openssl override (prober-host TLS leg)
#
# Requires (functions from sibling libs / the orchestrator — resolved at CALL
# time by whatever is sourced into the process; this lib does NOT source them):
#   log, warn           — orchestrator logging (oxpulse-channels-health-report.sh)
#   _elapsed_ms         — channel-health-lib.sh  (RTT helper; inline pre-P2)
#   _host_is_internal   — peer-ip-guard-lib.sh   (SSRF dial-time recheck; inline pre-P1)
#
# Sourced by oxpulse-channels-health-report.sh. Not executable on its own.
# NOTE: no code path here echoes/logs the server-side HMAC secret or the token
# file's raw contents to a log — the only bearer print is the DRY_RUN+CURL_TRACE
# debug seam in _post_cross_probe (both off in production). See
# tests/test_cross_probe_state_lib.sh (secret-non-leak fitness grep).
#
# CROSS-REFERENCE (council LOW4, undeclared file contract, 2026-07-08
# refresh-lib-extraction-strangler P3): _read_cross_probe_token above READS
# ${_PREFIX_ETC}/cross-probe-token (this script's own prefix var). The
# WRITER of that same physical path is lib/xprb-refresh-lib.sh's
# refresh_cross_probe_token, sourced by the SEPARATE daily
# oxpulse-partner-edge-refresh.sh process (its own $PREFIX_ETC var — same
# file-path convention, different variable, different script). A
# cross-repo-file contract between two independently-scheduled processes
# (60s peer-probe loop here vs. daily re-mint there), not a runtime function
# call — nothing statically ties them together. Keep the 0600 perms +
# raw-token-string (no trailing newline, no JSON envelope) contract stable
# on both sides if either changes it.

# Guard against double-sourcing.
[[ "${_CROSS_PROBE_LIB_LOADED:-0}" -eq 1 ]] && return 0
_CROSS_PROBE_LIB_LOADED=1

# ============================================================================
# P3b — edge cross-probe loop: probe each roster peer's TURNS:443 relay and
# report a prober-attributed channel-health verdict to the central.
#
# Consumes (persisted by hydrate.sh / install.sh from the P3a register response):
#   - peer-roster.json  ($STATE_DIR/peer-roster.json, 0644) — server-curated
#       array of {node_id, turns_host, turns_port:443} PUBLIC endpoints only.
#   - cross-probe-token ($PREFIX_ETC/cross-probe-token, 0600) — scoped xprb_
#       bearer for the prober-attributed POST.
# Both absent → loop self-skips (fail-closed: a pre-P3a central ships neither).
#
# Security invariants (mirror probe_ch4):
#   * HMAC mint via env-$K/python3 (OXPULSE_HMAC_BIN seam) — secret NEVER on argv.
#   * Roster hosts are UNTRUSTED: SSRF dial-time DNS recheck rejects any host
#     that resolves to loopback / RFC-1918 / link-local / ULA / ::1 BEFORE the
#     dial (closes P2-SEC-CR-001 at the actual dialer — defence-in-depth beyond
#     the central's string-only classifier, which does no DNS resolution).
#   * No shell interpolation of roster values into the dial — jq --arg builds
#     the report body; turnutils_uclient args are quoted.
# ============================================================================

# ---------- resolve cross-probe token ----------
# OXPULSE_CROSS_PROBE_TOKEN env (test/operator override) wins; else the 0600
# file. Empty → caller skips the whole loop.
_read_cross_probe_token() {
    if [[ -n "${OXPULSE_CROSS_PROBE_TOKEN:-}" ]]; then
        printf '%s' "$OXPULSE_CROSS_PROBE_TOKEN"
        return 0
    fi
    local f="${_CROSS_PROBE_TOKEN_FILE:-${_PREFIX_ETC}/cross-probe-token}"
    if [[ -r "$f" ]]; then
        local _token
        _token=$(cat "$f" 2>/dev/null || true)
        # Runtime validation of the cross-process file contract
        # (writer: lib/xprb-refresh-lib.sh refresh_cross_probe_token).
        # Contract: 0600 perms, raw-token-string, no trailing newline,
        # xprb_ prefix. A drift would fail silently at read time without
        # this guard — see #433.
        if [[ -z "$_token" ]]; then
            log "WARNING: _read_cross_probe_token: $f is empty — token not minted yet?"
            return 1
        fi
        if [[ "$_token" != xprb_* ]]; then
            log "WARNING: _read_cross_probe_token: $f content lacks xprb_ prefix — file contract drift?"
            return 1
        fi
        printf '%s' "$_token"
        return 0
    fi
    return 1
}

# ---------- resolve peer-roster path ----------
_peer_roster_file() {
    local state_dir="${STATE_DIR:-/var/lib/oxpulse-partner-edge}"
    printf '%s' "${_PEER_ROSTER_FILE:-$state_dir/peer-roster.json}"
}

# ---------- peer-probe-mode state file ----------
# Records the peer-probe cycle outcome atomically (mktemp+rename within the dir).
# Does NOT clobber the self-probe marker (coturn-probe-mode.env) — separate file.
#
# MAJOR 1 (marker truthfulness under SIGTERM): the systemd oneshot can be
# SIGTERM'd mid-loop when it overruns TimeoutStartSec. This writer is called at
# THREE points so the marker reflects REALITY even on partial completion:
#   1. mode=started  — written BEFORE the peer loop (running marker).
#   2. mode=started  — re-written per peer with updated running counts (so a
#      SIGTERM between peers leaves accurate partial counts, not a stale "peer").
#   3. mode=peer      — written once the loop completes normally (terminal).
# An EXIT/TERM trap (set in _run_peer_probe_loop) additionally stamps
# mode=interrupted if the process dies while still in mode=started — so a
# "peer" (complete) marker is NEVER left behind by a killed loop.
#
# Positional args (all optional, default 0/empty) — backward compatible; older
# call sites pass only the first four:
#   $1 mode  $2 probed  $3 ok  $4 rejected  $5 post_4xx  $6 offset  $7 dropped
_write_peer_probe_state() {
    local mode="$1"
    local probed="${2:-0}"
    local ok="${3:-0}"
    local rejected="${4:-0}"
    local post_4xx="${5:-0}"
    local offset="${6:-0}"
    local dropped="${7:-}"
    local state_dir="${STATE_DIR:-/var/lib/oxpulse-partner-edge}"
    local state_file="$state_dir/peer-probe-mode.env"
    mkdir -p "$state_dir" 2>/dev/null || return 0
    local tmp
    tmp=$(mktemp -p "$state_dir" peer-probe-mode.XXXXXX 2>/dev/null) || return 0
    {
        echo "# Generated by oxpulse-channels-health-report.sh — do not edit"
        printf 'PEER_PROBE_MODE=%s\n' "$mode"
        printf 'PEER_PROBE_PROBED=%s\n' "$probed"
        printf 'PEER_PROBE_OK=%s\n' "$ok"
        printf 'PEER_PROBE_REJECTED=%s\n' "$rejected"
        # MINOR 6: persistent 4xx (revoked token → endless swallowed warns) is now
        # observable. 1 = at least one peer POST returned 4xx this cycle.
        printf 'PEER_PROBE_POST_4XX=%s\n' "$post_4xx"
        # MINOR 5: rotation offset persisted so the NEXT cycle starts where this
        # one stopped — peers beyond the cap are eventually covered (no silent
        # permanent truncation of the roster tail).
        printf 'PEER_PROBE_OFFSET=%s\n' "$offset"
        # MINOR 5: node_ids dropped (beyond the cap) THIS cycle, by name — so the
        # truncation is visible, not a bare count.
        printf 'PEER_PROBE_DROPPED=%s\n' "$dropped"
        printf 'PEER_PROBE_AT=%s\n' "$(date +%s)"
    } > "$tmp"
    chmod 0640 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$state_file" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
}

# ---------- probe one peer's TURNS:443 relay ----------
# Args: turns_host turns_port turn_secret(unused)
# Echoes "<handshake_ok>\t<rtt_ms>"  (handshake_ok = true|false|skip).
#
# TLS-handshake reachability probe via `openssl s_client` on the PROBER HOST:
#
#   openssl s_client -connect <host>:<port> -servername <host> \
#                    -verify_return_error -brief </dev/null
#
#   -connect/-servername  caddy-l4 SNI-muxes :443 by SNI → routes to the peer's
#       coturn. openssl sends SNI = the -servername hostname.
#   -verify_hostname <host>  check the cert SAN matches the hostname (rustls always
#       SAN-checks; -verify_return_error ALONE does chain-but-not-hostname, so
#       without this a valid-chain / wrong-SAN cert would pass here yet fail at
#       hub → the two probers disagree, SEC-CR-322-01).
#   -verify_return_error  hard-fail (non-zero exit) on any verification error,
#       trusting the host system CA store. Together with -verify_hostname this
#       MIRRORS hub's probe_tls_allocate (rustls + webpki-roots: chain AND SAN,
#       never danger_accept_invalid_certs) so the two probers agree on coturn-tls.
#   -brief </dev/null  one handshake, no interactive stdin, concise output.
#
# WHY NOT turnutils_uclient -S (the original #306 leg): coturn 4.6.3
# turnutils_uclient does NOT send SNI when dialing TURNS over TLS, so caddy-l4's
# SNI-mux cannot pick a route and answers EVERY probe — even the edge's OWN :443
# — with a TLS "internal error" alert (exit 255). The 30/30 bash tests mocked
# turnutils so never caught it; edge-d (first real bash prober, 2026-06-16)
# surfaced it: host openssl/curl complete TLS1.3+SNI to the same endpoints while
# in-container turnutils fails. openssl is the host tool that drives the SNI-mux.
#
# Signal difference vs hub: hub additionally does a TURN Allocate (auth)
# after the TLS handshake; this leg stops at TLS+cert. The only divergence is a
# peer whose TLS is up but coturn auth is broken (rare; shared TURN_SECRET is
# stable) — hub would report it down, this leg up, the quorum then DISAGREES
# → no withdrawal (conservative/safe). All other failure modes (down/blackholed
# :443, expired/mismatched cert, non-coturn backend) agree.
#
# SEC-CR-302 (DNS-rebinding TOCTOU) — FIXED (PR #324, 2026-06-16, see
# docs/FOLLOWUPS.md §Q): _host_is_internal ECHOES the first vetted public IP
# on its allow path; the peer loop captures it as $4/dial_ip below and PINS
# the dial to that IP on both probe legs — openssl never re-resolves the
# hostname, so the resolve-then-dial window is closed. caddy-l4 still routes
# by SNI and the cert SAN is still checked against the hostname (`-connect
# <vetted-IP>:<port> -servername <hostname> -verify_hostname <hostname>`).
# tests/test_cross_probe_loop.sh test16 asserts the pin. No longer blocking —
# the loop may run default-ON fleetwide. Residual: the `${4:-$turns_host}`
# fallback below (older call sites / tests that don't pass dial_ip) keeps the
# pre-#324 re-resolve behavior on that path only — the live _run_peer_probe_loop
# call site always passes $vetted_ip, so production is not exposed.
_probe_peer_coturn() {
    local turns_host="$1"
    local turns_port="$2"
    # $3 (turn_secret) is accepted for caller-signature stability but UNUSED: the
    # TLS leg is a TLS-handshake reachability probe (NOT a TURN Allocate), so no
    # ephemeral credential is minted. See the header comment for why turnutils was
    # replaced by openssl.
    # $4 (dial_ip) — the SSRF-vetted IP from _host_is_internal. We dial THIS IP
    # (SEC-CR-322-02) so openssl does not re-resolve the hostname; SNI + SAN-check
    # keep using the hostname. Falls back to the hostname when absent (older
    # call sites / tests) — that path keeps the pre-322-02 re-resolve residual.
    local dial_ip="${4:-$turns_host}"
    local t0 t1 exit_code rtt_ms ossl_out
    local ossl_bin="${OXPULSE_OPENSSL_BIN:-openssl}"

    # openssl runs on the PROBER HOST (the coturn container ships no openssl, and
    # the host always has it). Graceful skip if absent — emit NO row rather than a
    # false negative (a missing prober tool must never look like a down peer).
    if ! command -v "$ossl_bin" >/dev/null 2>&1; then
        warn "peer-probe: '$ossl_bin' not on host PATH — skipping coturn-tls leg for $turns_host (no row emitted; NOT a false negative)"
        printf 'skip\t0'
        return 0
    fi

    # openssl -connect targets the SSRF-vetted IP (dial_ip), NOT the hostname, so
    # openssl never re-resolves (DNS-rebind TOCTOU closed). -connect needs a
    # bracketed IPv6 literal ([::1]:443); a dotted-quad / fallback hostname is bare.
    local connect_target="$dial_ip"
    [[ "$dial_ip" == *:* ]] && connect_target="[$dial_ip]"

    t0="${EPOCHREALTIME}"
    # TLS handshake + public-CA chain verification + hostname/SAN match against the
    # peer's caddy-l4 :443 with SNI = hostname (caddy-l4 SNI-muxes :443 → routes to
    # the peer's coturn). This MIRRORS hub's probe_tls_allocate TLS layer
    # (rustls + webpki-roots: chain AND SAN, never danger_accept_invalid_certs) so
    # the two probers make the SAME trust decision on coturn-tls:
    #   -verify_return_error  hard-fail (non-zero exit) on any verification error
    #   -verify_hostname      check the cert SAN matches the hostname — WITHOUT this
    #     openssl chain-verifies but accepts a valid-chain / wrong-SAN cert (exit 0)
    #     while rustls rejects it (SEC-CR-322-01); the two probers would then
    #     DISAGREE on a misrouted/catch-all cert. With it, both fail-closed.
    # Probe timeout default 8s — see _run_peer_probe_loop BUDGET block.
    # NOTE: capture is command-substitution + `$?` — do NOT pipe openssl through
    # tail/grep, or `$?` becomes the pipe-tail's status and every failure reads UP.
    ossl_out=$(timeout "${OXPULSE_PEER_PROBE_TIMEOUT:-8}" \
        "$ossl_bin" s_client \
            -connect "${connect_target}:${turns_port}" \
            -servername "$turns_host" \
            -verify_hostname "$turns_host" \
            -verify_return_error -brief </dev/null 2>&1)
    exit_code=$?
    t1="${EPOCHREALTIME}"
    rtt_ms=$(_elapsed_ms "$t0" "$t1")

    # exit 0 == TLS handshake completed AND the peer cert chained to a trusted
    # public CA (system store) AND SNI matched. A down/blackholed :443, an
    # expired/mismatched cert, or a non-TLS backend all exit non-zero → false.
    # Empirically verified on edge-d 2026-06-16: up→0, bogus→1, wrong-SNI→1.
    if [[ "$exit_code" -eq 0 ]]; then
        printf 'true\t%d' "$rtt_ms"
    else
        warn "peer-probe: $turns_host:$turns_port coturn-tls handshake/verify failed (exit=$exit_code): $(printf '%s' "$ossl_out" | tail -n1 | tr -d '\r')"
        printf 'false\t%d' "$rtt_ms"
    fi
}

# ---------- probe one peer's STUN/UDP port (coturn-udp leg) ----------
# Args: stun_host stun_port
# Echoes "<handshake_ok>\t<rtt_ms>"  (handshake_ok = true|false).
#
# Uses a plain STUN Binding request (turnutils_stunclient, no HMAC/auth needed)
# to verify UDP reachability of the peer's coturn on port 3478.  This is a
# connectivity probe, NOT an allocation probe — no TURN credentials are required
# and no allocation is created.  The signal is "UDP path to the peer's coturn
# ingress is open from THIS edge's vantage", which is exactly what the central
# needs for a second distinct prober on the coturn-udp transport.
#
# Target set: SAME roster as the TLS leg (_run_peer_probe_loop provides the
# SSRF-vetted turns_host — no new target source, P2-SEC-CR-001 unchanged).
#
# RU-edge note: a RU edge probing peers over UDP can only be advisory — it
# cannot unilaterally withdraw a peer (central requires ≥2 distinct probers).
# Worst-case a compromised RU edge reports false negatives; the quorum still
# needs hub + at least one other clean edge to agree.  This is the same
# §P4-SEC-CR-301 self-declared-geo caveat already accepted for the TLS leg;
# the UDP leg does NOT widen it.
#
# SSRF note: the SSRF recheck (_host_is_internal) runs ONCE per peer in
# _run_peer_probe_loop BEFORE any dial; this function is called AFTER that
# guard.  Re-running the guard here would add a redundant 3s getent wait with
# no security benefit — the UDP dial uses the same already-vetted IP.
# $3 (dial_ip) — the SSRF-vetted IP; STUN dials it directly so turnutils does
# not re-resolve the hostname (SEC-CR-322-02; STUN has no SNI so no hostname is
# needed). Falls back to the hostname when absent (older call sites / tests).
_probe_peer_udp_stun() {
    local stun_host="$1"
    local stun_port="$2"
    local dial_ip="${3:-$stun_host}"
    local t0 t1 exit_code rtt_ms stun_out

    t0="${EPOCHREALTIME}"
    # OXPULSE_PEER_UDP_STUN_TIMEOUT default 5s (vs 8s for TLS Allocate) — the
    # UDP Binding round-trip is a single packet exchange; 5s is ample even
    # under transient loss.  This keeps the per-peer budget increase to 13s
    # (5s probe + 8s POST) on top of the existing TLS leg, giving a worst-case
    # per-peer total of 32s (was 19s) and a full cycle cap=2 worst case of:
    #   32×2 + 3×2 + 10 = 80s ≤ TimeoutStartSec=90.
    # The bounding timeout runs INSIDE the container: an outer
    # `timeout N docker exec …` kills only the docker CLIENT, and the exec'd
    # process keeps running in the container forever. turnutils_stunclient
    # waits indefinitely when the Binding gets no answer, so every timed-out
    # probe leaked one process — 120 leaked stunclients (oldest 2.8 days,
    # each squatting a UDP port in coturn's 49152-65535 relay range) found on
    # an edge on 2026-08-17. The outer timeout stays as a +2s belt for a hung
    # docker daemon; exit 124 still classifies as timeout either way.
    stun_out=$(timeout "$(( ${OXPULSE_PEER_UDP_STUN_TIMEOUT:-5} + 2 ))" \
        docker exec oxpulse-partner-coturn \
        timeout "${OXPULSE_PEER_UDP_STUN_TIMEOUT:-5}" \
        turnutils_stunclient "$dial_ip" -p "$stun_port" \
        2>&1)
    exit_code=$?
    t1="${EPOCHREALTIME}"
    rtt_ms=$(_elapsed_ms "$t0" "$t1")

    if [[ "$exit_code" -eq 0 ]]; then
        printf 'true\t%d' "$rtt_ms"
    else
        warn "peer-probe udp: $stun_host:$stun_port STUN failed (exit=$exit_code): $(printf '%s' "$stun_out" | tail -n2 | tr '\n' ' ')"
        printf 'false\t%d' "$rtt_ms"
    fi
}

# ---------- POST a prober-attributed cross-probe report ----------
# Mirrors _post_channel but uses the cross_probe_token (xprb_) bearer and the
# CrossProbeReportRequest body. ALL untrusted values (target node_id / host) go
# through jq --arg / --argjson — never shell-interpolated into the request.
#
# Args: target_node_id handshake_ok rtt_ms token [channel_name]
#   channel_name defaults to "coturn" (TLS leg); pass "coturn-udp" for the UDP leg.
#   The same token, prober_node_id, and POST endpoint are used for both legs —
#   no new auth path is introduced.
_post_cross_probe() {
    local target_node_id="$1"
    local handshake_ok="$2"     # "true" | "false" (JSON bool)
    local rtt_ms="$3"
    local token="$4"
    local channel_name="${5:-coturn-tls}"   # "coturn-tls" | "coturn-udp" (both callers pass explicitly)

    local probed_at
    probed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    local body
    body=$(jq -nc \
        --arg prober "$NODE_ID" \
        --arg target "$target_node_id" \
        --arg ch "$channel_name" \
        --argjson ok "$handshake_ok" \
        --argjson rtt "$rtt_ms" \
        --arg ts "$probed_at" \
        '{prober_node_id:$prober, target_node_id:$target, channel_name:$ch, handshake_ok:$ok, rtt_ms:$rtt, probe_mode:"peer", probed_at:$ts}')

    if [[ "$DRY_RUN" -eq 1 ]]; then
        printf '%s\n' "$body"
        if [[ "$CURL_TRACE" -eq 1 ]]; then
            printf 'Authorization: Bearer %s\n' "$token" >&2
        fi
        return 0
    fi

    local http_code
    # --max-time 8 (was 15) — the cross-probe POST slice of the per-peer budget
    # (getent 3 + probe 8 + post 8 = 19s/peer); see _run_peer_probe_loop BUDGET.
    # CWE-214 hardening (2026-07-08 review, low-severity accepted-residual
    # closed): the Bearer token goes via `-K -` (curl config on stdin, a bash
    # here-string — no separate process ever holds the token as its own argv)
    # instead of `-H "Authorization: Bearer $token"`, which was ps/proc-visible
    # to any local user on the relay host for curl's whole lifetime.
    http_code=$(curl -s -o /dev/null -w '%{http_code}' \
        --max-time "${OXPULSE_PEER_PROBE_POST_TIMEOUT:-8}" \
        -X POST \
        -H 'Content-Type: application/json' \
        -K - \
        -d "$body" \
        "${OXPULSE_BACKEND_API}/api/partner/channel-health" \
        2>/dev/null <<< "header = \"Authorization: Bearer $token\"" || echo '000')

    if [[ "$http_code" =~ ^2 ]]; then
        log "cross-probe target=$target_node_id reported OK (HTTP $http_code)"
        return 0
    elif [[ "$http_code" == "429" || "$http_code" == "408" ]]; then
        # TRANSIENT (RFC 6585): rate-limited / request-timeout — NOT a revoked
        # token. The central sizes a dedicated channel-health limiter and sends
        # Retry-After; the 60s timer is our back-off, so just skip this tick and
        #
        # CROSS-REFERENCE (PR2 finding 4b — do NOT unify with the other retry
        # policies in this repo): this bash-level status-code carve-out is
        # DELIBERATELY separate from upgrade.sh/install.sh's RETRY_OPTS
        # (bootstrap-tier lib-loader fetches only, uses curl's own native
        # --retry-all-errors) and lib/xprb-refresh-lib.sh:88 (3-attempt backoff,
        # 4xx always terminal). See upgrade.sh's RETRY_OPTS header comment for
        # the full 3-way rationale.
        # retry next. Do NOT set the persistent-4xx marker (would mis-signal a
        # revoked token and trip the systemd failure on a recoverable hiccup).
        warn "cross-probe target=$target_node_id: HTTP $http_code — rate-limited/transient, retry next tick"
        return 0
    elif [[ "$http_code" =~ ^4 ]]; then
        warn "cross-probe target=$target_node_id: HTTP $http_code — check cross-probe token / roster membership"
        return 1
    else
        warn "cross-probe target=$target_node_id: HTTP $http_code — server/network hiccup, retry next tick"
        return 0
    fi
}

# ---------- read the persisted rotation offset (MINOR 5) ----------
# The last cycle persisted PEER_PROBE_OFFSET = where the NEXT cycle should
# start, so a roster larger than the cap is covered fairly over successive
# ticks instead of permanently truncating the tail. Missing / malformed →
# start at 0. Override the read path with OXPULSE_PEER_PROBE_OFFSET for tests.
_read_peer_probe_offset() {
    if [[ -n "${OXPULSE_PEER_PROBE_OFFSET:-}" ]]; then
        printf '%s' "$OXPULSE_PEER_PROBE_OFFSET"
        return 0
    fi
    local state_dir="${STATE_DIR:-/var/lib/oxpulse-partner-edge}"
    local state_file="$state_dir/peer-probe-mode.env"
    local val=""
    if [[ -r "$state_file" ]]; then
        val=$(sed -n 's/^PEER_PROBE_OFFSET=//p' "$state_file" 2>/dev/null | head -n1)
    fi
    [[ "$val" =~ ^[0-9]+$ ]] || val=0
    printf '%s' "$val"
}

# ---------- peer-probe loop (P3b) ----------
# Reads roster + token; skips cleanly (debug-log) if either is empty/absent.
# For each peer (capped at OXPULSE_PEER_PROBE_MAX): SSRF dial-recheck → pin →
# TLS handshake + UDP STUN → POST. Bounded for the TimeoutStartSec=90 budget (see
# the BUDGET block below). Rotates the probed slice per cycle (MINOR 5) and writes
# a SIGTERM-safe marker (MAJOR 1).
#
# ⚠️  MUST be called as `_run_peer_probe_loop || true` under `set -e` — like
# probe_ch4. The SSRF recheck `vetted_ip=$(_host_is_internal …)` returns 1 on the
# ALLOW path (every healthy public peer), so a BARE call would trip errexit on the
# first healthy peer and abort the loop, silently masked as success. Both current
# call sites (the timer entrypoint + the dry-run path) already shield with `|| true`.
_run_peer_probe_loop() {
    local token roster_file roster
    token=$(_read_cross_probe_token 2>/dev/null || true)
    if [[ -z "$token" ]]; then
        log "peer-probe: no cross-probe token — skipping (pre-P3a central or token absent)"
        _write_peer_probe_state "disabled" 0 0 0
        return 0
    fi

    roster_file=$(_peer_roster_file)
    if [[ ! -r "$roster_file" ]]; then
        log "peer-probe: no roster file at $roster_file — skipping"
        _write_peer_probe_state "disabled" 0 0 0
        return 0
    fi
    roster=$(cat "$roster_file" 2>/dev/null || echo '[]')
    local n
    n=$(printf '%s' "$roster" | jq 'length' 2>/dev/null || echo 0)
    if [[ "$n" -eq 0 ]]; then
        log "peer-probe: empty roster — skipping"
        _write_peer_probe_state "disabled" 0 0 0
        return 0
    fi

    # Read the shared TURN secret once (same source as probe_ch4). Without it we
    # cannot mint creds → skip.
    local turn_secret
    if [[ -n "${OXPULSE_TURN_SECRET:-}" ]]; then
        turn_secret="$OXPULSE_TURN_SECRET"
    else
        # Inner timeout so a wedged in-container sed cannot outlive its
        # docker-exec client (see _probe_peer_udp_stun for the leak class).
        turn_secret=$(timeout 12 docker exec oxpulse-partner-coturn \
            timeout 10 sed -n 's/^static-auth-secret=//p' \
            /etc/coturn/turnserver.conf 2>/dev/null || true)
    fi
    if [[ -z "$turn_secret" ]]; then
        warn "peer-probe: TURN secret unavailable — cannot mint cross-probe creds; skipping"
        _write_peer_probe_state "degraded" 0 0 0
        return 0
    fi

    # ── BUDGET (MAJOR 1) ──────────────────────────────────────────────────────
    # The loop is SERIAL per peer; each peer costs, worst case:
    #     getent SSRF recheck      timeout 3s   (OXPULSE_GETENT_TIMEOUT, _host_is_internal)
    #   + TLS handshake probe       timeout 8s   (OXPULSE_PEER_PROBE_TIMEOUT, _probe_peer_coturn)
    #   + coturn cross-probe POST  curl 8s       (OXPULSE_PEER_PROBE_POST_TIMEOUT, _post_cross_probe)
    #   + UDP STUN probe            timeout 5s   (OXPULSE_PEER_UDP_STUN_TIMEOUT, _probe_peer_udp_stun)
    #   + coturn-udp cross-probe POST curl 8s    (OXPULSE_PEER_PROBE_POST_TIMEOUT, _post_cross_probe)
    #   ────────────────────────────────────
    #     worst_per_peer           = 32s
    #
    # Plus a one-time pre-loop reserve before the first peer:
    #     TURN-secret read     timeout 10s   (docker exec sed, above)
    #   = self_loop_reserve ≈ 10s  (the per-CHANNEL self-probe loop in main()
    #     runs BEFORE this function and is bounded by its OWN timeouts; it is not
    #     part of THIS function's wall-time, but we keep headroom for it.)
    #
    # `cap` bounds DIALS (the expensive probe+POST work), NOT cheap SSRF rejects.
    # A rejected peer costs only the getent (3s, no dial, no POST), so counting it
    # against the dial cap would let an internal-host roster starve real probes.
    # The expensive slice is therefore: worst_per_peer × cap.
    #
    # To keep the getent rejects ALSO bounded (a pathological all-internal roster
    # could otherwise run getent n times), we cap total slots SCANNED per cycle at
    # `scan_cap = cap + reject_headroom`. Default reject_headroom = cap, so:
    #     scan_cap = 2 × cap.
    #
    # Invariant we must satisfy:
    #     worst_per_peer × cap                         (dials)
    #   + getent_timeout × (scan_cap − cap)            (extra rejects)
    #   + secret_read_reserve                          (pre-loop)
    #   ≤  TimeoutStartSec
    #
    # With cap = 2, scan_cap = 4:
    #     32×2 + 3×2 + 10 = 64 + 6 + 10 = 80s.
    # The systemd unit sets TimeoutStartSec=90 so the WHOLE oneshot — self-channel
    # loop + secret read + this peer pass + upstream-transition check — still fits
    # with 10s headroom (80s ≪ 90s). The UDP leg adds 13s/peer (5s STUN + 8s POST)
    # on top of the prior 19s; overall cap=2 worst case moved 54s → 80s.
    # Operators on a large mesh raise OXPULSE_PEER_PROBE_MAX knowingly AND must
    # raise TimeoutStartSec to match: worst_per_peer(32) × cap + 3×cap + 10 ≤ TSSec.
    local cap="${OXPULSE_PEER_PROBE_MAX:-2}"
    local scan_cap=$(( cap + ${OXPULSE_PEER_PROBE_REJECT_HEADROOM:-$cap} ))

    # MINOR 5 (fairness): start the probed slice at the persisted rotation offset
    # so the roster tail (peers beyond the cap) is eventually covered across
    # ticks. The next offset = (start + scanned) mod n, persisted at cycle end.
    local offset start
    offset=$(_read_peer_probe_offset)
    [[ "$offset" =~ ^[0-9]+$ ]] || offset=0
    start=$(( offset % n ))

    # MAJOR 1 (marker truthfulness): write a 'started' marker BEFORE the loop and
    # arm EXIT + signal traps that downgrade a still-'started' marker to
    # 'interrupted' if systemd SIGTERMs us mid-loop (TimeoutStartSec overrun) so
    # a stale "peer" (complete) marker is NEVER left behind. _PEER_PROBE_DONE is
    # flipped to 1 only after the terminal 'peer' marker, so a clean exit does
    # NOT stamp interrupted. The signal handler also RE-EXITS (128+signo) so the
    # oneshot actually dies for systemd instead of resuming the loop after the
    # trap returns (default bash behaviour under a returning TERM trap).
    _PEER_PROBE_DONE=0
    _PEER_PROBE_PROBED=0; _PEER_PROBE_OK=0; _PEER_PROBE_REJECTED=0
    _PEER_PROBE_POST_4XX=0; _PEER_PROBE_NEXT_OFFSET="$start"; _PEER_PROBE_DROPPED=""
    # shellcheck disable=SC2329  # invoked indirectly by the traps below
    _peer_probe_mark_interrupted() {
        [[ "${_PEER_PROBE_DONE:-0}" -eq 1 ]] && return 0
        _write_peer_probe_state "interrupted" \
            "$_PEER_PROBE_PROBED" "$_PEER_PROBE_OK" "$_PEER_PROBE_REJECTED" \
            "$_PEER_PROBE_POST_4XX" "$_PEER_PROBE_NEXT_OFFSET" "$_PEER_PROBE_DROPPED"
    }
    # shellcheck disable=SC2329  # invoked indirectly by the signal traps below
    _peer_probe_on_signal() {
        local signo="$1"
        _peer_probe_mark_interrupted
        trap - EXIT TERM INT
        exit $(( 128 + signo ))
    }
    trap '_peer_probe_mark_interrupted' EXIT
    trap '_peer_probe_on_signal 15' TERM
    trap '_peer_probe_on_signal 2'  INT
    _write_peer_probe_state "started" 0 0 0 0 "$start" ""

    local probed=0 ok_count=0 rejected=0 post_4xx=0
    local scanned=0   # roster slots WALKED this cycle (dial or reject) — drives
                      # rotation + the scan bound. `probed` (dials only) gates cap.
    local i idx node_id turns_host turns_port udp_port handshake_ok rtt result
    local vetted_ip _peer_is_internal
    # Walk the roster starting at `start`, wrapping once. Stop when we have either
    # dialled `cap` peers OR scanned `scan_cap` slots (the reject bound) OR
    # exhausted the roster. Rejects advance `scanned` (bounding getent cost) but
    # NOT `probed` (so they don't consume the dial budget).
    for (( i=0; i<n && probed<cap && scanned<scan_cap; i++ )); do
        idx=$(( (start + i) % n ))
        node_id=$(printf '%s' "$roster" | jq -r --argjson i "$idx" '.[$i].node_id // empty')
        turns_host=$(printf '%s' "$roster" | jq -r --argjson i "$idx" '.[$i].turns_host // empty')
        turns_port=$(printf '%s' "$roster" | jq -r --argjson i "$idx" '.[$i].turns_port // 443')
        # turns_port must be a clean integer; reject anything else (no shell use
        # of an untrusted value as a numeric).
        if ! [[ "$turns_port" =~ ^[0-9]+$ ]]; then
            turns_port=443
        fi
        # udp_port: optional roster field for the STUN/UDP port. Falls back to
        # OXPULSE_COTURN_STUN_PORT (operator override, default 3478). Must be a
        # clean integer; any other value falls back to the default silently.
        udp_port=$(printf '%s' "$roster" | jq -r --argjson i "$idx" '.[$i].udp_port // empty')
        if ! [[ "$udp_port" =~ ^[0-9]+$ ]]; then
            udp_port="${OXPULSE_COTURN_STUN_PORT:-3478}"
        fi
        if [[ -z "$node_id" || -z "$turns_host" ]]; then
            warn "peer-probe: roster entry $idx missing node_id/turns_host — skipping"
            scanned=$((scanned + 1))
            continue
        fi

        # SSRF dial-time recheck — REJECT before any dial (both TLS and UDP legs
        # target the same turns_host; a single recheck covers both). On ALLOW it
        # echoes the vetted IP on stdout; we PIN both legs' dial to that IP
        # (SEC-CR-322-02) so neither openssl nor turnutils re-resolves the hostname.
        # NOTE: must capture stdout — an uncaptured echo would leak into the
        # --dry-run JSON stream.
        vetted_ip=$(_host_is_internal "$turns_host"); _peer_is_internal=$?
        if [[ "$_peer_is_internal" -eq 0 ]]; then
            warn "peer-probe: REJECT $node_id ($turns_host) — resolves internal/unresolvable (SSRF guard)"
            rejected=$((rejected + 1))
            scanned=$((scanned + 1))
            _PEER_PROBE_REJECTED="$rejected"
            continue
        fi

        # ── TLS leg (coturn-tls) ────────────────────────────────────────────────
        result=$(_probe_peer_coturn "$turns_host" "$turns_port" "$turn_secret" "$vetted_ip")
        handshake_ok="${result%%$'\t'*}"
        rtt="${result##*$'\t'}"
        probed=$((probed + 1))
        scanned=$((scanned + 1))
        [[ "$handshake_ok" == "true" ]] && ok_count=$((ok_count + 1))

        # handshake_ok="skip" means the host lacks openssl — emit NO coturn-tls row
        # (a missing prober tool must not look like a down peer). The UDP leg below
        # is independent and still runs.
        # MINOR 6: capture a persistent-4xx signal. _post_cross_probe returns 1
        # ONLY on a 4xx (revoked token / roster-membership) — distinct from the
        # 5xx/000 transient path which returns 0. Without this the `|| true`
        # swallows the 4xx and a revoked token loops forever invisibly.
        # Channel is "coturn-tls" (NOT "coturn"): the per-transport carve-out
        # (#2064) + hub's probe_tls_allocate both key on coturn-tls; sending the
        # bare "coturn" self-channel name here defeats the cross-vantage quorum.
        if [[ "$handshake_ok" != "skip" ]]; then
            if ! _post_cross_probe "$node_id" "$handshake_ok" "$rtt" "$token" "coturn-tls"; then
                post_4xx=1
            fi
        fi

        # ── UDP leg (coturn-udp) ─────────────────────────────────────────────────
        # Probe the peer's STUN/UDP port (3478 by default) via a plain STUN Binding
        # request. The SSRF guard above already vetted turns_host; no second getent
        # needed. The same xprb_ token and POST endpoint are used — no new auth path.
        result=$(_probe_peer_udp_stun "$turns_host" "$udp_port" "$vetted_ip")
        handshake_ok="${result%%$'\t'*}"
        rtt="${result##*$'\t'}"
        if ! _post_cross_probe "$node_id" "$handshake_ok" "$rtt" "$token" "coturn-udp"; then
            post_4xx=1
        fi

        # Update the running marker per peer so a mid-loop SIGTERM leaves accurate
        # partial counts (MAJOR 1).
        _PEER_PROBE_PROBED="$probed"; _PEER_PROBE_OK="$ok_count"
        _PEER_PROBE_POST_4XX="$post_4xx"
        _write_peer_probe_state "started" \
            "$probed" "$ok_count" "$rejected" "$post_4xx" "$start" ""
    done

    # MINOR 5: compute the dropped tail (roster slots NOT walked this cycle) and
    # log them BY NAME — no silent truncation. They become the next cycle's head
    # via next_offset, so coverage is fair across ticks.
    local next_offset dropped="" d j
    next_offset=$(( (start + scanned) % n ))
    if [[ "$scanned" -lt "$n" ]]; then
        for (( j=scanned; j<n; j++ )); do
            d=$(printf '%s' "$roster" | jq -r --argjson i "$(( (start + j) % n ))" '.[$i].node_id // empty')
            # NIT: this value goes UNQUOTED into a KEY=VALUE marker line
            # (PEER_PROBE_DROPPED) consumed by external parsers. Sanitize each
            # node_id to [A-Za-z0-9._-] (drop newlines/'='/commas/etc.) so a
            # malformed roster entry cannot break the marker line. node_ids are
            # curated today; this is defence-in-depth.
            d=$(printf '%s' "$d" | tr -cd 'A-Za-z0-9._-')
            [[ -n "$d" ]] && dropped="${dropped:+$dropped,}$d"
        done
        [[ -n "$dropped" ]] && \
            log "peer-probe: $((n - scanned)) peer(s) deferred to next cycle (cap=$cap scan_cap=$scan_cap): $dropped"
    fi

    log "peer-probe: cycle done — probed=$probed ok=$ok_count rejected=$rejected post_4xx=$post_4xx (roster=$n cap=$cap scan_cap=$scan_cap start=$start next=$next_offset)"
    # Stash for the (now redundant) trap and write the terminal marker.
    _PEER_PROBE_PROBED="$probed"; _PEER_PROBE_OK="$ok_count"
    _PEER_PROBE_REJECTED="$rejected"; _PEER_PROBE_POST_4XX="$post_4xx"
    _PEER_PROBE_NEXT_OFFSET="$next_offset"; _PEER_PROBE_DROPPED="$dropped"
    _write_peer_probe_state "peer" \
        "$probed" "$ok_count" "$rejected" "$post_4xx" "$next_offset" "$dropped"
    _PEER_PROBE_DONE=1
    trap - EXIT TERM INT
}
