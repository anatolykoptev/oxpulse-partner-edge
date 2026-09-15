#!/usr/bin/env bats
# tests/test_install_awg_ensure.sh — bats matrix for ensure_amneziawg
# (lib/install-awg.sh), the upgrade-path version converge.
#
# Covers: skip on non-awg node, skip on pinned-version match, converge on
# drift (rebuild + awg-quick@awg0 restart + handshake verify), fail-soft
# returns on rebuild/restart/handshake failure.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    TMP="$(mktemp -d)"
    mkdir -p "$TMP/prefix/bin" "$TMP/conf"
}

teardown() {
    rm -rf "$TMP"
}

# Fake amneziawg-go / awg reporting $1 versions. Written OUTSIDE the bash -c
# so a quoted heredoc keeps the script body literal.
_make_go_fake() {  # $1 = reported version tag
    cat > "$TMP/prefix/bin/amneziawg-go" <<EOF
#!/usr/bin/env bash
[ "\$1" = --version ] && echo "amneziawg-go $1"
EOF
    chmod +x "$TMP/prefix/bin/amneziawg-go"
}
_make_awg_fake() {  # $1 = reported version tag; $2 = optional handshake line
    cat > "$TMP/awg" <<EOF
#!/usr/bin/env bash
if [ "\$1" = --version ]; then echo "amneziawg-tools $1"; fi
if [ "\$1" = show ]; then
    echo "interface: awg0"
    $2
fi
EOF
    chmod +x "$TMP/awg"
}

# ---------------------------------------------------------------------------
@test "ensure_amneziawg skips a node with no awg install at all" {
    run bash -c "
        source '$REPO_ROOT/lib/install-awg.sh'
        log()  { echo \"LOG: \$*\"; }
        warn() { echo \"WARN: \$*\"; }
        die()  { echo \"DIE: \$*\" >&2; exit 1; }
        systemctl() { echo SYSTEMCTL >> '$TMP/calls'; }

        AWG_INSTALL_PREFIX='$TMP/prefix'
        AWG_CONF_DIR='$TMP/conf-absent'
        ensure_amneziawg
        echo EXIT=\$?
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"no amneziawg install"* ]]
    [[ "$output" == *"EXIT=0"* ]]
    [[ ! -f "$TMP/calls" ]]
}

# ---------------------------------------------------------------------------
@test "ensure_amneziawg skips when installed versions already match the pins" {
    _make_go_fake "v9.9.9-test"
    _make_awg_fake "v9.9.9-test-tools"
    echo "[Interface]" > "$TMP/conf/awg0.conf"

    run bash -c "
        source '$REPO_ROOT/lib/install-awg.sh'
        log()  { echo \"LOG: \$*\"; }
        warn() { echo \"WARN: \$*\"; }
        die()  { echo \"DIE: \$*\" >&2; exit 1; }
        systemctl() { echo SYSTEMCTL >> '$TMP/calls'; }
        install_amneziawg() { echo REBUILT >> '$TMP/calls'; }

        AWG_INSTALL_PREFIX='$TMP/prefix'
        AWG_CONF_DIR='$TMP/conf'
        AWG_BIN='$TMP/awg'
        AWG_GO_REF='v9.9.9-test'
        AWG_TOOLS_REF='v9.9.9-test-tools'
        ensure_amneziawg
        echo EXIT=\$?
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"already at"* ]]
    [[ "$output" == *"EXIT=0"* ]]
    # No rebuild, no restart.
    [[ ! -f "$TMP/calls" ]]
}

# ---------------------------------------------------------------------------
@test "ensure_amneziawg converges on drift: rebuild + restart + handshake" {
    _make_go_fake "v0.2.18"
    _make_awg_fake "v1.0.20210914" "echo '  latest handshake: 3 seconds ago'"
    echo "[Interface]" > "$TMP/conf/awg0.conf"

    run bash -c "
        source '$REPO_ROOT/lib/install-awg.sh'
        log()  { echo \"LOG: \$*\"; }
        warn() { echo \"WARN: \$*\"; }
        die()  { echo \"DIE: \$*\" >&2; exit 1; }
        systemctl() { echo \"systemctl \$*\" >> '$TMP/calls'; }
        sleep() { :; }
        install_amneziawg() { echo REBUILT >> '$TMP/calls'; return 0; }

        AWG_INSTALL_PREFIX='$TMP/prefix'
        AWG_CONF_DIR='$TMP/conf'
        AWG_BIN='$TMP/awg'
        ensure_amneziawg
        echo EXIT=\$?
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"converging amneziawg"* ]]
    [[ "$output" == *"handshake confirmed"* ]]
    [[ "$output" == *"EXIT=0"* ]]
    grep -q "REBUILT" "$TMP/calls"
    grep -q "systemctl restart awg-quick@awg0" "$TMP/calls"
}

# ---------------------------------------------------------------------------
@test "ensure_amneziawg returns 1 (fail-soft) when the rebuild dies" {
    _make_go_fake "v0.2.18"
    _make_awg_fake "v1.0.20210914"
    echo "[Interface]" > "$TMP/conf/awg0.conf"

    run bash -c "
        source '$REPO_ROOT/lib/install-awg.sh'
        log()  { :; }
        warn() { echo \"WARN: \$*\"; }
        die()  { echo \"DIE: \$*\" >&2; exit 1; }
        systemctl() { echo SYSTEMCTL >> '$TMP/calls'; }
        # die() inside the subshell call must not kill ensure_amneziawg.
        install_amneziawg() { die 'amneziawg git clone failed'; }

        AWG_INSTALL_PREFIX='$TMP/prefix'
        AWG_CONF_DIR='$TMP/conf'
        AWG_BIN='$TMP/awg'
        ensure_amneziawg
        echo EXIT=\$?
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"rebuild failed"* ]]
    [[ "$output" == *"EXIT=1"* ]]
    # No restart attempted after a failed build.
    [[ ! -f "$TMP/calls" ]]
}

# ---------------------------------------------------------------------------
@test "ensure_amneziawg returns 1 when handshake never comes up" {
    _make_go_fake "v0.2.18"
    _make_awg_fake "v1.0.20210914"  # 'show' prints no handshake line
    echo "[Interface]" > "$TMP/conf/awg0.conf"

    run bash -c "
        source '$REPO_ROOT/lib/install-awg.sh'
        log()  { :; }
        warn() { echo \"WARN: \$*\"; }
        die()  { echo \"DIE: \$*\" >&2; exit 1; }
        systemctl() { :; }
        sleep() { :; }
        install_amneziawg() { return 0; }

        AWG_INSTALL_PREFIX='$TMP/prefix'
        AWG_CONF_DIR='$TMP/conf'
        AWG_BIN='$TMP/awg'
        AWG_HANDSHAKE_WAIT=0
        ensure_amneziawg
        echo EXIT=\$?
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"handshake not seen"* ]]
    [[ "$output" == *"EXIT=1"* ]]
}
