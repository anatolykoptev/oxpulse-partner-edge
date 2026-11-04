#!/usr/bin/env bash
# oxpulse-relay-health-report.sh — relay-only node heartbeat.
#
# Probes the local coturn and POSTs the results to
# /api/partner/channel-health with the node-scoped service token. That POST is
# what refreshes partner_nodes.last_seen_at centrally (pool liveness), so the
# payload is built and sent by the SAME functions the full edge uses
# (lib/channel-health-lib.sh::_post_channel); only the probe differs.
#
# Why a TCP allocate: the self-relay guard drops coturn's UDP replies to a
# client on this very host, so the probe talks TCP (`turnutils_uclient -t`).
# The UDP relay legs of `-y` stay inside the reserved relay range, which the
# guard allows. Reports two channels from the central allowlist
# (ch1|ch2|ch3|coturn|coturn-udp|coturn-tls):
#   coturn      TURN Allocate over TCP 3478 (the allocation path)
#   coturn-tls  TLS handshake to 443 with SNI = the relay hostname and full chain
#               verification (what a TURNS client actually needs; a dead or
#               expired certificate fails here and nowhere else)
#
#   oxpulse-relay-health-report.sh [--dry-run]
set -euo pipefail

_PREFIX_ETC="${PREFIX_ETC:-/etc/oxpulse-partner-edge}"
_LIB_DIR="${RELAY_LIB_DIR:-/usr/local/lib/oxpulse-relay}"
DRY_RUN=0
CURL_TRACE=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

log()  { printf '[relay-health] %s\n' "$*" >&2; }
warn() { printf '[relay-health] WARN: %s\n' "$*" >&2; }
die()  { printf '[relay-health] ERR:  %s\n' "$*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq not found"
command -v curl >/dev/null 2>&1 || die "curl not found"

# Node-scoped service token: a 0600 file, operator-provided. Never env, never argv.
read_service_token() {
	local f="${_PREFIX_ETC}/service-token" mode uid tok
	[[ -f "$f" && ! -L "$f" ]] || return 1
	mode=$(stat -c '%a' "$f" 2>/dev/null || stat -f '%Lp' "$f")
	uid=$(stat -c '%u' "$f" 2>/dev/null || stat -f '%u' "$f")
	[[ "$mode" == 600 ]] || { warn "service-token mode ${mode}, want 600 — refusing to use it"; return 1; }
	[[ "$uid" == "${RELAY_TOKEN_OWNER_UID:-0}" ]] || { warn "service-token owner uid ${uid}, want root — refusing to use it"; return 1; }
	tok=$(tr -d '\n' < "$f")
	[[ "$tok" =~ ^stkn_[A-Za-z0-9_-]{8,}$ ]] || { warn "service-token is not shaped like stkn_<base64url> — refusing to use it"; return 1; }
	printf '%s' "$tok"
}

NODE_ID=$(tr -d '[:space:]' < "${_PREFIX_ETC}/node-id" 2>/dev/null || true)
[[ -n "$NODE_ID" ]] || die "node-id missing at ${_PREFIX_ETC}/node-id"
# shellcheck source=/dev/null
. "${_PREFIX_ETC}/relay.env"
: "${EXTERNAL_IP:?relay.env missing EXTERNAL_IP}" "${RELAY_HOSTNAME:?relay.env missing RELAY_HOSTNAME}"
OXPULSE_BACKEND_API="${OXPULSE_BACKEND_API:-https://api.oxpulse.chat}"
OXPULSE_BACKEND_API="${OXPULSE_BACKEND_API%/}"
_installer_version=""
[[ -r /usr/local/share/oxpulse-partner-edge/VERSION ]] \
	&& _installer_version=$(awk '{print $1; exit}' /usr/local/share/oxpulse-partner-edge/VERSION)
export NODE_ID DRY_RUN CURL_TRACE OXPULSE_BACKEND_API _installer_version

# shellcheck source=lib/channel-health-lib.sh
. "${_LIB_DIR}/channel-health-lib.sh"

# The probes themselves live in relay-probe-lib.sh (shared with the upgrader's
# post-upgrade health gate); here they only get timed and shaped into payloads.
# shellcheck source=relay/relay-probe-lib.sh
. "${_LIB_DIR}/relay-probe-lib.sh"

probe_relay_coturn() {
	local t0 t1 ok=true
	t0="${EPOCHREALTIME}"
	relay_probe_allocate || ok=false
	t1="${EPOCHREALTIME}"
	if [[ "$RELAY_PROBE_REASON" == "no-secret" ]]; then
		printf '{"channel_name":"coturn","channel_rtt_ms":0,"channel_handshake_ok":false,"channel_probe_mode":"allocate-tcp","channel_probe_reason":"no-secret"}'
	elif [[ "$ok" == true ]]; then
		printf '{"channel_name":"coturn","channel_rtt_ms":%d,"channel_handshake_ok":true,"channel_probe_mode":"allocate-tcp"}' "$(_elapsed_ms "$t0" "$t1")"
	else
		printf '{"channel_name":"coturn","channel_rtt_ms":%d,"channel_handshake_ok":false,"channel_probe_mode":"allocate-tcp","channel_probe_reason":"%s"}' "$(_elapsed_ms "$t0" "$t1")" "$RELAY_PROBE_REASON"
	fi
}

probe_relay_tls() {
	local t0 t1 ok=true
	t0="${EPOCHREALTIME}"
	relay_probe_tls || ok=false
	t1="${EPOCHREALTIME}"
	if [[ "$ok" == true ]]; then
		printf '{"channel_name":"coturn-tls","channel_rtt_ms":%d,"channel_handshake_ok":true,"channel_probe_mode":"tls-verify"}' "$(_elapsed_ms "$t0" "$t1")"
	else
		printf '{"channel_name":"coturn-tls","channel_rtt_ms":%d,"channel_handshake_ok":false,"channel_probe_mode":"tls-verify","channel_probe_reason":"%s"}' "$(_elapsed_ms "$t0" "$t1")" "$RELAY_PROBE_REASON"
	fi
}

rc_all=0
_post_channel "$(probe_relay_coturn)" || rc_all=1
_post_channel "$(probe_relay_tls)" || rc_all=1
exit "$rc_all"
