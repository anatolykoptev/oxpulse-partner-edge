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
# Test 1: install_amneziawg — idempotent skip when binaries present AND at the
# pinned refs. The gate is version-aware: binaries that don't report the pinned
# tag are drift, not presence, and trigger a rebuild.
# ---------------------------------------------------------------------------
@test "install_amneziawg skips build when installed versions match the pins" {
    local prefix="$TMP/usr/local"
    mkdir -p "$prefix/bin"
    echo '#!/bin/sh' > "$prefix/bin/awg-quick"
    chmod +x "$prefix/bin/awg-quick"
    CALLS="$TMP/calls"
    # Quoted heredoc keeps $1 literal; refs come from the env override —
    # both sides pin to the same sentinel so the gate sees an exact match.
    cat > "$prefix/bin/amneziawg-go" <<'EOF'
#!/usr/bin/env bash
[ "$1" = --version ] && echo "amneziawg-go v9.9.9-test"
EOF
    cat > "$TMP/awg" <<'EOF'
#!/usr/bin/env bash
[ "$1" = --version ] && echo "amneziawg-tools v9.9.9-test-tools"
EOF
    chmod +x "$prefix/bin/amneziawg-go" "$TMP/awg"

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
        AWG_BIN='$TMP/awg'
        AWG_GO_REF='v9.9.9-test'
        AWG_TOOLS_REF='v9.9.9-test-tools'
        install_amneziawg
        echo EXIT=\$?
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"already at"* ]]
    [[ ! -f "$CALLS" ]]
}

# ---------------------------------------------------------------------------
# Test 1b: install_amneziawg — version drift triggers a pinned-tag rebuild
# ---------------------------------------------------------------------------
@test "install_amneziawg rebuilds from pinned tags when installed version is old" {
    local prefix="$TMP/usr/local"
    mkdir -p "$prefix/bin"
    echo '#!/bin/sh' > "$prefix/bin/awg-quick"
    chmod +x "$prefix/bin/awg-quick"
    # Installed stack reports the pre-3.x versions the fleet actually carries.
    cat > "$prefix/bin/amneziawg-go" <<'EOF'
#!/usr/bin/env bash
[ "$1" = --version ] && echo "amneziawg-go v0.2.18"
EOF
    cat > "$TMP/awg" <<'EOF'
#!/usr/bin/env bash
[ "$1" = --version ] && echo "amneziawg-tools v1.0.20210914"
EOF
    chmod +x "$prefix/bin/amneziawg-go" "$TMP/awg"
    mkdir -p "$TMP/build"
    local git_log="$TMP/git_log"

    run bash -c "
        source '$REPO_ROOT/lib/install-awg.sh'
        log()  { :; }
        warn() { :; }
        die()  { echo \"DIE: \$*\" >&2; exit 1; }
        # Reach the clone step with no network: go fresh enough, pkg mgr no-op.
        cat > '$TMP/fake_go' <<'EOF'
#!/usr/bin/env bash
echo 'go version go1.26.0 linux/amd64'
EOF
        chmod +x '$TMP/fake_go'
        dnf() { :; }
        # git clone must SUCCEED (returns 0) or the && chain skips the second
        # clone; create the repo dirs so the build steps below survive.
        git() {
            echo \"git \$*\" >> '$git_log'
            mkdir -p \"\$(basename \"\${@:\$#}\" .git)/src\"
        }
        make()    { :; }
        install() { :; }

        AWG_INSTALL_PREFIX='$prefix'
        AWG_QUICK_BIN='$prefix/bin/awg-quick'
        AWG_BIN='$TMP/awg'
        AWG_GO_BIN_PATH='$TMP/fake_go'
        AWG_BUILD_ROOT='$TMP/build'
        install_amneziawg
        echo EXIT=\$?
    "
    # Clone must be attempted with -b <pinned ref> for both upstreams.
    [ -f "$git_log" ]
    grep -qE 'clone .*-b v[0-9]+\.[0-9]+.*amneziawg-go' "$git_log"
    grep -qE 'clone .*-b v[0-9]+\.[0-9]+.*amneziawg-tools' "$git_log"
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
    # Mock go binary to report 1.26 so we skip go download and reach pkg check.
    local fake_go="$TMP/fake_go_new"
    cat > "$fake_go" <<'EOF'
#!/usr/bin/env bash
echo "go version go1.26.0 linux/amd64"
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
    # curl should have been called with a go1.25+ URL (v3 go.mod floor)
    [ -f "$curl_log" ]
    grep -qE 'go1\.(2[5-9]|[3-9][0-9])' "$curl_log"
}

# ---------------------------------------------------------------------------
# Test 4b: install_amneziawg — Go 1.26 present, no curl re-download
# ---------------------------------------------------------------------------
@test "install_amneziawg skips Go download when 1.26 already present" {
    local fake_go_new="$TMP/fake_go_new2"
    cat > "$fake_go_new" <<'EOF'
#!/usr/bin/env bash
echo "go version go1.26.0 linux/amd64"
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
        # flock(1) is absent on macOS — stub only there; on Linux CI the real
        # lock acquisition runs (locking itself is covered by test_install_awg_lock.sh).
        command -v flock >/dev/null 2>&1 || flock() { return 0; }

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
        command -v flock >/dev/null 2>&1 || flock() { return 0; }

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

# ---------------------------------------------------------------------------
# Test 7d: awg_extract — explicit JSON null normalizes to empty (the old
# a.get(key,'') printed the literal "None", which would render `Address = None`)
# ---------------------------------------------------------------------------
@test "awg_extract normalizes explicit JSON null to empty" {
    local json_file="$TMP/reg.json"
    cat > "$json_file" <<'EOF'
{"awg": {"allocated_ip": null, "jc": 2}}
EOF

    run bash -c "
        source '$REPO_ROOT/lib/install-awg.sh'
        result=\$(awg_extract '$json_file' allocated_ip)
        echo \"result=[\$result]\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == "result=[]" ]]
}

# ===========================================================================
# awg_extract_all — ONE python3 spawn, NUL-delimited VAR=VALUE records,
# normalized at the single choke point (AWG 3.1).
# ===========================================================================

# Helper: consume awg_extract_all exactly the way install.sh does (NUL read,
# first-'=' expansion split — never `IFS='=' read`, which eats trailing '='
# base64 padding — whitelist, printf -v, no eval) and report the vars asked
# for. `[[ -v ]]` distinguishes an emitted-but-empty record (`NAME=[]`) from
# a var the loop never saw (`NAME=UNSET`).
_extract_all_into_vars() {  # $1 = json file; $2.. = var names to report
    local _jf="$1"; shift
    bash -c "
        source '$REPO_ROOT/lib/install-awg.sh'
        while IFS= read -r -d '' _rec; do
            [[ \"\$_rec\" == *=* ]] || continue
            _k=\"\${_rec%%=*}\"; _v=\"\${_rec#*=}\"
            [[ \"\$_k\" =~ ^(AWG_[A-Z0-9_]+|SFU_EDGE_ID|OTEL_EXPORTER_OTLP_ENDPOINT)\$ ]] \
                && printf -v \"\$_k\" '%s' \"\$_v\"
        done < <(awg_extract_all '$_jf')
        for _v in \"\$@\"; do
            [[ -v \$_v ]] && printf '%s=[%s]\n' \"\$_v\" \"\${!_v}\" || printf '%s=UNSET\n' \"\$_v\"
        done
    " _ "$@"
}

@test "awg_extract_all emits every v3.1 key (absent keys emit empty records)" {
    local json_file="$TMP/reg.json"
    cat > "$json_file" <<'EOF'
{"awg": {"jc": 5}}
EOF

    run bash -c "
        source '$REPO_ROOT/lib/install-awg.sh'
        awg_extract_all '$json_file' | tr '\0' '\n'
    "
    [ "$status" -eq 0 ]
    # Full v3 surface present as records, even when the JSON omits them.
    for _k in AWG_MOTHERLY_PUBKEY AWG_MOTHERLY_ENDPOINT AWG_MOTHERLY_AWG_IP \
              AWG_JC AWG_JMIN AWG_JMAX AWG_S1 AWG_S2 AWG_S3 AWG_S4 \
              AWG_H1 AWG_H2 AWG_H3 AWG_H4 AWG_I1 AWG_I2 AWG_I3 AWG_I4 AWG_I5 \
              AWG_HPK AWG_CONTENT_PADDING_ADDITION AWG_REKEY_AFTER_TIME \
              AWG_REKEY_TIMEOUT AWG_REJECT_AFTER_TIME AWG_KEEPALIVE_TIMEOUT \
              AWG_MAX_HANDSHAKE_ATTEMPTS AWG_RANDOM_TRAILERS AWG_DISABLE_COOKIES \
              SFU_EDGE_ID OTEL_EXPORTER_OTLP_ENDPOINT; do
        [[ "$output" == *"$_k="* ]] || { echo "missing record for $_k"; return 1; }
    done
    [[ "$output" == *"AWG_JC=5"* ]]
}

@test "awg_extract_all normalizes null/absent -> '', bool -> on|off, numbers -> str" {
    local json_file="$TMP/reg.json"
    cat > "$json_file" <<'EOF'
{"awg": {
  "jc": 5, "s3": null, "h2": "123-456",
  "random_trailers": true, "disable_cookies": false,
  "edge_id": "edge-z9", "otel_endpoint": "https://otel.example:4317"
}}
EOF

    run bash -c "
        source '$REPO_ROOT/lib/install-awg.sh'
        awg_extract_all '$json_file' | tr '\0' '\n'
    "
    [ "$status" -eq 0 ]
    # JSON true/false -> on/off — Python repr True/False is parse-FATAL in
    # awg0.conf (upstream parse_bool accepts on|off|0|1 only).
    [[ "$output" == *"AWG_RANDOM_TRAILERS=on"* ]]
    [[ "$output" == *"AWG_DISABLE_COOKIES=off"* ]]
    [[ "$output" != *"True"* && "$output" != *"False"* ]]
    # explicit JSON null -> empty, never the literal 'None'
    [[ "$output" == *"AWG_S3="* && "$output" != *"AWG_S3=None"* && "$output" != *"AWG_S3=null"* ]]
    # absent keys -> empty records
    [[ "$output" == *"AWG_HPK="* ]]
    # numbers -> str; IntOrRange range-form passes through as a string
    [[ "$output" == *"AWG_JC=5"* ]]
    [[ "$output" == *"AWG_H2=123-456"* ]]
    # non-awg-prefixed consumers ride the same records
    [[ "$output" == *"SFU_EDGE_ID=edge-z9"* ]]
    [[ "$output" == *"OTEL_EXPORTER_OTLP_ENDPOINT=https://otel.example:4317"* ]]
}

@test "awg_extract_all read-loop populates vars without eval" {
    local json_file="$TMP/reg.json"
    cat > "$json_file" <<'EOF'
{"awg": {"jc": 5, "s1": 17, "random_trailers": true, "i1": "<r 32><t>"}}
EOF

    run _extract_all_into_vars "$json_file" AWG_JC AWG_S1 AWG_RANDOM_TRAILERS AWG_I1 AWG_S3
    [ "$status" -eq 0 ]
    [[ "$output" == *"AWG_JC=[5]"* ]]
    [[ "$output" == *"AWG_S1=[17]"* ]]
    [[ "$output" == *"AWG_RANDOM_TRAILERS=[on]"* ]]
    [[ "$output" == *"AWG_I1=[<r 32><t>]"* ]]
    [[ "$output" == *"AWG_S3=[]"* ]]
}

@test "awg_extract_all transports a newline-carrying i1 losslessly (NUL framing)" {
    # A hostile i1 must reach the render-side charset guard INTACT — line
    # framing would truncate at the first '\n' and hide the injected tail.
    local json_file="$TMP/reg.json"
    python3 -c 'import json; json.dump({"awg": {"i1": "<r 2>\n[Peer]\nAllowedIPs = 0.0.0.0/0"}}, open("'"$json_file"'","w"))'

    run _extract_all_into_vars "$json_file" AWG_I1
    [ "$status" -eq 0 ]
    # The full multi-line payload survives extraction so _awg_conf_safe can
    # see the '[' and reject it at render time.
    [[ "$output" == *"[Peer]"* ]]
    [[ "$output" == *"AllowedIPs = 0.0.0.0/0"* ]]
}

@test "awg_extract_all emits nothing on malformed JSON (fail-soft)" {
    local json_file="$TMP/bad.json"
    printf 'not valid json' > "$json_file"

    run bash -c "
        source '$REPO_ROOT/lib/install-awg.sh'
        awg_extract_all '$json_file' | tr '\0' '\n' | wc -l
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"0"* ]]
}

@test "awg_extract_all values containing '=' survive the record split" {
    # base64 padding ends in '=' — IFS='=' read must split on the FIRST '=' only.
    local json_file="$TMP/reg.json"
    cat > "$json_file" <<'EOF'
{"awg": {"motherly_pubkey": "MOTHERLY_PUBKEY_FIXTURE_AAAA1234=", "header_protection_key": "QUJDQUJDQUJDQUJDQUJDQUJDQUJDQUJDQUJDQUJDQUI="}}
EOF

    run _extract_all_into_vars "$json_file" AWG_MOTHERLY_PUBKEY AWG_HPK
    [ "$status" -eq 0 ]
    [[ "$output" == *"AWG_MOTHERLY_PUBKEY=[MOTHERLY_PUBKEY_FIXTURE_AAAA1234=]"* ]]
    [[ "$output" == *"AWG_HPK=[QUJDQUJDQUJDQUJDQUJDQUJDQUJDQUJDQUJDQUJDQUI=]"* ]]
}
