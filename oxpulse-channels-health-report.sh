#!/usr/bin/env bash
# oxpulse-channels-health-report.sh — per-channel liveness probe + health report
# to the central server via POST /api/partner/channel-health.
#
# Invoked by oxpulse-channels-health-report.timer every 60s.
# Each provisioned channel produces one POST with the server's schema:
#   { node_id, channel_name, channel_rtt_ms?, channel_handshake_ok?,
#     channel_probed_at }
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

# ---------- flags ----------
DRY_RUN=0
CURL_TRACE=0

for _arg in "$@"; do
    case "$_arg" in
        --dry-run)    DRY_RUN=1 ;;
        --curl-trace) CURL_TRACE=1 ;;
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

# ---------- probe: ch1 — xray dokodemo-door :3080 ----------
# RTT = container exec time (ms). handshake_ok = listener present.
probe_ch1() {
    local t0 t1 exit_code rtt_ms

    t0="${EPOCHREALTIME}"
    docker exec oxpulse-partner-xray ss -ltn 2>/dev/null | grep -q ':3080'
    exit_code=$?
    t1="${EPOCHREALTIME}"

    rtt_ms=$(_elapsed_ms "$t0" "$t1")

    if [[ "$exit_code" -eq 0 ]]; then
        printf '{"channel_name":"ch1","channel_rtt_ms":%d,"channel_handshake_ok":true}' "$rtt_ms"
    else
        printf '{"channel_name":"ch1","channel_rtt_ms":%d,"channel_handshake_ok":false}' "$rtt_ms"
    fi
}

# ---------- probe: ch2 — AmneziaWG mesh ping ----------
# ch2: no RTT concept (awg-show is age-based). handshake_ok = ping reachable.
probe_ch2() {
    local motherly_ip exit_code

    motherly_ip="${OXPULSE_AWG_MOTHERLY_IP:-10.9.0.2}"

    ping -c 1 -W 2 "$motherly_ip" >/dev/null 2>&1
    exit_code=$?

    if [[ "$exit_code" -eq 0 ]]; then
        printf '{"channel_name":"ch2","channel_handshake_ok":true}'
    else
        printf '{"channel_name":"ch2","channel_handshake_ok":false}'
    fi
}

# ---------- probe: ch3 — Hysteria2 TCP forwarder ----------
# RTT = nc connect time (ms). No handshake concept for Hysteria2 UDP.
probe_ch3() {
    local listen port t0 t1 exit_code rtt_ms

    # Derive port from OXPULSE_HY2_LOCAL_LISTEN (addr:port) or override.
    listen="${OXPULSE_HY2_LOCAL_LISTEN:-0.0.0.0:18443}"
    port="${listen##*:}"
    port="${OXPULSE_HY2_FALLBACK_PORT:-${port:-18443}}"

    t0="${EPOCHREALTIME}"
    nc -z 127.0.0.1 "$port" >/dev/null 2>&1
    exit_code=$?
    t1="${EPOCHREALTIME}"

    if [[ "$exit_code" -eq 0 ]]; then
        rtt_ms=$(_elapsed_ms "$t0" "$t1")
    else
        rtt_ms=0
    fi

    # channel_handshake_ok intentionally absent for ch3 (no handshake concept).
    printf '{"channel_name":"ch3","channel_rtt_ms":%d}' "$rtt_ms"
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
# a loopback address, which the production anti-SSRF guard
# `denied-peer-ip=127.0.0.0-127.255.255.255` (turnserver.conf) DENIES at
# CreatePermission — the data round-trip never completes, `timeout` kills the
# client (exit 124), handshake_ok is reported false on a perfectly healthy
# coturn, AND the killed client leaks its two allocations every tick (no
# graceful dealloc) which can wedge the public allocation quota into a
# persistent 486.  The fix is to point the probe at the address real clients
# use — the server's PUBLIC/external IP, which is NOT in the denied range — so
# the relayed peer is a public relay address and CreatePermission succeeds.
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
        warn "ch4: could not resolve public probe target — falling back to 127.0.0.1 (anti-SSRF denied-peer-ip will deny the -y self-test; expect a false negative)"
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
        if [[ "$exit_code" -ne 0 ]]; then
            case "$exit_code" in
                124|143)
                    # timeout(1) SIGTERM/SIGKILL — the data round-trip never
                    # completed (the classic anti-SSRF denied-peer collision, or
                    # a genuinely dead relay path).
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

    # channel_probe_mode is also emitted in the JSON payload — the central
    # server receives it over the wire (POST body is NOT swallowed), giving a
    # second, observable degraded signal independent of edge-local stderr.
    # channel_probe_reason is added only on failure (the _post_channel jq filter
    # preserves extra fields), so a false-negative carries its cause to the
    # central server instead of an opaque handshake_ok=false.
    if [[ "$exit_code" -eq 0 ]]; then
        printf '{"channel_name":"coturn","channel_rtt_ms":%d,"channel_handshake_ok":true,"channel_probe_mode":"%s"}' "$rtt_ms" "$probe_mode"
    else
        printf '{"channel_name":"coturn","channel_rtt_ms":%d,"channel_handshake_ok":false,"channel_probe_mode":"%s","channel_probe_reason":"%s"}' "$rtt_ms" "$probe_mode" "${probe_reason:-unknown}"
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

# ---------- main ----------
mapfile -t _PROVISIONED < <(jq -r '.channels[]?.id // empty' "$_NODE_CONFIG" 2>/dev/null || true)

if [[ "${#_PROVISIONED[@]}" -eq 0 ]]; then
    log "no channels in node-config.json — nothing to report"
    _check_upstream_transitions
    exit 0
fi

_AUTH_FAIL=0

for _chan in "${_PROVISIONED[@]}"; do
    # Channel ids in node-config may carry a node-specific suffix (e.g. "ch1-zvonilka").
    # Match on prefix: ch1* = Reality/VLESS, ch2* = AmneziaWG, ch3* = Hysteria2.
    # The server expects canonical names ch1/ch2/ch3, not the local variant.
    case "$_chan" in
        ch1*)
            _payload=$(probe_ch1 2>/dev/null || printf '{"channel_name":"ch1","channel_handshake_ok":false}')
            ;;
        ch2*)
            _payload=$(probe_ch2 2>/dev/null || printf '{"channel_name":"ch2","channel_handshake_ok":false}')
            ;;
        ch3*)
            _payload=$(probe_ch3 2>/dev/null || printf '{"channel_name":"ch3","channel_rtt_ms":0}')
            ;;
        ch4*)
            _payload=$(probe_ch4 2>/dev/null || printf '{"channel_name":"coturn","channel_rtt_ms":0,"channel_handshake_ok":false,"channel_probe_mode":"error"}')
            ;;
        ch5*|ch6*)
            log "$_chan not yet wired on edge — skipping"
            continue
            ;;
        *)
            warn "unknown channel '$_chan' — skipping"
            continue
            ;;
    esac

    if ! _post_channel "$_payload"; then
        _AUTH_FAIL=$((_AUTH_FAIL + 1))
    fi
done

# auth failures = exit 1 (timer logs; no infinite loop)
[[ "$_AUTH_FAIL" -eq 0 ]] || exit 1

_check_upstream_transitions
exit 0
