#!/usr/bin/env bash
# relay/relay-lib.sh — helpers for the relay-only node profile (install-relay.sh).
#
# A relay-only node runs coturn and nothing else. It holds exactly one TURN
# credential, its own per-node secret, and never registers with the backend.
#
# Requires (caller): log warn die. Sourced, not executed.
# Test seams: PREFIX_ETC (default /etc/oxpulse-partner-edge).

RELAY_PREFIX_ETC="${PREFIX_ETC:-/etc/oxpulse-partner-edge}"
RELAY_PREFIX_LIB="${PREFIX_LIB:-/var/lib/oxpulse-partner-edge}"

# Environment variables that carry material a relay-only node must never hold.
RELAY_FORBIDDEN_ENV=(
	SIGNALING_SFU_SECRET signaling_sfu_secret
	TURN_PARTNER_LEGACY TURN_CENTRAL_SECRET TURN_SECRET
	ROOM_HMAC_KEY
	OXPULSE_SERVICE_TOKEN
)
# Files the full register/install path leaves behind. Any of them present means
# this host is (or was) a full partner edge, not a relay-only node.
RELAY_FORBIDDEN_FILES=(
	node-config.json token .env reality.priv awg-private.key sfu-signing-key
	xray.env ghcr.token docker-compose.yml Caddyfile cross-probe-token
)
# Text that must not appear in any file under the prefix.
RELAY_FORBIDDEN_TEXT='signaling_sfu_secret|SIGNALING_SFU_SECRET|TURN_PARTNER_LEGACY|TURN_CENTRAL_SECRET|ROOM_HMAC_KEY|REALITY_[A-Z_]+'

# relay_assert_no_registration_material — fail closed. Prints names only, never values.
relay_assert_no_registration_material() {
	local v f hit=()
	for v in "${RELAY_FORBIDDEN_ENV[@]}"; do
		[[ -z "${!v:-}" ]] || hit+=("env ${v}")
	done
	while IFS= read -r v; do
		[[ -n "$v" ]] && hit+=("env ${v%%=*}")
	done < <(env | grep -E '^REALITY_[A-Z_]*=.' || true)
	for f in "${RELAY_FORBIDDEN_FILES[@]}"; do
		[[ ! -e "${RELAY_PREFIX_ETC}/${f}" ]] || hit+=("file ${RELAY_PREFIX_ETC}/${f}")
	done
	[[ ! -e "${RELAY_PREFIX_LIB}" ]] || hit+=("dir ${RELAY_PREFIX_LIB} (full-edge state)")
	if [[ -d "${RELAY_PREFIX_ETC}" ]]; then
		while IFS= read -r f; do
			[[ -n "$f" ]] && hit+=("secret name inside ${f}")
		done < <(grep -rIlE "${RELAY_FORBIDDEN_TEXT}" "${RELAY_PREFIX_ETC}" 2>/dev/null || true)
	fi
	if ((${#hit[@]})); then
		printf '  - %s\n' "${hit[@]}" >&2
		die "relay-only refused: registration/partner material present (listed above). A relay-only node must hold only its own node-secret. Use a clean host, or remove the items if this host is being repurposed."
	fi
}

# Public inbound ports of a relay-only node (SSH is handled separately, from
# the live sshd config), "<proto> <port-or-range>".
# 80/tcp is for ACME HTTP-01 only: nothing listens on it between renewals.
# TURNS is TCP 443; DTLS is disabled, so there is no udp 443 rule.
# The UDP relay range is opened explicitly: without it cross-TURN cascade
# packets and RFC 7675 consent traffic die at INPUT (silent mid-call drops).
relay_firewall_rules() {
	cat <<'RULES'
tcp 80
tcp 443
tcp 3478
udp 3478
udp 49152:65535
RULES
}

# relay_ssh_port — the port sshd actually listens on (first `port` of sshd -T).
relay_ssh_port() {
	local p
	p=$("${SSHD:-sshd}" -T 2>/dev/null | awk '$1=="port"{print $2; exit}')
	[[ "$p" =~ ^[0-9]+$ ]] || die "cannot determine the sshd port from 'sshd -T'; refusing to touch the firewall"
	printf '%s' "$p"
}

# relay_ufw_ssh_rule_exists <port> — a pre-existing source-restricted rule for
# the ssh port is kept as is; only if there is no rule at all do we open it.
relay_ufw_ssh_rule_exists() {
	ufw status 2>/dev/null | awk -v p="$1" '
		$1 == p || $1 == p "/tcp" { found=1 }
		END { exit(found ? 0 : 1) }'
}

# relay_firewall_apply — ufw (Debian family) or firewalld, detected by the
# shared lib/firewall-lib.sh. Default deny + the relay rule set; no SFU/AWG/mesh
# rules. ufw is NOT reset: existing rules (notably a source-restricted ssh rule)
# are preserved, and anything else already allowed is reported.
relay_firewall_apply() {
	local tool proto port ssh
	ssh=$(relay_ssh_port)
	tool=$(_firewall_detect_tool)
	case "$tool" in
		ufw|ufw-install)
			if [[ "$tool" == ufw-install ]]; then
				DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ufw
			fi
			grep -qE '^IPV6=yes' "${UFW_DEFAULT:-/etc/default/ufw}" 2>/dev/null \
				|| die "ufw: IPV6=yes is required in ${UFW_DEFAULT:-/etc/default/ufw} (otherwise IPv6 stays unfiltered)"
			ufw default deny incoming >/dev/null
			ufw default allow outgoing >/dev/null
			ufw default deny routed >/dev/null
			if relay_ufw_ssh_rule_exists "$ssh"; then
				log "[relay] ufw: keeping the existing rule for ssh port ${ssh}"
			else
				ufw allow "${ssh}/tcp" comment 'oxpulse-relay ssh' >/dev/null
			fi
			while read -r proto port; do
				ufw allow "${port}/${proto}" comment 'oxpulse-relay' >/dev/null
			done < <(relay_firewall_rules)
			ufw --force enable >/dev/null
			;;
		firewalld)
			firewall-cmd --permanent --add-port="${ssh}/tcp" >/dev/null
			while read -r proto port; do
				firewall-cmd --permanent --add-port="${port/:/-}/${proto}" >/dev/null
			done < <(relay_firewall_rules)
			firewall-cmd --reload >/dev/null
			;;
		*) die "relay firewall: no supported tool (ufw/firewalld). Apply manually: ssh ${ssh}/tcp; $(relay_firewall_rules | tr '\n' ';')" ;;
	esac
	log "[relay] firewall applied via ${tool} (ssh ${ssh}/tcp)"
}

# relay_assert_relay_range_clean — after the sysctl reservation, long-running
# daemons that already hold a port in the relay range (chrony, resolved) are
# restarted, then any non-turnserver socket still in 49152-65535 fails the
# install: the guard's "inside the range means a relay" argument needs it empty.
relay_assert_relay_range_clean() {
	local stray
	systemctl try-restart chrony.service systemd-resolved.service >/dev/null 2>&1 || true
	stray="$(
		{ "${SS:-ss}" -H -ulnp; "${SS:-ss}" -H -tlnp; } 2>/dev/null \
			| awk '{n=split($4,a,":"); p=a[n]+0; if (p>=49152 && p<=65535 && $0 !~ /"turnserver"/) print}'
	)"
	if [[ -n "$stray" ]]; then
		printf '%s\n' "$stray" >&2
		die "sockets inside the relay range 49152-65535 are not owned by turnserver (listed above); restart or reconfigure their owners and re-run"
	fi
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
