#!/usr/bin/env bash
# oxpulse-channels-health-report.sh — per-channel REAL end-to-end tunnel
# probe + health report to the central server via
# POST /api/partner/channel-health.
#
# Invoked by oxpulse-channels-health-report.timer every 60s.
# Each provisioned channel produces one POST with the server's schema:
#   { node_id, channel_name, channel_rtt_ms?, channel_handshake_ok?,
#     channel_probed_at }
#
# probe_ch1/ch2/ch3 each dial all the way through their own tunnel/upstream
# to the central backend's lightweight /api/health (or the local canary
# route that fronts it) — NOT a local container-liveness check. A relay
# whose process is up but whose tunnel is DPI-blocked end-to-end (live-
# verified on zvonilka: xray listening, VLESS-Reality 502 on the real path)
# now reports channel_handshake_ok=false instead of a false-healthy local
# check. ch1-ch3 run CONCURRENTLY (backgrounded, each bounded by its own
# curl --max-time via OXPULSE_CHANNEL_PROBE_TIMEOUT) so one blocked channel
# cannot delay the others.
#
# Usage:
#   oxpulse-channels-health-report           — probe + report, exit
#   oxpulse-channels-health-report --dry-run — print JSON to stdout, skip POST
#   oxpulse-channels-health-report --once    — synonym for default (for clarity)
#   oxpulse-channels-health-report --curl-trace — log Authorization header (dry-run only)
#
# Federation plan §12, M2 #6a.
set -euo pipefail

# ---------- paths / env ----------
_SBIN=/usr/local/sbin
_TOKEN_LIB="${_TOKEN_LIB:-${_SBIN}/oxpulse-token-lib.sh}"
_PREFIX_ETC="${PARTNER_EDGE_PREFIX_ETC:-/etc/oxpulse-partner-edge}"
_NODE_CONFIG="${_NODE_CONFIG:-${_PREFIX_ETC}/node-config.json}"

# Prefer installed defaults.conf (canonical share path — Bug 8 fix);
# fall back to repo-relative for local testing.
# install-systemd.sh installs this to /usr/local/share/oxpulse-partner-edge/config/.
_DEFAULTS_CONF="${_DEFAULTS_CONF:-/usr/local/share/oxpulse-partner-edge/config/defaults.conf}"
_DEFAULTS_CONF_LOCAL="${_DEFAULTS_CONF_LOCAL:-$(dirname "$0")/config/defaults.conf}"

# lib/peer-ip-guard-lib.sh sha-verified install path — same PREFIX_SBIN as
# _TOKEN_LIB above, and the same install target telegram-alert-lib.sh uses
# (the existing lib consumed by THIS script's transition detector; installed
# by lib/install-systemd.sh's _systemd_install_lib_scripts AND synced to
# existing fleet nodes by upgrade.sh's _HOST_SCRIPT_SBIN_FILES). Repo-relative
# fallback is for local dev/test runs from a checkout only.
_PEER_IP_GUARD_LIB="${_PEER_IP_GUARD_LIB:-${_SBIN}/peer-ip-guard-lib.sh}"
_PEER_IP_GUARD_LIB_LOCAL="${_PEER_IP_GUARD_LIB_LOCAL:-$(dirname "$0")/lib/peer-ip-guard-lib.sh}"

# ---------- flags ----------
DRY_RUN=0
CURL_TRACE=0
SERVE_ONLY=0

for _arg in "$@"; do
    case "$_arg" in
        --dry-run)    DRY_RUN=1 ;;
        --curl-trace) CURL_TRACE=1 ;;
        --serveability) SERVE_ONLY=1 ;;   # settle-gate probe-only mode (see _emit_serveability)
        --once)       ;;   # no-op; timer drives cadence, --once is for clarity
        *) printf 'WARN: unknown flag: %s\n' "$_arg" >&2 ;;
    esac
done
unset _arg

# ---------- logging ----------
log()  { printf '[oxpulse-health] %s\n' "$*" >&2; }
warn() { printf '[oxpulse-health] WARN: %s\n' "$*" >&2; }
die()  { printf '[oxpulse-health] ERR:  %s\n' "$*" >&2; exit 1; }

# ---------- load token lib ----------
if [[ -r "$_TOKEN_LIB" ]]; then
    # shellcheck source=/dev/null
    source "$_TOKEN_LIB"
else
    # Inline fallback — same logic as oxpulse-token-lib.sh.
    read_service_token() {
        if [[ -n "${OXPULSE_SERVICE_TOKEN:-}" ]]; then
            printf '%s' "$OXPULSE_SERVICE_TOKEN"; return 0
        fi
        if [[ -r "${_PREFIX_ETC}/token" ]]; then
            cat "${_PREFIX_ETC}/token"; return 0
        fi
        return 1
    }
fi

# ---------- load peer-ip-guard-lib.sh (SSRF / internal-IP classification) ----------
# Security-critical (SEC-CR-301/306/322-02): sourced fail-closed from the
# sha-verified installed dir (install-systemd.sh syncs, lib-checksums.txt
# verifies at install time — ADR-6 of the 2026-07-08 health-report-lib-
# extraction plan). NOT re-fetched per-tick — the integrity gate already ran
# upstream at install/upgrade time; a 60s-cadence network round-trip just to
# re-verify would be pure cost for zero added safety.
#
# Unlike the token-lib load above, there is NO inline duplicate-logic
# fallback here: an SSRF guard that silently degrades to a second, drift-
# prone copy is worse than one that refuses to run. If neither the installed
# nor the repo-relative (local dev/test) path resolves, die loudly.
if [[ -r "$_PEER_IP_GUARD_LIB" ]]; then
    # shellcheck source=/dev/null
    source "$_PEER_IP_GUARD_LIB"
elif [[ -r "$_PEER_IP_GUARD_LIB_LOCAL" ]]; then
    # shellcheck source=/dev/null
    source "$_PEER_IP_GUARD_LIB_LOCAL"
else
    die "peer-ip-guard-lib.sh not found (checked $_PEER_IP_GUARD_LIB and $_PEER_IP_GUARD_LIB_LOCAL) — refusing to run without the SSRF guard"
fi

# ---------- load defaults.conf ----------
if [[ -r "$_DEFAULTS_CONF" ]]; then
    # shellcheck source=/dev/null
    source "$_DEFAULTS_CONF"
elif [[ -r "$_DEFAULTS_CONF_LOCAL" ]]; then
    # shellcheck source=/dev/null
    source "$_DEFAULTS_CONF_LOCAL"
fi

OXPULSE_BACKEND_API="${OXPULSE_BACKEND_API:-${OXPULSE_BACKEND_URL:-https://api.oxpulse.chat}}"
OXPULSE_BACKEND_API="${OXPULSE_BACKEND_API%/}"

# ---------- preflight ----------
command -v jq    >/dev/null 2>&1 || die "jq not found — install jq"
command -v curl  >/dev/null 2>&1 || die "curl not found"

[[ -r "$_NODE_CONFIG" ]] || die "node-config.json not found at $_NODE_CONFIG"

NODE_ID=$(jq -r '.node_id // empty' "$_NODE_CONFIG" 2>/dev/null)
[[ -n "$NODE_ID" ]] || die "node_id missing in $_NODE_CONFIG"

# ---------- installer version (defence-in-depth freshness signal) ----------
# Read installer bundle version from the VERSION file (same source as hydrate.sh).
# Canonical install path: /usr/local/share/oxpulse-partner-edge/VERSION.
# Local-dev / CI fallback: script-dir VERSION.
# Operator override: OXPULSE_INSTALLER_VERSION env (matches OXPULSE_BACKEND_API pattern).
# Test override: _VERSION_FILE env (set by tests to avoid hitting the real install path).
# If the file is unreadable or empty, the field is omitted from the payload;
# the server COALESCE-preserves the prior value — no DB write, no failure.
_VERSION_FILE="${_VERSION_FILE:-/usr/local/share/oxpulse-partner-edge/VERSION}"
_installer_version=""
if [[ -n "${OXPULSE_INSTALLER_VERSION:-}" ]]; then
    _installer_version="$OXPULSE_INSTALLER_VERSION"
elif [[ -r "$_VERSION_FILE" ]]; then
    _installer_version=$(awk '{print $1; exit}' "$_VERSION_FILE" 2>/dev/null || true)
fi

# ---------- helper: elapsed milliseconds ----------
# Args: t0 t1 (EPOCHREALTIME floats)
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
        cat "$f"
        return 0
    fi
    return 1
}

# ---------- resolve peer-roster path ----------
_peer_roster_file() {
    local state_dir="${STATE_DIR:-/var/lib/oxpulse-partner-edge}"
    printf '%s' "${_PEER_ROSTER_FILE:-$state_dir/peer-roster.json}"
}

# ---------- SSRF / internal-IP guard ----------
# _ip_is_internal / _host_is_internal / _ipv4_literal_is_suspect /
# _ipv6_embedded_v4 now live in lib/peer-ip-guard-lib.sh (P1 of the
# 2026-07-08 health-report-lib-extraction plan) — sourced fail-closed
# below (see "load peer-ip-guard-lib.sh" block). Moved verbatim; see
# that file's header for the SEC-CR-301/306/322-02 threat-class citations
# and tests/test_peer_ip_guard_lib.sh for the ported assertions.

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
#       krolik → the two probers disagree, SEC-CR-322-01).
#   -verify_return_error  hard-fail (non-zero exit) on any verification error,
#       trusting the host system CA store. Together with -verify_hostname this
#       MIRRORS krolik's probe_tls_allocate (rustls + webpki-roots: chain AND SAN,
#       never danger_accept_invalid_certs) so the two probers agree on coturn-tls.
#   -brief </dev/null  one handshake, no interactive stdin, concise output.
#
# WHY NOT turnutils_uclient -S (the original #306 leg): coturn 4.6.3
# turnutils_uclient does NOT send SNI when dialing TURNS over TLS, so caddy-l4's
# SNI-mux cannot pick a route and answers EVERY probe — even the edge's OWN :443
# — with a TLS "internal error" alert (exit 255). The 30/30 bash tests mocked
# turnutils so never caught it; ruoxp (first real bash prober, 2026-06-16)
# surfaced it: host openssl/curl complete TLS1.3+SNI to the same endpoints while
# in-container turnutils fails. openssl is the host tool that drives the SNI-mux.
#
# Signal difference vs krolik: krolik additionally does a TURN Allocate (auth)
# after the TLS handshake; this leg stops at TLS+cert. The only divergence is a
# peer whose TLS is up but coturn auth is broken (rare; shared TURN_SECRET is
# stable) — krolik would report it down, this leg up, the quorum then DISAGREES
# → no withdrawal (conservative/safe). All other failure modes (down/blackholed
# :443, expired/mismatched cert, non-coturn backend) agree.
#
# SEC-CR-302 (DNS-rebinding TOCTOU) — residual UNCHANGED from the turnutils leg:
# _host_is_internal resolves+vets the host, but openssl re-resolves the SAME
# hostname at dial time. Bounded: the roster is SERVER-CURATED (P2 only lists
# vetted partner edges). UNLIKE turnutils, openssl CAN close this cleanly —
# `-connect <vetted-IP>:<port> -servername <hostname>` dials the pre-vetted IP
# while keeping SNI = hostname — once the caller threads the resolved IP through.
# Tracked in docs/FOLLOWUPS.md as MEDIUM; the connect-IP+SNI fix is now a clean
# follow-up (was IMPOSSIBLE with turnutils). BLOCKING before default-ON fleetwide.
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
    # the peer's coturn). This MIRRORS krolik's probe_tls_allocate TLS layer
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
    # Empirically verified on ruoxp 2026-06-16: up→0, bogus→1, wrong-SNI→1.
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
# needs krolik + at least one other clean edge to agree.  This is the same
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
    stun_out=$(timeout "${OXPULSE_PEER_UDP_STUN_TIMEOUT:-5}" \
        docker exec oxpulse-partner-coturn \
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
    http_code=$(curl -s -o /dev/null -w '%{http_code}' \
        --max-time "${OXPULSE_PEER_PROBE_POST_TIMEOUT:-8}" \
        -X POST \
        -H 'Content-Type: application/json' \
        -H "Authorization: Bearer $token" \
        -d "$body" \
        "${OXPULSE_BACKEND_API}/api/partner/channel-health" \
        2>/dev/null || echo '000')

    if [[ "$http_code" =~ ^2 ]]; then
        log "cross-probe target=$target_node_id reported OK (HTTP $http_code)"
        return 0
    elif [[ "$http_code" == "429" || "$http_code" == "408" ]]; then
        # TRANSIENT (RFC 6585): rate-limited / request-timeout — NOT a revoked
        # token. The central sizes a dedicated channel-health limiter and sends
        # Retry-After; the 60s timer is our back-off, so just skip this tick and
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
        turn_secret=$(timeout 10 docker exec oxpulse-partner-coturn \
            sed -n 's/^static-auth-secret=//p' \
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
        # (#2064) + krolik's probe_tls_allocate both key on coturn-tls; sending the
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
        --arg iv "$_installer_version" \
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
    http_code=$(curl -s -o /dev/null -w '%{http_code}' \
        --max-time 15 \
        -X POST \
        -H 'Content-Type: application/json' \
        -H "Authorization: Bearer $token" \
        -d "$full_payload" \
        "${OXPULSE_BACKEND_API}/api/partner/channel-health" \
        2>/dev/null || echo '000')

    if [[ "$http_code" =~ ^2 ]]; then
        log "channel $channel_name reported OK (HTTP $http_code)"
        return 0
    elif [[ "$http_code" == "429" || "$http_code" == "408" ]]; then
        # TRANSIENT (RFC 6585): rate-limited / request-timeout — NOT an auth
        # failure. Back off (the 60s timer is our retry; central sends
        # Retry-After) and retry next tick. Must NOT return 1, or a recoverable
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

# ---------- main ----------
mapfile -t _PROVISIONED < <(jq -r '.channels[]?.id // empty' "$_NODE_CONFIG" 2>/dev/null || true)

# Serve-ability probe mode: emit chN=OK|DOWN and exit BEFORE the report/POST/
# peer-probe machinery. Safe on a box with no channels (emits nothing, exit 0).
if [[ "${SERVE_ONLY:-0}" -eq 1 ]]; then
    _emit_serveability
    exit 0
fi

if [[ "${#_PROVISIONED[@]}" -eq 0 ]]; then
    log "no channels in node-config.json — nothing to report"
    # A node with no local channels can still be a prober (P3b mesh producer);
    # run the peer-probe pass before exiting. ||true shields set -e (mirrors the
    # probe_ch4 ||-guard convention) — the loop self-skips on no token/roster.
    _run_peer_probe_loop || true
    _check_upstream_transitions
    exit 0
fi

_AUTH_FAIL=0

# Concurrency (real-tunnel rewrite): each provisioned channel's probe is
# backgrounded so a single stuck/blocked channel (e.g. ch1 blackholed by
# ТСПУ) cannot delay the others' reports. Every probe's own external call is
# bounded by its own hard timeout (curl --max-time via
# OXPULSE_CHANNEL_PROBE_TIMEOUT for ch1/ch2/ch3; probe_ch4 keeps its existing
# internal `timeout` calls) — nothing backgrounded here can hang forever.
# Results land in per-channel temp files under a private mktemp -d dir, then
# POST runs serially afterwards (POST already has its own bounded --max-time
# and gains nothing from concurrency; only the PROBE phase was ever the
# source of head-of-line blocking).
#
# NOTE: deliberately NOT using an EXIT trap for cleanup here — this dir is
# read-and-removed inline below, well before _run_peer_probe_loop runs, and
# that function unconditionally clears EXIT/TERM/INT traps on its normal
# return path (`trap - EXIT TERM INT`), which would silently clobber any
# trap registered here.
_CHAN_TMPROOT=$(mktemp -d) || die "mktemp -d failed for channel-probe concurrency"

declare -a _CHAN_NAMES=()
declare -a _CHAN_OUT=()
_chan_idx=0

for _chan in "${_PROVISIONED[@]}"; do
    # Channel ids in node-config may carry a node-specific suffix (e.g. "ch1-zvonilka").
    # Match on prefix: ch1* = Reality/VLESS, ch2* = AmneziaWG, ch3* = Hysteria2.
    # The server expects canonical names ch1/ch2/ch3, not the local variant.
    case "$_chan" in
        ch1*)
            _probe_fn=probe_ch1
            _fallback='{"channel_name":"ch1","channel_handshake_ok":false}'
            ;;
        ch2*)
            _probe_fn=probe_ch2
            _fallback='{"channel_name":"ch2","channel_handshake_ok":false}'
            ;;
        ch3*)
            _probe_fn=probe_ch3
            _fallback='{"channel_name":"ch3","channel_rtt_ms":0,"channel_handshake_ok":false}'
            ;;
        ch4*)
            _probe_fn=probe_ch4
            # The fallback here mirrors probe_ch4's own ||-guard convention:
            # probe_ch4 relies on being called through a shielded fallback to
            # remain safe under set -e; it must not be called bare elsewhere.
            _fallback='{"channel_name":"coturn","channel_rtt_ms":0,"channel_handshake_ok":false,"channel_probe_mode":"error"}'
            ;;
        ch0*|naive*|ch5*|ch6*)
            # ch0 = naive/socks fallback channel (install.sh PROTOCOL_ID_MAP
            # defaults unmapped protocols, incl. naive, to ch0). No probe_ch0
            # exists yet — this is a deployed-but-unprobed channel, not a
            # misroute, so it gets the honest "not yet wired" skip rather
            # than falling into the "unknown channel" catch-all below. The
            # real naive health probe is tracked separately (Escalation #3).
            log "$_chan not yet wired on edge — skipping"
            continue
            ;;
        *)
            warn "unknown channel '$_chan' — skipping"
            continue
            ;;
    esac

    _chan_out="$_CHAN_TMPROOT/$_chan_idx.json"
    _chan_idx=$((_chan_idx + 1))
    ( "$_probe_fn" 2>/dev/null || printf '%s' "$_fallback" ) > "$_chan_out" &
    _CHAN_NAMES+=("$_chan")
    _CHAN_OUT+=("$_chan_out")
done

# Block until every backgrounded probe above has written its result file.
# Bare `wait` (no PID args) waits for ALL background jobs and always returns
# 0 — it cannot itself trip `set -e`, so no `|| true` guard is needed.
wait

for _i in "${!_CHAN_NAMES[@]}"; do
    _payload=$(cat "${_CHAN_OUT[$_i]}" 2>/dev/null || true)
    if [[ -z "$_payload" ]]; then
        warn "${_CHAN_NAMES[$_i]}: empty probe result file — reporting as failed"
        _payload="{\"channel_name\":\"${_CHAN_NAMES[$_i]}\",\"channel_handshake_ok\":false}"
    fi
    if ! _post_channel "$_payload"; then
        _AUTH_FAIL=$((_AUTH_FAIL + 1))
    fi
done

rm -rf "$_CHAN_TMPROOT"

# P3b mesh producer — probe roster peers' TURNS:443 + report prober-attributed
# verdicts. Hung after the self-channel loop, before the auth-fail gate, so a
# peer-probe never masks a self-report auth failure. ||true shields set -e (the
# loop returns 0 on every path; self-skips on no token/roster).
_run_peer_probe_loop || true

# auth failures = exit 1 (timer logs; no infinite loop)
[[ "$_AUTH_FAIL" -eq 0 ]] || exit 1

_check_upstream_transitions
exit 0
