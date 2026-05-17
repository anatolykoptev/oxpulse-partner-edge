#!/usr/bin/env bats
# tests/test_install_network_module.sh

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    TMPBIN="$(mktemp -d)"
}

teardown() {
    rm -rf "$TMPBIN"
}

@test "network module sources cleanly" {
    run bash -c "source '$REPO_ROOT/lib/install-network.sh'; type network_run"
    [ "$status" -eq 0 ]
    [[ "$output" == *"network_run is a function"* ]]
}

@test "network_run honors OXPULSE_PUBLIC_IP env override" {
    run bash -c "
        source '$REPO_ROOT/lib/install-network.sh'
        OXPULSE_PUBLIC_IP=203.0.113.42
        OXPULSE_PRIVATE_IP=10.0.0.5
        REGION=us-test
        log()  { echo \"log: \$*\"; }
        warn() { echo \"warn: \$*\"; }
        die()  { echo \"die: \$*\" >&2; exit 1; }
        network_run
        echo PUBLIC_IP=\$PUBLIC_IP
        echo PRIVATE_IP=\$PRIVATE_IP
        echo REGION=\$REGION
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"PUBLIC_IP=203.0.113.42"* ]]
    [[ "$output" == *"PRIVATE_IP=10.0.0.5"* ]]
    [[ "$output" == *"REGION=us-test"* ]]
    # No detection attempted when overrides set — should not call curl
    [[ "$output" != *"region auto-detected"* ]]
}

@test "network_run dies if PUBLIC_IP cannot be resolved (mocked curl returns empty)" {
    # PATH shim: curl returns empty for everything
    cat > "$TMPBIN/curl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "$TMPBIN/curl"
    run bash -c "
        export PATH='$TMPBIN:/usr/bin:/bin'
        source '$REPO_ROOT/lib/install-network.sh'
        OXPULSE_PUBLIC_IP=
        REGION=
        log()  { :; }
        warn() { :; }
        die()  { echo \"die: \$*\" >&2; exit 1; }
        network_run
    "
    [ "$status" -ne 0 ]
    [[ "$output" == *"unable to autodetect public IP"* ]]
}

@test "network_run warns when region detect fails but does not die" {
    cat > "$TMPBIN/curl" <<'EOF'
#!/usr/bin/env bash
# Empty body for ipinfo.io; valid IP otherwise via OXPULSE_PUBLIC_IP override.
exit 1
EOF
    chmod +x "$TMPBIN/curl"
    run bash -c "
        export PATH='$TMPBIN:/usr/bin:/bin'
        source '$REPO_ROOT/lib/install-network.sh'
        OXPULSE_PUBLIC_IP=198.51.100.10
        OXPULSE_PRIVATE_IP=10.0.0.5
        REGION=
        log()  { echo \"log: \$*\"; }
        warn() { echo \"warn: \$*\"; }
        die()  { echo \"die: \$*\" >&2; exit 1; }
        network_run
        echo REGION_AFTER=\$REGION
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"region auto-detect failed"* ]]
    [[ "$output" == *"REGION_AFTER="* ]]
}
