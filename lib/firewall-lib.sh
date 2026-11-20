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
# API) and :8920 (SFU client WS) on the public IP.
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

# Public TCP. SSH is NOT listed: its port(s) are detected from the running sshd
# (_firewall_detect_ssh_ports) because a hardcoded 22 locked an operator out of a
# host whose sshd listens only on a non-default port (2026-11-20 incident).
_PE_FW_PUB_TCP=(80 443 3478 5349)
# Public UDP:
_PE_FW_PUB_UDP=(443 3478 5349 7878)
# Public UDP RANGES — coturn's relay port range, for cascade-relay RTP and RFC 7675
# STUN consent-freshness traffic. Without this, peer-edge consent packets
# (~104-128 byte UDP) get dropped at our INPUT chain, causing silent mid-call
# disconnect at 25-35s on RU<->diaspora cross-TURN routes. Evidence: edge-b
# /var/log/ufw.log* (2026-06-05 investigation,
# reports/oxpulse-chat/research/2026-06-05-partner-edge-relay-disconnect-class.md).
# EXACTLY the range coturn.conf.tpl sets as min-port/max-port, and the range
# oxpulse-partner-edge-coturn-guard reserves from the ephemeral pool
# (net.ipv4.ip_local_reserved_ports) and lets the self-relay nft guard treat as
# "a relay socket". Was 49152:65535, which overlapped the kernel ephemeral range
# (32768-60999) — opening the upper part of the ephemeral pool to the internet and
# making the guard's allow-range meaningless. tests/test_coturn_guard.sh pins the equality.
_PE_FW_PUB_UDP_RANGES=(49152:49999)
# Mesh-only TCP (sources restricted to 10.9.0.0/24):
_PE_FW_MESH_TCP=(9317 8912)
# Fixed bridge interface of the docker `edge` network. MUST equal the
# com.docker.network.bridge.name driver_opt in docker-compose.yml.tpl
# (tests/test_install_firewall_module.sh pins the equality). Without it docker
# names the bridge br-<network-id>, and the id changes every time the network is
# recreated (`docker compose down` on every unit stop), staling the
# `in on <iface>` :8920 rule. <=15 chars (IFNAMSIZ).
_PE_FW_EDGE_BRIDGE=pe-edge0

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

# --- SSH port detection ------------------------------------------------------
# Every TCP port the host's sshd listens on, space-separated on one line, sorted
# and de-duplicated. UNION of: operator override PE_SSH_PORTS (space/comma list),
# `sshd -T` (configured Port lines, includes sshd_config.d; needs root) and the
# live listeners of the sshd process from `ss -ltnp` (catches socket-activated
# ssh.socket / ListenStream overrides that `sshd -T` does not report). Union, not
# first-hit: allowing one port too many is harmless, missing one is a lockout.
# Prints nothing and returns 1 when no source yielded a port.
_firewall_detect_ssh_ports() {
	local raw="" sshd_bin
	local ov="${PE_SSH_PORTS:-}"
	raw+=" ${ov//,/ }"
	sshd_bin=$(command -v sshd 2>/dev/null || true)
	[[ -n "$sshd_bin" ]] || { [[ -x /usr/sbin/sshd ]] && sshd_bin=/usr/sbin/sshd; }
	if [[ -n "$sshd_bin" ]]; then
		raw+=" $("$sshd_bin" -T 2>/dev/null | awk '$1=="port"{print $2}' || true)"
	fi
	if command -v ss >/dev/null 2>&1; then
		# local-address column is field 4; strip everything through the last ':'
		# (handles 0.0.0.0:22, [::]:22, *:22).
		raw+=" $(ss -H -ltnp 2>/dev/null | awk '/"sshd/{n=split($4,a,":"); print a[n]}' || true)"
	fi
	local p out=""
	for p in $raw; do
		[[ "$p" =~ ^[0-9]+$ ]] || continue
		(( 10#$p >= 1 && 10#$p <= 65535 )) || continue
		out+="$((10#$p))"$'\n'
	done
	out=$(printf '%s' "$out" | sort -nu | tr '\n' ' ')
	out="${out% }"
	[[ -n "$out" ]] || return 1
	printf '%s' "$out"
}

# Detected ssh ports, or "22" + a loud warning when nothing could be determined.
# Always prints a non-empty space-separated list; always returns 0.
_firewall_resolve_ssh_ports() {
	local ports
	if ports=$(_firewall_detect_ssh_ports); then
		printf '%s' "$ports"; return 0
	fi
	warn "[firewall] WARNING: could not determine the sshd listen port (PE_SSH_PORTS unset, 'sshd -T' and 'ss -ltnp' yielded nothing) — allowing 22/tcp ONLY."
	warn "           If sshd listens elsewhere you WILL be locked out: set PE_SSH_PORTS=<port[,port]> and re-run."
	printf '22'
}

# Hard stop: every detected sshd port must appear as an allow rule in what is about
# to be enabled. Reads the ufw/firewalld state back (an oracle independent of the
# loop that wrote it), so a no-op/failed `allow` is caught, not just a bad port list.
# $1 = space-separated ports; stdin-free. rc 0 covered, rc 3 not covered.
_firewall_ufw_require_ssh_covered() {
	local added p missing=""
	added=$(ufw show added 2>/dev/null || true)
	for p in $1; do
		grep -Eq "^ufw allow ${p}(/tcp)?([[:space:]]|\$)" <<<"$added" || missing+=" ${p}/tcp"
	done
	[[ -z "$missing" ]] && return 0
	warn "[firewall] REFUSING to enable ufw: sshd listens on${missing} but the ruleset about to be enabled does not allow it — enabling would lock out SSH."
	warn "           ufw is left DISABLED (reset already ran). Fix the rules or set PE_SSH_PORTS, then re-run."
	return 3
}

_firewall_firewalld_require_ssh_covered() {
	local zone="$1" ports="$2" lp ls p missing=""
	lp=$(firewall-cmd --permanent --zone="$zone" --list-ports 2>/dev/null | tr '\n' ' ' || true)
	ls=$(firewall-cmd --permanent --zone="$zone" --list-services 2>/dev/null | tr '\n' ' ' || true)
	for p in $ports; do
		if [[ " $lp " == *" ${p}/tcp "* ]]; then continue; fi
		if [[ "$p" == "22" && " $ls " == *" ssh "* ]]; then continue; fi
		missing+=" ${p}/tcp"
	done
	[[ -z "$missing" ]] && return 0
	warn "[firewall] REFUSING to reload firewalld: sshd listens on${missing} but the permanent ${zone} zone does not allow it — reloading would lock out SSH."
	return 3
}

# --- Takeover guard ----------------------------------------------------------
# Installing ufw REMOVES iptables-persistent/netfilter-persistent (package
# conflict) and `ufw --force reset` discards the rules the operator kept in
# /etc/iptables/rules.v4. Their runtime iptables rules keep working until the
# next reboot, so the loss is invisible for weeks (2026-11-20 incident: reboot
# dropped a mesh-only exporter port and an SSH port). Refuse unless the operator
# opts in with PE_FIREWALL_TAKEOVER=1. No attempt is made to translate rules.

_firewall_rules_v4_path() { printf '%s' "${PE_FW_RULES_V4:-/etc/iptables/rules.v4}"; }

_firewall_persistent_pkg_installed() {
	local pkg
	for pkg in iptables-persistent netfilter-persistent; do
		if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
			return 0
		fi
	done
	return 1
}

# `-A INPUT ... -j ACCEPT` lines of rules.v4 (empty when absent/none).
_firewall_rules_v4_input_accepts() {
	local f; f=$(_firewall_rules_v4_path)
	[[ -r "$f" ]] || return 0
	grep -E '^-A INPUT .*-j ACCEPT' "$f" || true
}

# Subset of the rules.v4 INPUT ACCEPT lines that the ufw set we are about to apply
# does NOT reproduce. Deliberately conservative: only conntrack/loopback/icmp
# (ufw's built-in before.rules) and a plain `-p tcp|udp --dport N` whose port is in
# our public set (or an unrestricted/10.9.0.0/24 match for our mesh ports) count as
# covered. Anything else is reported. $1 = awg port, $2 = ssh ports.
_firewall_uncovered_v4_rules() {
	local awg="$1" ssh="$2" line proto ports port ok src
	local re_proto='-p (tcp|udp)( |$)' re_ports='--dports? ([0-9:,]+)' re_src='-s ([0-9./]+)'
	while IFS= read -r line; do
		[[ -n "$line" ]] || continue
		case "$line" in
			*"RELATED,ESTABLISHED"*|*"ESTABLISHED,RELATED"*|*" -i lo "*|*" -i lo"|*"-p icmp"*) continue ;;
		esac
		proto="" ports="" src=""
		[[ "$line" =~ $re_proto ]] && proto="${BASH_REMATCH[1]}"
		[[ "$line" =~ $re_ports ]] && ports="${BASH_REMATCH[1]}"
		[[ "$line" =~ $re_src ]] && src="${BASH_REMATCH[1]}"
		ok=0
		if [[ -n "$proto" && -n "$ports" ]]; then
			ok=1
			for port in ${ports//,/ }; do
				_firewall_port_covered "$proto" "$port" "$src" "$awg" "$ssh" || ok=0
			done
		fi
		(( ok )) || printf '%s\n' "$line"
	done < <(_firewall_rules_v4_input_accepts)
}

_firewall_port_covered() {
	local proto="$1" port="$2" src="$3" awg="$4" ssh="$5" p r
	if [[ "$proto" == tcp ]]; then
		for p in "${_PE_FW_PUB_TCP[@]}" $ssh; do [[ "$p" == "$port" ]] && return 0; done
		for p in "${_PE_FW_MESH_TCP[@]}"; do
			[[ "$p" == "$port" && "$src" == "10.9.0.0/24" ]] && return 0
		done
	else
		for p in "${_PE_FW_PUB_UDP[@]}" "$awg"; do [[ "$p" == "$port" ]] && return 0; done
		for r in "${_PE_FW_PUB_UDP_RANGES[@]}"; do [[ "$r" == "$port" ]] && return 0; done
	fi
	return 1
}

# rc 0 proceed, rc 4 refuse. Only guards the FIRST transition to ufw: once ufw is
# active the takeover already happened (and a leftover rules.v4 is stale), so the
# every-converge re-apply must not refuse forever.
_firewall_takeover_guard() {
	local awg="$1" ssh="$2" pkg=0 rules uncovered
	_firewall_persistent_pkg_installed && pkg=1
	rules=$(_firewall_rules_v4_input_accepts)
	[[ "$pkg" == 1 || -n "$rules" ]] || return 0
	if [[ "$pkg" == 0 ]] && command -v ufw >/dev/null 2>&1 \
		&& ufw status 2>/dev/null | head -1 | grep -qi 'Status: active'; then
		return 0
	fi
	uncovered=$(_firewall_uncovered_v4_rules "$awg" "$ssh")
	warn "[firewall] this host has an existing iptables-based firewall that the ufw takeover would discard:"
	[[ "$pkg" == 1 ]] && warn "           iptables-persistent/netfilter-persistent is installed — installing ufw REMOVES it."
	if [[ -n "$uncovered" ]]; then
		warn "           INPUT ACCEPT rules in $(_firewall_rules_v4_path) that the partner-edge ufw set will NOT cover (lost on takeover):"
		while IFS= read -r rules; do warn "             $rules"; done <<<"$uncovered"
	fi
	if [[ "${PE_FIREWALL_TAKEOVER:-}" == "1" ]]; then
		warn "           PE_FIREWALL_TAKEOVER=1 set — proceeding; re-create the rules above by hand afterwards (ufw allow ...)."
		return 0
	fi
	warn "[firewall] REFUSING firewall takeover. Re-run with PE_FIREWALL_TAKEOVER=1 once you have noted the rules above, or skip the firewall step."
	return 4
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
# pins NO ipam in docker-compose.yml.tpl, so its subnet is docker-assigned and
# DYNAMIC per install — read live, never hardcoded. Its bridge interface is the
# fixed _PE_FW_EDGE_BRIDGE (pe-edge0) on current networks, br-<network-id[:12]> on
# a legacy network not yet recreated. Emits one "<iface> <cidr>"
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
	# Stable name when the network was created with our fixed bridge name
	# (docker-compose.yml.tpl driver_opts); a node whose network predates that
	# change still has docker's default br-<id[:12]>, which is the interface that
	# really exists until compose recreates the network — pin that one for now, the
	# next converge swaps to the stable name.
	local opt
	opt=$(docker network inspect "$net" \
		--format '{{index .Options "com.docker.network.bridge.name"}}' 2>/dev/null) || opt=""
	if [[ "$opt" == "$_PE_FW_EDGE_BRIDGE" ]]; then
		iface="$_PE_FW_EDGE_BRIDGE"
	else
		iface="br-${id:0:12}"
	fi
	local sub
	for sub in "${parts[@]:1}"; do
		printf '%s\n' "$sub" | _firewall_rfc1918_cidrs | sed "s|^|${iface} |"
	done
	return 0
}

_firewall_apply_ufw() {
	local awg_port="$1" ssh_ports="${2:-}"
	[[ -n "$ssh_ports" ]] || ssh_ports=$(_firewall_resolve_ssh_ports)
	ufw --force reset >/dev/null
	ufw default deny incoming
	ufw default allow outgoing
	ufw default allow routed   # let Docker FORWARD work (docker manages its own DOCKER chain)
	local p
	for p in $ssh_ports; do
		ufw allow "${p}/tcp" comment 'partner-edge ssh' >/dev/null
	done
	for p in "${_PE_FW_PUB_TCP[@]}"; do
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
	# → 502 on every group call (live incident on a US edge, 2026-07-09).
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
	# Hard stop BEFORE enable: never turn the firewall on over an sshd port the
	# ruleset does not allow.
	_firewall_ufw_require_ssh_covered "$ssh_ports" || return $?
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
	local awg_port="$1" ssh_ports="${2:-}"
	[[ -n "$ssh_ports" ]] || ssh_ports=$(_firewall_resolve_ssh_ports)
	local zone=public
	local p
	for p in $ssh_ports; do
		if [[ "$p" == "22" ]]; then
			firewall-cmd --permanent --zone=$zone --add-service=ssh >/dev/null
		else
			firewall-cmd --permanent --zone=$zone --add-port="${p}/tcp" >/dev/null
		fi
	done
	for p in "${_PE_FW_PUB_TCP[@]}"; do
		firewall-cmd --permanent --zone=$zone --add-port="${p}/tcp" >/dev/null
	done
	for p in "${_PE_FW_PUB_UDP[@]}"; do
		firewall-cmd --permanent --zone=$zone --add-port="${p}/udp" >/dev/null
	done
	local r fr
	# Retire the pre-fix relay range before adding the narrower one: every edge installed before the
	# coturn self-relay fix has 49152-65535/udp in its permanent zone config, which
	# overlaps the kernel ephemeral range and stays open until someone removes it
	# (add-port alone never does). `|| true`: absent on a clean node.
	firewall-cmd --permanent --zone=$zone --remove-port=49152-65535/udp >/dev/null 2>&1 || true
	for r in "${_PE_FW_PUB_UDP_RANGES[@]}"; do
		# firewalld wants dashes; our array uses ufw-style colons.
		fr="${r/:/-}"
		firewall-cmd --permanent --zone=$zone --add-port="${fr}/udp" >/dev/null
	done
	firewall-cmd --permanent --zone=$zone --add-port="${awg_port}/udp" >/dev/null

	# Retire :18443, the retired hysteria2 (CH3) forwarder. Older releases opened it
	# to the world (tcp+udp) and add-port alone never removes it. Permanent AND
	# runtime; `|| true` + silent: absent on a clean node.
	for p in tcp udp; do
		firewall-cmd --permanent --zone=$zone --remove-port="18443/${p}" >/dev/null 2>&1 || true
		firewall-cmd --zone=$zone --remove-port="18443/${p}" >/dev/null 2>&1 || true
	done

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

	# Hard stop BEFORE reload (permanent config is inert until then).
	_firewall_firewalld_require_ssh_covered "$zone" "$ssh_ports" || return $?
	firewall-cmd --reload >/dev/null
}

# Public entry point. Caller passes nothing; we discover everything.
firewall_apply() {
	local tool awg_port ssh_ports
	tool=$(_firewall_detect_tool)
	awg_port=$(_firewall_resolve_awg_port) || {
		warn "[firewall] cannot resolve AWG listen port — skipping firewall step."
		warn "           Run 'firewall_apply' manually after awg0 is up, or set AWG_LISTEN_PORT."
		return 0
	}

	ssh_ports=$(_firewall_resolve_ssh_ports)

	case "$tool" in
		ufw)
			_firewall_takeover_guard "$awg_port" "$ssh_ports" || return $?
			log "[firewall] applying ufw rules (awg=${awg_port}/udp ssh=${ssh_ports// /,}/tcp)"
			_firewall_apply_ufw "$awg_port" "$ssh_ports" || return $?
			;;
		ufw-install)
			# Guard BEFORE apt: installing ufw removes iptables-persistent.
			_firewall_takeover_guard "$awg_port" "$ssh_ports" || return $?
			log "[firewall] installing ufw, then applying rules (ssh=${ssh_ports// /,}/tcp)"
			DEBIAN_FRONTEND=noninteractive apt-get update -qq
			DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ufw
			_firewall_apply_ufw "$awg_port" "$ssh_ports" || return $?
			;;
		firewalld)
			log "[firewall] applying firewalld rules (awg=${awg_port}/udp ssh=${ssh_ports// /,}/tcp)"
			_firewall_apply_firewalld "$awg_port" "$ssh_ports" || return $?
			;;
		none|*)
			warn "[firewall] no supported firewall tool (ufw/firewalld) — skipping."
			warn "           Apply the partner-edge whitelist manually:"
			warn "           public: ${ssh_ports// /,},80,443/tcp 443,${awg_port}/udp 3478,5349/tcp+udp 7878/udp"
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
