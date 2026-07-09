#!/usr/bin/env bash
# lib/channel-health-lib.sh — P2 strangler-fig extraction (2026-07-08 plan):
# real end-to-end channel probes + the report/verdict logic consumed by
# oxpulse-channels-health-report.sh (60s systemd timer) and by upgrade.sh's
# settle-gate (via --serveability --dry-run).
#
# Provides:
#   _elapsed_ms T0 T1                          — awk ms delta of two
#                                                 EPOCHREALTIME floats
#   probe_ch1                                  — xray/VLESS-Reality real
#                                                 tunnel probe (canary/tunnel)
#   probe_ch2                                  — AmneziaWG mesh real tunnel
#                                                 probe (awg0 → backend)
#   probe_ch3                                  — Hysteria2 real tunnel probe
#                                                 (tcpForwarding → backend)
#   _resolve_coturn_probe_target                — resolves the public relay
#                                                 IP the ch4 -y self-test
#                                                 dials (anti-SSRF vs.
#                                                 denied-peer-ip loopback)
#   probe_ch4                                  — coturn TURN Allocate probe
#                                                 (HMAC use-auth-secret) with
#                                                 STUN-only degraded fallback
#   _write_probe_mode_state MODE TARGET SOURCE REASON
#                                               — persists ch4's probe mode/
#                                                 target/reason (sole caller:
#                                                 probe_ch4; co-located per
#                                                 ADR-3, not split elsewhere)
#   _post_channel PAYLOAD_JSON                 — POSTs one channel payload to
#                                                 /api/partner/channel-health
#                                                 (WIRE CONTRACT #1 — see below)
#   _check_upstream_transitions                — polls Caddy /metrics, fires
#                                                 tg_alert() on upstream
#                                                 health transitions
#   _emit_serveability                         — --serveability --dry-run
#                                                 stdout: one `chN=OK|DOWN`
#                                                 line per provisioned tunnel
#                                                 channel (WIRE CONTRACT #2)
#
# ============================================================================
# TWO LIVE WIRE CONTRACTS PINNED ACROSS ALL PHASES OF THE STRANGLER PLAN —
# do not change byte-shape without updating BOTH sides:
#
#  1. _post_channel's JSON envelope posted to POST /api/partner/channel-health:
#       { node_id, channel_name, channel_rtt_ms?, channel_handshake_ok?,
#         channel_probed_at }
#     The central server's ingest schema is pinned to this shape (field
#     name/order/type). A silent drift breaks channel-health ingestion
#     fleet-wide.
#
#  2. _emit_serveability's stdout on `--serveability --dry-run`:
#       ^ch[0-9]+=(OK|DOWN)$   (one line per provisioned tunnel channel)
#     upgrade.sh's _settle_serveability_snapshot greps this EXACT stdout
#     shape to decide SERVING_FULL / PARTIAL / LOST during a live upgrade —
#     LOST triggers an automatic rollback of a live relay node. A format
#     drift here either hides a real regression (never triggers LOST) or
#     worse, misparses and false-triggers a rollback of a healthy box.
#     Oracle: tests/test_settle_serveability.sh.
#
# ADR-5 fail-loud precondition: _emit_serveability dynamically dispatches
# probe_ch1/2/3 via a variable holding the function name; a `declare -F
# probe_ch1 || die` guard at its top converts a load-order/missing-function
# regression into a hard exit instead of a silent all-DOWN (which would trip
# upgrade.sh's LOST/rollback verdict on a healthy box). See its own comment
# for the ADR-3 co-location rationale (this used to be a cross-lib dynamic-
# dispatch edge; the 3-lib collapse made it intra-file, but the guard stays —
# cheap insurance).
#
# Requires (caller globals, set by oxpulse-channels-health-report.sh before
# sourcing this lib — see that script's arg-parse / preflight / node-config
# read, which run before the `source lib/channel-health-lib.sh` line):
#   STATE_DIR                    path, default /var/lib/oxpulse-partner-edge
#                                 (probe_ch4's coturn-probe-mode.env +
#                                 coturn-skip-count.env read; _check_upstream_
#                                 transitions' upstream-state.env)
#   _NODE_CONFIG                  path to node-config.json, already validated
#                                 readable by the orchestrator's preflight
#                                 (_resolve_coturn_probe_target's public_ip
#                                 fallback read)
#   NODE_ID                      string, node_id read from node-config.json
#                                 by the orchestrator (_post_channel payload)
#   DRY_RUN                      int 0|1 (_post_channel: print vs POST)
#   CURL_TRACE                   int 0|1 (_post_channel: log the Authorization
#                                 header in dry-run mode only)
#   _installer_version             string, optional installer VERSION read by
#                                 the orchestrator (_post_channel payload)
#   OXPULSE_BACKEND_API           URL base, e.g. https://api.oxpulse.chat
#                                 (_post_channel's POST target)
#   _PROVISIONED                  array, provisioned channel ids read from
#                                 node-config.json by the orchestrator's main
#                                 section (_emit_serveability)
#   SCRIPT_DIR / PREFIX_SBIN      paths, both optional with inline defaults
#                                 (_check_upstream_transitions: locate
#                                 lib/telegram-alert-lib.sh; self-guarded —
#                                 silent-skips the alert feature, not fatal,
#                                 if neither resolves)
#   _COTURN_SKIP_COUNT_FILE       path override (optional; defaults under
#                                 STATE_DIR) — probe_ch4's skip-counter read,
#                                 written by lib/reconcile.sh
#
# Requires (functions, provided by the orchestrator before sourcing — see
# oxpulse-channels-health-report.sh's own "load token lib" / logging blocks):
#   log() warn() die()           logging (used throughout this lib)
#   read_service_token()         from oxpulse-token-lib.sh / _TOKEN_LIB, or
#                                 the orchestrator's inline fallback
#                                 (_post_channel's Bearer token source)
#
# Requires (env overrides, all optional — every one has an inline default in
# the function that reads it, so none of these are hard runtime requirements):
#   OXPULSE_CHANNEL_PROBE_TIMEOUT, OXPULSE_CH1_CANARY_URL,
#   OXPULSE_AWG_MOTHERLY_IP, OXPULSE_BACKEND_PORT, OXPULSE_HY2_LOCAL_LISTEN,
#   OXPULSE_HY2_FALLBACK_PORT, OXPULSE_COTURN_PORT,
#   OXPULSE_COTURN_PROBE_TARGET, OXPULSE_TURN_SECRET, OXPULSE_HMAC_BIN,
#   OXPULSE_METRICS_SRC
#
# Sourced by oxpulse-channels-health-report.sh fail-closed from the installed
# lib dir (ADR-6: no per-tick network re-fetch — install-systemd.sh already
# copies + the release pipeline already checksums this file at install/
# upgrade time; mirrors this exact script's existing telegram-alert-lib.sh
# runtime-source precedent, hardened here to fail-closed since these
# functions are load-bearing, not an optional feature). Not executable on its
# own — sourced only.
#
# NOT extracted here (different scope, different PRs of the same plan):
#   _ip_is_internal / _host_is_internal / _ipv4_literal_is_suspect /
#   _ipv6_embedded_v4                    → lib/peer-ip-guard-lib.sh (P1)
#   _read_cross_probe_token / _peer_roster_file / _write_peer_probe_state /
#   _probe_peer_coturn / _probe_peer_udp_stun / _post_cross_probe /
#   _read_peer_probe_offset / _run_peer_probe_loop
#                                         → lib/cross-probe-lib.sh (P3,
#                                           merge-gated on the xprb-refresh
#                                           rollout soak — operator ack req.)
#
# See ~/deploy/server-config/plans/oxpulse-partner-edge/
# 2026-07-08-health-report-lib-extraction.md for the full council-vetted plan.

# Guard against double-sourcing.
[[ "${_CHANNEL_HEALTH_LIB_LOADED:-0}" -eq 1 ]] && return 0
_CHANNEL_HEALTH_LIB_LOADED=1

_elapsed_ms() {
    awk "BEGIN { printf \"%d\", ($2 - $1) * 1000 }"
}

# ---------- probe: ch1 — xray/VLESS-Reality — REAL end-to-end tunnel ----------
# Dials the Phase 1 canary site's /canary/tunnel route (Caddyfile.tpl,
# 127.0.0.1:9080, host-only) instead of checking local container liveness.
# /canary/tunnel rewrites to /api/health/live and reverse-proxies through the
# xray-client container's VLESS-Reality tunnel to the central backend — 2xx
# only when BOTH the tunnel and the backend are reachable end-to-end.
#
# BEFORE this fix: `docker exec oxpulse-partner-xray ss -ltn | grep :3080`
# only proved the xray-client PROCESS was listening. Live-verified on
# zvonilka: ss -ltn stayed green the whole time ТСПУ was returning 502 on the
# real VLESS-Reality path (canary/tunnel) — a silent healthy/blocked blind
# spot with zero alerting, since nothing downstream ever saw a failure signal.
probe_ch1() {
    local t0 t1 http_code rtt_ms
    local timeout_s="${OXPULSE_CHANNEL_PROBE_TIMEOUT:-5}"
    local canary_url="${OXPULSE_CH1_CANARY_URL:-http://127.0.0.1:9080/canary/tunnel}"

    t0="${EPOCHREALTIME}"
    http_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$timeout_s" \
        "$canary_url" 2>/dev/null || echo '000')
    t1="${EPOCHREALTIME}"

    rtt_ms=$(_elapsed_ms "$t0" "$t1")

    if [[ "$http_code" =~ ^2 ]]; then
        printf '{"channel_name":"ch1","channel_rtt_ms":%d,"channel_handshake_ok":true}' "$rtt_ms"
    else
        printf '{"channel_name":"ch1","channel_rtt_ms":%d,"channel_handshake_ok":false}' "$rtt_ms"
    fi
}

# ---------- probe: ch2 — AmneziaWG mesh — REAL end-to-end tunnel ----------
# Dials the central backend's /api/health directly through the awg0 tunnel
# (the AWG mesh "motherly" hub node, OXPULSE_AWG_MOTHERLY_IP, on the port the
# backend itself listens on, OXPULSE_BACKEND_PORT — both already shared with
# Caddyfile.tpl's own tunnel_upstream failover group). A response proves the
# awg0 DATA PLANE actually reaches the backend, not merely that the mesh peer
# answers ICMP — the same class of blind spot ch1 had via ss -ltn: a
# WireGuard handshake can be up while the routed traffic itself never reaches
# anything. channel_rtt_ms is now populated for the first time (a real HTTP
# round trip, unlike the ping-based check it replaces).
probe_ch2() {
    local motherly_ip backend_port t0 t1 http_code rtt_ms
    local timeout_s="${OXPULSE_CHANNEL_PROBE_TIMEOUT:-5}"

    motherly_ip="${OXPULSE_AWG_MOTHERLY_IP:-10.9.0.2}"
    backend_port="${OXPULSE_BACKEND_PORT:-8907}"

    t0="${EPOCHREALTIME}"
    http_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$timeout_s" \
        "http://${motherly_ip}:${backend_port}/api/health" 2>/dev/null || echo '000')
    t1="${EPOCHREALTIME}"

    rtt_ms=$(_elapsed_ms "$t0" "$t1")

    if [[ "$http_code" =~ ^2 ]]; then
        printf '{"channel_name":"ch2","channel_rtt_ms":%d,"channel_handshake_ok":true}' "$rtt_ms"
    else
        printf '{"channel_name":"ch2","channel_rtt_ms":%d,"channel_handshake_ok":false}' "$rtt_ms"
    fi
}

# ---------- probe: ch3 — Hysteria2 — REAL end-to-end tunnel ----------
# Dials the central backend's /api/health through the hysteria2-client
# container's local tcpForwarding listener (127.0.0.1:PORT), which forwards
# over the QUIC tunnel to OXPULSE_HY2_REMOTE_BACKEND on the far side (the same
# backend every other channel targets — defaults.conf: 127.0.0.1:8907, from
# the hysteria2 SERVER's own vantage). This is the FIRST real signal for ch3:
# the `nc -z` port check it replaces only proved the local forwarder was
# LISTENING, never that a byte made it through the tunnel — and it never
# emitted channel_handshake_ok at all, so the backend's ch1/ch2/ch3 OR'd
# signaling health (health_poller.rs) had zero ch3 visibility.
# channel_handshake_ok is populated for the first time here.
probe_ch3() {
    local listen port t0 t1 http_code rtt_ms
    local timeout_s="${OXPULSE_CHANNEL_PROBE_TIMEOUT:-5}"

    # Derive port from OXPULSE_HY2_LOCAL_LISTEN (addr:port) or override.
    listen="${OXPULSE_HY2_LOCAL_LISTEN:-0.0.0.0:18443}"
    port="${listen##*:}"
    port="${OXPULSE_HY2_FALLBACK_PORT:-${port:-18443}}"

    t0="${EPOCHREALTIME}"
    http_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$timeout_s" \
        "http://127.0.0.1:${port}/api/health" 2>/dev/null || echo '000')
    t1="${EPOCHREALTIME}"

    rtt_ms=$(_elapsed_ms "$t0" "$t1")

    if [[ "$http_code" =~ ^2 ]]; then
        printf '{"channel_name":"ch3","channel_rtt_ms":%d,"channel_handshake_ok":true}' "$rtt_ms"
    else
        printf '{"channel_name":"ch3","channel_rtt_ms":%d,"channel_handshake_ok":false}' "$rtt_ms"
    fi
}

# ---------- probe: ch4 — coturn TURN Allocate (HMAC shared-secret) ----------
# Tests the real TURN relay data path: if coturn is dead, quota-exceeded (486),
# or the allocator is broken, handshake_ok=false is reported and the central
# server can alert — closing the M2.6a observability blind spot.
#
# Method: derive a canonical coturn use-auth-secret ephemeral credential
#   username = "<unix-expiry-ts>:healthprobe"   (now + 600 s)
#   password = base64( HMAC-SHA1( static-auth-secret, username ) )
# then run `turnutils_uclient -u <username> -w <password> -y -n 1 -p <port>`
# inside the running coturn container.  This exercises the exact lt-cred-mech +
# use-auth-secret auth + quota path real WebRTC clients hit (RFC 7635 TURN REST
# API).  -y is the client-to-client self-test (allocates two relays and relays
# between them — no external peer needed); -n 1 sends one test-data burst after
# Allocate, then exits.  Catches the three silent-failure modes: dead allocator,
# 486 Allocation Quota Reached, and HMAC credential drift.
#
# SECURITY: the HMAC is computed by python3 with the base secret passed via the
# ENVIRONMENT ($K), never on argv — /proc/<pid>/cmdline is world-readable on the
# edge (no hidepid), so any argv form (`openssl -hmac`, `-macopt hexkey:`,
# `turnutils_uclient -W`) would leak the long-term secret to a co-resident
# process.  Only the public username + the short-lived password reach argv.
#
# Fallback: if the secret cannot be read, STUN Binding via turnutils_stunclient
# is used instead (weaker: only proves the process is listening, not that auth
# or quota works).  This degraded mode is reported via channel_probe_mode in the
# payload AND a coturn-probe-mode.env state file (the warn() to stderr is
# swallowed by the dispatch command-substitution, so it must not be relied on).
#
# Secret source: rendered /etc/coturn/turnserver.conf inside the container
# (same read used by healthcheck.sh check #8).  Override via OXPULSE_TURN_SECRET
# env var for dry-run / testing without a running container.
#
# NOTE: coturn exposes no Prometheus /metrics endpoint, so quota exhaustion
# (486 Allocation Quota Reached) leaves no counter.  A coturn-exporter sidecar
# that parses /var/log/turnserver/turn.log for 486 lines would close this gap —
# tracked as a followup, out of scope here.
#
# PROBE TARGET (anti-SSRF-vs-loopback-self-test collision — see below):
# the `-y` self-test relays between two allocations via a peer reached at the
# server-address argument.  When that argument is 127.0.0.1 the relayed peer is
# a loopback address, which TWO independent guards in the production config DENY
# at CreatePermission:
#   1. `denied-peer-ip=127.0.0.0-127.255.255.255` (coturn.conf.tpl) — explicit
#      RFC-defined loopback SSRF block.
#   2. `no-loopback-peers` (coturn.conf.tpl:42) — coturn's built-in flag that
#      independently denies any peer address that is a loopback address, even if
#      denied-peer-ip were removed.
# Either guard alone is sufficient to deny the self-test peer; both are present.
# The data round-trip never completes, `timeout` kills the
# client (exit 124), handshake_ok is reported false on a perfectly healthy
# coturn, AND the killed client leaks its two allocations every tick (no
# graceful dealloc — turnutils_uclient has no --lifetime/allocation-duration
# flag; `-l` controls message length, not allocation lifetime).  At a 60 s tick
# rate this is ~10 leaked allocations outstanding at steady state (600 s coturn
# default expiry); the default per-user quota is 16, so a continuously-timing-
# out probe wedges into 486 Allocation Quota Reached after ~8 min.  The fix is
# to point the probe at the address real clients use — the server's PUBLIC/
# external IP, which is NOT in the denied range — so the relayed peer is a
# public relay address and CreatePermission succeeds and the client exits 0
# (sending a graceful Refresh(0)).  On pure-NAT edges where hairpin is dropped,
# set OXPULSE_COTURN_PROBE_TARGET to a non-hairpin reachable address.  See
# FOLLOWUPS.md 'ch4 coturn probe — hairpin/NAT caveat' for the full analysis.
# We do NOT loosen denied-peer-ip to make loopback work: that would re-open the
# SSRF hole the guard exists to close.

# ---------- helper: resolve the coturn probe target (public relay IP) ----------
# Resolution order:
#   1. OXPULSE_COTURN_PROBE_TARGET   explicit operator/test override
#   2. external-ip from the running container's turnserver.conf — the literal
#      address coturn advertises as its relay; strip any "/private" NAT suffix
#      (install.sh renders "public/private" behind NAT) to get the public part.
#   3. public_ip from node-config.json — the same public IP sent to the backend
#      at registration (hydrate.sh writes it); read with jq, already loaded, no
#      extra network call.
#   4. 127.0.0.1 — last-resort fallback so resolution never hard-fails; this is
#      the broken loopback target, so the caller annotates the degraded reason.
# Echoes "<target>\t<source>" so the caller can record provenance.
_resolve_coturn_probe_target() {
    local target source
    if [[ -n "${OXPULSE_COTURN_PROBE_TARGET:-}" ]]; then
        printf '%s\t%s' "$OXPULSE_COTURN_PROBE_TARGET" "env-override"
        return 0
    fi
    # external-ip from the container's rendered turnserver.conf.  sed extracts
    # the value; the public part is everything before the first '/' (NAT form
    # "public/private"); no '/' → the whole value is public.
    local ext_line
    ext_line=$(timeout 10 docker exec oxpulse-partner-coturn \
        sed -n 's/^external-ip=//p' \
        /etc/coturn/turnserver.conf 2>/dev/null | head -n1 || true)
    if [[ -n "$ext_line" ]]; then
        target="${ext_line%%/*}"
        if [[ -n "$target" ]]; then
            printf '%s\t%s' "$target" "external-ip"
            return 0
        fi
    fi
    # public_ip persisted in node-config.json at registration.
    if [[ -r "$_NODE_CONFIG" ]]; then
        source=$(jq -r '.public_ip // empty' "$_NODE_CONFIG" 2>/dev/null || true)
        if [[ -n "$source" ]]; then
            printf '%s\t%s' "$source" "node-config"
            return 0
        fi
    fi
    # Last resort: the (broken) loopback target.  Caller flags this as degraded.
    printf '%s\t%s' "127.0.0.1" "loopback-fallback"
}

probe_ch4() {
    local turn_secret turn_port turn_username turn_password t0 t1 exit_code rtt_ms
    # probe_mode is reported in the payload AND a state file so the degraded
    # signal survives — the dispatch command-substitution swallows stderr
    # with 2>/dev/null (MAJOR fix), so a bare warn() would be invisible to
    # operators and they could silently run STUN-only (no auth/quota coverage,
    # the exact blind spot this probe exists to close).
    local probe_mode="allocate"
    # probe_reason carries WHY a probe failed (timeout / auth-486 / other) so a
    # false handshake_ok=false is no longer indistinguishable from a real one.
    # Reported in the payload AND the state file (stderr is swallowed).
    local probe_reason=""
    local uclient_out=""

    turn_port="${OXPULSE_COTURN_PORT:-3478}"

    # Resolve the address real clients use — NOT 127.0.0.1.  Pointing the -y
    # self-test at the public/external relay IP avoids the anti-SSRF
    # denied-peer-ip collision documented above (loopback peer → CreatePermission
    # denied → timeout-kill → false-negative + leaked allocations).
    local probe_target probe_target_source _resolved
    _resolved=$(_resolve_coturn_probe_target)
    probe_target="${_resolved%%$'\t'*}"
    probe_target_source="${_resolved##*$'\t'}"
    if [[ "$probe_target_source" == "loopback-fallback" ]]; then
        warn "ch4: could not resolve public probe target — falling back to 127.0.0.1 (anti-SSRF denied-peer-ip will deny the -y self-test; expect a false negative). On pure-NAT edges where hairpin is dropped this also occurs with a valid public IP; set OXPULSE_COTURN_PROBE_TARGET to a reachable non-hairpin address. See FOLLOWUPS.md 'ch4 coturn probe — hairpin/NAT caveat'."
        # Seed the failure reason so that IF the probe fails (the expected
        # outcome when the loopback target is denied-peer-ip'd), the central
        # server can distinguish "loopback fallback → anti-SSRF denial" from
        # a genuinely dead relay — both produce exit 124 / handshake_ok=false
        # but have different remediation paths.  Overridden below by the
        # exit-code classifier if a more specific reason is known.
        probe_reason="loopback-fallback"
    fi

    # Read static-auth-secret from the running container's rendered config.
    # OXPULSE_TURN_SECRET env allows dry-run / test override without a container.
    # NOTE: sed avoids awk -F= which truncates base64 secrets at the first '='
    # padding character (e.g. "abc==" → "abc").
    if [[ -n "${OXPULSE_TURN_SECRET:-}" ]]; then
        turn_secret="$OXPULSE_TURN_SECRET"
    else
        turn_secret=$(timeout 10 docker exec oxpulse-partner-coturn \
            sed -n 's/^static-auth-secret=//p' \
            /etc/coturn/turnserver.conf 2>/dev/null || true)
    fi

    if [[ -n "$turn_secret" ]]; then
        # Derive RFC 7635 short-lived ephemeral credential in-script so that
        # only a time-limited username+password (valid 600s) appears on argv —
        # NOT the long-term base secret.  This prevents any co-resident process
        # scraping /proc/<pid>/cmdline from obtaining unlimited TURN creds.
        #
        # SECURITY (SEC-CR-001): the base static-auth-secret MUST NEVER appear
        # on any process argv.  /proc/<pid>/cmdline is world-readable (the edge
        # has no hidepid), so the HMAC computation cannot pass the secret as a
        # command-line argument — `openssl -hmac VALUE`, `-macopt hexkey:VALUE`
        # and `turnutils_uclient -W VALUE` ALL leak it via argv equally.  We
        # therefore compute the HMAC with python3, passing the secret through
        # the ENVIRONMENT ($K, readable only by same-uid/root via
        # /proc/<pid>/environ — NOT world-readable like cmdline).  Only the
        # public username travels on argv.
        #
        # Derivation (canonical coturn use-auth-secret / RFC 7635 TURN REST API,
        # matches WebRTC client + /api/turn-credentials):
        #   username = <unix-expiry-timestamp>:<userid>   (now + 600 s)
        #   password = base64( HMAC-SHA1( base_secret, username ) )
        #
        # The "<ts>:<userid>" form (SEC-CR-002) is mandatory: coturn parses the
        # colon to extract the expiry; a bare timestamp takes a different
        # username-parse branch than real clients, so the probe would not
        # exercise the same code path.  base64 is single-line (SEC-CR-003) —
        # python's b64encode never wraps.
        #
        # turnutils_uclient flags used:
        #   -u  ephemeral username (public — safe on argv)
        #   -w  ephemeral password (HMAC-SHA1 — short-lived, safe on argv)
        #   -y  client-to-client self-test — allocates two relays and relays
        #       traffic between them, so no external peer is needed; exercises
        #       Allocate + CreatePermission + ChannelBind + data round-trip
        #       end-to-end against the server's own relay-ip.  (Verified live:
        #       valid cred → exit 0 with data relayed; wrong/expired cred → 255
        #       at Allocate; quota exhaustion → 486 → 255.)
        #   -n 1  one test-data message burst, then exit
        #   -p  TURN server port (honours OXPULSE_COTURN_PORT)
        turn_username="$(( $(date +%s) + 600 )):healthprobe"
        # HMAC binary chosen at runtime so the leak-resistance test can stub it.
        local hmac_bin="${OXPULSE_HMAC_BIN:-python3}"
        turn_password=$(K="$turn_secret" "$hmac_bin" -c \
            'import hmac,hashlib,os,sys,base64; print(base64.b64encode(hmac.new(os.environb[b"K"], sys.argv[1].encode(), hashlib.sha1).digest()).decode())' \
            "$turn_username")

        t0="${EPOCHREALTIME}"
        # Capture combined output so the failure tail can be logged/classified
        # locally — the dispatch command-substitution swallows stderr, so the
        # next investigation would otherwise be blind to WHY the probe failed.
        uclient_out=$(timeout 10 docker exec oxpulse-partner-coturn \
            turnutils_uclient \
                -u "$turn_username" \
                -w "$turn_password" \
                -y -n 1 \
                -p "$turn_port" \
                "$probe_target" \
            2>&1)
        exit_code=$?
        t1="${EPOCHREALTIME}"

        # Classify the failure so handshake_ok=false carries a reason.
        # When probe_reason is already "loopback-fallback" (seeded above because
        # all three resolution sources failed), preserve it — it is more specific
        # than "timeout" and lets the central server distinguish a config gap
        # from a genuinely dead relay.  Otherwise classify by exit code.
        if [[ "$exit_code" -ne 0 ]]; then
            if [[ "$probe_reason" != "loopback-fallback" ]]; then
                case "$exit_code" in
                    124|143)
                        # timeout(1) SIGTERM/SIGKILL — the data round-trip never
                        # completed (the classic anti-SSRF denied-peer collision,
                        # or a genuinely dead relay path).
                        probe_reason="timeout"
                        ;;
                    *)
                        if printf '%s' "$uclient_out" | grep -qiE '486|Allocation Quota Reached'; then
                            probe_reason="auth-486"
                        else
                            probe_reason="other"
                        fi
                        ;;
                esac
            fi
            # Log the uclient tail locally (last 3 lines) so an investigator has
            # evidence even though the POST/stderr paths are swallowed upstream.
            warn "ch4: coturn probe failed (target=$probe_target source=$probe_target_source exit=$exit_code reason=$probe_reason): $(printf '%s' "$uclient_out" | tail -n3 | tr '\n' ' ')"
        fi
    else
        # Fallback: STUN Binding only — proves the process is alive, not
        # that auth or quota works.  Weaker than Allocate; annotated so
        # operators know what they're looking at.
        probe_mode="stun-degraded"
        warn "ch4: TURN secret unavailable — falling back to STUN Binding probe (degraded: no auth/quota coverage)"
        t0="${EPOCHREALTIME}"
        uclient_out=$(timeout 10 docker exec oxpulse-partner-coturn \
            turnutils_stunclient "$probe_target" -p "$turn_port" \
            2>&1)
        exit_code=$?
        t1="${EPOCHREALTIME}"
        if [[ "$exit_code" -ne 0 ]]; then
            case "$exit_code" in
                124|143) probe_reason="timeout" ;;
                *)       probe_reason="other" ;;
            esac
            warn "ch4: STUN probe failed (target=$probe_target source=$probe_target_source exit=$exit_code reason=$probe_reason): $(printf '%s' "$uclient_out" | tail -n3 | tr '\n' ' ')"
        fi
    fi

    rtt_ms=$(_elapsed_ms "$t0" "$t1")

    # Persist the probe mode + target provenance + failure reason to a state
    # file (outside the swallowed stderr + the swallowed command-substitution)
    # so operators / central tooling can detect degraded STUN-only mode AND see
    # which target the probe used + why it failed, even though the WARN never
    # reaches them.
    _write_probe_mode_state "$probe_mode" "$probe_target" "$probe_target_source" "$probe_reason"

    # Read the consecutive-skip counter written by lib/reconcile.sh.  Missing
    # file (pre-P4b edges) or non-numeric value both default to 0 so old edges
    # are not dark — the field is simply 0 until the first SKIP cycle writes it.
    local _skip_state_dir="${STATE_DIR:-/var/lib/oxpulse-partner-edge}"
    local _skip_count=0
    local _skip_raw
    _skip_raw=$(grep '^COTURN_SKIP_CONSECUTIVE=' \
        "${_COTURN_SKIP_COUNT_FILE:-${_skip_state_dir}/coturn-skip-count.env}" \
        2>/dev/null | head -1 | cut -d= -f2 || true)
    if [[ "$_skip_raw" =~ ^[0-9]+$ ]]; then
        _skip_count="$_skip_raw"
    fi

    # channel_probe_mode is also emitted in the JSON payload — the central
    # server receives it over the wire (POST body is NOT swallowed), giving a
    # second, observable degraded signal independent of edge-local stderr.
    # channel_probe_reason is added only on failure (the _post_channel jq filter
    # preserves extra fields), so a false-negative carries its cause to the
    # central server instead of an opaque handshake_ok=false.
    # coturn_skip_consecutive surfaces reconcile.sh's durable stuck-edge counter
    # so the central scraper / motherly health view can detect a non-zero count
    # on a stuck edge without needing to read edge-local state files directly.
    if [[ "$exit_code" -eq 0 ]]; then
        printf '{"channel_name":"coturn","channel_rtt_ms":%d,"channel_handshake_ok":true,"channel_probe_mode":"%s","coturn_skip_consecutive":%d}' "$rtt_ms" "$probe_mode" "$_skip_count"
    else
        printf '{"channel_name":"coturn","channel_rtt_ms":%d,"channel_handshake_ok":false,"channel_probe_mode":"%s","channel_probe_reason":"%s","coturn_skip_consecutive":%d}' "$rtt_ms" "$probe_mode" "${probe_reason:-unknown}" "$_skip_count"
    fi
}

# ---------- ch4 probe-mode state file ----------
# Records whether the coturn probe ran in full "allocate" mode or fell back to
# "stun-degraded".  The dispatch command-substitution swallows stderr, so the
# warn() in probe_ch4 is invisible; this file is the observable degraded signal
# (operators / monitoring read it; the central server also gets channel_probe_mode
# in the POST payload).  Atomic write via mktemp + rename within the same dir.
_write_probe_mode_state() {
    local mode="$1"
    local target="${2:-}"
    local target_source="${3:-}"
    local reason="${4:-}"
    local state_dir="${STATE_DIR:-/var/lib/oxpulse-partner-edge}"
    local state_file="$state_dir/coturn-probe-mode.env"
    mkdir -p "$state_dir" 2>/dev/null || return 0
    local tmp
    tmp=$(mktemp -p "$state_dir" coturn-probe-mode.XXXXXX 2>/dev/null) || return 0
    {
        echo "# Generated by oxpulse-channels-health-report.sh — do not edit"
        printf 'COTURN_PROBE_MODE=%s\n' "$mode"
        printf 'COTURN_PROBE_TARGET=%s\n' "$target"
        printf 'COTURN_PROBE_TARGET_SOURCE=%s\n' "$target_source"
        printf 'COTURN_PROBE_REASON=%s\n' "$reason"
        printf 'COTURN_PROBE_AT=%s\n' "$(date +%s)"
    } > "$tmp"
    chmod 0640 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$state_file" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
}

# ---------- post one channel payload ----------
_post_channel() {
    local payload="$1"
    local token

    token=$(read_service_token 2>/dev/null || true)
    if [[ -z "$token" ]]; then
        warn "no service token — skipping $(printf '%s' "$payload" | jq -r '.channel_name // "?"')"
        return 1
    fi

    local probed_at
    probed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    local full_payload
    full_payload=$(printf '%s' "$payload" | jq \
        --arg node_id "$NODE_ID" \
        --arg ts "$probed_at" \
        --arg iv "${_installer_version:-}" \
        '. + {node_id: $node_id, channel_probed_at: $ts} + (if $iv == "" then {} else {installer_version: $iv} end)')

    local channel_name
    channel_name=$(printf '%s' "$payload" | jq -r '.channel_name // "?"')

    if [[ "$DRY_RUN" -eq 1 ]]; then
        printf '%s\n' "$full_payload"
        if [[ "$CURL_TRACE" -eq 1 ]]; then
            printf 'Authorization: Bearer %s\n' "$token" >&2
        fi
        return 0
    fi

    local http_code
    # CWE-214 hardening (2026-07-08 review, low-severity accepted-residual
    # closed): the Bearer token goes via `-K -` (curl config on stdin, a bash
    # here-string — no separate process ever holds the token as its own argv)
    # instead of `-H "Authorization: Bearer $token"`, which was ps/proc-visible
    # to any local user on the relay host for curl's whole lifetime.
    http_code=$(curl -s -o /dev/null -w '%{http_code}' \
        --max-time 15 \
        -X POST \
        -H 'Content-Type: application/json' \
        -K - \
        -d "$full_payload" \
        "${OXPULSE_BACKEND_API}/api/partner/channel-health" \
        2>/dev/null <<< "header = \"Authorization: Bearer $token\"" || echo '000')

    if [[ "$http_code" =~ ^2 ]]; then
        log "channel $channel_name reported OK (HTTP $http_code)"
        return 0
    elif [[ "$http_code" == "429" || "$http_code" == "408" ]]; then
        # TRANSIENT (RFC 6585): rate-limited / request-timeout — NOT an auth
        # failure. Back off (the 60s timer is our retry; central sends
        # Retry-After) and retry next tick. Must NOT return 1, or a recoverable
        #
        # CROSS-REFERENCE (PR2 finding 4b — do NOT unify with the other retry
        # policies in this repo): this bash-level status-code carve-out is
        # DELIBERATELY separate from upgrade.sh/install.sh's RETRY_OPTS
        # (bootstrap-tier lib-loader fetches only, uses curl's own native
        # --retry-all-errors) and lib/xprb-refresh-lib.sh:88 (3-attempt backoff,
        # 4xx always terminal). See upgrade.sh's RETRY_OPTS header comment for
        # the full 3-way rationale.
        # rate-limit would surface as a systemd unit failure.
        warn "channel $channel_name: HTTP $http_code — rate-limited/transient, retry next tick"
        return 0
    elif [[ "$http_code" =~ ^4 ]]; then
        warn "channel $channel_name: HTTP $http_code — check service token"
        return 1   # auth failure — exit 1 so timer logs it
    else
        # 5xx / 000 (timeout/network) — transient, try next tick
        warn "channel $channel_name: HTTP $http_code — server/network hiccup, retry next tick"
        return 0
    fi
}

# ---------- Phase 5.8 Task 5: upstream-transition Telegram alerting ----------
# Polls Caddy /metrics (or fixture file via OXPULSE_METRICS_SRC), compares
# upstream health against persisted state, fires tg_alert() on transitions.
# State file: ${STATE_DIR:-/var/lib/oxpulse-partner-edge}/upstream-state.env
#
# Env overrides:
#   OXPULSE_METRICS_SRC  — file path or URL (default http://127.0.0.1:2019/metrics)
#   STATE_DIR            — directory for upstream-state.env
#                          (default /var/lib/oxpulse-partner-edge)

_check_upstream_transitions() {
    local metrics_src="${OXPULSE_METRICS_SRC:-http://127.0.0.1:2019/metrics}"
    local state_dir="${STATE_DIR:-/var/lib/oxpulse-partner-edge}"
    local state_file="$state_dir/upstream-state.env"
    local raw

    if [[ "$metrics_src" =~ ^http ]]; then
        raw=$(curl -sf --max-time 3 "$metrics_src" 2>/dev/null || return 0)
    else
        [[ -r "$metrics_src" ]] || return 0
        raw=$(cat "$metrics_src")
    fi

    declare -A current
    local line up val
    while IFS= read -r line; do
        [[ "$line" =~ ^caddy_reverse_proxy_upstreams_healthy ]] || continue
        up=$(printf '%s' "$line" | sed -nE 's/.*upstream="([^"]+)".*/\1/p')
        val=$(printf '%s' "$line" | sed -nE 's/.* ([01])$/\1/p')
        [[ -z "$up" || -z "$val" ]] && continue
        if [[ "$val" == "1" ]]; then
            current["$up"]=healthy
        else
            current["$up"]=unhealthy
        fi
    done <<< "$raw"

    declare -A previous
    if [[ -r "$state_file" ]]; then
        local key rest
        while IFS='=' read -r key rest; do
            [[ -z "$key" || "$key" =~ ^# ]] && continue
            previous["$key"]=$(printf '%s' "$rest" | cut -d: -f1)
        done < "$state_file"
    fi

    # Load alert lib from SCRIPT_DIR, then sbin fallback; silent-skip if missing.
    local _lib_loaded=0
    # shellcheck source=lib/telegram-alert-lib.sh
    if source "${SCRIPT_DIR:-$(dirname "$0")}/lib/telegram-alert-lib.sh" 2>/dev/null; then
        _lib_loaded=1
    elif source "${PREFIX_SBIN:-/usr/local/sbin}/telegram-alert-lib.sh" 2>/dev/null; then
        _lib_loaded=1
    fi

    if [[ "$_lib_loaded" -eq 0 ]]; then
        warn "telegram-alert-lib.sh not found — skipping transition alerts"
        return 0
    fi

    local cur prev _hostname
    _hostname=$(hostname -s 2>/dev/null || echo edge)

    for up in "${!current[@]}"; do
        cur="${current[$up]}"
        prev="${previous[$up]:-}"
        if [[ -n "$prev" && "$cur" != "$prev" ]]; then
            tg_alert "[$_hostname] TRANSITION upstream=${up} ${prev} -> ${cur}"
        fi
    done

    # Persist current state atomically.
    # mktemp -p same dir as state_file ensures rename stays intra-fs (POSIX atomic).
    # Cross-fs mv (e.g. /tmp → /var/lib) is non-atomic — MAJOR 4 fix.
    mkdir -p "$state_dir" 2>/dev/null || true
    local tmp
    tmp=$(mktemp -p "$(dirname "$state_file")" upstream-state.XXXXXX) || {
        warn "mktemp failed in $(dirname "$state_file") — skipping state persist"
        return 0
    }
    {
        echo "# Generated by oxpulse-channels-health-report.sh — do not edit"
        for up in "${!current[@]}"; do
            printf '%s=%s:%s\n' "$up" "${current[$up]}" "$(date +%s)"
        done
    } > "$tmp"
    chmod 0640 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$state_file"
}

# ---------- serve-ability probe (upgrade settle-gate consumer) ----------
# --serveability: probe ONLY the provisioned tunnel channels (ch1/ch2/ch3) via
# the SAME honest end-to-end probe_ch1/ch2/ch3 used by the 60s health report,
# and emit one parseable `chN=OK|DOWN` line each — no POST, no peer-probe, no
# ch4 (coturn is a TURN relay, not a user-facing serve channel; its probe is
# also slow and leaks allocations, so it must never run on the settle path).
# This is the real-time serve-ability oracle the upgrade settle gate consults
# before rolling back: a box whose xray (ch1) is ТСПУ-blocked but whose awg
# (ch2) / hy2 (ch3) still serve via Caddy's multi-homed tunnel_upstream must NOT
# be rolled back. `OK` = the channel's tunnel reached the backend end-to-end
# (handshake_ok true); `DOWN` otherwise. Channels absent from node-config are
# simply not emitted (the consumer treats an absent channel as non-applicable /
# info, never a regression).
_emit_serveability() {
    # ADR-5 fail-loud precondition: _emit_serveability dynamically dispatches
    # probe_ch1/2/3 via a variable holding the function name ("$_fn" below);
    # if a future regression (load-order bug, partial source failure, a
    # truncated/corrupt copy of this lib) leaves those functions undefined,
    # the dispatch would silently degrade every channel to DOWN instead of
    # failing loudly. A false all-DOWN here trips upgrade.sh's
    # _settle_serveability_snapshot LOST verdict and auto-rolls back an
    # otherwise healthy relay node — so this converts a silent false-DOWN
    # into a hard exit instead. Co-located in the same file as probe_ch1-3
    # since the 3-lib collapse (ADR-3) made this an intra-file check, not a
    # cross-lib one — cheap insurance, kept anyway.
    declare -F probe_ch1 >/dev/null || die "channel-health-lib.sh probe functions not loaded — refusing to emit a possibly-false serveability verdict"
    local _chan _fn _canon _json _ok
    for _chan in "${_PROVISIONED[@]}"; do
        case "$_chan" in
            ch1*) _fn=probe_ch1; _canon=ch1 ;;
            ch2*) _fn=probe_ch2; _canon=ch2 ;;
            ch3*) _fn=probe_ch3; _canon=ch3 ;;
            *)    continue ;;   # ch4/coturn, ch0/naive (unwired), unknown → not a serve channel
        esac
        _json=$( "$_fn" 2>/dev/null || printf '{"channel_handshake_ok":false}' )
        _ok=$(printf '%s' "$_json" | jq -r '.channel_handshake_ok // false' 2>/dev/null || echo false)
        if [[ "$_ok" == "true" ]]; then
            printf '%s=OK\n' "$_canon"
        else
            printf '%s=DOWN\n' "$_canon"
        fi
    done
}
