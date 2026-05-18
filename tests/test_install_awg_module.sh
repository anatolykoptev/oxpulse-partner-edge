#!/usr/bin/env bats
# tests/test_install_awg_module.sh — bats matrix for lib/install-awg.sh
#
# Covers: install_amneziawg (idempotent skip, unsupported arch, no pkg mgr, Go
# version check), configure_amneziawg (golden render, awg-quick failure),
# awg_extract (JSON parsing semantics).

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    TMP="$(mktemp -d)"
}

teardown() {
    rm -rf "$TMP"
}

# ---------------------------------------------------------------------------
# Helper: frozen AWG_* fixture globals used by configure tests
# ---------------------------------------------------------------------------
_load_awg_globals() {
    export AWG_PRIV_PATH="$TMP/awg-private.key"
    export AWG_PUB_PATH="$TMP/awg-public.key"
    export AWG_MOTHERLY_PUBKEY="MOTHERLY_PUBKEY_FIXTURE_AAAA1234="
    export AWG_MOTHERLY_ENDPOINT="10.0.0.1:51820"
    export AWG_MOTHERLY_AWG_IP="192.168.100.1"
    export AWG_ALLOCATED_IP="192.168.100.42/32"
    export AWG_JC="5"
    export AWG_JMIN="20"
    export AWG_JMAX="70"
    export AWG_S1="17"
    export AWG_S2="13"
    export AWG_S4="6"
    export AWG_H1="1234567890"
    export AWG_H2="2345678901"
    export AWG_H3="3456789012"
    export AWG_H4="4567890123"
    export AWG_CONF_DIR="$TMP/awg-conf"
    export AWG_LISTEN_PORT="43842"
    echo "mocked-private-key-base64==" > "$TMP/awg-private.key"
    mkdir -p "$TMP/awg-conf"
}

# ---------------------------------------------------------------------------
# Test 1: install_amneziawg — idempotent skip when binaries present
# ---------------------------------------------------------------------------
@test "install_amneziawg skips build when binaries already present" {
    # Real production idempotency gate now uses AWG_QUICK_BIN env hook
    # (defaults to /usr/bin/awg-quick). Test injects writable shim path
    # so we exercise the live skip branch without root or /usr/bin write.
    local prefix="$TMP/usr/local"
    mkdir -p "$prefix/bin"
    echo "fake" > "$prefix/bin/amneziawg-go"
    echo '#!/bin/sh' > "$prefix/bin/awg-quick"
    chmod +x "$prefix/bin/awg-quick"
    CALLS="$TMP/calls"

    run bash -c "
        source '$REPO_ROOT/lib/install-awg.sh'
        log()  { echo \"LOG: \$*\"; }
        warn() { :; }
        die()  { echo \"DIE: \$*\" >&2; exit 1; }
        curl() { echo mock_curl >> '$CALLS'; }
        git()  { echo mock_git  >> '$CALLS'; }
        make() { echo mock_make >> '$CALLS'; }

        AWG_INSTALL_PREFIX='$prefix'
        AWG_QUICK_BIN='$prefix/bin/awg-quick'
        install_amneziawg
        echo EXIT=\$?
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"amneziawg already installed (skip)"* ]]
    [[ ! -f "$CALLS" ]]
}

# ---------------------------------------------------------------------------
# Test 2: install_amneziawg — unsupported arch dies
# ---------------------------------------------------------------------------
@test "install_amneziawg dies on unsupported architecture" {
    # Create a fake go binary that reports too-old version, forcing arch check.
    local fake_go="$TMP/fake_go"
    cat > "$fake_go" <<'EOF'
#!/usr/bin/env bash
echo "go version go1.18.0 linux/amd64"
EOF
    chmod +x "$fake_go"

    run bash -c "
        source '$REPO_ROOT/lib/install-awg.sh'
        log()  { :; }
        warn() { :; }
        die()  { echo \"DIE: \$*\" >&2; exit 1; }
        uname() { echo 'riscv64'; }
        curl()  { :; }
        AWG_INSTALL_PREFIX='$TMP/nonexistent'
        AWG_GO_BIN_PATH='$fake_go'
        install_amneziawg
    "
    [ "$status" -ne 0 ]
    [[ "$output" == *"unsupported architecture"* ]]
}

# ---------------------------------------------------------------------------
# Test 3: install_amneziawg — no package manager dies
# ---------------------------------------------------------------------------
@test "install_amneziawg dies when no supported package manager" {
    # Mock go binary to report 1.24.4 so we skip go download and reach pkg check.
    local fake_go="$TMP/fake_go_new"
    cat > "$fake_go" <<'EOF'
#!/usr/bin/env bash
echo "go version go1.24.4 linux/amd64"
EOF
    chmod +x "$fake_go"

    # Create a minimal PATH with no dnf/apt-get but with other needed commands.
    local mockbin="$TMP/mockbin"
    mkdir -p "$mockbin"
    # Provide git/make as stubs (won't be reached if pkg manager check dies first)

    # Build a safebin with all standard tools except dnf and apt-get.
    local safebin="$TMP/safebin"
    mkdir -p "$safebin"
    for _tool in grep uname python3 install git make gcc tar rm bash env; do
        local _p
        _p="$(which "$_tool" 2>/dev/null)" && [[ -n "$_p" ]] && ln -sf "$_p" "$safebin/$_tool" || true
    done
    # Deliberately omit dnf and apt-get from safebin.

    run bash -c "
        source '$REPO_ROOT/lib/install-awg.sh'
        log()  { :; }
        warn() { :; }
        die()  { echo \"DIE: \$*\" >&2; exit 1; }
        # PATH contains only our safebin — no dnf, no apt-get executables.
        export PATH='$safebin'
        AWG_INSTALL_PREFIX='$TMP/nonexistent'
        AWG_GO_BIN_PATH='$fake_go'
        install_amneziawg
    "
    [ "$status" -ne 0 ]
    [[ "$output" == *"no supported package manager"* ]]
}

# ---------------------------------------------------------------------------
# Test 4a: install_amneziawg — old Go triggers curl re-download
# ---------------------------------------------------------------------------
@test "install_amneziawg downloads Go when existing version is too old" {
    local fake_go_old="$TMP/fake_go_old"
    cat > "$fake_go_old" <<'EOF'
#!/usr/bin/env bash
echo "go version go1.18.0 linux/amd64"
EOF
    chmod +x "$fake_go_old"

    local curl_log="$TMP/curl_log"
    local mockbin="$TMP/mockbin2"
    mkdir -p "$mockbin"
    # Provide uname to return x86_64
    cat > "$mockbin/uname" <<'EOF'
#!/usr/bin/env bash
echo "x86_64"
EOF
    chmod +x "$mockbin/uname"
    # Provide tar/rm as no-ops
    cat > "$mockbin/tar" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$mockbin/tar"
    cat > "$mockbin/rm" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$mockbin/rm"

    run bash -c "
        source '$REPO_ROOT/lib/install-awg.sh'
        log()  { :; }
        warn() { :; }
        die()  { echo \"DIE: \$*\" >&2; exit 1; }
        curl() { echo \"curl_called \$*\" >> '$curl_log'; }
        # Need dnf so we don't die at pkg manager check; die on git clone
        dnf()  { :; }
        git()  { die 'git clone not expected in this test'; }
        export PATH='$mockbin:/usr/bin:/bin'
        AWG_INSTALL_PREFIX='$TMP/nonexistent'
        AWG_GO_BIN_PATH='$fake_go_old'
        AWG_GO_DL_BASE='https://go.dev/dl'
        install_amneziawg || true
    "
    # curl should have been called with a go1.24+ URL
    [ -f "$curl_log" ]
    grep -qE 'go1\.(2[4-9]|[3-9][0-9])' "$curl_log"
}

# ---------------------------------------------------------------------------
# Test 4b: install_amneziawg — Go 1.24.4 present, no curl re-download
# ---------------------------------------------------------------------------
@test "install_amneziawg skips Go download when 1.24.4 already present" {
    local fake_go_new="$TMP/fake_go_new2"
    cat > "$fake_go_new" <<'EOF'
#!/usr/bin/env bash
echo "go version go1.24.4 linux/amd64"
EOF
    chmod +x "$fake_go_new"

    local curl_log="$TMP/curl_log_b"

    run bash -c "
        source '$REPO_ROOT/lib/install-awg.sh'
        log()  { :; }
        warn() { :; }
        die()  { echo \"DIE: \$*\" >&2; exit 1; }
        curl() { echo \"curl_called \$*\" >> '$curl_log'; }
        dnf()  { :; }
        git()  { die 'stopping at git'; }
        AWG_INSTALL_PREFIX='$TMP/nonexistent'
        AWG_GO_BIN_PATH='$fake_go_new'
        install_amneziawg || true
    "
    # curl should NOT have been called (go 1.24.4 satisfies requirement)
    [ ! -f "$curl_log" ]
}

# ---------------------------------------------------------------------------
# Test 5: configure_amneziawg — renders awg0.conf byte-identical to fixture
# ---------------------------------------------------------------------------
@test "configure_amneziawg renders awg0.conf byte-identical to fixture" {
    _load_awg_globals

    run bash -c "
        source '$REPO_ROOT/lib/install-awg.sh'
        log()      { :; }
        warn()     { :; }
        die()      { echo \"DIE: \$*\" >&2; exit 1; }
        systemctl() { :; }
        awg()      { :; }
        sleep()    { :; }

        $(declare -p AWG_PRIV_PATH AWG_PUB_PATH AWG_MOTHERLY_PUBKEY AWG_MOTHERLY_ENDPOINT \
            AWG_MOTHERLY_AWG_IP AWG_ALLOCATED_IP AWG_JC AWG_JMIN AWG_JMAX \
            AWG_S1 AWG_S2 AWG_S4 AWG_H1 AWG_H2 AWG_H3 AWG_H4 \
            AWG_CONF_DIR AWG_LISTEN_PORT)

        configure_amneziawg
        echo CONFIGURE_EXIT=\$?
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"CONFIGURE_EXIT=0"* ]]

    local fixture="$REPO_ROOT/tests/fixtures/install-awg/expected-awg0.conf"
    local rendered="$TMP/awg-conf/awg0.conf"
    diff "$fixture" "$rendered"
}

# ---------------------------------------------------------------------------
# Test 6: configure_amneziawg — systemctl failure warns, does not die
# ---------------------------------------------------------------------------
@test "configure_amneziawg warns but does not die when awg-quick@awg0 fails" {
    _load_awg_globals

    run bash -c "
        source '$REPO_ROOT/lib/install-awg.sh'
        log()      { :; }
        warn()     { echo \"WARN: \$*\"; }
        die()      { echo \"DIE: \$*\" >&2; exit 1; }
        sleep()    { :; }
        awg()      { :; }
        systemctl() {
            case \"\$*\" in
                *'awg-quick@awg0'*) return 1 ;;
                *) return 0 ;;
            esac
        }

        $(declare -p AWG_PRIV_PATH AWG_PUB_PATH AWG_MOTHERLY_PUBKEY AWG_MOTHERLY_ENDPOINT \
            AWG_MOTHERLY_AWG_IP AWG_ALLOCATED_IP AWG_JC AWG_JMIN AWG_JMAX \
            AWG_S1 AWG_S2 AWG_S4 AWG_H1 AWG_H2 AWG_H3 AWG_H4 \
            AWG_CONF_DIR AWG_LISTEN_PORT)

        configure_amneziawg
        echo EXIT=\$?
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"EXIT=0"* ]]
    [[ "$output" == *"awg-quick@awg0"* ]]
}

# ---------------------------------------------------------------------------
# Test 7a: awg_extract — reads key from nested awg object
# ---------------------------------------------------------------------------
@test "awg_extract reads jc from nested awg object" {
    local json_file="$TMP/reg.json"
    cat > "$json_file" <<'EOF'
{"awg": {"jc": 2, "jmin": 50}, "other": "value"}
EOF

    run bash -c "
        source '$REPO_ROOT/lib/install-awg.sh'
        awg_extract '$json_file' jc
    "
    [ "$status" -eq 0 ]
    [ "$output" = "2" ]
}

# ---------------------------------------------------------------------------
# Test 7b: awg_extract — missing key returns empty string
# ---------------------------------------------------------------------------
@test "awg_extract returns empty string for missing key" {
    local json_file="$TMP/reg.json"
    cat > "$json_file" <<'EOF'
{"awg": {"jc": 2}}
EOF

    run bash -c "
        source '$REPO_ROOT/lib/install-awg.sh'
        result=\$(awg_extract '$json_file' missing_key)
        echo \"result=[\$result]\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == "result=[]" ]]
}

# ---------------------------------------------------------------------------
# Test 7c: awg_extract — malformed JSON returns empty (2>/dev/null semantics)
# ---------------------------------------------------------------------------
@test "awg_extract returns empty string for malformed JSON" {
    local json_file="$TMP/bad.json"
    printf 'not valid json' > "$json_file"

    run bash -c "
        source '$REPO_ROOT/lib/install-awg.sh'
        result=\$(awg_extract '$json_file' jc)
        echo \"result=[\$result]\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"result=[]"* ]]
}
