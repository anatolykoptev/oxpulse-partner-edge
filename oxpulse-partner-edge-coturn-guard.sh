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
# (allowed-peer-ip=PRIVATE_IP) on NAT'd edges.
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
# healthcheck.sh check_15_coturn_self_relay_guard calls `status`.
#
# `apply` is idempotent and atomic (one nft transaction, delete+create preamble).
# It also installs/refreshes the sysctl.d file. It never touches coturn.
#
# Env (tests / operator overrides): SFU_UDP_PORT, ETC_DIR, SYSCTL_DIR, NFT,
# SYSCTL_BIN, SS_BIN, COMPOSE_FILE, NFT_INSTALL=0 (do not try to install nftables).
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

ETC_DIR="${ETC_DIR:-/etc}"
SYSCTL_DIR="${SYSCTL_DIR:-${ETC_DIR}/sysctl.d}"
NFT="${NFT:-nft}"
SYSCTL_BIN="${SYSCTL_BIN:-sysctl}"
SS_BIN="${SS_BIN:-ss}"
COMPOSE_FILE="${COMPOSE_FILE:-${ETC_DIR}/oxpulse-partner-edge/docker-compose.yml}"
SYSCTL_FILE="${SYSCTL_DIR}/99-oxpulse-coturn-relay-ports.conf"

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
warn_stray_sockets() {
	command -v "$SS_BIN" >/dev/null 2>&1 || return 0
	local stray
	stray=$(
		{ "$SS_BIN" -H -uanp; "$SS_BIN" -H -tanp; } 2>/dev/null \
			| awk -v lo="$RELAY_MIN" -v hi="$RELAY_MAX" \
				'{n=split($4,a,":"); p=a[n]+0; if (p>=lo && p<=hi && $0 !~ /"turnserver"/) print}'
	)
	if [[ -n "$stray" ]]; then
		warn "sockets in ${RELAY_MIN}-${RELAY_MAX} not owned by turnserver (restart their process to move it out of the relay range):"
		printf '%s\n' "$stray" >&2
	fi
}

cmd_apply() {
	local sfu_port; sfu_port=$(resolve_sfu_port)
	ensure_nft
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
	"$SYSCTL_BIN" -q -w "net.ipv4.ip_local_reserved_ports=${RELAY_MIN}-${RELAY_MAX}" \
		|| die "could not reserve ${RELAY_MIN}-${RELAY_MAX} from the ephemeral pool"
	"$SYSCTL_BIN" -q -w "net.netfilter.nf_conntrack_udp_timeout_stream=${CONNTRACK_UDP_STREAM_TIMEOUT}" \
		|| warn "could not set nf_conntrack_udp_timeout_stream (nf_conntrack not loaded?); sysctl.d applies it at next boot"
	warn_stray_sockets
	log "applied: table inet ${TABLE} (uid ${COTURN_UID}, sfu udp ${sfu_port}, relay ${RELAY_MIN}-${RELAY_MAX})"
}

cmd_remove() {
	"$NFT" delete table inet "${TABLE}" 2>/dev/null || true
	log "removed table inet ${TABLE} (sysctl.d file left in place)"
}

# Exit 0 iff the guard is in force: table loaded with the drop rule for the
# fixed uid, and the relay range reserved. Silent on success (healthcheck probe).
cmd_status() {
	local chain reserved
	command -v "$NFT" >/dev/null 2>&1 || { echo "nft missing" >&2; return 1; }
	chain=$("$NFT" list chain inet "${TABLE}" output 2>/dev/null) \
		|| { echo "table inet ${TABLE} not loaded" >&2; return 1; }
	grep -q "meta skuid ${COTURN_UID} .*drop" <<<"$chain" \
		|| { echo "table inet ${TABLE} has no drop rule for uid ${COTURN_UID}" >&2; return 1; }
	reserved=$(cat /proc/sys/net/ipv4/ip_local_reserved_ports 2>/dev/null || true)
	[[ "$reserved" == *"${RELAY_MIN}-${RELAY_MAX}"* ]] \
		|| { echo "relay range ${RELAY_MIN}-${RELAY_MAX} not reserved (got '${reserved}')" >&2; return 1; }
}

case "${1:-apply}" in
	apply)  cmd_apply ;;
	remove) cmd_remove ;;
	status) cmd_status ;;
	render) render_ruleset "$(resolve_sfu_port)" ;;   # test / review seam: no side effects
	*) echo "usage: ${0##*/} [apply|remove|status|render]" >&2; exit 2 ;;
esac
