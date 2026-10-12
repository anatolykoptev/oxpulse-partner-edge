#!/usr/bin/env bash
# oxpulse-partner-edge-coturn-guard — stop the edge's coturn relaying UDP to the
# host's own services.
#
#   oxpulse-partner-edge-coturn-guard [apply|remove|status]
#
# THE FLAW. coturn (network_mode: host) relays a TURN client's UDP to any peer
# address the client names, and TURN credentials are minted by a public endpoint
# (POST /api/turn-credentials), so anyone can hold one. A relay packet addressed
# to an address that is local to the host is delivered by the kernel locally, via
# `-i lo ACCEPT`-style paths that INPUT allowlists (ufw) never see. Net effect: a
# credential holder can send UDP to every non-loopback UDP listener on the edge
# (rpcbind, hysteria client sockets, amneziawg, QUIC listeners, the SFU...).
# coturn.conf's denied-peer-ip does not stop it: coturn maps its own external IP
# to the private one only when sending, after the deny check ran on the public
# address. The pre-fix template additionally re-permitted the whole private IP
# (allowed-peer-ip=PRIVATE_IP) on NAT'd edges — which is the ONE allowance that must
# stay (this host's OWN relay address, else coturn's own 10/8 deny blocks same-edge
# relaying); the nft guard below is what makes it safe.
#
# THE GUARD. One nft table, `inet coturn_self_relay_guard`, OUTPUT hook, matching
# the numeric uid the coturn container runs as (COTURN_UID, baked into
# images/Dockerfile.coturn — numeric because the host has no such user):
#
#   1. ct direction reply            -> accept   (replies to a client ON this host:
#                                                 healthcheck / cross-probe turn
#                                                 clients; see "hook" below)
#   2. local addr, udp dport = SFU   -> accept   (client -> relay -> co-located SFU,
#                                                 the legitimate hairpin; on NAT'd
#                                                 edges the destination is the
#                                                 private IP, on public-NIC edges
#                                                 the public IP — both are local)
#   3. local addr, udp dport outside
#      RELAY_MIN-RELAY_MAX           -> drop     (everything else coturn sends to
#                                                 this host)
#
# One `inet` table covers IPv4 and IPv6. Packets to remote peers (the normal relay
# path) and replies to remote clients are not `fib daddr type local`: untouched.
# The relay range is reserved from the kernel's ephemeral pool
# (net.ipv4.ip_local_reserved_ports) so the only sockets listening inside it are
# coturn's own relay sockets: "local + inside the range" means "relay-to-relay".
#
# Hook choice: priority `mangle` (-150). After conntrack (-200), which rule 1
# needs; before the nat OUTPUT chain at dstnat (-100), because Docker's nat OUTPUT
# rewrites local-destined published ports to container addresses, and a later hook
# would see the rewritten address (not "local") and miss exactly the docker-
# published UDP services. Rule 1 deliberately differs from the krolik canon
# (priority raw, no state): partner edges run a TURN client on the host itself
# (lib/channel-health-lib.sh ch4, lib/cross-probe-lib.sh) and, on public-NIC edges,
# coturn's replies to it go to a LOCAL address on an ephemeral port that rule 3
# would otherwise drop, blinding the probe. A reply-direction packet can only match
# a flow some local socket opened toward coturn first; a TURN credential holder
# cannot make rpcbind (etc.) do that, and cannot forge it.
#
# Not coupled to coturn.service/compose (no Requires=/BindsTo=): a coupling either
# way breaks restarts and rollback. A missing table is made visible instead:
# healthcheck.sh check_22_coturn_self_relay_guard calls `status`.
#
# `apply` is idempotent; the nft load is one atomic transaction (delete+create
# preamble). Besides the table it:
#   * migrates the LIVE coturn.conf (min-port/max-port -> the guard range, allowed-peer-ip
#     limited to this host's own relay address, mode 0600), BEFORE the table loads, so a plain upgrade — which never
#     reaches reconcile_all — leaves no edge running the old 49152-65535 range or
#     the old allowed-peer-ip under a guard that would drop its relays; coturn is
#     restarted only if the file actually changed;
#   * reserves the relay range (merged into whatever is already reserved) and
#     writes the sysctl.d file (our range only);
#   * makes the firewall (firewalld / ufw) allow exactly the conf's relay range and
#     retires the legacy 49152-65535/udp allowance - removing it FIRST under firewalld
#     (which coalesces, see fw_converge_firewalld) and restoring it if the narrow
#     range does not end up in force. `firewall-sync` runs just this step.
#
# `status` is the single definition of "in force" (healthcheck + selfheal): the
# rule set, the reservation, the RUNNING turnserver's uid, the deployed conf's
# range, and no foreign UDP socket inside the relay range.
#
# Env (tests / operator overrides): SFU_UDP_PORT, ETC_DIR, SYSCTL_DIR, NFT,
# SYSCTL_BIN, SS_BIN, IP_BIN, COMPOSE_FILE, COTURN_CONF, PROC_DIR, RESERVED_PORTS_FILE, PGREP_BIN, DOCKER_BIN,
# FIREWALL_CMD, UFW_BIN, NFT_INSTALL=0 (do not try to install nftables).
set -euo pipefail

# --- constants: single source of truth for the guard side ---------------------
# COTURN_UID  == `ARG COTURN_UID` / `USER` in images/Dockerfile.coturn
# RELAY_MIN/MAX == min-port/max-port in coturn.conf.tpl == _PE_FW_PUB_UDP_RANGES
#                  in lib/firewall-lib.sh (and its frozen twin install-firewall.sh)
# tests/test_coturn_guard.sh fails if any of them drifts.
readonly COTURN_UID=58731
readonly RELAY_MIN=49152
readonly RELAY_MAX=49999
readonly DEFAULT_SFU_UDP_PORT=7878
readonly TABLE="coturn_self_relay_guard"
# nf_conntrack_udp_timeout_stream 120 -> 180: the kernel default can lapse on the
# low-rate edge<->edge cascade leg (2026-06-05 partner-edge relay-disconnect
# research, fix #2). Shipped here because this is the file that owns the relay
# ports' kernel tuning.
readonly CONNTRACK_UDP_STREAM_TIMEOUT=180
# The range every pre-fix edge has in coturn.conf, ufw and firewalld (it overlaps
# the kernel ephemeral range 32768-60999). Referenced only to retire it.
readonly LEGACY_RELAY_RANGE="49152-65535"

ETC_DIR="${ETC_DIR:-/etc}"
SYSCTL_DIR="${SYSCTL_DIR:-${ETC_DIR}/sysctl.d}"
NFT="${NFT:-nft}"
SYSCTL_BIN="${SYSCTL_BIN:-sysctl}"
SS_BIN="${SS_BIN:-ss}"
COMPOSE_FILE="${COMPOSE_FILE:-${ETC_DIR}/oxpulse-partner-edge/docker-compose.yml}"
SYSCTL_FILE="${SYSCTL_DIR}/99-oxpulse-coturn-relay-ports.conf"
COTURN_CONF="${COTURN_CONF:-${ETC_DIR}/oxpulse-partner-edge/coturn.conf}"
PROC_DIR="${PROC_DIR:-/proc}"
RESERVED_PORTS_FILE="${RESERVED_PORTS_FILE:-/proc/sys/net/ipv4/ip_local_reserved_ports}"
PGREP_BIN="${PGREP_BIN:-pgrep}"
DOCKER_BIN="${DOCKER_BIN:-docker}"
IP_BIN="${IP_BIN:-ip}"
FIREWALL_CMD="${FIREWALL_CMD:-firewall-cmd}"
UFW_BIN="${UFW_BIN:-ufw}"
CONF_CHANGED=0

log()  { printf '%s coturn-guard: %s\n' "$(date -u +%FT%TZ)" "$*"; }
warn() { printf '%s coturn-guard: WARN: %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }
die()  { printf '%s coturn-guard: ERROR: %s\n' "$(date -u +%FT%TZ)" "$*" >&2; exit 1; }

# The SFU's media port: the port the co-located SFU binds, from the node's own
# compose file (authoritative, persisted; install.env does not carry it).
resolve_sfu_port() {
	local p="${SFU_UDP_PORT:-}"
	if [[ -z "$p" && -r "$COMPOSE_FILE" ]]; then
		p=$(sed -n 's/^[[:space:]]*SFU_UDP_PORT:[[:space:]]*"\{0,1\}\([0-9]\{1,5\}\).*/\1/p' "$COMPOSE_FILE" | head -n1)
	fi
	p="${p:-$DEFAULT_SFU_UDP_PORT}"
	[[ "$p" =~ ^[0-9]{1,5}$ ]] && (( 10#$p >= 1 && 10#$p <= 65535 )) \
		|| die "SFU media port '$p' is not a valid UDP port"
	printf '%s' "$((10#$p))"
}

# The ruleset. One `nft -f` transaction: the delete+create preamble makes a
# reload replace the table atomically, with no window where it is absent.
render_ruleset() {
	local sfu_port="$1"
	cat <<EOF
table inet ${TABLE}
delete table inet ${TABLE}
table inet ${TABLE} {
  chain output {
    type filter hook output priority mangle; policy accept;
    meta skuid ${COTURN_UID} ct direction reply counter accept comment "replies to a TURN client on this host"
    meta skuid ${COTURN_UID} fib daddr type local meta l4proto udp udp dport ${sfu_port} counter accept comment "relay to co-located SFU media port"
    meta skuid ${COTURN_UID} fib daddr type local meta l4proto udp udp dport != ${RELAY_MIN}-${RELAY_MAX} counter drop comment "coturn self-relay guard"
  }
}
EOF
}

render_sysctl() {
	cat <<EOF
# Managed by oxpulse-partner-edge-coturn-guard — do not edit.
# Keeps coturn's relay range (min-port/max-port in coturn.conf) out of the kernel's
# ephemeral pool. Without it any outbound or port-0 UDP socket on the host can land
# inside ${RELAY_MIN}-${RELAY_MAX}, and a TURN credential holder could then relay to it.
# Pairs with the nft table ${TABLE}, which lets coturn send to local addresses only
# inside this range (plus the SFU port): the reservation is what makes "inside this
# range" mean "a relay socket". An explicit bind() to a reserved port still works,
# which is how coturn takes its relay ports.
net.ipv4.ip_local_reserved_ports = ${RELAY_MIN}-${RELAY_MAX}
# Edge<->edge cascade relay can idle past the 120s default (see the script header).
net.netfilter.nf_conntrack_udp_timeout_stream = ${CONNTRACK_UDP_STREAM_TIMEOUT}
EOF
}

ensure_nft() {
	command -v "$NFT" >/dev/null 2>&1 && return 0
	[[ "${NFT_INSTALL:-1}" = 1 ]] || die "nft not found and NFT_INSTALL=0"
	warn "nft not found — trying to install nftables"
	if command -v apt-get >/dev/null 2>&1; then
		DEBIAN_FRONTEND=noninteractive apt-get install -y -q nftables >/dev/null 2>&1 || true
	elif command -v dnf >/dev/null 2>&1; then
		dnf install -y nftables >/dev/null 2>&1 || true
	fi
	command -v "$NFT" >/dev/null 2>&1 || die "nft not found and nftables could not be installed — guard NOT applied"
}

# Sockets already bound inside the relay range that coturn does not own stay
# reachable through rule 3's allow-range (the reservation only affects sockets
# opened afterwards). Tell the operator; restarting that process moves it.
stray_sockets() {
	command -v "$SS_BIN" >/dev/null 2>&1 || return 0
	# UDP only: the guard governs UDP relays (coturn runs no-tcp-relay), and a TCP
	# connection that predates the reservation must not turn `status` red.
	"$SS_BIN" -H -uanp 2>/dev/null \
		| awk -v lo="$RELAY_MIN" -v hi="$RELAY_MAX" \
			'{n=split($4,a,":"); p=a[n]+0; if (p>=lo && p<=hi && $0 !~ /"turnserver"/) print}'
}

warn_stray_sockets() {
	local stray
	stray=$(stray_sockets)
	if [[ -n "$stray" ]]; then
		warn "sockets in ${RELAY_MIN}-${RELAY_MAX} not owned by turnserver (restart their process to move it out of the relay range):"
		printf '%s\n' "$stray" >&2
	fi
}

# Union of CURRENT (kernel format: "a-b,c ...") and our relay range, as the sorted,
# merged "a-b,c-d" list the kernel accepts. Pure: the sysctl is never clobbered
# with just our range when something else already reserved ports.
merge_ports() { _ports_awk merge "$1"; }

# yes/no: does the reserved list CURRENT already cover the whole relay range?
reserved_covers_relay() { [[ $(_ports_awk covers "$1") == yes ]]; }

# One interval engine for both: mode "merge" prints the union with our range;
# mode "covers" prints yes|no for "CURRENT alone covers RELAY_MIN..RELAY_MAX".
_ports_awk() {
	local mode="$1" cur="$2" extra=""
	[[ $mode == merge ]] && extra="${RELAY_MIN}-${RELAY_MAX}"
	printf '%s,%s\n' "$cur" "$extra" | awk -v mode="$mode" -v rlo="$RELAY_MIN" -v rhi="$RELAY_MAX" '
		{ n = split($0, tok, /[ ,\t]+/); c = 0
		  for (i = 1; i <= n; i++) {
			if (tok[i] == "") continue
			if (split(tok[i], ab, "-") == 2) { lo = ab[1] + 0; hi = ab[2] + 0 } else { lo = tok[i] + 0; hi = lo }
			c++; L[c] = lo; H[c] = hi
		  }
		  if (c == 0) { print (mode == "covers" ? "no" : ""); exit }
		  for (i = 2; i <= c; i++) { l = L[i]; h = H[i]; j = i - 1
			while (j >= 1 && L[j] > l) { L[j+1] = L[j]; H[j+1] = H[j]; j-- }
			L[j+1] = l; H[j+1] = h }
		  out = ""; cl = L[1]; ch = H[1]; cov = 0
		  for (i = 2; i <= c; i++) {
			if (L[i] <= ch + 1) { if (H[i] > ch) ch = H[i] }
			else { if (cl <= rlo && ch >= rhi) cov = 1
				out = out (out == "" ? "" : ",") (cl == ch ? cl : cl "-" ch); cl = L[i]; ch = H[i] }
		  }
		  if (cl <= rlo && ch >= rhi) cov = 1
		  out = out (out == "" ? "" : ",") (cl == ch ? cl : cl "-" ch)
		  print (mode == "covers" ? (cov ? "yes" : "no") : out) }'
}

# This host's OWN relay address as coturn.conf declares it: `relay-ip=` if set, else
# the private half of `external-ip=PUBLIC/PRIVATE` (NAT'd edge). Empty on a
# public-NIC edge. It is the ONE address coturn may be allowed to relay to.
conf_own_addr() {
	awk -F= '
		$1 == "relay-ip" { r = $2 }
		$1 == "external-ip" { if (split($2, a, "/") == 2) e = a[2] }
		END { print (r != "" ? r : e) }' "$1" 2>/dev/null || true
}

# Is ADDR configured on a local interface right now? The "own relay address" comes
# from the conf (or STATE), which can be stale (re-IP, a carried-over value, the wrong
# NIC picked). Allowing coturn to relay to a NON-local address is not covered by the
# nft guard (it only matches `fib daddr type local`): it would be SSRF to every UDP
# port on that host, reported green. Fails closed: no `ip`, or no match -> not local.
addr_is_local() {
	command -v "$IP_BIN" >/dev/null 2>&1 || return 1
	"$IP_BIN" -o addr show 2>/dev/null | awk -v a="$1" '
		{ for (i = 1; i <= NF; i++) if ($i == "inet" || $i == "inet6") { x = $(i + 1); sub(/\/.*/, "", x); if (x == a) f = 1 } }
		END { exit !f }'
}

# Candidate own addresses the conf declares: relay-ip= and the private half of
# external-ip= (one per line). Every one of them must be a local address.
conf_candidate_addrs() {
	awk -F= '
		$1 == "relay-ip" && $2 != "" { print $2 }
		$1 == "external-ip" { if (split($2, a, "/") == 2 && a[2] != "") print a[2] }' "$1" 2>/dev/null || true
}

# Rewrite the LIVE coturn.conf to the guard's contract:
#   * min-port/max-port = RELAY_MIN/RELAY_MAX (appended if absent — coturn's default
#     is 49152-65535);
#   * allowed-peer-ip: EXACTLY ONE line, this host's own relay address (conf_own_addr),
#     kept in place if already there, else emitted after relay-ip=/external-ip=; every
#     other allowed-peer-ip is dropped (a second local address such as a secondary
#     private IP is not a relay address and is not needed; a non-local one would be
#     SSRF the nft guard, which only covers local addresses, cannot stop). Deleting the own address too
#     was the v0.16.29 regression: denied-peer-ip 10.0.0.0/8 then blocks coturn's own
#     relay address and same-edge relaying fails with 403 Forbidden IP. No own address
#     (public-NIC edge) -> none; an own address that is NOT configured on a local
#     interface is stale: no allowed-peer-ip at all, loudly (fail closed);
#   * mode 0600 (the file carries static-auth-secret).
# Every other line (static-auth-secret x1..2, cert paths, ...) passes through
# untouched; no content is ever printed. Atomic (temp file in the same dir cloned
# with cp -p so ownership survives, then rename) and idempotent (an unchanged result
# is not renamed in). Sets CONF_CHANGED=1 only on a CONTENT change (a mode fix alone
# needs no coturn restart).
migrate_conf() {
	CONF_CHANGED=0
	[[ -f "$COTURN_CONF" ]] || return 0
	local tmp own anchor haveown mode
	own=$(conf_own_addr "$COTURN_CONF")
	if [[ -n "$own" ]] && ! addr_is_local "$own"; then
		warn "${COTURN_CONF}: relay address '${own}' is NOT a local address on this host (stale conf/STATE, re-IP?) - allowed-peer-ip dropped, same-edge relaying stays broken until the conf is corrected (guard status goes red)"
		own=""
	fi
	anchor=external-ip
	if awk -F= '$1 == "relay-ip" { f = 1 } END { exit !f }' "$COTURN_CONF"; then anchor=relay-ip; fi
	haveown=0
	if [[ -n "$own" ]] && awk -v o="allowed-peer-ip=$own" '$0 == o { f = 1 } END { exit !f }' "$COTURN_CONF"; then haveown=1; fi
	tmp=$(mktemp "${COTURN_CONF}.XXXXXX") || { warn "cannot create a temp file next to ${COTURN_CONF}; conf not migrated"; return 1; }
	if ! cp -p "$COTURN_CONF" "$tmp" 2>/dev/null; then rm -f "$tmp"; warn "cannot clone ${COTURN_CONF} attributes; conf not migrated"; return 1; fi
	if ! awk -v lo="$RELAY_MIN" -v hi="$RELAY_MAX" -v own="$own" -v anchor="$anchor" -v haveown="$haveown" '
		/^allowed-peer-ip=/ {
			if (own != "" && !kept && $0 == "allowed-peer-ip=" own) { kept = 1; print }
			next }
		/^min-port=/ { if (!m) print "min-port=" lo; m = 1; next }
		/^max-port=/ { if (!x) print "max-port=" hi; x = 1; next }
		{ print
		  if (own != "" && !haveown && !emitted && index($0, anchor "=") == 1) { print "allowed-peer-ip=" own; emitted = 1 } }
		END { if (!m) print "min-port=" lo; if (!x) print "max-port=" hi
		      if (own != "" && !haveown && !emitted) print "allowed-peer-ip=" own }' "$COTURN_CONF" > "$tmp"; then
		rm -f "$tmp"; warn "awk failed migrating ${COTURN_CONF}; conf not migrated"; return 1
	fi
	mode=$(stat -c %a "$COTURN_CONF" 2>/dev/null || stat -f %Lp "$COTURN_CONF" 2>/dev/null || true)
	if cmp -s "$COTURN_CONF" "$tmp"; then
		rm -f "$tmp"
		if [[ "$mode" != 600 ]]; then chmod 0600 "$COTURN_CONF" && log "set ${COTURN_CONF} mode 0600 (was ${mode:-unknown}; it carries static-auth-secret)"; fi
		return 0
	fi
	chmod 0600 "$tmp"
	mv -f "$tmp" "$COTURN_CONF" || { rm -f "$tmp"; warn "could not replace ${COTURN_CONF}"; return 1; }
	CONF_CHANGED=1
	log "migrated ${COTURN_CONF}: relay range ${RELAY_MIN}-${RELAY_MAX}, allowed-peer-ip limited to this host's own address${own:+ (${own})}, mode 0600 (secrets untouched)"
}

# The bind-mounted coturn.conf is a single-file mount: a rename gives it a new
# inode that a RUNNING container never sees, so a changed conf needs a restart.
# Best effort and only when docker is up with the container present (at boot the
# guard runs before docker and there is nothing to restart).
restart_coturn() {
	command -v "$DOCKER_BIN" >/dev/null 2>&1 || return 0
	local id
	id=$(tmo 15 "$DOCKER_BIN" ps -q --filter 'name=^oxpulse-partner-coturn$' 2>/dev/null || true)
	[[ -n "$id" ]] || return 0
	if tmo 90 "$DOCKER_BIN" restart oxpulse-partner-coturn >/dev/null 2>&1; then
		log "restarted oxpulse-partner-coturn to load the migrated coturn.conf"
	else
		warn "could not restart oxpulse-partner-coturn — it keeps the old config until recreated (docker compose up -d --force-recreate coturn)"
	fi
}

tmo() { # tmo SECONDS CMD... — timeout(1) where it exists (absent on macOS test hosts)
	if command -v timeout >/dev/null 2>&1; then timeout "$@"; else shift; "$@"; fi
}

# --- firewall: relay range must equal the conf, always ----------------------------
# firewalld 1.x COALESCES: add-port of a range already covered by an existing entry is
# a no-op (WARNING ALREADY_ENABLED, nothing added) and remove-port removes only an
# EXACT entry. So "add the narrow range first, then remove 49152-65535" - the order
# this function used to have - adds nothing and then deletes the only entry: the box
# is left with NO relay range, exit 0, and a log line that claims the opposite
# (rvpn, 2026-10-12 09:30:48 UTC). Therefore: remove the legacy entry FIRST, add the
# narrow one, VERIFY it is in force in BOTH scopes, and put the legacy entry back if
# it is not. A relay range that is too wide beats one that is absent.

# fw_ports SCOPE - allowed port entries of zone public, one per line. SCOPE is
# "--permanent" or "" (runtime).
fw_ports() { # shellcheck disable=SC2086
	"$FIREWALL_CMD" $1 --zone=public --list-ports 2>/dev/null | tr ' ' '\n' | awk 'NF'
}

# fw_range_in_force SCOPE LO-HI - yes if some udp entry in SCOPE covers LO-HI.
fw_range_in_force() {
	fw_ports "$1" | awk -v want="$2" '
		BEGIN { split(want, w, "-"); wl = w[1] + 0; wh = w[2] + 0 }
		$0 ~ /\/udp$/ { e = $0; sub(/\/udp$/, "", e)
			if (split(e, r, "-") == 2) { l = r[1] + 0; h = r[2] + 0 } else { l = e + 0; h = l }
			if (l <= wl && h >= wh) f = 1 }
		END { exit !f }'
}

# fw_has_exact SCOPE LO-HI - the entry itself (not just coverage) exists.
fw_has_exact() { fw_ports "$1" | grep -qx -- "$2/udp"; }

# fw_set SCOPE ACTION LO-HI - ACTION is add|remove. Failures are not fatal here
# (an absent/ALREADY_ENABLED entry is normal); the caller verifies the END STATE.
fw_set() { # shellcheck disable=SC2086
	"$FIREWALL_CMD" $1 --zone=public "--$2-port=$3/udp" >/dev/null 2>&1 || true
}

# The relay range coturn.conf declares (what coturn will actually bind). No conf on
# this host -> the guard's own range; a conf WITHOUT the directive -> coturn's own
# default (the legacy range), which is what it will really use.
conf_relay_range() {
	local lo="" hi=""
	[[ -f "$COTURN_CONF" ]] || { printf '%s-%s' "$RELAY_MIN" "$RELAY_MAX"; return 0; }
	lo=$(awk -F= '$1 == "min-port" {v = $2} END {print v}' "$COTURN_CONF" 2>/dev/null || true)
	hi=$(awk -F= '$1 == "max-port" {v = $2} END {print v}' "$COTURN_CONF" 2>/dev/null || true)
	[[ "$lo" =~ ^[0-9]+$ ]] || lo=${LEGACY_RELAY_RANGE%-*}
	[[ "$hi" =~ ^[0-9]+$ ]] || hi=${LEGACY_RELAY_RANGE#*-}
	printf '%s-%s' "$lo" "$hi"
}

# firewalld: make WANT (LO-HI) allowed in both scopes. When WANT is narrower than the
# legacy range, the legacy entry is retired - and only kept retired if WANT is then
# verifiably in force. Returns 1 (loudly) when the end state is not WANT.
fw_converge_firewalld() {
	local want="$1" scope retired=0
	if [[ "$want" != "$LEGACY_RELAY_RANGE" ]]; then
		for scope in --permanent ""; do
			if fw_has_exact "$scope" "$LEGACY_RELAY_RANGE"; then
				fw_set "$scope" remove "$LEGACY_RELAY_RANGE"; retired=1
			fi
		done
	fi
	for scope in --permanent ""; do
		fw_range_in_force "$scope" "$want" || fw_set "$scope" add "$want"
	done
	if fw_range_in_force --permanent "$want" && fw_range_in_force "" "$want"; then
		[[ "$retired" = 1 ]] && log "firewalld: legacy ${LEGACY_RELAY_RANGE}/udp retired, ${want}/udp in force (permanent + runtime)"
		return 0
	fi
	if [[ "$retired" = 1 ]]; then
		for scope in --permanent ""; do fw_set "$scope" add "$LEGACY_RELAY_RANGE"; done
		warn "firewalld: could not put ${want}/udp in force - legacy ${LEGACY_RELAY_RANGE}/udp RESTORED (too wide beats closed); fix the zone and re-run 'coturn-guard apply'"
	else
		warn "firewalld: ${want}/udp is NOT allowed in zone public (permanent or runtime) - inbound relay media is blocked"
	fi
	return 1
}

# ufw does not coalesce (rules are textual), so the narrow rule is added first and
# the legacy one is deleted only once the narrow one is listed.
fw_converge_ufw() {
	local want="$1" ufw_want="${1/-/:}" ufw_legacy="${LEGACY_RELAY_RANGE/-/:}" st
	st=$("$UFW_BIN" status 2>/dev/null || true)
	if [[ "$st" != *"${ufw_want}/udp"* ]]; then
		"$UFW_BIN" allow "${ufw_want}/udp" >/dev/null 2>&1 || true
		st=$("$UFW_BIN" status 2>/dev/null || true)
	fi
	[[ "$st" == *"${ufw_want}/udp"* ]] \
		|| { warn "ufw: ${ufw_want}/udp is NOT allowed - inbound relay media is blocked"; return 1; }
	if [[ "$want" != "$LEGACY_RELAY_RANGE" && "$st" == *"${ufw_legacy}/udp"* ]]; then
		"$UFW_BIN" --force delete allow "${ufw_legacy}/udp" >/dev/null 2>&1 \
			&& log "ufw: legacy ${ufw_legacy}/udp removed, ${ufw_want}/udp allowed"
	fi
	return 0
}

# firewall-sync: the firewall's relay range = the range coturn.conf declares.
# Idempotent; silent on a node with no active firewall. Run by `apply` (after the
# conf migration) and by upgrade.sh after ANY rollback, because a rollback leaves the
# migrated conf in place and restores an older guard that may not do this itself.
cmd_firewall_sync() {
	local want rc=0; want=$(conf_relay_range)
	if command -v "$FIREWALL_CMD" >/dev/null 2>&1 && "$FIREWALL_CMD" --state >/dev/null 2>&1; then
		fw_converge_firewalld "$want" || rc=1
	fi
	if command -v "$UFW_BIN" >/dev/null 2>&1; then
		fw_converge_ufw "$want" || rc=1
	fi
	return "$rc"
}

cmd_apply() {
	local sfu_port; sfu_port=$(resolve_sfu_port)
	ensure_nft
	# conf first: a guard that already drops relays outside the range must never
	# meet a coturn still allocating in the old 49152-65535.
	migrate_conf || true
	local rules; rules=$(render_ruleset "$sfu_port")
	# Validate first so a bad ruleset fails the unit without touching a loaded table.
	printf '%s\n' "$rules" | "$NFT" -c -f - || die "nft rejected the generated ruleset; nothing changed"
	printf '%s\n' "$rules" | "$NFT" -f - || die "nft failed to load the ruleset"

	install -d -m 0755 "$SYSCTL_DIR"
	local tmp; tmp=$(mktemp "${SYSCTL_FILE}.XXXXXX")
	render_sysctl > "$tmp"
	chmod 0644 "$tmp"
	mv -f "$tmp" "$SYSCTL_FILE"
	# -w per key (not -p): the conntrack key exists only once nf_conntrack is
	# loaded (the nft ct rule above loads it), and one absent key must not skip
	# the reservation.
	local cur merged
	cur=$(cat "$RESERVED_PORTS_FILE" 2>/dev/null || true)
	merged=$(merge_ports "$cur")
	"$SYSCTL_BIN" -q -w "net.ipv4.ip_local_reserved_ports=${merged}" \
		|| die "could not reserve ${RELAY_MIN}-${RELAY_MAX} from the ephemeral pool"
	"$SYSCTL_BIN" -q -w "net.netfilter.nf_conntrack_udp_timeout_stream=${CONNTRACK_UDP_STREAM_TIMEOUT}" \
		|| warn "could not set nf_conntrack_udp_timeout_stream (nf_conntrack not loaded?); sysctl.d applies it at next boot"
	warn_stray_sockets
	cmd_firewall_sync || warn "relay firewall range not in force (see above); guard status will report it"
	[[ "$CONF_CHANGED" = 1 ]] && restart_coturn
	log "applied: table inet ${TABLE} (uid ${COTURN_UID}, sfu udp ${sfu_port}, relay ${RELAY_MIN}-${RELAY_MAX})"
}

cmd_remove() {
	"$NFT" delete table inet "${TABLE}" 2>/dev/null || true
	log "removed table inet ${TABLE} (sysctl.d file left in place)"
}

# Exit 0 iff the guard is in force: table loaded with the drop rule for the
# fixed uid, and the relay range reserved. Silent on success (healthcheck probe).
cmd_status() {
	local chain reserved pid uid_line f
	command -v "$NFT" >/dev/null 2>&1 || { echo "nft missing" >&2; return 1; }
	chain=$("$NFT" list chain inet "${TABLE}" output 2>/dev/null) \
		|| { echo "table inet ${TABLE} not loaded" >&2; return 1; }
	grep -q "meta skuid ${COTURN_UID} .*drop" <<<"$chain" \
		|| { echo "table inet ${TABLE} has no drop rule for uid ${COTURN_UID}" >&2; return 1; }
	reserved=$(cat "$RESERVED_PORTS_FILE" 2>/dev/null || true)
	reserved_covers_relay "$reserved" \
		|| { echo "relay range ${RELAY_MIN}-${RELAY_MAX} not reserved (got '${reserved}')" >&2; return 1; }

	# (a) the RUNNING turnserver must be the uid the table matches: a guard keyed on
	# 58731 protects nothing while coturn still runs as root (old image) or as any
	# other uid. Read /proc directly (host pid namespace sees container processes);
	# no docker exec. No turnserver running = nothing to be wrong about.
	for pid in $("$PGREP_BIN" -x turnserver 2>/dev/null || true); do
		uid_line=$(awk '/^Uid:/ {print $2 " " $3}' "${PROC_DIR}/${pid}/status" 2>/dev/null || true)
		[[ "$uid_line" == "${COTURN_UID} ${COTURN_UID}" ]] \
			|| { echo "turnserver pid ${pid} runs as uid '${uid_line:-unknown}', the table matches ${COTURN_UID}" >&2; return 1; }
	done

	# (b) the deployed conf's relay range must be the one the guard allows and the
	# kernel reserves. Absent directive = coturn's default 49152-65535 = a mismatch.
	if [[ -f "$COTURN_CONF" ]]; then
		for f in min max; do
			local want have
			[[ $f == min ]] && want=$RELAY_MIN || want=$RELAY_MAX
			have=$(awk -F= -v k="${f}-port" '$1 == k {v = $2} END {print v}' "$COTURN_CONF" 2>/dev/null || true)
			[[ "$have" == "$want" ]] \
				|| { echo "${COTURN_CONF}: ${f}-port='${have:-<default>}', the guard range needs ${want}" >&2; return 1; }
		done
	fi

	# (b2) allowed-peer-ip must be exactly this host's own relay address when it has one
	# (missing -> coturn's 10/8 deny blocks same-edge relaying, 403 Forbidden IP) and
	# nothing else (any other address is an unneeded allowance; a non-local one is SSRF
	# the nft guard does not cover), and that address must be LOCAL (a stale one is SSRF).
	if [[ -f "$COTURN_CONF" ]]; then
		local own allowed cand
		for cand in $(conf_candidate_addrs "$COTURN_CONF"); do
			addr_is_local "$cand" \
				|| { echo "${COTURN_CONF}: relay address '${cand}' is not a local address on this host (stale conf/STATE?) - allowing it would be SSRF to that host" >&2; return 1; }
		done
		own=$(conf_own_addr "$COTURN_CONF")
		allowed=$(awk '/^allowed-peer-ip=/' "$COTURN_CONF" 2>/dev/null || true)
		if [[ -n "$own" ]]; then
			[[ "$allowed" == "allowed-peer-ip=${own}" ]] \
				|| { echo "${COTURN_CONF}: allowed-peer-ip must be exactly 'allowed-peer-ip=${own}' (this host's relay address); same-edge relaying is broken otherwise" >&2; return 1; }
		else
			[[ -z "$allowed" ]] || { echo "${COTURN_CONF}: allowed-peer-ip present but this edge has no private relay address" >&2; return 1; }
		fi
	fi

	# (c) a foreign socket inside the relay range is reachable through the allow-range.
	local stray; stray=$(stray_sockets)
	[[ -z "$stray" ]] || { echo "non-turnserver socket(s) inside ${RELAY_MIN}-${RELAY_MAX}" >&2; return 1; }
}

case "${1:-apply}" in
	apply)  cmd_apply ;;
	remove) cmd_remove ;;
	status) cmd_status ;;
	firewall-sync) cmd_firewall_sync ;;
	migrate-conf) migrate_conf ;;                     # test seam: conf migration only
	merge-ports) merge_ports "${2:-}" ;;                # test seam: pure
	render) render_ruleset "$(resolve_sfu_port)" ;;   # test / review seam: no side effects
	*) echo "usage: ${0##*/} [apply|remove|status|render|firewall-sync|migrate-conf|merge-ports LIST]" >&2; exit 2 ;;
esac
