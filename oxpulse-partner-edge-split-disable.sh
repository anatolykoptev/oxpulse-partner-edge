#!/usr/bin/env bash
# oxpulse-partner-edge-split-disable.sh — selective split-routing revert.
#
# Removes all state applied by oxpulse-partner-edge-split-routing.sh:
#   - nft tables ip mangle and ip split_nat
#   - ip rules (fwmark 0x1, suppress_prefixlength 0)
#   - ip routes from the split-routing table
#   - sysctl values (restores saved originals from state file)
#   - sysctl persist file
#   - runtime state file
#
# Safe to run multiple times (idempotent). Does not touch docker's ip nat
# or inet firewalld. Does NOT restore AllowedIPs (the awg-params-agent owns
# the conf; re-installing or restarting the agent will normalise it).
#
# Spec: ~/deploy/krolik-server/plans/oxpulse-partner-edge/
#       2026-05-27-split-routing-settings-canon.md §10
#
# Options (same as apply):
#   --vpn-if       VPN interface  (default: awg0)
#   --state-dir    persistent state (default: /var/lib/oxpulse-partner-edge)
#   --sysctl-persist-dir          (default: /etc/sysctl.d)
set -euo pipefail

# ── argument parsing ──────────────────────────────────────────────────────────
VPN_IF="${VPN_IF:-awg0}"
STATE_DIR="${STATE_DIR:-/var/lib/oxpulse-partner-edge}"
SYSCTL_PERSIST_DIR="${SYSCTL_PERSIST_DIR:-/etc/sysctl.d}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vpn-if)             VPN_IF="$2";            shift 2 ;;
        --state-dir)          STATE_DIR="$2";          shift 2 ;;
        --sysctl-persist-dir) SYSCTL_PERSIST_DIR="$2"; shift 2 ;;
        *) echo "ERR: unknown argument: $1" >&2; exit 1 ;;
    esac
done

PKT_MARK="0x1"
TBL_BASE=13573          # numeric routing table id; matches apply script default

# ── 1. remove nft tables (idempotent — || true on missing) ────────────────────
nft delete table ip mangle    2>/dev/null || true
nft delete table ip split_nat 2>/dev/null || true

# ── 2. remove ip rules ────────────────────────────────────────────────────────
# Drain all duplicate fwmark rules (idempotent apply may have added >1 on broken state).
# Safety cap: at most 10 iterations to avoid infinite loop if del always succeeds.
_drain=0
while [[ $_drain -lt 10 ]] && ip rule del fwmark "$PKT_MARK" 2>/dev/null; do
    _drain=$((_drain + 1))
done
ip rule del table main suppress_prefixlength 0 2>/dev/null || true

# ── 3. flush the split-routing routing table ───────────────────────────────────
# CRITICAL: read the RECORDED table id from TBL_FILE, not a hardcoded fallback.
# A hardcoded fallback leaks any auto-bumped id (13574+) and leaves stale routes.
TBL_FILE="$STATE_DIR/oxpulse-split-routing.tbl"
if [[ -f "$TBL_FILE" ]]; then
    TBL=$(cat "$TBL_FILE")
    ip route flush table "$TBL" 2>/dev/null || true
    rm -f "$TBL_FILE"
else
    # Best-effort flush of the base id — TBL_FILE absent means apply never ran
    # or completed (state inconsistency). Flush the base to clean up what we can.
    ip route flush table "$TBL_BASE" 2>/dev/null || true
fi

# ── 4. restore sysctl values ──────────────────────────────────────────────────
# The STATE_FILE in the persistent STATE_DIR holds the true pristine values
# (before our sysctl.d file took effect on the first apply). Restore from there.
# If STATE_FILE is absent (disable without prior apply), fall back to safe defaults.
STATE_FILE="$STATE_DIR/oxpulse-split-routing.state"
if [[ -f "$STATE_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$STATE_FILE"
fi
_restore_rp="${SAVED_RP_FILTER_ALL:-1}"
_restore_wan_rp="${SAVED_RP_FILTER_WAN:-1}"
_restore_vpn_rp="${SAVED_RP_FILTER_VPN:-1}"
_restore_ip_fwd="${SAVED_IP_FORWARD:-0}"

sysctl -qw "net.ipv4.conf.all.rp_filter=${_restore_rp}" || true
# We need the WAN iface name to restore per-iface value.
# Try state file, else auto-detect, else skip (not fatal).
WAN_IF="${SAVED_WAN_IF:-}"
if [[ -z "$WAN_IF" ]]; then
    WAN_IF=$(ip -4 route show default 2>/dev/null | awk '/default/{print $5; exit}') || true
fi
[[ -z "$WAN_IF" ]] || sysctl -qw "net.ipv4.conf.${WAN_IF}.rp_filter=${_restore_wan_rp}" || true
sysctl -qw "net.ipv4.conf.${VPN_IF}.rp_filter=${_restore_vpn_rp}" || true
sysctl -qw "net.ipv4.ip_forward=${_restore_ip_fwd}" || true

# Remove the persist file.
rm -f "${SYSCTL_PERSIST_DIR}/99-oxpulse-split-routing.conf"
# Remove state file (leave STATE_DIR intact — future state may share it).
rm -f "$STATE_FILE"

echo "DISABLED partner-edge split-routing: nft tables removed, ip rules/routes cleared, sysctl restored"
