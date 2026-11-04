#!/usr/bin/env bash
# relay/relay-probe-lib.sh — the two probes of a relay-only node, shared by the
# heartbeat (oxpulse-relay-health-report.sh) and the post-upgrade health gate
# (oxpulse-relay-upgrade.sh), so "healthy" means the same thing in both.
#
# Why a TCP allocate: the self-relay guard drops coturn's UDP replies to a client
# on this very host, so a UDP-transport allocate from the box itself can never
# succeed by design. The probe talks TCP to 3478 (`turnutils_uclient -t`); the
# allocation it creates is still a UDP relay (no-tcp-relay is set) and `-y` sends
# data between two relayed addresses, which stays inside the reserved relay range
# the guard allows. So the UDP relay legs ARE exercised; only the client->server
# UDP transport is not (use relay_probe_udp_listener for the bind check).
#
# Requires (caller): warn; globals _PREFIX_ETC EXTERNAL_IP RELAY_HOSTNAME.
# Seams: TURN_UCLIENT, OPENSSL_BIN, SS_BIN.
# Contract: every probe returns 0 (ok) / 1 (failed) and sets RELAY_PROBE_REASON
# ("" on success): no-secret | timeout | auth-486 | other | cert-verify.

# relay_probe_allocate — TURN Allocate over TCP against this node's public
# address. RFC 7635 ephemeral credential derived from the FIRST (current) secret
# line; the base secret travels in the environment of one python3 process, never argv.
relay_probe_allocate() {
	local secret user pass out rc
	RELAY_PROBE_REASON=""
	secret=$(head -n1 "${_PREFIX_ETC}/node-secret" 2>/dev/null || true)
	if [[ -z "$secret" ]]; then RELAY_PROBE_REASON="no-secret"; return 1; fi
	user="$(( $(date +%s) + 600 )):healthprobe"
	pass=$(K="$secret" python3 -c \
		'import hmac,hashlib,os,sys,base64; print(base64.b64encode(hmac.new(os.environb[b"K"], sys.argv[1].encode(), hashlib.sha1).digest()).decode())' \
		"$user")
	secret=""
	out=$(timeout 15 "${TURN_UCLIENT:-turnutils_uclient}" -t -u "$user" -w "$pass" -y -n 1 -p 3478 "${EXTERNAL_IP}" 2>&1) && rc=0 || rc=$?
	[[ "$rc" -ne 0 ]] || return 0
	case "$rc" in
		124|143) RELAY_PROBE_REASON=timeout ;;
		*) if printf '%s' "$out" | grep -qiE '486|Allocation Quota Reached'; then RELAY_PROBE_REASON=auth-486; else RELAY_PROBE_REASON=other; fi ;;
	esac
	warn "coturn probe failed (exit=${rc} reason=${RELAY_PROBE_REASON})"
	return 1
}

# relay_probe_tls — TLS handshake to 443 as a TURNS client would do it: SNI and
# hostname verification against the relay hostname, system trust store, chain
# errors are fatal. Connects to the node's own address (no DNS dependency).
relay_probe_tls() {
	local out rc
	RELAY_PROBE_REASON=""
	out=$(printf '' | timeout 15 "${OPENSSL_BIN:-openssl}" s_client -connect "${EXTERNAL_IP}:443" \
		-servername "${RELAY_HOSTNAME}" -verify_hostname "${RELAY_HOSTNAME}" -verify_return_error 2>&1) && rc=0 || rc=$?
	[[ "$rc" -ne 0 ]] || return 0
	case "$rc" in
		124|143) RELAY_PROBE_REASON=timeout ;;
		*) if printf '%s' "$out" | grep -qiE 'verify error|certificate'; then RELAY_PROBE_REASON=cert-verify; else RELAY_PROBE_REASON=other; fi ;;
	esac
	warn "TLS probe failed (exit=${rc} reason=${RELAY_PROBE_REASON})"
	return 1
}

# relay_probe_udp_listener — a UDP socket on 3478 is bound by turnserver. The
# only UDP-transport evidence obtainable on the box (see the header).
relay_probe_udp_listener() {
	RELAY_PROBE_REASON=""
	"${SS_BIN:-ss}" -H -lunp 2>/dev/null | awk '/turnserver/ { for (i = 1; i <= NF; i++) if ($i ~ /:3478$/) f = 1 } END { exit !f }' && return 0
	RELAY_PROBE_REASON=no-udp-listener
	warn "no turnserver UDP listener on :3478"
	return 1
}
