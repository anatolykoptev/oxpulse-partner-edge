#!/usr/bin/env bash
# relay/relay-lib.sh — helpers for the relay-only node profile (install-relay.sh).
#
# A relay-only node runs coturn and nothing else. It holds exactly one TURN
# credential, its own per-node secret, and never registers with the backend.
#
# Requires (caller): log warn die. Sourced, not executed.
# Test seams: PREFIX_ETC (default /etc/oxpulse-partner-edge).

RELAY_PREFIX_ETC="${PREFIX_ETC:-/etc/oxpulse-partner-edge}"

# Environment variables that carry material a relay-only node must never hold.
RELAY_FORBIDDEN_ENV=(
	SIGNALING_SFU_SECRET signaling_sfu_secret
	TURN_PARTNER_LEGACY TURN_CENTRAL_SECRET TURN_SECRET
	ROOM_HMAC_KEY
	REALITY_PRIVATE_KEY REALITY_PRIVATE_KEY_B64 REALITY_SHORT_ID
	OXPULSE_SERVICE_TOKEN
)
# Files the full register/install path leaves behind. Any of them present means
# this host is (or was) a full partner edge, not a relay-only node.
RELAY_FORBIDDEN_FILES=(node-config.json token .env reality.priv awg-private.key sfu-signing-key)
# Text that must not appear in any file under the prefix.
RELAY_FORBIDDEN_TEXT='signaling_sfu_secret|SIGNALING_SFU_SECRET|TURN_PARTNER_LEGACY|TURN_CENTRAL_SECRET|ROOM_HMAC_KEY'

# relay_assert_no_registration_material — fail closed. Prints names only, never values.
relay_assert_no_registration_material() {
	local v f hit=()
	for v in "${RELAY_FORBIDDEN_ENV[@]}"; do
		[[ -z "${!v:-}" ]] || hit+=("env ${v}")
	done
	for f in "${RELAY_FORBIDDEN_FILES[@]}"; do
		[[ ! -e "${RELAY_PREFIX_ETC}/${f}" ]] || hit+=("file ${RELAY_PREFIX_ETC}/${f}")
	done
	if [[ -d "${RELAY_PREFIX_ETC}" ]]; then
		while IFS= read -r f; do
			[[ -n "$f" ]] && hit+=("secret name inside ${f}")
		done < <(grep -rIlE "${RELAY_FORBIDDEN_TEXT}" "${RELAY_PREFIX_ETC}" 2>/dev/null || true)
	fi
	if ((${#hit[@]})); then
		printf '  - %s\n' "${hit[@]}" >&2
		die "relay-only install refused: registration/partner material present (listed above). A relay-only node must hold only its own node-secret. Use a clean host, or remove the items if this host is being repurposed."
	fi
}

# Public inbound ports of a relay-only node, "<proto> <port-or-range>".
# 80/tcp is for ACME HTTP-01 only: nothing listens on it between renewals.
# The UDP relay range is opened explicitly: without it cross-TURN cascade
# packets and RFC 7675 consent traffic die at INPUT (silent mid-call drops).
relay_firewall_rules() {
	cat <<'RULES'
tcp 22
tcp 80
tcp 443
udp 443
tcp 3478
udp 3478
udp 49152:65535
RULES
}

# relay_firewall_apply — ufw (Debian family) or firewalld, detected by the
# shared lib/firewall-lib.sh. Same default-deny shape as firewall_apply, with
# the relay rule set and no SFU/AWG/mesh rules.
relay_firewall_apply() {
	local tool proto port
	tool=$(_firewall_detect_tool)
	case "$tool" in
		ufw|ufw-install)
			if [[ "$tool" == ufw-install ]]; then
				DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ufw
			fi
			ufw --force reset >/dev/null
			ufw default deny incoming >/dev/null
			ufw default allow outgoing >/dev/null
			ufw default deny routed >/dev/null
			while read -r proto port; do
				ufw allow "${port}/${proto}" comment 'oxpulse-relay' >/dev/null
			done < <(relay_firewall_rules)
			ufw --force enable >/dev/null
			;;
		firewalld)
			while read -r proto port; do
				firewall-cmd --permanent --add-port="${port/:/-}/${proto}" >/dev/null
			done < <(relay_firewall_rules)
			firewall-cmd --reload >/dev/null
			;;
		*) die "relay firewall: no supported tool (ufw/firewalld). Apply manually: $(relay_firewall_rules | tr '\n' ';')" ;;
	esac
	log "[relay] firewall applied via ${tool}"
}

# relay_secret_fingerprints <file> — "line N: sha256 xxxxxxxx" per secret line.
# The secret moves through the shell builtin printf into a pipe, never argv.
relay_secret_fingerprints() {
	local n=0 line
	while IFS= read -r line || [[ -n "$line" ]]; do
		n=$((n + 1))
		printf 'secret line %d: sha256 %s\n' "$n" "$(printf '%s' "$line" | sha256sum | cut -c1-8)"
	done < "$1"
}
