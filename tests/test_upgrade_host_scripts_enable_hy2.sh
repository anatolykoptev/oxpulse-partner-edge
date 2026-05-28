#!/usr/bin/env bats
# tests/test_upgrade_host_scripts_enable_hy2.sh — C3 gate.
#
# Asserts that upgrade.sh correctly wires oxpulse-partner-edge-enable-hy2
# into the host-script sync pipeline:
#   1. _HOST_SCRIPT_SBIN_FILES contains the script
#   2. _host_script_remote_name maps it to its repo-root filename
#
# No systemd units associated (script is manual-invoke only, no timer/service).
#
# Bats <1.5 compat: no bats_require_minimum_version, no `run !`.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    UPGRADE="$REPO_ROOT/upgrade.sh"
}

# ── _HOST_SCRIPT_SBIN_FILES ──────────────────────────────────────────────────

@test "upgrade.sh _HOST_SCRIPT_SBIN_FILES contains oxpulse-partner-edge-enable-hy2" {
    awk '/^_HOST_SCRIPT_SBIN_FILES/,/^\)/' "$UPGRADE" \
        | grep -qE 'oxpulse-partner-edge-enable-hy2[[:space:]]*$'
}

# ── _host_script_remote_name ─────────────────────────────────────────────────

@test "upgrade.sh _host_script_remote_name maps enable-hy2 -> enable-hy2 (no .sh suffix)" {
    grep -A2 'oxpulse-partner-edge-enable-hy2)' "$UPGRADE" \
        | grep -q '"oxpulse-partner-edge-enable-hy2"'
}

# ── no systemd unit needed ───────────────────────────────────────────────────

@test "upgrade.sh does not add an enable-hy2 systemd unit (manual-invoke only)" {
    # If a systemd unit appeared it would be wrong — this script is not a timer.
    result=$(awk '/^_HOST_SCRIPT_SYSTEMD_FILES/,/^\)/' "$UPGRADE" \
        | grep -c 'enable-hy2' || true)
    [ "$result" = "0" ]
}

# ── syntax guard ─────────────────────────────────────────────────────────────

@test "upgrade.sh passes bash -n syntax check" {
    run bash -n "$UPGRADE"
    [ "$status" -eq 0 ]
}
