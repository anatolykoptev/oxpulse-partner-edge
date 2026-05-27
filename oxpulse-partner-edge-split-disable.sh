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
#   --state-dir    runtime state  (default: /run)
#   --sysctl-persist-dir          (default: /etc/sysctl.d)
set -euo pipefail

# ── argument parsing ──────────────────────────────────────────────────────────
VPN_IF="${VPN_IF:-awg0}"
STATE_DIR="${STATE_DIR:-/run}"
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

# ── 1. remove nft tables (idempotent — || true on missing) ────────────────────
nft delete table ip mangle    2>/dev/null || true
nft delete table ip split_nat 2>/dev/null || true

# ── 2. remove ip rules ────────────────────────────────────────────────────────
ip rule del fwmark "$PKT_MARK" 2>/dev/null || true
ip rule del table main suppress_prefixlength 0 2>/dev/null || true

# ── 3. flush the split-routing routing table ───────────────────────────────────
TBL_FILE="$STATE_DIR/oxpulse-split-routing.tbl"
if [[ -f "$TBL_FILE" ]]; then
    TBL=$(cat "$TBL_FILE")
    ip route flush table "$TBL" 2>/dev/null || true
    rm -f "$TBL_FILE"
else
    # Best-effort flush of the default table id.
    ip route flush table 13573 2>/dev/null || true
fi

# ── 4. restore sysctl values ──────────────────────────────────────────────────
# Judgment call (эталон §10 does not specify): on apply we save the pre-apply
# rp_filter values into ${STATE_DIR}/oxpulse-split-routing.state so disable
# can restore them. If the state file is absent (disable run without prior
# apply), fall back to the kernel default of 1 (strict) for safety.
STATE_FILE="$STATE_DIR/oxpulse-split-routing.state"
if [[ -f "$STATE_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$STATE_FILE"
fi
_restore_rp="${SAVED_RP_FILTER_ALL:-1}"
_restore_wan_rp="${SAVED_RP_FILTER_WAN:-1}"
_restore_vpn_rp="${SAVED_RP_FILTER_VPN:-1}"

sysctl -qw "net.ipv4.conf.all.rp_filter=${_restore_rp}"
# We need the WAN iface name to restore per-iface value.
# Try state file, else auto-detect, else skip (not fatal).
WAN_IF="${SAVED_WAN_IF:-}"
if [[ -z "$WAN_IF" ]]; then
    WAN_IF=$(ip -4 route show default 2>/dev/null | awk '/default/{print $5; exit}') || true
fi
[[ -n "$WAN_IF" ]] && sysctl -qw "net.ipv4.conf.${WAN_IF}.rp_filter=${_restore_wan_rp}"
sysctl -qw "net.ipv4.conf.${VPN_IF}.rp_filter=${_restore_vpn_rp}"

# Remove the persist file.
rm -f "${SYSCTL_PERSIST_DIR}/99-oxpulse-split-routing.conf"
# Remove state file.
rm -f "$STATE_FILE"

echo "DISABLED partner-edge split-routing: nft tables removed, ip rules/routes cleared, rp_filter restored"
