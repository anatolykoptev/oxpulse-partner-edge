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
# healthcheck.sh check_22_coturn_self_relay_guard calls `status`.
#
# `apply` is idempotent; the nft load is one atomic transaction (delete+create
# preamble). Besides the table it:
#   * migrates the LIVE coturn.conf (min-port/max-port -> the guard range, drops
#     allowed-peer-ip), BEFORE the table loads, so a plain upgrade — which never
#     reaches reconcile_all — leaves no edge running the old 49152-65535 range or
#     the old allowed-peer-ip under a guard that would drop its relays; coturn is
#     restarted only if the file actually changed;
#   * reserves the relay range (merged into whatever is already reserved) and
#     writes the sysctl.d file (our range only);
#   * removes the legacy 49152-65535/udp firewall allowance (firewalld / ufw), after
#     the narrower range is in place.
#
# `status` is the single definition of "in force" (healthcheck + selfheal): the
# rule set, the reservation, the RUNNING turnserver's uid, the deployed conf's
# range, and no foreign UDP socket inside the relay range.
#
# Env (tests / operator overrides): SFU_UDP_PORT, ETC_DIR, SYSCTL_DIR, NFT,
# SYSCTL_BIN, SS_BIN, COMPOSE_FILE, COTURN_CONF, PROC_DIR, RESERVED_PORTS_FILE, PGREP_BIN, DOCKER_BIN,
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

# Rewrite the LIVE coturn.conf to the guard's contract: min-port/max-port =
# RELAY_MIN/RELAY_MAX (appended if absent — coturn's default is 49152-65535), every
# allowed-peer-ip line dropped; every other line (static-auth-secret x1..2, cert
# paths, ...) passes through untouched. Never prints file content. Atomic (temp file
# in the same dir cloned with cp -p so owner and mode 0600 survive, then rename) and
# idempotent (an unchanged result is not renamed in). Sets CONF_CHANGED=1 on change.
migrate_conf() {
	CONF_CHANGED=0
	[[ -f "$COTURN_CONF" ]] || return 0
	local tmp
	tmp=$(mktemp "${COTURN_CONF}.XXXXXX") || { warn "cannot create a temp file next to ${COTURN_CONF}; conf not migrated"; return 1; }
	if ! cp -p "$COTURN_CONF" "$tmp" 2>/dev/null; then rm -f "$tmp"; warn "cannot clone ${COTURN_CONF} attributes; conf not migrated"; return 1; fi
	if ! awk -v lo="$RELAY_MIN" -v hi="$RELAY_MAX" '
		/^allowed-peer-ip=/ { next }
		/^min-port=/ { if (!m) print "min-port=" lo; m = 1; next }
		/^max-port=/ { if (!x) print "max-port=" hi; x = 1; next }
		{ print }
		END { if (!m) print "min-port=" lo; if (!x) print "max-port=" hi }' "$COTURN_CONF" > "$tmp"; then
		rm -f "$tmp"; warn "awk failed migrating ${COTURN_CONF}; conf not migrated"; return 1
	fi
	if cmp -s "$COTURN_CONF" "$tmp"; then rm -f "$tmp"; return 0; fi
	mv -f "$tmp" "$COTURN_CONF" || { rm -f "$tmp"; warn "could not replace ${COTURN_CONF}"; return 1; }
	CONF_CHANGED=1
	log "migrated ${COTURN_CONF}: relay range ${RELAY_MIN}-${RELAY_MAX}, allowed-peer-ip removed (secrets untouched)"
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

# Retire the legacy 49152-65535/udp allowance. The narrower range is added FIRST so
# there is no moment where live relay traffic has no inbound allow. Silent when
# the tool is absent/inactive or the legacy rule is not there (every clean node).
legacy_firewall_cleanup() {
	local zone=public new="${RELAY_MIN}-${RELAY_MAX}"
	if command -v "$FIREWALL_CMD" >/dev/null 2>&1 && "$FIREWALL_CMD" --state >/dev/null 2>&1; then
		if "$FIREWALL_CMD" --permanent --zone=$zone --query-port="${LEGACY_RELAY_RANGE}/udp" >/dev/null 2>&1; then
			"$FIREWALL_CMD" --permanent --zone=$zone --add-port="${new}/udp" >/dev/null 2>&1 || true
			"$FIREWALL_CMD" --zone=$zone --add-port="${new}/udp" >/dev/null 2>&1 || true
			"$FIREWALL_CMD" --permanent --zone=$zone --remove-port="${LEGACY_RELAY_RANGE}/udp" >/dev/null 2>&1 \
				&& log "firewalld: legacy ${LEGACY_RELAY_RANGE}/udp removed (permanent), ${new}/udp allowed"
			"$FIREWALL_CMD" --zone=$zone --remove-port="${LEGACY_RELAY_RANGE}/udp" >/dev/null 2>&1 || true
		fi
	fi
	if command -v "$UFW_BIN" >/dev/null 2>&1; then
		local st; st=$("$UFW_BIN" status 2>/dev/null || true)
		if [[ "$st" == *"${LEGACY_RELAY_RANGE/-/:}/udp"* ]]; then
			"$UFW_BIN" allow "${RELAY_MIN}:${RELAY_MAX}/udp" >/dev/null 2>&1 || true
			"$UFW_BIN" --force delete allow "${LEGACY_RELAY_RANGE/-/:}/udp" >/dev/null 2>&1 \
				&& log "ufw: legacy ${LEGACY_RELAY_RANGE/-/:}/udp removed, ${RELAY_MIN}:${RELAY_MAX}/udp allowed"
		fi
	fi
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
	legacy_firewall_cleanup
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

	# (c) a foreign socket inside the relay range is reachable through the allow-range.
	local stray; stray=$(stray_sockets)
	[[ -z "$stray" ]] || { echo "non-turnserver socket(s) inside ${RELAY_MIN}-${RELAY_MAX}" >&2; return 1; }
}

case "${1:-apply}" in
	apply)  cmd_apply ;;
	remove) cmd_remove ;;
	status) cmd_status ;;
	migrate-conf) migrate_conf ;;                     # test seam: conf migration only
	merge-ports) merge_ports "${2:-}" ;;                # test seam: pure
	render) render_ruleset "$(resolve_sfu_port)" ;;   # test / review seam: no side effects
	*) echo "usage: ${0##*/} [apply|remove|status|render|migrate-conf|merge-ports LIST]" >&2; exit 2 ;;
esac
