#!/usr/bin/env bash
# lib/firewall-lib.sh — shared partner-edge host firewall hardening.
# (Phase 6 naming reclassification: renamed from lib/install-firewall.sh —
# *-lib.sh = shared across multiple consumers, install-*.sh = install.sh-only.
# This module is sourced by BOTH install.sh AND lib/reconcile.sh's converge
# loop (reconcile_firewall_surface), so it belongs in the *-lib.sh class.
# A frozen back-compat duplicate remains at lib/install-firewall.sh for one
# release — see that file's own header for the removal criteria.)
#
# Closes the 2026-05-21 audit finding: edge-b.example + edge-c + edge-d shipped
# with no host firewall, exposing :9317 (SFU /metrics), :8912 (SFU relay
# API), :8920 (SFU client WS), and :18443 (hysteria2) on the public IP.
# The SFU code uses a single SFU_BIND_ADDRESS for ALL its sockets
# (per oxpulse-sfu-kit/examples/basic-sfu.rs), so we cannot scope the
# metrics socket to the mesh at the application layer. Firewall is the
# only place we can enforce mesh-only access for these ports today.
#
# Detects host firewall tooling:
#   - Ubuntu/Debian → ufw
#   - CentOS/RHEL/Rocky/Alma → firewalld
#   - Otherwise   → log+skip (operator must apply manually)
#
# Exports:
#   firewall_apply   — install/configure the partner-edge host firewall.
#
# Reads (caller globals):
#   log warn die     functions (install.sh provides; die MUST exit)
#   AWG_LISTEN_PORT  optional override; if unset, read from `awg show awg0`
#                    after configure_amneziawg ran.
#
# IDEMPOTENT: safe to re-run; ports already-allowed are no-ops.

# --- Allowed ports (mirrors the manual 2026-05-21 hardening) -----------------

# Public TCP:
_PE_FW_PUB_TCP=(22 80 443 18443 3478 5349)
# Public UDP:
_PE_FW_PUB_UDP=(443 18443 3478 5349 7878)
# Public UDP RANGES — coturn/SFU ephemeral relay range for cascade-relay
# RTP and RFC 7675 STUN consent-freshness traffic. Without this, peer-edge
# consent packets (~104-128 byte UDP) get dropped at our INPUT chain,
# causing silent mid-call disconnect at 25-35s on RU↔diaspora cross-TURN
# routes. Evidence: edge-b /var/log/ufw.log* (2026-06-05 investigation,
# reports/oxpulse-chat/research/2026-06-05-partner-edge-relay-disconnect-class.md).
# Range matches coturn defaults (min-port=49152 max-port=65535).
_PE_FW_PUB_UDP_RANGES=(49152:65535)
# Mesh-only TCP (sources restricted to 10.9.0.0/24):
_PE_FW_MESH_TCP=(9317 8912)

_firewall_detect_tool() {
	if command -v ufw >/dev/null 2>&1 && [[ -r /etc/os-release ]]; then
		# Prefer ufw on Debian-family even if firewalld also present.
		. /etc/os-release
		case "${ID_LIKE:-$ID}" in
			*debian*|*ubuntu*) printf 'ufw'; return 0 ;;
		esac
	fi
	if command -v firewall-cmd >/dev/null 2>&1; then
		printf 'firewalld'; return 0
	fi
	# Last resort — Debian-family without ufw installed: install it.
	if [[ -r /etc/os-release ]]; then
		. /etc/os-release
		case "${ID_LIKE:-$ID}" in
			*debian*|*ubuntu*) printf 'ufw-install'; return 0 ;;
		esac
	fi
	printf 'none'
}

_firewall_resolve_awg_port() {
	# Prefer explicit override (test seam).
	if [[ -n "${AWG_LISTEN_PORT:-}" ]]; then
		printf '%s' "$AWG_LISTEN_PORT"; return 0
	fi
	# Then runtime introspection — requires awg0 to be up.
	local port
	port=$(awg show awg0 listen-port 2>/dev/null || true)
	if [[ "$port" =~ ^[0-9]+$ ]]; then
		printf '%s' "$port"; return 0
	fi
	return 1
}

# Resolve the local docker `edge` bridge subnet(s) so the co-located Caddy
# container can reach the host-networked SFU's client WS port (:8920). Caddy
# reverse_proxies /sfu/ws/* to host.docker.internal:8920 (see Caddyfile.tpl);
# the `edge` network pins NO ipam in docker-compose.yml.tpl, so its subnet is
# docker-assigned and DYNAMIC per install — we read it live rather than
# hardcoding 172.18.0.0/16. Prints one CIDR per line; prints nothing (rc 0)
# when docker or the network is not up yet (first install, before the initial
# `docker compose up` creates the net) — reconcile_firewall_surface re-runs
# firewall_apply every converge and picks the subnet up once the network exists.
_firewall_resolve_edge_subnets() {
	# Test seam / operator override (space- or newline-separated CIDR list).
	if [[ -n "${PE_FW_EDGE_SUBNETS:-}" ]]; then
		printf '%s\n' "$PE_FW_EDGE_SUBNETS" | tr ' ' '\n' \
			| grep -E '^[0-9.]+/[0-9]+$' || true
		return 0
	fi
	command -v docker >/dev/null 2>&1 || return 0
	local net="${PE_FW_EDGE_NETWORK:-${COMPOSE_PROJECT_NAME:-oxpulse-partner-edge}_edge}"
	docker network inspect "$net" \
		--format '{{range .IPAM.Config}}{{println .Subnet}}{{end}}' 2>/dev/null \
		| grep -E '^[0-9.]+/[0-9]+$' || true
	return 0
}

_firewall_apply_ufw() {
	local awg_port="$1"
	ufw --force reset >/dev/null
	ufw default deny incoming
	ufw default allow outgoing
	ufw default allow routed   # let Docker FORWARD work (docker manages its own DOCKER chain)
	ufw allow 22/tcp comment 'partner-edge ssh' >/dev/null
	local p
	for p in "${_PE_FW_PUB_TCP[@]}"; do
		[[ "$p" == "22" ]] && continue
		ufw allow "${p}/tcp" comment "partner-edge pub" >/dev/null
	done
	for p in "${_PE_FW_PUB_UDP[@]}"; do
		ufw allow "${p}/udp" comment 'partner-edge pub' >/dev/null
	done
	local r
	for r in "${_PE_FW_PUB_UDP_RANGES[@]}"; do
		ufw allow "${r}/udp" comment 'partner-edge ephemeral relay' >/dev/null
	done
	ufw allow "${awg_port}/udp" comment "amneziawg ${awg_port}" >/dev/null
	for p in "${_PE_FW_MESH_TCP[@]}"; do
		ufw allow from 10.9.0.0/24 to any port "$p" proto tcp \
			comment 'partner-edge mesh-only' >/dev/null
	done
	# SFU client WS (:8920) — reachable ONLY from the local docker `edge` bridge.
	# Caddy reverse_proxies /sfu/ws/* to host.docker.internal:8920; browsers reach
	# it exclusively through Caddy's :443 TLS front, never :8920 directly. Without
	# this rule `default deny incoming` drops Caddy→host:8920 ("no route to host")
	# → 502 on every group call (live incident us_zvonilka 2026-07-09). This is NOT
	# public exposure: the source is a docker-internal RFC1918 bridge subnet,
	# unreachable and unspoofable from the internet (a public-iface packet with a
	# 172.x source is martian-dropped). 8920 stays off the public whitelist.
	local edge_subnet
	while read -r edge_subnet; do
		[[ -n "$edge_subnet" ]] || continue
		ufw allow from "$edge_subnet" to any port 8920 proto tcp \
			comment 'partner-edge sfu-ws local-bridge' >/dev/null
	done < <(_firewall_resolve_edge_subnets)
	ufw --force enable >/dev/null
}

_firewall_apply_firewalld() {
	local awg_port="$1"
	local zone=public
	firewall-cmd --permanent --zone=$zone --add-service=ssh >/dev/null
	local p
	for p in "${_PE_FW_PUB_TCP[@]}"; do
		[[ "$p" == "22" ]] && continue
		firewall-cmd --permanent --zone=$zone --add-port="${p}/tcp" >/dev/null
	done
	for p in "${_PE_FW_PUB_UDP[@]}"; do
		firewall-cmd --permanent --zone=$zone --add-port="${p}/udp" >/dev/null
	done
	local r fr
	for r in "${_PE_FW_PUB_UDP_RANGES[@]}"; do
		# firewalld wants dashes; our array uses ufw-style colons.
		fr="${r/:/-}"
		firewall-cmd --permanent --zone=$zone --add-port="${fr}/udp" >/dev/null
	done
	firewall-cmd --permanent --zone=$zone --add-port="${awg_port}/udp" >/dev/null

	# Strip any legacy public exposure of mesh-only ports.
	for p in "${_PE_FW_MESH_TCP[@]}" 8920; do
		firewall-cmd --permanent --zone=$zone --remove-port="${p}/tcp" 2>/dev/null || true
	done

	# Re-add mesh-only via rich rules (idempotent).
	for p in "${_PE_FW_MESH_TCP[@]}"; do
		firewall-cmd --permanent --zone=$zone --remove-rich-rule \
			"rule family=ipv4 source address=10.9.0.0/24 port port=$p protocol=tcp accept" 2>/dev/null || true
		firewall-cmd --permanent --zone=$zone --add-rich-rule \
			"rule family=ipv4 source address=10.9.0.0/24 port port=$p protocol=tcp accept" >/dev/null
	done

	# SFU client WS (:8920) — local docker `edge` bridge only (see the ufw path
	# comment for the full rationale; 8920 was already stripped from the public
	# zone in the legacy-strip loop above). Source subnet derived live.
	local edge_subnet
	while read -r edge_subnet; do
		[[ -n "$edge_subnet" ]] || continue
		firewall-cmd --permanent --zone=$zone --remove-rich-rule \
			"rule family=ipv4 source address=$edge_subnet port port=8920 protocol=tcp accept" 2>/dev/null || true
		firewall-cmd --permanent --zone=$zone --add-rich-rule \
			"rule family=ipv4 source address=$edge_subnet port port=8920 protocol=tcp accept" >/dev/null
	done < <(_firewall_resolve_edge_subnets)

	firewall-cmd --reload >/dev/null
}

# Public entry point. Caller passes nothing; we discover everything.
firewall_apply() {
	local tool awg_port
	tool=$(_firewall_detect_tool)
	awg_port=$(_firewall_resolve_awg_port) || {
		warn "[firewall] cannot resolve AWG listen port — skipping firewall step."
		warn "           Run 'firewall_apply' manually after awg0 is up, or set AWG_LISTEN_PORT."
		return 0
	}

	case "$tool" in
		ufw)
			log "[firewall] applying ufw rules (awg=${awg_port}/udp)"
			_firewall_apply_ufw "$awg_port"
			;;
		ufw-install)
			log "[firewall] installing ufw, then applying rules"
			DEBIAN_FRONTEND=noninteractive apt-get update -qq
			DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ufw
			_firewall_apply_ufw "$awg_port"
			;;
		firewalld)
			log "[firewall] applying firewalld rules (awg=${awg_port}/udp)"
			_firewall_apply_firewalld "$awg_port"
			;;
		none|*)
			warn "[firewall] no supported firewall tool (ufw/firewalld) — skipping."
			warn "           Apply the partner-edge whitelist manually:"
			warn "           public: 22,80,443/tcp 443,${awg_port}/udp 18443,3478,5349/tcp+udp 7878/udp"
			warn "           mesh-only (10.9.0.0/24): 9317,8912/tcp"
			# Distinct non-zero (t14 fix): this branch applies NOTHING, so it must
			# not report success. Previously `return 0` here made
			# `firewall_apply || warn ...` in reconcile_firewall_surface a dead
			# branch — the converge cycle logged green with
			# _RECONCILE_FIREWALL_APPLIED=1 while SFU mesh-only ports (:9317,
			# :8912) and the public whitelist stayed unenforced on any distro
			# without ufw/firewalld. Callers MUST check the exit code; 2 mirrors
			# the "could-not-apply" SKIP-signal convention already used by
			# lib/reconcile.sh's _setup_coturn_render_env (return 2 there means
			# "caller must not treat this as success").
			return 2
			;;
	esac
	log "[firewall] applied. SFU mesh-only sockets (:9317,:8912) and SFU WS (:8920) no longer publicly reachable."
}
