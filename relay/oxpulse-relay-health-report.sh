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

# probe_relay_coturn — TURN Allocate over TCP against this node's public address.
# RFC 7635 ephemeral credential derived from the FIRST (current) secret line; the
# base secret travels in the environment of one python3 process, never argv.
probe_relay_coturn() {
	local secret user pass out rc t0 t1 reason="" ok=true
	secret=$(head -n1 "${_PREFIX_ETC}/node-secret" 2>/dev/null || true)
	if [[ -z "$secret" ]]; then
		printf '{"channel_name":"coturn","channel_rtt_ms":0,"channel_handshake_ok":false,"channel_probe_mode":"allocate-tcp","channel_probe_reason":"no-secret"}'
		return 0
	fi
	user="$(( $(date +%s) + 600 )):healthprobe"
	pass=$(K="$secret" python3 -c \
		'import hmac,hashlib,os,sys,base64; print(base64.b64encode(hmac.new(os.environb[b"K"], sys.argv[1].encode(), hashlib.sha1).digest()).decode())' \
		"$user")
	secret=""
	t0="${EPOCHREALTIME}"
	out=$(timeout 15 "${TURN_UCLIENT:-turnutils_uclient}" -t -u "$user" -w "$pass" -y -n 1 -p 3478 "${EXTERNAL_IP}" 2>&1) && rc=0 || rc=$?
	t1="${EPOCHREALTIME}"
	if [[ "$rc" -ne 0 ]]; then
		ok=false
		case "$rc" in
			124|143) reason=timeout ;;
			*) if printf '%s' "$out" | grep -qiE '486|Allocation Quota Reached'; then reason=auth-486; else reason=other; fi ;;
		esac
		warn "coturn probe failed (exit=${rc} reason=${reason})"
	fi
	if [[ "$ok" == true ]]; then
		printf '{"channel_name":"coturn","channel_rtt_ms":%d,"channel_handshake_ok":true,"channel_probe_mode":"allocate-tcp"}' "$(_elapsed_ms "$t0" "$t1")"
	else
		printf '{"channel_name":"coturn","channel_rtt_ms":%d,"channel_handshake_ok":false,"channel_probe_mode":"allocate-tcp","channel_probe_reason":"%s"}' "$(_elapsed_ms "$t0" "$t1")" "$reason"
	fi
}

# probe_relay_tls — TLS handshake to 443 as a TURNS client would do it: SNI and
# hostname verification against the relay hostname, system trust store, chain
# errors are fatal. Connects to the node's own address (no DNS dependency).
probe_relay_tls() {
	local out rc t0 t1 reason=""
	t0="${EPOCHREALTIME}"
	out=$(printf '' | timeout 15 "${OPENSSL_BIN:-openssl}" s_client -connect "${EXTERNAL_IP}:443" \
		-servername "${RELAY_HOSTNAME}" -verify_hostname "${RELAY_HOSTNAME}" -verify_return_error 2>&1) && rc=0 || rc=$?
	t1="${EPOCHREALTIME}"
	if [[ "$rc" -eq 0 ]]; then
		printf '{"channel_name":"coturn-tls","channel_rtt_ms":%d,"channel_handshake_ok":true,"channel_probe_mode":"tls-verify"}' "$(_elapsed_ms "$t0" "$t1")"
		return 0
	fi
	case "$rc" in
		124|143) reason=timeout ;;
		*) if printf '%s' "$out" | grep -qiE 'verify error|certificate'; then reason=cert-verify; else reason=other; fi ;;
	esac
	warn "TLS probe failed (exit=${rc} reason=${reason})"
	printf '{"channel_name":"coturn-tls","channel_rtt_ms":%d,"channel_handshake_ok":false,"channel_probe_mode":"tls-verify","channel_probe_reason":"%s"}' "$(_elapsed_ms "$t0" "$t1")" "$reason"
}

rc_all=0
_post_channel "$(probe_relay_coturn)" || rc_all=1
_post_channel "$(probe_relay_tls)" || rc_all=1
exit "$rc_all"
