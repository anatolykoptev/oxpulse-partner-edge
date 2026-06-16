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

# ---------- byte-level embedded-v4 extractor (closes SEC-CR-306) ----------
# An IPv6 literal can embed a v4 address in THREE families, each in ANY textual
# encoding (dotted, hex-compressed, uppercase):
#   * IPv4-mapped     ::ffff:a.b.c.d  /  ::ffff:0:0/96   (bytes[0:12]=…0000ffff)
#   * NAT64 well-known 64:ff9b::a.b.c.d /  64:ff9b::/96   (bytes[0:12]=0064ff9b…0)
#   * IPv4-compatible ::a.b.c.d / ::<hex> (deprecated)    (bytes[0:12]=all-zero)
# The PRIOR classifier matched the textual SHAPE (a dotted ".*.*.*.*" tail), so
# hex-compressed forms (::ffff:7f00:1, ::FFFF:7F00:1, ::7f00:1, 64:ff9b::7f00:1)
# slipped past the guard — getaddrinfo/turnutils later re-expand them to the
# internal v4 and connect. SEC-CR-306. We now classify by the 16-byte VALUE, not
# the string: normalize with python3 socket.inet_pton(AF_INET6,…) → if the upper
# 12 bytes match a known v4-bearing prefix, the lower 4 bytes ARE the embedded
# v4. Override the interpreter with OXPULSE_PY_BIN for tests.
#
# stdout: the embedded dotted-quad (when the literal embeds a v4).
# exit 0  → embeds a v4 (caller reclassifies the printed v4 via the v4 path)
# exit 1  → a pure IPv6 literal with NO embedded v4 (caller uses v6 range arms)
# exit 2  → not a parseable v6 literal / ambiguous (caller FAILS CLOSED = reject)
_ipv6_embedded_v4() {
    local py_bin="${OXPULSE_PY_BIN:-python3}"
    L="$1" "$py_bin" -c '
import socket, os, sys
lit = os.environ.get("L", "")
try:
    b = socket.inet_pton(socket.AF_INET6, lit)
except OSError:
    sys.exit(2)
prefix, v4 = b[:12], b[12:16]
MAPPED = bytes(10) + b"\xff\xff"          # ::ffff:0:0/96
NAT64  = b"\x00\x64\xff\x9b" + bytes(8)   # 64:ff9b::/96
ZERO   = bytes(12)                        # ::/96 (compat, ::, ::1)
if prefix in (MAPPED, NAT64, ZERO):
    sys.stdout.write(socket.inet_ntop(socket.AF_INET, v4))
    sys.exit(0)
sys.exit(1)
' 2>/dev/null
}

# ---------- SSRF dial-time recheck (closes P2-SEC-CR-001) ----------
# Returns 0 (TRUE — internal, REJECT) when the host is, or resolves to, a
# loopback / RFC-1918 / link-local / ULA / ::1 address. Returns 1 (public, OK).
#
# Defeats split-horizon / DNS-rebinding: the central SSRF-guards the roster
# STRING at curation time but resolves no DNS (by design — TOCTOU). We resolve
# here, at the dialer, and classify EVERY returned A/AAAA. A host that is an IP
# literal is classified directly (no resolution needed).
#
# Resolution via getent ahosts (honours nsswitch; returns both v4 + v6). A
# resolution failure (NXDOMAIN / timeout) is treated as INTERNAL=reject — we do
# not dial a host we cannot vet (fail-closed). Override the resolver with
# OXPULSE_GETENT_BIN for tests.
_ip_is_internal() {
    local ip="$1"
    # Strip a [..] bracket wrapper (URL-form IPv6 literal: "[::1]") before
    # matching — SEC-CR-301 (brackets must not let ::1 slip past the case arms).
    ip="${ip#[}"; ip="${ip%]}"
    # IPv4-mapped / NAT64 / IPv4-compatible IPv6 ALL embed a v4 — in ANY encoding
    # (dotted, hex-compressed, uppercase). Classify by the 16-byte value, not the
    # textual shape (SEC-CR-306: the old dotted-".*.*.*.*" match let hex through).
    # Only run the byte-level extractor on literals that contain a colon (cheap
    # gate — a bare v4 literal has no ':' and needs no normalization).
    if [[ "$ip" == *:* ]]; then
        local _embedded_v4 _embed_rc
        _embedded_v4=$(_ipv6_embedded_v4 "$ip"); _embed_rc=$?
        case "$_embed_rc" in
            0)
                # Embeds a v4 → classify the embedded v4 via the v4 path. An
                # internal embedded v4 (loopback/RFC-1918/CGNAT/0.0.0.0/…) rejects;
                # a public one (e.g. ::ffff:8.8.8.8) falls through to public.
                _ip_is_internal "$_embedded_v4" && return 0
                return 1
                ;;
            1)
                # Pure IPv6, no embedded v4 → fall through to the v6 range arms
                # (::1 / fe80::/10 / fc00::/7) below.
                : ;;
            *)
                # rc=2 (unparseable / ambiguous v6 literal) OR any other code
                # (python3 unavailable / errored, e.g. 127) → FAIL CLOSED (treat as
                # internal, reject). We never dial a literal we cannot prove is a
                # public pure-v6 address.
                return 0
                ;;
        esac
    fi
    case "$ip" in
        # IPv4 loopback 127.0.0.0/8
        127.*) return 0 ;;
        # "this network" 0.0.0.0/8 (SEC-CR-301) — 0.0.0.0 is also unspecified
        0.*) return 0 ;;
        # RFC-1918 10.0.0.0/8
        10.*) return 0 ;;
        # RFC-1918 192.168.0.0/16
        192.168.*) return 0 ;;
        # link-local / cloud metadata 169.254.0.0/16
        169.254.*) return 0 ;;
        # RFC-1918 172.16.0.0/12 (172.16 – 172.31)
        172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 0 ;;
        # CGNAT 100.64.0.0/10 (100.64 – 100.127) (SEC-CR-301)
        100.6[4-9].*|100.7[0-9].*|100.8[0-9].*|100.9[0-9].*|100.1[0-1][0-9].*|100.12[0-7].*) return 0 ;;
        # IPv6 loopback / unspecified
        ::1|::) return 0 ;;
        # IPv6 link-local fe80::/10  (fe80 – febf)
        [Ff][Ee][89AaBb]*:*) return 0 ;;
        # IPv6 ULA fc00::/7  (fc.. / fd..)
        [Ff][CcDd]*:*) return 0 ;;
        *) return 1 ;;
    esac
}

# ---------- is this token a NON-canonical IPv4 literal? (SEC-CR-301) ----------
# getent / DNS only ever return canonical dotted-decimal v4 or canonical v6.
# A roster host that is an IP LITERAL in any OTHER numeric encoding — hex
# (0x7f000001), octal (0177.0.0.1), bare decimal (2130706433), or short/mixed
# dotted forms (127.1, 10.0x2.3) — can only be an attacker trying to smuggle an
# internal address past a naive dotted-quad classifier. inet_aton accepts ALL of
# them; our regex-based range arms do NOT. We cannot enumerate every encoding,
# so we FAIL CLOSED: any IP-literal-shaped host that is not an UNAMBIGUOUS
# canonical public dotted-quad (four 0-255 octets) is treated as internal.
# Returns 0 (TRUE — suspect, reject) / 1 (clean canonical dotted-quad).
_ipv4_literal_is_suspect() {
    local h="$1"
    # Canonical dotted-quad: exactly four decimal octets, each 0-255, no leading
    # zeros (a leading zero = octal interpretation by inet_aton).
    local o='(0|[1-9][0-9]?|1[0-9][0-9]|2[0-4][0-9]|25[0-5])'
    if [[ "$h" =~ ^${o}\.${o}\.${o}\.${o}$ ]]; then
        return 1   # clean canonical dotted-quad — let the range arms decide
    fi
    return 0       # any other all-numeric-ish literal → suspect → reject
}

_host_is_internal() {
    local host="$1"
    [[ -z "$host" ]] && return 0   # empty host → reject

    # Strip a [..] IPv6-URL-literal wrapper for the literal-shape tests below.
    local bare="$host"
    bare="${bare#[}"; bare="${bare%]}"

    # IPv6 literal (contains a colon, possibly bracketed) → classify directly.
    if [[ "$bare" == *:* ]]; then
        _ip_is_internal "$bare" && return 0
        return 1
    fi

    # A host that LOOKS like a numeric IPv4 literal (starts with a digit, no DNS
    # label letters, or a hex/octal lead) is classified WITHOUT resolution and
    # fail-closed on any non-canonical encoding (SEC-CR-301). This catches
    # 0x7f000001, 0177.0.0.1, 2130706433, 127.1, etc. — inet_aton would dial
    # them as 127.0.0.1, but they never come from getent, so a literal in this
    # shape is adversarial.
    if [[ "$bare" =~ ^0[xX][0-9a-fA-F]+$ \
       || "$bare" =~ ^[0-9]+$ \
       || "$bare" =~ ^[0-9]+(\.[0-9xXa-fA-F]+)+$ ]]; then
        if _ipv4_literal_is_suspect "$bare"; then
            return 0   # non-canonical numeric literal → reject
        fi
        # Canonical dotted-quad → range classification.
        _ip_is_internal "$bare" && return 0
        return 1
    fi

    # Hostname → resolve and classify every returned address. Fail-closed:
    # a resolution failure rejects (we never dial an un-vettable host).
    local getent_bin resolved ip
    getent_bin="${OXPULSE_GETENT_BIN:-getent}"
    # 3s (was 5s) — bounds the per-peer SSRF-recheck slice of the budget
    # arithmetic in _run_peer_probe_loop (getent 3 + probe 8 + post 8 = 19s/peer).
    resolved=$(timeout "${OXPULSE_GETENT_TIMEOUT:-3}" "$getent_bin" ahosts "$host" 2>/dev/null | awk '{print $1}' | sort -u)
    if [[ -z "$resolved" ]]; then
        return 0   # unresolvable → reject
    fi
    while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue
        if _ip_is_internal "$ip"; then
            return 0   # ANY internal address → reject the whole host
        fi
    done <<< "$resolved"
    return 1   # all resolved addresses public → allow
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
# Args: turns_host turns_port turn_secret
# Echoes "<handshake_ok>\t<rtt_ms>"  (handshake_ok = true|false).
#
# Mints an RFC-7635 ephemeral cred against the SHARED TURN_SECRET (identical on
# every edge + krolik coturn) — EXACTLY the probe_ch4 mint block (env-$K/python3,
# OXPULSE_HMAC_BIN seam; secret never on argv). Dials the PEER's TURNS:443 with
# TLS (not the own-coturn plain turn:3478 path):
#
#   turnutils_uclient -S -t -c -p <port> -u <eph-user> -w <eph-pass> -n 1 -X <host>
#
#   -S  Secure SSL/TLS connection (TURNS) — caddy-l4 SNI-muxes :443 by SNI, and
#       turnutils_uclient resolves the positional HOSTNAME and uses it as the
#       TLS SNI, so the peer's caddy routes to its coturn. (verified: Debian
#       coturn manpage + coturn#1333 — hostname positional → SNI.)
#   -t  TCP client transport (TLS rides on TCP). Required with -S over :443.
#   -c  no RTCP connection — one Allocate, lighter, fewer relays.
#   -X  IPv4 relay address explicitly requested (matches real WebRTC clients).
#   -n 1  one message attempt, then exit.
#
#   We do NOT pass -y (client-to-client self-test). The cross-probe signal is
#   "TLS reaches the peer's caddy-l4 by SNI AND a TURN Allocate authenticates
#   against the peer's shared secret" — i.e. the Allocate handshake. -y would
#   relay loopback-to-loopback inside the peer's coturn, tripping its
#   denied-peer-ip/no-loopback-peers guards (a false negative) AND leaking two
#   allocations per probe — the exact failure probe_ch4 had to engineer around
#   for the own-coturn path. A single Allocate with -n 1 then exit holds one
#   short-lived allocation that coturn expires; at ≤cap peers / 60s the rate is
#   bounded.
#
# We pass the HOSTNAME (not a resolved IP) so SNI is correct — the SSRF recheck
# (_host_is_internal) has ALREADY validated every resolved address before this
# function is called.
#
# SEC-CR-302 (DNS-rebinding TOCTOU) — KNOWN RESIDUAL, accepted for now:
# _host_is_internal resolves the host, but turnutils_uclient re-resolves the
# SAME hostname at dial time. A rebinding attacker could answer the recheck with
# a public A record and the dial with an internal one. The clean fix is to dial
# the vetted IP while keeping SNI = hostname — but turnutils_uclient CANNOT do
# that: its only target is the positional <TURN-Server-IP-address>, which it
# ALSO uses as the TLS SNI (coturn#1333). There is no connect-to-IP / SNI-
# override flag (-X = "IPv4 relay address requested" is a TURN-protocol option,
# NOT a connect target; -L = local bind source; -E = CA file). Passing the
# resolved IP positionally would make SNI an IP literal → caddy-l4 :443 SNI-mux
# has no matching route/cert → the probe fails on EVERY healthy peer. We do NOT
# hack turnutils. The residual is bounded today: the roster is SERVER-CURATED
# (P2 only lists vetted partner edges), so an attacker must first compromise the
# central's curation to inject a rebinding host. Tracked in docs/FOLLOWUPS.md as
# MEDIUM, BLOCKING before the loop is flipped default-ON across the fleet.
_probe_peer_coturn() {
    local turns_host="$1"
    local turns_port="$2"
    local turn_secret="$3"
    local turn_username turn_password t0 t1 exit_code rtt_ms uclient_out

    turn_username="$(( $(date +%s) + 600 )):healthprobe"
    local hmac_bin="${OXPULSE_HMAC_BIN:-python3}"
    turn_password=$(K="$turn_secret" "$hmac_bin" -c \
        'import hmac,hashlib,os,sys,base64; print(base64.b64encode(hmac.new(os.environb[b"K"], sys.argv[1].encode(), hashlib.sha1).digest()).decode())' \
        "$turn_username")

    t0="${EPOCHREALTIME}"
    # Dial the peer directly from the prober host/container — NOT docker exec
    # into the peer. turnutils_uclient must run where coturn-utils is installed;
    # the own-coturn container has it, so we exec turnutils_uclient there but
    # TARGET the remote peer host (the container has outbound network).
    # Probe timeout default 8s (was 10s) — see _run_peer_probe_loop BUDGET block:
    # the per-peer worst case (getent 3 + probe 8 + post 8 = 19s) × cap must fit
    # TimeoutStartSec; shrinking this is one of the three levers that makes the
    # arithmetic hold.
    uclient_out=$(timeout "${OXPULSE_PEER_PROBE_TIMEOUT:-8}" \
        docker exec oxpulse-partner-coturn \
        turnutils_uclient \
            -S -t -c \
            -p "$turns_port" \
            -u "$turn_username" \
            -w "$turn_password" \
            -n 1 -X \
            "$turns_host" \
        2>&1)
    exit_code=$?
    t1="${EPOCHREALTIME}"
    rtt_ms=$(_elapsed_ms "$t0" "$t1")

    # Success classification: a peerless Allocate over TLS prints an allocation
    # success line ("success" / "allocate" / a relay address) even though it
    # receives 0 echoed bytes (no peer). exit 0 OR an explicit allocate-success
    # in output = handshake_ok=true. A TLS/auth failure prints no allocate
    # success and exits non-zero. We treat exit 0 as the primary signal and the
    # output grep as a fallback so a clean Allocate that times out waiting for a
    # (non-existent) peer echo is not misreported as a failure.
    if [[ "$exit_code" -eq 0 ]] || \
       printf '%s' "$uclient_out" | grep -qiE 'allocate[d]? (success|address)|relay address|success.*0x0003'; then
        printf 'true\t%d' "$rtt_ms"
    else
        warn "peer-probe: $turns_host:$turns_port handshake failed (exit=$exit_code): $(printf '%s' "$uclient_out" | tail -n2 | tr '\n' ' ')"
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
# no security benefit — the UDP dial uses the same already-vetted host.
_probe_peer_udp_stun() {
    local stun_host="$1"
    local stun_port="$2"
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
        turnutils_stunclient "$stun_host" -p "$stun_port" \
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
    local channel_name="${5:-coturn}"   # "coturn" | "coturn-udp"

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
# For each peer (capped at OXPULSE_PEER_PROBE_MAX): SSRF dial-recheck → mint →
# TLS Allocate → POST. Bounded for the TimeoutStartSec=90 budget (see the BUDGET
# block below for the arithmetic). Rotates the probed slice per cycle (MINOR 5)
# and writes a SIGTERM-safe marker (MAJOR 1).
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
    #   + TLS Allocate probe        timeout 8s   (OXPULSE_PEER_PROBE_TIMEOUT, _probe_peer_coturn)
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
        # target the same turns_host; a single recheck covers both).
        if _host_is_internal "$turns_host"; then
            warn "peer-probe: REJECT $node_id ($turns_host) — resolves internal/unresolvable (SSRF guard)"
            rejected=$((rejected + 1))
            scanned=$((scanned + 1))
            _PEER_PROBE_REJECTED="$rejected"
            continue
        fi

        # ── TLS leg (coturn) ────────────────────────────────────────────────────
        result=$(_probe_peer_coturn "$turns_host" "$turns_port" "$turn_secret")
        handshake_ok="${result%%$'\t'*}"
        rtt="${result##*$'\t'}"
        probed=$((probed + 1))
        scanned=$((scanned + 1))
        [[ "$handshake_ok" == "true" ]] && ok_count=$((ok_count + 1))

        # MINOR 6: capture a persistent-4xx signal. _post_cross_probe returns 1
        # ONLY on a 4xx (revoked token / roster-membership) — distinct from the
        # 5xx/000 transient path which returns 0. Without this the `|| true`
        # swallows the 4xx and a revoked token loops forever invisibly.
        if ! _post_cross_probe "$node_id" "$handshake_ok" "$rtt" "$token" "coturn"; then
            post_4xx=1
        fi

        # ── UDP leg (coturn-udp) ─────────────────────────────────────────────────
        # Probe the peer's STUN/UDP port (3478 by default) via a plain STUN Binding
        # request. The SSRF guard above already vetted turns_host; no second getent
        # needed. The same xprb_ token and POST endpoint are used — no new auth path.
        result=$(_probe_peer_udp_stun "$turns_host" "$udp_port")
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
    # A node with no local channels can still be a prober (P3b mesh producer);
    # run the peer-probe pass before exiting. ||true shields set -e (mirrors the
    # probe_ch4 ||-guard convention) — the loop self-skips on no token/roster.
    _run_peer_probe_loop || true
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
            # The || here suppresses set -e for probe_ch4; probe_ch4 relies on
            # this ||-shielded call site to remain safe under set -e — it must
            # not be called bare (without ||) elsewhere in this script.
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

# P3b mesh producer — probe roster peers' TURNS:443 + report prober-attributed
# verdicts. Hung after the self-channel loop, before the auth-fail gate, so a
# peer-probe never masks a self-report auth failure. ||true shields set -e (the
# loop returns 0 on every path; self-skips on no token/roster).
_run_peer_probe_loop || true

# auth failures = exit 1 (timer logs; no infinite loop)
[[ "$_AUTH_FAIL" -eq 0 ]] || exit 1

_check_upstream_transitions
exit 0
