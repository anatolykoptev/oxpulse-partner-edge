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
# live listeners of the sshd process from `ss -ltnp`, the ListenStream ports of an
# ACTIVE ssh.socket/sshd.socket (systemd socket activation, Ubuntu 22.10+/24.04:
# the socket's port overrides sshd_config Port, and until the first connection
# `ss -p` shows the owner as "systemd", not sshd), and the local port of the
# session running this installer (${SSH_CONNECTION##* }). Union, not first-hit:
# allowing one port too many is harmless, missing one is a lockout.
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
	if command -v systemctl >/dev/null 2>&1; then
		local unit
		for unit in ssh.socket sshd.socket; do
			systemctl is-active --quiet "$unit" 2>/dev/null || continue
			# `Listen=[::]:22 (Stream)` / `Listen=0.0.0.0:1987 (Stream)` / `Listen=22 (Stream)`
			raw+=" $(systemctl show -p Listen "$unit" 2>/dev/null \
				| sed -n 's/^Listen=//p' | sed 's/ (.*$//' | awk '{n=split($1,a,":"); print a[n]}' || true)"
		done
	fi
	# The live session's own destination port (empty when not run over ssh).
	local conn="${SSH_CONNECTION:-}"
	[[ -z "$conn" ]] || raw+=" ${conn##* }"
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

# Hard stop #2: EVERY rule this run meant to add (pub tcp/udp, relay range, awg,
# mesh, :8920) must be in `ufw show added`. A `ufw allow` that exited 0 without
# landing, or one whose failure was swallowed, would otherwise ship a firewall
# that default-denies a required port. $@ = rule specs ("allow 443/tcp", ...).
# rc 0 all present, rc 5 otherwise.
_firewall_ufw_require_rules_present() {
	local added spec line found missing=""
	added=$(ufw show added 2>/dev/null || true)
	for spec in "$@"; do
		found=0
		while IFS= read -r line; do
			if [[ "$line" == "ufw $spec" || "$line" == "ufw $spec "* ]]; then found=1; break; fi
		done <<<"$added"
		(( found )) || missing+=$'\n'"             ufw $spec"
	done
	[[ -z "$missing" ]] && return 0
	warn "[firewall] REFUSING to enable ufw: required rules missing from the ruleset about to be enabled:${missing}"
	warn "           ufw is left DISABLED (reset already ran). Re-run once the cause is fixed."
	return 5
}

# $1 = space-separated ssh ports (non-empty), $2 = awg port; each a plain integer
# 1-65535. Checked BEFORE
# `ufw --force reset` so a detection problem never leaves an active ufw disabled.
_firewall_validate_ports() {
	local ssh_list="$1" awg="$2" p n=0
	for p in $ssh_list "$awg"; do
		[[ "$p" =~ ^[0-9]+$ ]] && (( 10#$p >= 1 && 10#$p <= 65535 )) || {
			warn "[firewall] REFUSING to touch the firewall: invalid port '${p}' (ssh='${ssh_list}' awg='${awg}')."
			return 3
		}
	done
	for p in $ssh_list; do n=$((n+1)); done
	if (( n == 0 )); then
		warn "[firewall] REFUSING to touch the firewall: empty ssh port list."
		return 3
	fi
	return 0
}

# Run one ufw mutation; a failure is reported and returned (callers `|| return`),
# never swallowed: `fn || return $?` at the call site disables errexit inside fn,
# so each required step must propagate explicitly.
_firewall_ufw_do() {
	ufw "$@" >/dev/null || {
		warn "[firewall] 'ufw $*' FAILED — not enabling a partial ruleset."
		return 5
	}
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

# Same for every required plain port (pub tcp/udp, relay range, awg): "80/tcp" ...
# Rich rules (mesh, :8920) have no stable listing format and rely on their
# explicit rc check at the call site.
_firewall_firewalld_require_ports_present() {
	local zone="$1"; shift
	local lp spec missing=""
	lp=$(firewall-cmd --permanent --zone="$zone" --list-ports 2>/dev/null | tr '\n' ' ' || true)
	for spec in "$@"; do
		[[ " $lp " == *" ${spec} "* ]] || missing+=" ${spec}"
	done
	[[ -z "$missing" ]] && return 0
	warn "[firewall] REFUSING to reload firewalld: required ports missing from the permanent ${zone} zone:${missing}"
	return 5
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

# `-A INPUT ... -j ACCEPT` lines of rules.v4 and rules.v6 (empty when absent/none).
_firewall_rules_v4_input_accepts() {
	local f
	for f in "$(_firewall_rules_v4_path)" "${PE_FW_RULES_V6:-/etc/iptables/rules.v6}"; do
		[[ -r "$f" ]] || continue
		grep -E '^-A INPUT .*-j ACCEPT' "$f" || true
	done
}
# Subset of the rules.v4 INPUT ACCEPT lines that the ufw set we are about to apply
# does NOT reproduce. Deliberately conservative: only conntrack/loopback/icmp
# (ufw's built-in before.rules) and a plain `-p tcp|udp --dport N` whose port is in
# our public set (or an unrestricted/10.9.0.0/24 match for our mesh ports) count as
# covered. Anything else is reported. $1 = awg port, $2 = ssh ports.
_firewall_uncovered_v4_rules() {
	local awg="$1" ssh="$2" line proto ports port ok src
	local re_proto='-p (tcp|udp)( |$)' re_ports='--dports? ([0-9:,]+)' re_src='-s ([^ ]+)' re_if='-i ([^ ]+)' iif
	while IFS= read -r line; do
		[[ -n "$line" ]] || continue
		case "$line" in
			*"RELATED,ESTABLISHED"*|*"ESTABLISHED,RELATED"*|*" -i lo "*|*" -i lo"|*"-p icmp"*|*"-p ipv6-icmp"*) continue ;;
		esac
		proto="" ports="" src="" iif=""
		[[ "$line" =~ $re_proto ]] && proto="${BASH_REMATCH[1]}"
		[[ "$line" =~ $re_ports ]] && ports="${BASH_REMATCH[1]}"
		[[ "$line" =~ $re_src ]] && src="${BASH_REMATCH[1]}"
		[[ "$line" =~ $re_if ]] && iif="${BASH_REMATCH[1]}"
		ok=0
		if [[ -n "$proto" && -n "$ports" ]]; then
			ok=1
			for port in ${ports//,/ }; do
				_firewall_port_covered "$proto" "$port" "$src" "$awg" "$ssh" "$iif" || ok=0
			done
		fi
		(( ok )) || printf '%s\n' "$line"
	done < <(_firewall_rules_v4_input_accepts)
}

_firewall_port_covered() {
	local proto="$1" port="$2" src="$3" awg="$4" ssh="$5" iif="${6:-}" p r
	# ufw opens our public ports to EVERYONE on EVERY interface: a v4/v6 rule that
	# was source- or interface-restricted is therefore NOT reproduced (it would
	# widen), except the mesh-only ports from exactly the mesh CIDR.
	[[ -z "$iif" ]] || return 1
	if [[ "$proto" == tcp ]]; then
		if [[ -z "$src" ]]; then
			for p in "${_PE_FW_PUB_TCP[@]}" $ssh; do [[ "$p" == "$port" ]] && return 0; done
		fi
		for p in "${_PE_FW_MESH_TCP[@]}"; do
			[[ "$p" == "$port" && "$src" == "10.9.0.0/24" ]] && return 0
		done
	else
		[[ -z "$src" ]] || return 1
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
	if [[ "$pkg" == 0 ]] && command -v ufw >/dev/null 2>&1; then
		# Capture first (no `| head`/`grep -q` pipe: SIGPIPE + pipefail can turn an
		# active ufw into a false "not active"); C locale because ufw translates the
		# word "active" and a localized status would miss the match.
		local ufw_st
		ufw_st=$(LC_ALL=C ufw status 2>/dev/null || true)
		if grep -qi 'Status: active' <<<"$ufw_st"; then
			return 0
		fi
	fi
	uncovered=$(_firewall_uncovered_v4_rules "$awg" "$ssh")
	warn "[firewall] this host has an existing iptables-based firewall that the ufw takeover would discard:"
	[[ "$pkg" == 1 ]] && warn "           iptables-persistent/netfilter-persistent is installed — installing ufw REMOVES it."
	if [[ -n "$uncovered" ]]; then
		warn "           INPUT ACCEPT rules in $(_firewall_rules_v4_path) / ${PE_FW_RULES_V6:-/etc/iptables/rules.v6} that the partner-edge ufw set will NOT cover (lost on takeover):"
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

# --- Operator extra rules ----------------------------------------------------
# `ufw --force reset` wipes every operator rule on each apply, so rules the node
# needs beyond the partner-edge set live in a file that is re-applied after it:
#   /etc/oxpulse-partner-edge/firewall-extra.ufw   (override: PE_FW_EXTRA_FILE)
# One ufw rule per line in the exact `ufw show added` form minus the leading
# "ufw ", e.g.
#   allow from 10.9.0.0/24 to any port 9100 proto tcp comment 'node-exporter mesh-only'
# `#` comments and blank lines are ignored. The grammar is a strict allowlist (see
# _firewall_extra_parse_line); nothing is ever eval'd or word-split into a command.
# ufw only: firewalld has no equivalent here (warned, not failed).

_firewall_extra_file() { printf '%s' "${PE_FW_EXTRA_FILE:-/etc/oxpulse-partner-edge/firewall-extra.ufw}"; }

_firewall_valid_port_spec() { # N or N:M, 1-65535, N<M
	local v="$1" a b
	[[ "$v" =~ ^([0-9]{1,5})(:([0-9]{1,5}))?$ ]] || return 1
	a="${BASH_REMATCH[1]}"; b="${BASH_REMATCH[3]:-}"
	(( 10#$a >= 1 && 10#$a <= 65535 )) || return 1
	[[ -z "$b" ]] || { (( 10#$b <= 65535 && 10#$a < 10#$b )) || return 1; }
	return 0
}

_firewall_valid_src() { # any | IPv4[/0-32] | IPv6[/0-128]
	local v="$1" ip pfx o
	[[ "$v" == any ]] && return 0
	ip="${v%%/*}"; pfx=""; [[ "$v" == */* ]] && pfx="${v#*/}"
	if [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
		local IFS=.
		# shellcheck disable=SC2086  # intentional split on '.'
		for o in $ip; do (( 10#$o <= 255 )) || return 1; done
		[[ -z "$pfx" ]] || { [[ "$pfx" =~ ^[0-9]{1,2}$ ]] && (( 10#$pfx <= 32 )); } || return 1
		return 0
	fi
	if [[ "$ip" =~ ^[0-9A-Fa-f:]+$ && "$ip" == *:*:* ]]; then
		[[ -z "$pfx" ]] || { [[ "$pfx" =~ ^[0-9]{1,3}$ ]] && (( 10#$pfx <= 128 )); } || return 1
		return 0
	fi
	return 1
}

# Parse ONE rule line. On success sets _X_VERB, _X_COMMENT and the array _X_WORDS
# (rule words after the verb) and returns 0; on failure sets _X_ERR, returns 1.
# Accepted shapes (ufw's own printed form; fixed token order):
#   (allow|deny) <N|N:M>/(tcp|udp)
#   (allow|deny) [in on IFACE] [from SRC] [to any port PORT [proto tcp|udp]]
# each optionally followed by:  comment '<text without quotes>'
# An allow must be scoped: a port, or a source other than `any`.
_firewall_extra_parse_line() {
	local line="$1" body comment="" re_c n i verb has_port=0 has_to=0 src=""
	_X_VERB=""; _X_COMMENT=""; _X_WORDS=(); _X_ERR=""
	re_c="^(.*[^[:space:]])[[:space:]]+comment[[:space:]]+'([^']*)'$"
	if [[ "$line" =~ $re_c ]]; then
		body="${BASH_REMATCH[1]}"; comment="${BASH_REMATCH[2]}"
		if [[ ! "$comment" =~ ^[[:print:]]{1,200}$ || "$comment" == *\\* ]]; then
			_X_ERR="comment must be 1-200 printable characters without quotes or backslashes"; return 1
		fi
	else
		body="$line"
	fi
	if [[ ! "$body" =~ ^[A-Za-z0-9_.:/\ -]+$ ]]; then
		_X_ERR="unsupported character (allowed: letters digits _ . : / - and spaces; comment only as trailing comment '<text>')"; return 1
	fi
	local -a t=()
	read -ra t <<<"$body"
	n=${#t[@]}
	verb="${t[0]:-}"
	[[ "$verb" == allow || "$verb" == deny ]] || { _X_ERR="rule must start with allow or deny"; return 1; }
	_X_VERB="$verb"; _X_COMMENT="$comment"
	if (( n == 2 )) && [[ "${t[1]}" =~ ^([0-9:]+)/(tcp|udp)$ ]]; then
		_firewall_valid_port_spec "${BASH_REMATCH[1]}" || { _X_ERR="invalid port '${t[1]}'"; return 1; }
		_X_WORDS=("${t[1]}"); return 0
	fi
	i=1
	if [[ "${t[i]:-}" == in ]]; then
		[[ "${t[i+1]:-}" == on && "${t[i+2]:-}" =~ ^[A-Za-z0-9_.-]{1,15}$ ]] || { _X_ERR="expected 'in on <iface>' (iface <=15 chars)"; return 1; }
		_X_WORDS+=(in on "${t[i+2]}"); i=$((i+3))
	fi
	if [[ "${t[i]:-}" == from ]]; then
		src="${t[i+1]:-}"
		_firewall_valid_src "$src" || { _X_ERR="invalid source '${src}' (any, IPv4/IPv6, optional /prefix)"; return 1; }
		_X_WORDS+=(from "$src"); i=$((i+2))
	fi
	if [[ "${t[i]:-}" == to ]]; then
		[[ "${t[i+1]:-}" == any ]] || { _X_ERR="only 'to any' is supported"; return 1; }
		_X_WORDS+=(to any); has_to=1; i=$((i+2))
	fi
	if [[ "${t[i]:-}" == port ]]; then
		_firewall_valid_port_spec "${t[i+1]:-}" || { _X_ERR="invalid port '${t[i+1]:-}'"; return 1; }
		_X_WORDS+=(port "${t[i+1]}"); has_port=1; i=$((i+2))
		if [[ "${t[i]:-}" == proto ]]; then
			[[ "${t[i+1]:-}" == tcp || "${t[i+1]:-}" == udp ]] || { _X_ERR="proto must be tcp or udp"; return 1; }
			_X_WORDS+=(proto "${t[i+1]}"); i=$((i+2))
		fi
	fi
	(( i == n )) || { _X_ERR="unexpected token '${t[i]:-}' (expected: [in on IF] [from SRC] [to any port N [proto tcp|udp]])"; return 1; }
	(( has_port == has_to )) || { _X_ERR="'to any' and 'port' must appear together"; return 1; }
	(( ${#_X_WORDS[@]} > 0 )) || { _X_ERR="empty rule"; return 1; }
	if [[ "$verb" == allow && $has_port -eq 0 && ( -z "$src" || "$src" == any ) ]]; then
		_X_ERR="unscoped allow (needs a port, or a source other than 'any')"; return 1
	fi
	return 0
}

# Validate the whole extra file; load the rules into _PE_FW_EXTRA (entries
# "<verb> <words...>\t<comment>"). Every bad line is reported; rc 6 if any.
# Called BEFORE `ufw --force reset`.
_firewall_extra_load() {
	_PE_FW_EXTRA=()
	local f; f=$(_firewall_extra_file)
	[[ -e "$f" ]] || return 0
	[[ -r "$f" ]] || { warn "[firewall] extra rules file $f is not readable — refusing to touch the firewall."; return 6; }
	local line n=0 bad=0
	while IFS= read -r line || [[ -n "$line" ]]; do
		n=$((n+1))
		line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
		[[ -z "$line" || "$line" == \#* ]] && continue
		if _firewall_extra_parse_line "$line"; then
			_PE_FW_EXTRA+=("${_X_VERB} ${_X_WORDS[*]}"$'\t'"${_X_COMMENT}")
		else
			warn "[firewall] $f:$n: ${_X_ERR}: $line"
			bad=1
		fi
	done <"$f"
	if (( bad )); then
		warn "[firewall] REFUSING to touch the firewall: fix $f (nothing was changed)."
		return 6
	fi
	return 0
}

_firewall_extra_has_rules() {
	local f; f=$(_firewall_extra_file)
	[[ -r "$f" ]] && grep -qvE '^[[:space:]]*(#|$)' "$f"
}

# The partner-edge rule set as "<comment>\t<spec>" lines (spec = "allow <words>"),
# the single source for BOTH the apply loop and the seeding comparison, so the two
# cannot drift. $1 = awg port, $2 = ssh ports.
_firewall_ufw_plan() {
	local awg_port="$1" ssh_ports="$2" p r
	for p in $ssh_ports; do printf '%s\t%s\n' 'partner-edge ssh' "allow ${p}/tcp"; done
	for p in "${_PE_FW_PUB_TCP[@]}"; do printf '%s\t%s\n' 'partner-edge pub' "allow ${p}/tcp"; done
	for p in "${_PE_FW_PUB_UDP[@]}"; do printf '%s\t%s\n' 'partner-edge pub' "allow ${p}/udp"; done
	for r in "${_PE_FW_PUB_UDP_RANGES[@]}"; do printf '%s\t%s\n' 'partner-edge ephemeral relay' "allow ${r}/udp"; done
	printf '%s\t%s\n' "amneziawg ${awg_port}" "allow ${awg_port}/udp"
	for p in "${_PE_FW_MESH_TCP[@]}"; do
		printf '%s\t%s\n' 'partner-edge mesh-only' "allow from 10.9.0.0/24 to any port ${p} proto tcp"
	done
	# SFU client WS (:8920) — see the scoping rationale in _firewall_apply_ufw.
	local edge_iface edge_subnet fixed_done=0 c='partner-edge sfu-ws local-bridge'
	while read -r edge_iface edge_subnet; do
		[[ -n "$edge_subnet" ]] || continue
		if [[ "$edge_iface" == "-" || -z "$edge_iface" ]]; then
			printf '%s\t%s\n' "$c" "allow from ${edge_subnet} to any port 8920 proto tcp"
		elif [[ "$edge_iface" == "$_PE_FW_EDGE_BRIDGE" ]]; then
			(( fixed_done )) && continue
			fixed_done=1
			printf '%s\t%s\n' "$c" "allow in on ${edge_iface} to any port 8920 proto tcp"
		else
			printf '%s\t%s\n' "$c" "allow in on ${edge_iface} from ${edge_subnet} to any port 8920 proto tcp"
		fi
	done < <(_firewall_resolve_edge_bridges)
}

# One-time seeding for nodes that predate the extra-rules file: write it from the
# live `ufw show added`, MINUS what the partner-edge set owns. Runs before the
# first reset with this code; never overwrites (noclobber = O_EXCL), so it is
# idempotent and an operator's file is never touched. A live rule is
# partner-edge-owned when (a) its comment starts with "partner-edge" (covers stale
# pins such as the old in-on-br-<id> rule and the iface-agnostic 8920 rule),
# (b) its spec equals one the plan would add now (ssh ports from detection, awg,
# pub/relay/mesh), or (c) it opens :8920. Anything else that parses is seeded; a
# live rule outside the grammar is kept as a "# NOT SEEDED" comment and warned.
# $1 = awg port, $2 = ssh ports.
_firewall_seed_extra_rules() {
	local f; f=$(_firewall_extra_file)
	[[ -e "$f" ]] && return 0
	local added plan planned line rule spec comment out="" n_seed=0 n_skip=0
	local re_c="^(.*[^[:space:]])[[:space:]]+comment[[:space:]]+'(.*)'$"
	added=$(ufw show added 2>/dev/null || true)
	plan=$(_firewall_ufw_plan "$1" "$2")
	planned=$'\n'"$(cut -f2 <<<"$plan")"$'\n'
	while IFS= read -r line; do
		[[ "$line" == "ufw "* ]] || continue
		rule="${line#ufw }"; spec="$rule"; comment=""
		if [[ "$rule" =~ $re_c ]]; then spec="${BASH_REMATCH[1]}"; comment="${BASH_REMATCH[2]}"; fi
		[[ "$comment" == partner-edge* ]] && continue
		[[ "$planned" == *$'\n'"$spec"$'\n'* ]] && continue
		[[ "$spec" =~ (^|[[:space:]])port\ 8920([[:space:]]|$) ]] && continue
		if _firewall_extra_parse_line "$rule"; then
			out+="$rule"$'\n'; n_seed=$((n_seed+1))
		else
			out+="# NOT SEEDED (${_X_ERR}): $rule"$'\n'; n_skip=$((n_skip+1))
			warn "[firewall] live ufw rule not seeded into $f (${_X_ERR}): $rule"
		fi
	done <<<"$added"
	mkdir -p "$(dirname "$f")" 2>/dev/null || true
	if ( set -o noclobber; printf '%s\n%s\n%s' \
		"# Operator firewall rules, re-applied after the partner-edge set on every apply (ufw only)." \
		"# seeded from live ufw on $(date -u +%F)" \
		"$out" >"$f" ) 2>/dev/null; then
		log "[firewall] seeded $f from live ufw: ${n_seed} rule(s) kept, ${n_skip} not seedable"
	else
		[[ -e "$f" ]] || warn "[firewall] could not write $f — operator ufw rules (if any) will not survive this apply"
	fi
	return 0
}

# `ufw allow <words...> comment <c>`; records the rule words in the caller's
# `_fw_want` array (dynamic scope) so the pre-enable read-back can verify them.
_firewall_ufw_add() {
	local comment="$1"; shift
	_firewall_ufw_add_rule "$comment" allow "$@"
}

# Generic form: $1 comment ("" = none), $2 verb (allow|deny), rest = rule words.
_firewall_ufw_add_rule() {
	local comment="$1" verb="$2"; shift 2
	if [[ -n "$comment" ]]; then
		_firewall_ufw_do "$verb" "$@" comment "$comment" || return $?
	else
		_firewall_ufw_do "$verb" "$@" || return $?
	fi
	_fw_want+=("$verb $*")
}
# NOTE every required mutation below propagates its failure explicitly
# (`|| return`): callers invoke this as `_firewall_apply_ufw ... || return $?`,
# which suspends errexit inside the whole function, so a bare failing command
# would be silently ignored and `ufw --force enable` would still go live.
_firewall_apply_ufw() {
	local awg_port="$1" ssh_ports="${2:-}"
	[[ -n "$ssh_ports" ]] || ssh_ports=$(_firewall_resolve_ssh_ports)
	# Validate EVERYTHING that can be validated BEFORE the destructive reset: a bad
	# detection result or a malformed operator rule must never leave a
	# previously-active ufw disabled.
	_firewall_validate_ports "$ssh_ports" "$awg_port" || return $?
	local -a _PE_FW_EXTRA=()
	_firewall_extra_load || return $?
	local -a _fw_want=()
	_firewall_ufw_do --force reset || return $?
	_firewall_ufw_do default deny incoming || return $?
	_firewall_ufw_do default allow outgoing || return $?
	_firewall_ufw_do default allow routed || return $?   # let Docker FORWARD work (docker manages its own DOCKER chain)
	# The partner-edge set comes from _firewall_ufw_plan (also used by the seeding
	# comparison). :8920 scoping rationale, implemented in the plan:
	# SFU client WS (:8920) — reachable ONLY from the local docker `edge` bridge.
	# Caddy reverse_proxies /sfu/ws/* to host.docker.internal:8920; browsers reach
	# it exclusively through Caddy's :443 TLS front, never :8920 directly. Without
	# this rule `default deny incoming` drops Caddy→host:8920 ("no route to host")
	# → 502 on every group call (live incident on a US edge, 2026-07-09).
	#
	# SCOPING (correct-by-construction): the rule is bound to the docker bridge
	# INTERFACE (`in on <iface>`), so it can only match traffic that actually
	# arrived on that bridge — never the public NIC. Source-IP alone is NOT
	# sufficient: RFC1918 is not martian (RFC1812) and rp_filter defaults to loose
	# (=2) on these distros, so a spoofed 172.x source on the public interface would
	# pass a source-only check; the interface match is the real guard. (This TCP
	# port's return path also can't reach a spoofer, but we do not rely on that.)
	# 8920 stays off the public whitelist — not public exposure.
	#   - fixed bridge (_PE_FW_EDGE_BRIDGE): interface-only rule, NO source subnet —
	#     the subnet is docker-assigned and can change when the network is recreated,
	#     which would stale the rule exactly like the bridge name did.
	#   - legacy br-<id> network: interface + source subnet (as before).
	#   - iface unknown (override seam, iface "-"): source-only, RFC1918-gated.
	local plan c spec
	local -a w
	plan=$(_firewall_ufw_plan "$awg_port" "$ssh_ports")
	while IFS=$'\t' read -r c spec; do
		[[ -n "$spec" ]] || continue
		read -ra w <<<"${spec#allow }"
		_firewall_ufw_add "$c" "${w[@]}" || return $?
	done <<<"$plan"
	if [[ "$plan" == *"port 8920 "* ]]; then _firewall_warn_if_no_bridge 1; else _firewall_warn_if_no_bridge 0; fi
	# Operator extra rules (validated above), after the partner-edge set; they are
	# in _fw_want, so the pre-enable read-back covers them too.
	local entry verb rest
	for entry in "${_PE_FW_EXTRA[@]}"; do
		c="${entry#*$'\t'}"; spec="${entry%%$'\t'*}"
		verb="${spec%% *}"; rest="${spec#* }"
		read -ra w <<<"$rest"
		_firewall_ufw_add_rule "$c" "$verb" "${w[@]}" || return $?
	done
	# Hard stops BEFORE enable, each against ufw's own read-back: never turn the
	# firewall on over an sshd port, or any other required rule, that is not there.
	_firewall_ufw_require_ssh_covered "$ssh_ports" || return $?
	_firewall_ufw_require_rules_present "${_fw_want[@]}" || return $?
	_firewall_ufw_do --force enable || return $?
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
	_firewall_validate_ports "$ssh_ports" "$awg_port" || return $?
	# Every required mutation propagates explicitly (`|| return 5`): the caller's
	# `|| return $?` suspends errexit inside this function.
	if _firewall_extra_has_rules; then
		warn "[firewall] $(_firewall_extra_file) has operator rules but firewalld does not apply them (ufw only) — add them with firewall-cmd (permanent rich rules) or they stay closed."
	fi
	local zone=public
	local p
	local -a _fw_want_ports=()
	# NOTE: on an existing node the `ssh` service (22) added by older releases is NOT
	# removed here — a non-22 sshd leaves 22/tcp open until an operator removes it.
	for p in $ssh_ports; do
		if [[ "$p" == "22" ]]; then
			firewall-cmd --permanent --zone=$zone --add-service=ssh >/dev/null || return 5
		else
			firewall-cmd --permanent --zone=$zone --add-port="${p}/tcp" >/dev/null || return 5
		fi
	done
	for p in "${_PE_FW_PUB_TCP[@]}"; do
		firewall-cmd --permanent --zone=$zone --add-port="${p}/tcp" >/dev/null || return 5
		_fw_want_ports+=("${p}/tcp")
	done
	for p in "${_PE_FW_PUB_UDP[@]}"; do
		firewall-cmd --permanent --zone=$zone --add-port="${p}/udp" >/dev/null || return 5
		_fw_want_ports+=("${p}/udp")
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
		firewall-cmd --permanent --zone=$zone --add-port="${fr}/udp" >/dev/null || return 5
		_fw_want_ports+=("${fr}/udp")
	done
	firewall-cmd --permanent --zone=$zone --add-port="${awg_port}/udp" >/dev/null || return 5
	_fw_want_ports+=("${awg_port}/udp")

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
			"rule family=ipv4 source address=10.9.0.0/24 port port=$p protocol=tcp accept" >/dev/null || return 5
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
			"rule family=ipv4 source address=$edge_subnet port port=8920 protocol=tcp accept" >/dev/null || return 5
	done < <(_firewall_resolve_edge_bridges)
	_firewall_warn_if_no_bridge "$had_bridge"

	# Hard stop BEFORE reload (permanent config is inert until then).
	_firewall_firewalld_require_ssh_covered "$zone" "$ssh_ports" || return $?
	_firewall_firewalld_require_ports_present "$zone" "${_fw_want_ports[@]}" || return $?
	firewall-cmd --reload >/dev/null || return 5
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
			_firewall_seed_extra_rules "$awg_port" "$ssh_ports"
			_firewall_apply_ufw "$awg_port" "$ssh_ports" || return $?
			;;
		ufw-install)
			# Guard BEFORE apt: installing ufw removes iptables-persistent.
			_firewall_takeover_guard "$awg_port" "$ssh_ports" || return $?
			log "[firewall] installing ufw, then applying rules (ssh=${ssh_ports// /,}/tcp)"
			DEBIAN_FRONTEND=noninteractive apt-get update -qq
			DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ufw
			_firewall_seed_extra_rules "$awg_port" "$ssh_ports"
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
