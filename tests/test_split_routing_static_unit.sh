#!/usr/bin/env bats
# tests/test_split_routing_static_unit.sh — CL-A regression gate.
#
# Asserts:
# 1. systemd/oxpulse-partner-edge-split-routing.service exists and is correct.
# 2. Its content matches what _split_routing_install_unit() previously rendered
#    (byte-identical to edge-a's installed unit with PREFIX_SBIN=/usr/local/sbin).
# 3. lib/install-split-routing.sh no longer contains the heredoc render path.
# 4. lib/install-split-routing.sh installs the file from systemd/ (static path).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "systemd/oxpulse-partner-edge-split-routing.service exists" {
  [ -f "$REPO_ROOT/systemd/oxpulse-partner-edge-split-routing.service" ]
}

@test "static unit has correct Description" {
  grep -q "Description=OxPulse partner-edge selective split-routing" \
    "$REPO_ROOT/systemd/oxpulse-partner-edge-split-routing.service"
}

@test "static unit has correct After= ordering" {
  grep -q "After=network-online.target awg-quick@awg0.service oxpulse-awg-params-agent.service" \
    "$REPO_ROOT/systemd/oxpulse-partner-edge-split-routing.service"
}

@test "static unit has ConditionPathExists for ru-subnets.txt" {
  grep -q "ConditionPathExists=/etc/oxpulse-partner-edge/ru-subnets.txt" \
    "$REPO_ROOT/systemd/oxpulse-partner-edge-split-routing.service"
}

@test "static unit has ConditionPathExists for awg0.conf" {
  grep -q "ConditionPathExists=/etc/amnezia/amneziawg/awg0.conf" \
    "$REPO_ROOT/systemd/oxpulse-partner-edge-split-routing.service"
}

@test "static unit ExecStart uses /usr/local/sbin (default PREFIX_SBIN)" {
  grep -q "ExecStart=/usr/local/sbin/oxpulse-partner-edge-split-routing" \
    "$REPO_ROOT/systemd/oxpulse-partner-edge-split-routing.service"
}

@test "static unit has Type=oneshot + RemainAfterExit=yes" {
  grep -q "Type=oneshot" "$REPO_ROOT/systemd/oxpulse-partner-edge-split-routing.service"
  grep -q "RemainAfterExit=yes" "$REPO_ROOT/systemd/oxpulse-partner-edge-split-routing.service"
}

@test "static unit has WantedBy=multi-user.target" {
  grep -q "WantedBy=multi-user.target" \
    "$REPO_ROOT/systemd/oxpulse-partner-edge-split-routing.service"
}

@test "install-split-routing.sh no longer renders unit via heredoc (no <<UNIT marker)" {
  # The old render path used a '<<UNIT' heredoc marker. Must be gone.
  run grep -c "<<UNIT" "$REPO_ROOT/lib/install-split-routing.sh"
  [ "$status" -ne 0 ] || [ "$output" = "0" ]
}

@test "install-split-routing.sh installs unit from systemd/ static file" {
  grep -q 'systemd/${_SPLIT_ROUTING_UNIT}' "$REPO_ROOT/lib/install-split-routing.sh"
}

@test "_unit_tmp tempfile variable is no longer used in install-split-routing.sh" {
  run grep -c "_unit_tmp" "$REPO_ROOT/lib/install-split-routing.sh"
  [ "$status" -ne 0 ] || [ "$output" = "0" ]
}

@test "static unit content matches edge-a installed unit (byte check on key fields)" {
  # Verify ExecStart is exactly the value edge-a has (verified live 2026-05-27).
  grep -qF "ExecStart=/usr/local/sbin/oxpulse-partner-edge-split-routing" \
    "$REPO_ROOT/systemd/oxpulse-partner-edge-split-routing.service"
  # No variable placeholders remain (e.g. ${PREFIX_SBIN} must not appear).
  run grep -c '${PREFIX_SBIN}' "$REPO_ROOT/systemd/oxpulse-partner-edge-split-routing.service"
  [ "$status" -ne 0 ] || [ "$output" = "0" ]
}
