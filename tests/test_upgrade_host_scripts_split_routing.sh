#!/usr/bin/env bats
# tests/test_upgrade_host_scripts_split_routing.sh — CL-C gate.
#
# Asserts that upgrade.sh correctly wires 3 new sbin scripts and 3 new systemd
# units from the split-routing feature (PR #280) into the host-script pipeline.
#
# Bats <1.5 compat: no bats_require_minimum_version, no `run !`.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  UPGRADE="$REPO_ROOT/upgrade.sh"
}

# ── _HOST_SCRIPT_SBIN_FILES ──────────────────────────────────────────────────

@test "upgrade.sh _HOST_SCRIPT_SBIN_FILES contains oxpulse-partner-edge-split-routing" {
  grep -qE 'oxpulse-partner-edge-split-routing[[:space:]]*$' "$UPGRADE"
}

@test "upgrade.sh _HOST_SCRIPT_SBIN_FILES contains oxpulse-partner-edge-split-disable" {
  grep -qE 'oxpulse-partner-edge-split-disable[[:space:]]*$' "$UPGRADE"
}

@test "upgrade.sh _HOST_SCRIPT_SBIN_FILES contains oxpulse-partner-edge-ru-subnets-update" {
  # Must appear as a standalone entry (not with .service/.timer suffix)
  awk '/^_HOST_SCRIPT_SBIN_FILES/,/^\)/' "$UPGRADE" \
    | grep -qE 'oxpulse-partner-edge-ru-subnets-update[[:space:]]*$'
}

# ── _host_script_remote_name ─────────────────────────────────────────────────

@test "upgrade.sh _host_script_remote_name maps split-routing -> split-routing.sh" {
  grep -A5 'oxpulse-partner-edge-split-routing)' "$UPGRADE" \
    | grep -q 'oxpulse-partner-edge-split-routing\.sh'
}

@test "upgrade.sh _host_script_remote_name maps split-disable -> split-disable.sh" {
  grep -A5 'oxpulse-partner-edge-split-disable)' "$UPGRADE" \
    | grep -q 'oxpulse-partner-edge-split-disable\.sh'
}

@test "upgrade.sh _host_script_remote_name maps ru-subnets-update -> ru-subnets-update (no .sh)" {
  grep -A5 'oxpulse-partner-edge-ru-subnets-update)' "$UPGRADE" \
    | grep -q '"oxpulse-partner-edge-ru-subnets-update"'
}

# ── _HOST_SCRIPT_SYSTEMD_FILES ───────────────────────────────────────────────

@test "upgrade.sh _HOST_SCRIPT_SYSTEMD_FILES constant exists" {
  grep -q '^_HOST_SCRIPT_SYSTEMD_FILES=(' "$UPGRADE"
}

@test "upgrade.sh _HOST_SCRIPT_SYSTEMD_FILES contains oxpulse-partner-edge-split-routing.service" {
  awk '/^_HOST_SCRIPT_SYSTEMD_FILES/,/^\)/' "$UPGRADE" \
    | grep -q 'oxpulse-partner-edge-split-routing\.service'
}

@test "upgrade.sh _HOST_SCRIPT_SYSTEMD_FILES contains oxpulse-partner-edge-ru-subnets-update.service" {
  awk '/^_HOST_SCRIPT_SYSTEMD_FILES/,/^\)/' "$UPGRADE" \
    | grep -q 'oxpulse-partner-edge-ru-subnets-update\.service'
}

@test "upgrade.sh _HOST_SCRIPT_SYSTEMD_FILES contains oxpulse-partner-edge-ru-subnets-update.timer" {
  awk '/^_HOST_SCRIPT_SYSTEMD_FILES/,/^\)/' "$UPGRADE" \
    | grep -q 'oxpulse-partner-edge-ru-subnets-update\.timer'
}

@test "upgrade.sh sync_host_scripts Step 5 iterates _HOST_SCRIPT_SYSTEMD_FILES" {
  # Step 5 must reference the constant, not an inline array
  grep -q '_HOST_SCRIPT_SYSTEMD_FILES' "$UPGRADE"
  # And Step 5 should NOT have a local units_to_fetch=( inline array anymore
  run grep -c 'local units_to_fetch' "$UPGRADE"
  [ "$status" -ne 0 ] || [ "$output" = "0" ]
}

# ── _HOST_SCRIPT_RESTART_UNITS ───────────────────────────────────────────────

@test "upgrade.sh _HOST_SCRIPT_RESTART_UNITS contains oxpulse-partner-edge-ru-subnets-update.timer" {
  awk '/^_HOST_SCRIPT_RESTART_UNITS/,/^\)/' "$UPGRADE" \
    | grep -q 'oxpulse-partner-edge-ru-subnets-update\.timer'
}

@test "upgrade.sh _HOST_SCRIPT_RESTART_UNITS contains oxpulse-partner-edge-split-routing.service" {
  awk '/^_HOST_SCRIPT_RESTART_UNITS/,/^\)/' "$UPGRADE" \
    | grep -q 'oxpulse-partner-edge-split-routing\.service'
}

# ── awg-params-agent post-apply hook wiring ─────────────────────────────────

@test "upgrade.sh _HOST_SCRIPT_SYSTEMD_FILES contains oxpulse-awg-params-agent.service" {
  # Agent unit must be synced so OXPULSE_RESTART_UNIT_AFTER_APPLY reaches existing boxes.
  awk '/^_HOST_SCRIPT_SYSTEMD_FILES/,/^\)/' "$UPGRADE" \
    | grep -q 'oxpulse-awg-params-agent\.service'
}

@test "upgrade.sh _HOST_SCRIPT_RESTART_UNITS contains oxpulse-awg-params-agent.service" {
  # Agent must be restarted after unit sync to pick up the new env var.
  awk '/^_HOST_SCRIPT_RESTART_UNITS/,/^\)/' "$UPGRADE" \
    | grep -q 'oxpulse-awg-params-agent\.service'
}

@test "systemd/oxpulse-awg-params-agent.service sets OXPULSE_RESTART_UNIT_AFTER_APPLY" {
  UNIT="$REPO_ROOT/systemd/oxpulse-awg-params-agent.service"
  grep -q 'OXPULSE_RESTART_UNIT_AFTER_APPLY' "$UNIT"
  grep -q 'oxpulse-partner-edge-split-routing\.service' "$UNIT"
}

# ── syntax guard ─────────────────────────────────────────────────────────────

@test "upgrade.sh passes bash -n syntax check" {
  run bash -n "$UPGRADE"
  [ "$status" -eq 0 ]
}
