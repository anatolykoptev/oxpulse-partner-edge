#!/usr/bin/env bats
# tests/test_install_preflight_module.sh

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    TMPMOD="$(mktemp -d)"
}

teardown() {
    rm -rf "$TMPMOD"
}

@test "preflight module sources cleanly without side effects" {
    run bash -c "source '$REPO_ROOT/lib/install-preflight.sh'; type preflight_run"
    [ "$status" -eq 0 ]
    [[ "$output" == *"preflight_run is a function"* ]]
}

@test "preflight_run detects debian family from /etc/os-release fixture" {
    fake_os="$TMPMOD/os-release"
    cat > "$fake_os" <<'EOF'
ID=ubuntu
ID_LIKE=debian
EOF
    run bash -c "
        OS_RELEASE_PATH='$fake_os'
        source '$REPO_ROOT/lib/install-preflight.sh'
        DRY_RUN=1
        SFU_UDP_PORT=7878
        SFU_METRICS_PORT=9317
        log()  { :; }
        warn() { :; }
        die()  { echo die >&2; return 1; }
        preflight_run
        echo OS_FAMILY=\$OS_FAMILY
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"OS_FAMILY=debian"* ]]
}

@test "preflight_run detects rhel family from /etc/os-release fixture" {
    fake_os="$TMPMOD/os-release"
    cat > "$fake_os" <<'EOF'
ID=almalinux
ID_LIKE="rhel centos fedora"
EOF
    run bash -c "
        OS_RELEASE_PATH='$fake_os'
        source '$REPO_ROOT/lib/install-preflight.sh'
        DRY_RUN=1
        SFU_UDP_PORT=7878
        SFU_METRICS_PORT=9317
        log()  { :; }
        warn() { :; }
        die()  { echo die >&2; return 1; }
        preflight_run
        echo OS_FAMILY=\$OS_FAMILY
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"OS_FAMILY=rhel"* ]]
}

@test "preflight_run dies on unsupported OS" {
    fake_os="$TMPMOD/os-release"
    cat > "$fake_os" <<'EOF'
ID=arch
ID_LIKE=
EOF
    run bash -c "
        OS_RELEASE_PATH='$fake_os'
        source '$REPO_ROOT/lib/install-preflight.sh'
        DRY_RUN=1
        SFU_UDP_PORT=7878
        SFU_METRICS_PORT=9317
        log()  { :; }
        warn() { :; }
        die()  { echo die: \"\$*\" >&2; exit 1; }
        preflight_run
    "
    [ "$status" -ne 0 ]
    [[ "$output" == *"unsupported OS"* ]]
}

@test "preflight_run dies naming the missing binary when ip/ss absent (F2)" {
    # Measured on a clean ubuntu:22.04: `ip` missing → exit 127 at step 3 with
    # no diagnostic (stderr suppressed in the command substitution). The fix
    # adds a step-1 binary check so a missing iproute2 fails fast with the
    # command name + install hint instead of a mystery 127 at step 3.
    # curl/jq/python3 are NOT checked (deps_install provisions them at step 2).
    fake_os="$TMPMOD/os-release"
    cat > "$fake_os" <<'EOF'
ID=ubuntu
ID_LIKE=debian
EOF
    empty_bin="$TMPMOD/empty-bin"
    mkdir -p "$empty_bin"
    run bash -c "
        OS_RELEASE_PATH='$fake_os'
        PATH='$empty_bin'
        source '$REPO_ROOT/lib/install-preflight.sh'
        DRY_RUN=1
        SFU_UDP_PORT=7878
        SFU_METRICS_PORT=9317
        log()  { :; }
        warn() { :; }
        die()  { echo \"ERR \$*\" >&2; exit 1; }
        preflight_run
    "
    [ "$status" -ne 0 ]
    # Must name the missing command(s) — the whole point of the fix.
    [[ "$output" == *"ip"* ]]
    # Must carry an install hint, not just a bare 127.
    [[ "$output" == *"iproute2"* ]]
}
