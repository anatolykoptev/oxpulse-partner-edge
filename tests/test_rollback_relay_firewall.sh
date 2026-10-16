#!/usr/bin/env bash
# tests/test_rollback_relay_firewall.sh - after ANY rollback the firewall's relay range
# must equal the live coturn.conf's min-port/max-port.
#
# Incident (rvpn v0.16.28 -> v0.16.31, 2026-10-12): the guard's `apply` (run during the
# host-script sync, before the settle gate) migrated coturn.conf to 49152-49999 and
# retired the firewalld 49152-65535 entry; a rollback then restored images, compose and
# an OLDER guard but left the migrated conf, and the zone had no relay range at all
# for ~26 min. Every rollback branch funnels through restore_host_scripts
# (lib/host-scripts-lib.sh), which now re-asserts the range via `coturn-guard
# firewall-sync`. This drives the REAL restore_host_scripts and the REAL guard against
# a stateful firewalld stub (tests/fixtures/stateful-firewall-cmd.sh).
# shellcheck disable=SC2034  # variables below are consumed by the sourced lib
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LIB="$REPO_ROOT/lib/host-scripts-lib.sh"
GUARD="$REPO_ROOT/oxpulse-partner-edge-coturn-guard.sh"
PASS=0; FAIL=0
ok()  { echo "  PASS: $*"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
echo "test_rollback_relay_firewall.sh"

TC=$(mktemp -d); trap 'rm -rf "$TC"' EXIT
mkdir -p "$TC/sbin" "$TC/snap/sbin" "$TC/fw" "$TC/etc/oxpulse-partner-edge" "$TC/bin"
install -m 0755 "$REPO_ROOT/tests/fixtures/stateful-firewall-cmd.sh" "$TC/fw/firewall-cmd"
# The "restored" guard: what the previous release shipped - no firewall-sync subcommand.
printf '#!/bin/bash\n[[ "${1:-apply}" == firewall-sync ]] && { echo "usage: old guard" >&2; exit 2; }\nexit 0\n' > "$TC/snap/sbin/oxpulse-partner-edge-coturn-guard"
printf '#!/bin/bash\nexit 0\n' > "$TC/bin/ip"; chmod +x "$TC/bin/ip"

# run_restore SNAPDIR - drive the real restore_host_scripts with the NEW guard installed.
run_restore() {
    install -m 0755 "$GUARD" "$TC/sbin/oxpulse-partner-edge-coturn-guard"
    ( set +e
      export FWS="$TC/fw" FIREWALL_CMD="$TC/fw/firewall-cmd" UFW_BIN=/nonexistent COTURN_CONF="$TC/etc/oxpulse-partner-edge/coturn.conf"
      export ETC_DIR="$TC/etc" SYSCTL_DIR="$TC/etc/sysctl.d"
      log() { :; }; warn() { printf 'WARN: %s\n' "$*" >> "$TC/warns"; }
      PREV_HOST_SCRIPTS_DIR="$1"; PREFIX_SBIN="$TC/sbin"; PREFIX_SHARE="$TC/share"; PREFIX_LIBDIR="$TC/lib"
      SYSTEMD_DIR="$TC/systemd"; SYSTEMCTL_BIN=true
      _HOST_SCRIPT_SBIN_FILES=(oxpulse-partner-edge-coturn-guard); _HOST_SCRIPT_ASSET_FILES=()
      _host_script_mode() { echo 0755; }; _host_script_install_dir() { echo "$PREFIX_SBIN"; }
      # shellcheck disable=SC1090
      . "$LIB"
      restore_host_scripts ) >/dev/null 2>&1
}
fwstate() { echo "perm=[$(tr '\n' ' ' < "$TC/fw/perm")] run=[$(tr '\n' ' ' < "$TC/fw/run")]"; }
reset() { : > "$TC/fw/perm"; : > "$TC/fw/run"; local e; for e in "$@"; do echo "$e" >> "$TC/fw/perm"; echo "$e" >> "$TC/fw/run"; done; : > "$TC/warns"; }

# R1: migrated conf, zone lost the range, guard restored to an old one without firewall-sync.
printf 'min-port=49152\nmax-port=49999\n' > "$TC/etc/oxpulse-partner-edge/coturn.conf"
reset 3478/udp
run_restore "$TC/snap"
[[ "$(fwstate)" == "perm=[3478/udp 49152-49999/udp ] run=[3478/udp 49152-49999/udp ]" ]] \
    && ok "R1: after rollback the zone carries the conf's 49152-49999/udp (permanent + runtime)" \
    || bad "R1: zone state after rollback: $(fwstate)"
cmp -s "$TC/snap/sbin/oxpulse-partner-edge-coturn-guard" "$TC/sbin/oxpulse-partner-edge-coturn-guard" \
    && ok "R1b: the host scripts were still restored (old guard back on disk)" \
    || bad "R1b: rollback no longer restores the host scripts"

# R2: the exact rvpn state - legacy entry already retired, nothing replaced it.
reset
run_restore "$TC/snap"
[[ "$(fwstate)" == "perm=[49152-49999/udp ] run=[49152-49999/udp ]" ]] \
    && ok "R2: empty zone after rollback -> relay range restored" || bad "R2: $(fwstate)"

# R3: a conf that was never migrated (rollback before the guard ran) keeps the LEGACY range.
printf 'realm=x\n' > "$TC/etc/oxpulse-partner-edge/coturn.conf"
reset 49152-65535/udp
run_restore "$TC/snap"
[[ "$(fwstate)" == "perm=[49152-65535/udp ] run=[49152-65535/udp ]" ]] \
    && ok "R3: unmigrated conf -> firewall keeps the range coturn will bind (legacy)" || bad "R3: $(fwstate)"

# R4: no host-script snapshot at all ('no host-script snapshot to restore' early return) still syncs.
printf 'min-port=49152\nmax-port=49999\n' > "$TC/etc/oxpulse-partner-edge/coturn.conf"
reset 3478/udp
run_restore "$TC/nosnap"
[[ "$(fwstate)" == "perm=[3478/udp 49152-49999/udp ] run=[3478/udp 49152-49999/udp ]" ]] \
    && ok "R4: the no-snapshot early return also re-asserts the range" || bad "R4: $(fwstate)"

echo; echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
