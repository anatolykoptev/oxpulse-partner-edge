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

# RFC1918-only CIDR filter (stdin → stdout). Docker bridge subnets are always
# private; on the operator-override path this is the cheap insurance that a
# fat-fingered PE_FW_EDGE_SUBNETS=0.0.0.0/0 can never open :8920 to the world.
# Accepts 10/8, 172.16/12, 192.168/16; drops everything else (incl. malformed).
_firewall_rfc1918_cidrs() {
	grep -E '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)[0-9.]+/[0-9]+$' || true
}

# Resolve the local docker `edge` bridge(s) so the co-located Caddy container can
# reach the host-networked SFU's client WS port (:8920). Caddy reverse_proxies
# /sfu/ws/* to host.docker.internal:8920 (see Caddyfile.tpl); the `edge` network
# pins NO ipam in docker-compose.yml.tpl, so BOTH its subnet and its bridge
# interface (docker names it br-<network-id[:12]>) are docker-assigned and
# DYNAMIC per install — read live, never hardcoded. Emits one "<iface> <cidr>"
# row per subnet (iface "-" = unknown, override path → source-only fallback).
# Emits nothing (rc 0) when docker or the network is not up yet (first install,
# before the initial `docker compose up` creates the net) — the caller warns and
# reconcile_firewall_surface re-runs firewall_apply every converge, picking the
# bridge up once the network exists. All emitted CIDRs are RFC1918-filtered.
_firewall_resolve_edge_bridges() {
	# Test seam / operator override (space- or newline-separated CIDR list). The
	# iface is unknown here, so rows are source-only ("-"); still RFC1918-gated.
	if [[ -n "${PE_FW_EDGE_SUBNETS:-}" ]]; then
		printf '%s\n' "$PE_FW_EDGE_SUBNETS" | tr ' ' '\n' \
			| _firewall_rfc1918_cidrs | sed 's/^/- /'
		return 0
	fi
	command -v docker >/dev/null 2>&1 || return 0
	# NOTE: this default MIRRORS docker-compose's own project-name derivation
	# (compose top-level `name: oxpulse-partner-edge` → network
	# `oxpulse-partner-edge_edge`; hydrate.sh runs compose without a `-p` flag).
	# A change to EITHER side alone silently breaks resolution — keep in sync, or
	# set PE_FW_EDGE_NETWORK explicitly.
	local net="${PE_FW_EDGE_NETWORK:-${COMPOSE_PROJECT_NAME:-oxpulse-partner-edge}_edge}"
	local raw id iface
	raw=$(docker network inspect "$net" \
		--format '{{.Id}}{{range .IPAM.Config}} {{.Subnet}}{{end}}' 2>/dev/null) || return 0
	[[ -n "$raw" ]] || return 0
	local -a parts
	read -ra parts <<<"$raw"
	id=${parts[0]}
	# Docker's default bridge-name convention; no com.docker.network.bridge.name
	# override is set on this network (docker-compose.yml.tpl uses driver: bridge).
	iface="br-${id:0:12}"
	local sub
	for sub in "${parts[@]:1}"; do
		printf '%s\n' "$sub" | _firewall_rfc1918_cidrs | sed "s|^|${iface} |"
	done
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
	# → 502 on every group call (live incident us_zvonilka 2026-07-09).
	#
	# SCOPING (correct-by-construction): the rule is bound to the docker bridge
	# INTERFACE (`in on br-<id>`) AND the bridge source subnet, so it can only
	# match traffic that actually arrived on that bridge — never the public NIC.
	# Source-IP alone is NOT sufficient: RFC1918 is not martian (RFC1812) and
	# rp_filter defaults to loose (=2) on these distros, so a spoofed 172.x source
	# on the public interface would pass a source-only check; the interface match
	# is the real guard. (This TCP port's return path also can't reach a spoofer,
	# but we do not rely on that.) 8920 stays off the public whitelist — not
	# public exposure. If the bridge iface is unknown (override seam, iface "-"),
	# we fall back to source-only, still RFC1918-gated.
	local edge_iface edge_subnet had_bridge=0
	while read -r edge_iface edge_subnet; do
		[[ -n "$edge_subnet" ]] || continue
		had_bridge=1
		if [[ "$edge_iface" == "-" || -z "$edge_iface" ]]; then
			ufw allow from "$edge_subnet" to any port 8920 proto tcp \
				comment 'partner-edge sfu-ws local-bridge' >/dev/null
		else
			ufw allow in on "$edge_iface" from "$edge_subnet" to any port 8920 proto tcp \
				comment 'partner-edge sfu-ws local-bridge' >/dev/null
		fi
	done < <(_firewall_resolve_edge_bridges)
	_firewall_warn_if_no_bridge "$had_bridge"
	ufw --force enable >/dev/null
}

# Shared breadcrumb: if docker is present and no override is set but the resolver
# yielded ZERO bridges, the :8920 local-path rule did NOT land this run. On a
# converged node (docker transiently down mid-converge, network vanished, wrong
# project-name derivation) that is a diagnosable silent gap — the exact class
# that caused the 2026-07-09 incident — so log it (repo convention: write-
# failures must log or bump a metric). Pre-first-`compose up` this is expected;
# we still warn (cheap, and the next converge clears it). Non-fatal by design.
_firewall_warn_if_no_bridge() {
	local had_bridge="$1"
	[[ "$had_bridge" == "1" ]] && return 0
	[[ -n "${PE_FW_EDGE_SUBNETS:-}" ]] && return 0
	command -v docker >/dev/null 2>&1 || return 0
	warn "[firewall] docker edge-network subnet not found — SFU WS local-path rule (:8920) NOT applied this run; Caddy to :8920 may 502 until the network exists (self-heals next converge)."
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

	# SFU client WS (:8920) — local docker `edge` bridge only (8920 was already
	# stripped from the public zone in the legacy-strip loop above; this re-adds it
	# for the bridge subnet). SCOPING CAVEAT: firewalld rich rules CANNOT match an
	# ingress interface (interface scoping is zone-level), so — unlike the ufw path
	# — this is source-subnet-scoped only. The subnet is RFC1918 (helper-filtered).
	# A future NON-TCP service MUST NOT copy this source-only pattern without zone
	# or interface scoping: a spoofed RFC1918 source on the public NIC would match
	# (for this TCP port a spoofer gets no return path; UDP has no such guard).
	# The bridge iface from the resolver is unused here (rich rules can't consume
	# it) — read into the `_` throwaway.
	local edge_subnet had_bridge=0
	while read -r _ edge_subnet; do
		[[ -n "$edge_subnet" ]] || continue
		had_bridge=1
		firewall-cmd --permanent --zone=$zone --remove-rich-rule \
			"rule family=ipv4 source address=$edge_subnet port port=8920 protocol=tcp accept" 2>/dev/null || true
		firewall-cmd --permanent --zone=$zone --add-rich-rule \
			"rule family=ipv4 source address=$edge_subnet port port=8920 protocol=tcp accept" >/dev/null
	done < <(_firewall_resolve_edge_bridges)
	_firewall_warn_if_no_bridge "$had_bridge"

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

	# Purge rogue raw-iptables REJECT/DROP rules that sit BEFORE the UFW chain
	# in INPUT, bypassing UFW's allowlist. These accumulate from manual
	# iptables edits, legacy pre-ufw configs, or distro default rules left
	# behind when ufw was adopted. Symptoms: UFW allows a port (e.g. AWG
	# listen port) but traffic is still blocked because a REJECT at a lower
	# line number fires first. The 2026-07-16 awg mesh outage was caused by
	# exactly this — pillow's UFW had 43938/udp ALLOW but a raw REJECT at
	# line 17 (before the UFW chain at line 18) blocked it. See issue #416.
	_firewall_purge_rogue_rejects

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

# Purge rogue raw-iptables REJECT/DROP rules in the INPUT chain that sit
# BEFORE the UFW before-chain (ufw-before-logging-input). These rules bypass
# UFW's allowlist entirely — UFW may allow a port, but a raw REJECT at a
# lower line number fires first and blocks the traffic. Idempotent: only
# removes rules whose target is REJECT or DROP and whose position is before
# the first ufw-* chain reference. Preserves ESTABLISHED/RELATED rules and
# explicit ACCEPT rules (those are legitimate pre-UFW rules, not rogue).
# No-op when UFW is not the active firewall tool (no ufw-* chain to find).
_firewall_purge_rogue_rejects() {
	command -v iptables >/dev/null 2>&1 || return 0
	# Find the line number of the first ufw-* chain in INPUT — rogue rules
	# are those BEFORE this line.
	local ufw_line
	ufw_line=$(iptables -L INPUT --line-numbers -n 2>/dev/null | grep -n 'ufw-' | head -1 | cut -d: -f1 || true)
	[[ "$ufw_line" =~ ^[0-9]+$ ]] || return 0  # no UFW chain — not our problem

	# Walk INPUT rules from top, collect rogue REJECT/DROP rule numbers
	# (before the ufw line). We collect in reverse order so deletion doesn't
	# shift line numbers of rules we haven't processed yet.
	local -a rogue_nums=()
	local num target rest
	while IFS=$' \t' read -r num target rest; do
		[[ "$num" =~ ^[0-9]+$ ]] || continue
		[[ "$num" -ge "$ufw_line" ]] && break  # past UFW chain — stop
		case "$target" in
			REJECT|DROP)
				rogue_nums=("$num" "${rogue_nums[@]}")
				;;
		esac
	done < <(iptables -L INPUT --line-numbers -n 2>/dev/null)

	[[ ${#rogue_nums[@]} -gt 0 ]] || return 0  # no rogue rules

	warn "[firewall] found ${#rogue_nums[@]} rogue raw-iptables REJECT/DROP rule(s) before UFW chain — purging"
	for num in "${rogue_nums[@]}"; do
		# Delete by line number (reverse order keeps remaining numbers stable).
		if iptables -D INPUT "$num" 2>/dev/null; then
			log "[firewall] purged rogue INPUT rule #${num}"
		else
			warn "[firewall] could not purge INPUT rule #${num} (may have shifted) — manual cleanup needed"
		fi
	done
}
