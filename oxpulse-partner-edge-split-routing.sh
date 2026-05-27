#!/usr/bin/env bash
# oxpulse-partner-edge-split-routing.sh — selective split-routing apply.
#
# Routes foreign TCP/UDP from user.slice processes (box mgmt: ssh, apt,
# windsurf) through the AWG mesh to krolik, leaving docker containers and
# .ru traffic on the direct WAN path.
#
# Idempotent. Re-asserts federation-volatile settings (AllowedIPs, FwMark)
# LIVE every run — the awg-params-agent overwrites the conf; live re-assert
# is the load-bearing mechanism.
#
# Spec: ~/deploy/server-config/plans/oxpulse-partner-edge/
#       2026-05-27-split-routing-settings-canon.md §10
#
# Parameterized for fleet portability (no per-node manual steps):
#   --vpn-if       VPN interface  (default: awg0)
#   --conf         awg conf path  (default: /etc/amnezia/amneziawg/awg0.conf)
#   --ru-file      RU subnet list (default: /etc/oxpulse-partner-edge/ru-subnets.txt)
#   --state-dir    persistent state (default: /var/lib/oxpulse-partner-edge)
#   --sysctl-persist-dir          (default: /etc/sysctl.d)
#
# All can also be set via VPN_IF / CONF / RU_FILE / STATE_DIR / SYSCTL_PERSIST_DIR env vars.
set -euo pipefail

# ── argument parsing ──────────────────────────────────────────────────────────
VPN_IF="${VPN_IF:-awg0}"
CONF="${CONF:-}"
RU_FILE="${RU_FILE:-}"
STATE_DIR="${STATE_DIR:-/var/lib/oxpulse-partner-edge}"
SYSCTL_PERSIST_DIR="${SYSCTL_PERSIST_DIR:-/etc/sysctl.d}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vpn-if)             VPN_IF="$2";            shift 2 ;;
        --conf)               CONF="$2";               shift 2 ;;
        --ru-file)            RU_FILE="$2";            shift 2 ;;
        --state-dir)          STATE_DIR="$2";          shift 2 ;;
        --sysctl-persist-dir) SYSCTL_PERSIST_DIR="$2"; shift 2 ;;
        *) echo "ERR: unknown argument: $1" >&2; exit 1 ;;
    esac
done

# Set defaults that depend on VPN_IF.
CONF="${CONF:-/etc/amnezia/amneziawg/${VPN_IF}.conf}"
RU_FILE="${RU_FILE:-/etc/oxpulse-partner-edge/ru-subnets.txt}"

PKT_MARK="0x1"          # packet mark: "foreign, route via tunnel"
WG_FWMARK="0xCA6D"      # 51821 — wg's own outer UDP mark (loop immunity)
TBL_BASE=13573          # numeric routing table id; never a name (§6)
MESH_SUBNET="10.9.0.0/24"  # mesh-internal; not SNAT'd (§4)

# ── preflight checks ──────────────────────────────────────────────────────────
[[ -s "$RU_FILE" ]] || { echo "ERR: RU subnets file missing or empty: $RU_FILE" >&2; exit 1; }
[[ -f "$CONF"    ]] || { echo "ERR: AWG conf not found: $CONF" >&2; exit 1; }

# ── 0. detect WAN iface + gateway ─────────────────────────────────────────────
# Handles ens3/enp1s0/eth0 transparently (NAT or public).
WAN_IF=$(ip -4 route show default | awk '/default/{print $5; exit}')
WAN_GW=$(ip -4 route show default | awk '/default/{print $3; exit}')
[[ -n "$WAN_IF" && -n "$WAN_GW" ]] || { echo "ERR: no default route — cannot auto-detect WAN" >&2; exit 1; }


# ── save original rp_filter + ip_forward values for disable to restore ────────
# CRITICAL: STATE_DIR is /var/lib/oxpulse-partner-edge (persistent across reboots).
# Snapshot is guarded by [[ ! -f STATE_FILE ]] — first apply only. This ensures
# the "pristine" values (before sysctl.d takes effect at boot) are recorded once
# and survive reboots. A second apply after reboot will find the STATE_FILE and
# skip re-snapshotting — so disable always restores the true pre-apply original,
# NOT the post-sysctl.d value that would be in the kernel on subsequent applies.
mkdir -p "$STATE_DIR"
STATE_FILE="$STATE_DIR/oxpulse-split-routing.state"
if [[ ! -f "$STATE_FILE" ]]; then
    _rp_all=$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null || echo 1)
    _rp_wan=$(sysctl -n "net.ipv4.conf.${WAN_IF}.rp_filter" 2>/dev/null || echo 1)
    _rp_vpn=$(sysctl -n "net.ipv4.conf.${VPN_IF}.rp_filter" 2>/dev/null || echo 1)
    _ip_fwd=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)
    cat >"$STATE_FILE" <<STATE
SAVED_RP_FILTER_ALL=${_rp_all}
SAVED_RP_FILTER_WAN=${_rp_wan}
SAVED_RP_FILTER_VPN=${_rp_vpn}
SAVED_IP_FORWARD=${_ip_fwd}
SAVED_WAN_IF=${WAN_IF}
STATE
fi

# ── 1. routing table: reuse our own if stable, else first free numeric ─────────
# Stability: re-apply (boot, agent change) must NOT bump to a new id and orphan
# the previous table's routes. Check the state file first, then by table content.
TBL_FILE="$STATE_DIR/oxpulse-split-routing.tbl"
if [[ -f "$TBL_FILE" ]]; then
    TBL=$(cat "$TBL_FILE")
elif ip route show table "$TBL_BASE" 2>/dev/null | grep -q "default dev ${VPN_IF}"; then
    TBL="$TBL_BASE"
else
    TBL="$TBL_BASE"
    while ip route show table "$TBL" 2>/dev/null | grep -q .; do
        TBL=$((TBL + 1))
    done
fi
mkdir -p "$STATE_DIR"
echo "$TBL" >"$TBL_FILE"

# ── 2. sysctl: ip_forward FIRST (changing it resets conf params), then rp_filter ─
# Эталон §1: ip_forward MUST precede rp_filter; the kernel resets per-iface conf
# on ip_forward change. Loose RPF (2) is required — strict RPF (1) drops the
# reply leg on asymmetric awg0 routing (see §1 for the RFC 3704 mechanism).
sysctl -qw net.ipv4.ip_forward=1
sysctl -qw net.ipv4.conf.all.rp_filter=2
sysctl -qw "net.ipv4.conf.${WAN_IF}.rp_filter=2"
sysctl -qw "net.ipv4.conf.${VPN_IF}.rp_filter=2"
sysctl -qw net.ipv4.conf.all.src_valid_mark=1

# Persist across reboots (rendered with the detected iface — fleet-portable).
mkdir -p "$SYSCTL_PERSIST_DIR"
cat >"${SYSCTL_PERSIST_DIR}/99-oxpulse-split-routing.conf" <<SYSCTL
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.${WAN_IF}.rp_filter = 2
net.ipv4.conf.${VPN_IF}.rp_filter = 2
net.ipv4.conf.all.src_valid_mark = 1
SYSCTL

# ── 3. mangle table: dedicated, never touches docker's ip nat / inet firewalld ──
# OUTPUT route-hook so locally-generated marked packets trigger a route re-lookup.
# cgroupv2 level 1 "user.slice" = box mgmt sessions; docker runs in system.slice.
# No prerouting/forward hook — we do NOT forward client traffic (§3).
nft delete table ip mangle 2>/dev/null || true
nft -f - <<NFT
table ip mangle {
    set ru_nets { type ipv4_addr; flags interval; auto-merge; }
    chain output {
        type route hook output priority mangle; policy accept;
        ct state established,related meta mark set ct mark
        ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16, 127.0.0.0/8 } accept
        socket cgroupv2 level 1 "user.slice" ct state new ip daddr != @ru_nets meta mark set ${PKT_MARK}
        ct state new meta mark != 0x0 ct mark set meta mark
    }
    chain postrouting {
        type filter hook postrouting priority mangle; policy accept;
        oifname "${VPN_IF}" tcp flags syn tcp option maxseg size set rt mtu
    }
}
NFT

# Load ru_nets into the mangle set atomically.
# Filter comments (#) and blank lines before joining — bare paste -sd, would
# produce malformed nft set elements (e.g. "# comment,1.2.3.0/24") which abort
# the nft -f - call under set -e AFTER mangle/sysctl/nat are already applied.
_ru_elements=$(grep -vE '^[[:space:]]*(#|$)' "$RU_FILE" | paste -sd, - || true)
if [[ -n "$_ru_elements" ]]; then
    printf 'add element ip mangle ru_nets { %s }\n' "$_ru_elements" | nft -f -
fi

# ── 4. masquerade scoped to FOREIGN dst (§4) ──────────────────────────────────
# mesh-internal ${MESH_SUBNET} is NOT SNAT'd — protects container→krolik SFU relay.
# Dedicated table ip split_nat (srcnat priority) — never touches docker's ip nat.
nft delete table ip split_nat 2>/dev/null || true
nft -f - <<NFT2
table ip split_nat {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        oifname "${VPN_IF}" ip daddr != ${MESH_SUBNET} masquerade
    }
}
NFT2

# ── 5. wg FwMark on the VPN interface (loop immunity, endpoint-agnostic) ───────
# Эталон §2: set fwmark on awg0 so the tunnel's outer UDP is identity-tagged.
# NOTE: we do NOT add wg-quick's `ip rule not fwmark ... lookup TBL` here.
# That is the FULL-TUNNEL idiom (every unmarked packet → tunnel). We are the
# opposite: only 0x1-marked packets use table TBL. The wg fwmark provides
# loop immunity for the tunnel's own outer UDP — it needs no ip rule because
# unmarked traffic never reaches TBL in the first place (§6 CRITICAL).
awg set "$VPN_IF" fwmark "$WG_FWMARK"

# ── 6. policy routing: ONLY marked foreign (0x1) → table TBL → VPN_IF ─────────
# Endpoint re-derived from conf each run (not hardcoded) — robust to B0 hub moves.
# NOTE: do NOT add `ip rule ... not fwmark ... lookup TBL` — design inversion (§6).
#
# IPv4-only note: Endpoint parse splits on first ':' — does not handle IPv6
# '[::1]:443', but the mesh is v4-only (эталон §11.4).
#
# NOTE (B0 multi-hub future work): currently widens AllowedIPs on the FIRST peer
# only (head -1). When B0 multi-hub ships multiple awg peers, ALL foreign-routing
# peers will need widening here. At that point remove head -1 and loop over peers.
ENDPOINT_HOST=$(awk -F'= *' '/^[[:space:]]*Endpoint/{split($2,a,":"); print a[1]; exit}' "$CONF")
ENDPOINT_IP=""
if [[ -n "$ENDPOINT_HOST" ]]; then
    ENDPOINT_IP=$(getent ahostsv4 "$ENDPOINT_HOST" 2>/dev/null | awk '{print $1; exit}' || true)
fi

ip route replace default dev "$VPN_IF" table "$TBL"
[[ -n "$ENDPOINT_IP" ]] && \
    ip route replace "$ENDPOINT_IP"/32 via "$WAN_GW" dev "$WAN_IF" onlink table "$TBL"

# Del-then-add ensures idempotency (second run = same state, no duplicate rules).
ip rule del fwmark "$PKT_MARK" lookup "$TBL" 2>/dev/null || true
ip rule add fwmark "$PKT_MARK" lookup "$TBL" priority 1000

ip rule del table main suppress_prefixlength 0 2>/dev/null || true
ip rule add table main suppress_prefixlength 0 priority 999

# ── 7. re-assert federation-volatile AllowedIPs LIVE ──────────────────────────
# The awg-params-agent rewrites awg0.conf → may reset AllowedIPs to /32.
# The LIVE `awg set` is the load-bearing re-assert; the conf persist is advisory.
PEER=$(awg show "$VPN_IF" peers 2>/dev/null | head -1)
[[ -n "$PEER" ]] && awg set "$VPN_IF" peer "$PEER" allowed-ips 0.0.0.0/0

echo "APPLIED partner-edge split-routing: WAN=${WAN_IF} gw=${WAN_GW} table=${TBL} endpoint=${ENDPOINT_IP:-<unresolved>}"
