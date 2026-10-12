#!/usr/bin/env bash
# install-relay.sh — relay-only node profile: coturn and nothing else.
#
#   sudo bash relay/install-relay.sh --hostname relay.example.org \
#        --public-ip 203.0.113.10 --node-id relay-node-1 [--acme-email ops@example.org]
#
# NO /api/partner/register, NO node-config, NO credential-refresh timer, NO
# caddy/xray/hy2/naive/SFU/AWG/docker. The node holds only its own per-node TURN
# secret (written by the operator to /etc/oxpulse-partner-edge/node-secret) and
# a node-scoped service token (service-token) for the liveness heartbeat.
# Fails closed when any registration material is present on the host.
#
# Idempotent. Run from a checkout/release tree: it reuses lib/firewall-lib.sh and
# lib/channel-health-lib.sh from the sibling lib/ directory.
# Exit 3 = installed, but TLS was not issued (DNS does not point at --public-ip).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${HERE}/.." && pwd)"
PREFIX_ETC="${PREFIX_ETC:-/etc/oxpulse-partner-edge}"
LIB_DST="${RELAY_LIB_DIR:-/usr/local/lib/oxpulse-relay}"
SBIN="${PREFIX_SBIN:-/usr/local/sbin}"
UNIT_DIR="${UNIT_DIR:-/etc/systemd/system}"
RELAY_HOSTNAME="" PUBLIC_IP="" NODE_ID="" ACME_EMAIL="" TLS_OK=1

log()  { printf '\033[32m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[33m!!\033[0m  %s\n' "$*" >&2; }
die()  { printf '\033[31mERR\033[0m %s\n' "$*" >&2; exit 1; }

# shellcheck source=relay-lib.sh
. "${HERE}/relay-lib.sh"
# shellcheck source=../lib/firewall-lib.sh
. "${REPO_DIR}/lib/firewall-lib.sh"

relay_parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--hostname)   RELAY_HOSTNAME="${2:-}"; shift 2 ;;
			--public-ip)  PUBLIC_IP="${2:-}"; shift 2 ;;
			--node-id)    NODE_ID="${2:-}"; shift 2 ;;
			--acme-email) ACME_EMAIL="${2:-}"; shift 2 ;;
			*) die "unknown argument: $1 (relay-only profile takes --hostname --public-ip --node-id [--acme-email]; no token/partner flags exist)" ;;
		esac
	done
	[[ -n "$RELAY_HOSTNAME" && -n "$PUBLIC_IP" && -n "$NODE_ID" ]] \
		|| die "usage: $0 --hostname H --public-ip IP --node-id ID [--acme-email E]"
	[[ "$RELAY_HOSTNAME" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || die "bad --hostname"
	[[ "$PUBLIC_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "bad --public-ip"
	[[ "$NODE_ID" =~ ^[A-Za-z0-9._-]{1,128}$ ]] || die "bad --node-id"
}

relay_install_packages() {
	[[ -r /etc/os-release ]] && . /etc/os-release
	case " ${ID:-} ${ID_LIKE:-} " in *" debian "*|*" ubuntu "*) ;; *) die "relay profile supports Debian/Ubuntu only" ;; esac
	export DEBIAN_FRONTEND=noninteractive
	apt-get update -qq
	apt-get install -y -qq coturn certbot jq curl python3 ufw chrony >/dev/null
	# The package's own unit would run coturn on /etc/turnserver.conf, outside this profile.
	systemctl disable --now coturn.service >/dev/null 2>&1 || true
	systemctl mask coturn.service >/dev/null 2>&1 || true
	log "packages present (coturn certbot jq curl python3 ufw chrony); package coturn.service masked"
}

relay_ensure_opec() {
	command -v opec >/dev/null 2>&1 && [[ "$(command -v opec)" == /usr/bin/opec ]] && return 0
	local arch asset base tmp sums
	case "$(uname -m)" in x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; *) die "opec: unsupported arch $(uname -m)" ;; esac
	asset="opec-${arch}"
	if [[ -f "${REPO_DIR}/${asset}" ]]; then
		install -m 0755 "${REPO_DIR}/${asset}" /usr/bin/opec
		log "opec installed from ${REPO_DIR}/${asset}"
		return 0
	fi
	base="https://github.com/anatolykoptev/oxpulse-partner-edge/releases/latest/download"
	tmp="$(mktemp -d)"; trap 'rm -rf "${tmp}"' RETURN
	curl -fsSL --proto '=https' --tlsv1.2 --max-time 120 "${base}/${asset}" -o "${tmp}/${asset}" \
		&& curl -fsSL --proto '=https' --tlsv1.2 --max-time 30 "${base}/SHA256SUMS" -o "${tmp}/SHA256SUMS" \
		|| die "opec download failed; place ${asset} next to the checkout or put opec at /usr/bin/opec"
	sums="$(awk -v a="$asset" '$2 == a || $2 == "./" a { print $1 "  " a; exit }' "${tmp}/SHA256SUMS")"
	[[ -n "$sums" ]] || die "opec: ${asset} not listed in SHA256SUMS; refusing an unverified binary"
	(cd "$tmp" && printf '%s\n' "$sums" | sha256sum -c --quiet) || die "opec checksum mismatch"
	install -m 0755 "${tmp}/${asset}" /usr/bin/opec
	log "opec installed (checksum verified)"
}

relay_install_files() {
	install -d -m 0755 "${LIB_DST}" "${SBIN}"
	install -d -m 0750 -o root -g turnserver "${PREFIX_ETC}"
	install -m 0644 "${HERE}/relay-lib.sh" "${REPO_DIR}/lib/firewall-lib.sh" "${REPO_DIR}/lib/channel-health-lib.sh" "${LIB_DST}/"
	install -m 0755 "${HERE}/oxpulse-relay-apply.sh" "${SBIN}/oxpulse-relay-apply"
	install -m 0755 "${HERE}/oxpulse-relay-health-report.sh" "${SBIN}/oxpulse-relay-health-report.sh"
	install -m 0644 "${HERE}/coturn-relay.conf.tpl" "${PREFIX_ETC}/coturn-relay.conf.tpl"
	install -m 0644 "${HERE}/coturn-self-relay-guard.nft" "${PREFIX_ETC}/coturn-self-relay-guard.nft"
	install -m 0644 "${HERE}/99-coturn-relay-ports.conf" /etc/sysctl.d/99-coturn-relay-ports.conf
	local u
	for u in oxpulse-relay-coturn.service oxpulse-relay-health.service oxpulse-relay-health.timer coturn-self-relay-guard.service; do
		install -m 0644 "${HERE}/${u}" "${UNIT_DIR}/${u}"
	done
	printf '%s\n' "${NODE_ID}" > "${PREFIX_ETC}/node-id"
	printf 'RELAY_HOSTNAME=%s\nEXTERNAL_IP=%s\n' "${RELAY_HOSTNAME}" "${PUBLIC_IP}" > "${PREFIX_ETC}/relay.env"
	chmod 0644 "${PREFIX_ETC}/node-id" "${PREFIX_ETC}/relay.env"
	systemctl daemon-reload
	log "relay files installed"
}

relay_install_guard() {
	sysctl -q -p /etc/sysctl.d/99-coturn-relay-ports.conf
	systemctl enable coturn-self-relay-guard.service >/dev/null 2>&1
	systemctl reload-or-restart coturn-self-relay-guard.service
	log "self-relay guard active; reserved $(cat /proc/sys/net/ipv4/ip_local_reserved_ports)"
}

relay_dns_points_here() {
	getent ahostsv4 "${RELAY_HOSTNAME}" 2>/dev/null | awk '{print $1}' | sort -u | grep -qx "${PUBLIC_IP}"
}

relay_setup_tls() {
	local certdir="${PREFIX_ETC}/relay-certs" hook=/etc/letsencrypt/renewal-hooks/deploy/oxpulse-relay-coturn.sh
	install -d -m 0750 -o root -g turnserver "${certdir}"
	install -d /etc/letsencrypt/renewal-hooks/deploy
	cat > "${hook}" <<HOOK
#!/bin/bash
# certbot deploy hook (installed by install-relay.sh): hand the renewed cert to coturn.
set -euo pipefail
case "\${RENEWED_LINEAGE:-}" in */live/${RELAY_HOSTNAME}) ;; *) exit 0 ;; esac
install -m 0640 -o root -g turnserver "\${RENEWED_LINEAGE}/fullchain.pem" ${certdir}/fullchain.pem
install -m 0640 -o root -g turnserver "\${RENEWED_LINEAGE}/privkey.pem" ${certdir}/privkey.pem
systemctl try-restart oxpulse-relay-coturn.service || true
HOOK
	chmod 0755 "${hook}"
	if ! relay_dns_points_here; then
		warn "TLS skipped: ${RELAY_HOSTNAME} does not resolve to ${PUBLIC_IP}. Create the A record, then re-run."
		TLS_OK=0; return 0
	fi
	if [[ ! -d "/etc/letsencrypt/live/${RELAY_HOSTNAME}" ]]; then
		local mail=(--register-unsafely-without-email)
		[[ -z "$ACME_EMAIL" ]] || mail=(-m "$ACME_EMAIL")
		certbot certonly --standalone --non-interactive --agree-tos "${mail[@]}" -d "${RELAY_HOSTNAME}" \
			|| { warn "certbot could not issue for ${RELAY_HOSTNAME}"; TLS_OK=0; return 0; }
	fi
	RENEWED_LINEAGE="/etc/letsencrypt/live/${RELAY_HOSTNAME}" bash "${hook}"
	systemctl enable --now certbot.timer >/dev/null 2>&1 || true
	log "certificate deployed to ${certdir}; renewal via certbot.timer"
}

relay_main() {
	relay_parse_args "$@"
	[[ "$(id -u)" -eq 0 ]] || die "run as root"
	relay_assert_no_registration_material
	relay_install_packages
	relay_ensure_opec
	relay_install_files
	relay_firewall_apply
	relay_install_guard
	relay_setup_tls
	systemctl enable oxpulse-relay-coturn.service >/dev/null 2>&1
	systemctl enable --now oxpulse-relay-health.timer >/dev/null 2>&1
	log "DONE. Next: write ${PREFIX_ETC}/node-secret and ${PREFIX_ETC}/service-token (both 0600 root), then run: oxpulse-relay-apply"
	if [[ "$TLS_OK" != 1 ]]; then
		warn "EXIT 3: TLS not issued; coturn will not start until the certificate exists."
		exit 3
	fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then relay_main "$@"; fi
