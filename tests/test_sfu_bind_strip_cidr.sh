#!/usr/bin/env bats
# Regression guard for bug: SFU_METRICS_BIND / SFU_RELAY_API_BIND rendered
# with raw CIDR form (e.g. "10.9.0.7/24") causes SFU v0.12.67+ crash loop:
#   Error: bind metrics at 10.9.0.7/24:9317
#   Caused by: failed to lookup address information: Name or service not known
#
# Fix: AWG_HOST_IP="${AWG_ALLOCATED_IP%%/*}" is derived in install.sh and
# exported; compose template uses {{AWG_HOST_IP}} (not {{AWG_ALLOCATED_IP}}).
# AWG_ALLOCATED_IP is kept intact for awg0.conf Address= and ip addr add.
#
# bats <1.5 compat: no bats_require_minimum_version, no "run !".

setup() {
    cd "$BATS_TEST_DIRNAME/.."
    # shellcheck source=../channel-render-lib.sh
    source ./channel-render-lib.sh
}

# --- Helper: shell strip function using same idiom as install.sh %%/* ---
_strip_cidr() {
    local v="$1"
    printf '%s' "${v%%/*}"
}

# -------------------------------------------------------------------------
# Unit tests: _strip_cidr semantics (3 required cases)
# -------------------------------------------------------------------------

@test "_strip_cidr: /24 prefix removed" {
    result=$(_strip_cidr "10.9.0.7/24")
    [ "$result" = "10.9.0.7" ]
}

@test "_strip_cidr: /32 prefix removed" {
    result=$(_strip_cidr "10.9.0.9/32")
    [ "$result" = "10.9.0.9" ]
}

@test "_strip_cidr: passthrough when no CIDR prefix" {
    result=$(_strip_cidr "10.9.0.6")
    [ "$result" = "10.9.0.6" ]
}

# -------------------------------------------------------------------------
# install.sh structural checks
# -------------------------------------------------------------------------

@test "install.sh: derives AWG_HOST_IP via AWG_ALLOCATED_IP%%/* idiom" {
    grep -qE 'AWG_HOST_IP="\$\{AWG_ALLOCATED_IP%%/\*\}"' install.sh \
        || { echo "AWG_HOST_IP derivation missing or has wrong form in install.sh"; return 1; }
}

@test "install.sh: exports AWG_HOST_IP in render export block" {
    # The export is a multi-line block; AWG_HOST_IP appears on a continuation line.
    # grep over the single combined line (tr removes backslash-newlines) to match.
    tr -d '\n' < install.sh | grep -qF 'AWG_HOST_IP' \
        || { echo "AWG_HOST_IP not found in install.sh"; return 1; }
    # Stricter: the export block must contain AWG_HOST_IP on a line after "export"
    awk '/^export /{found=1} found && /AWG_HOST_IP/{print; found=0; exit}' install.sh \
        | grep -q AWG_HOST_IP \
        || { echo "AWG_HOST_IP not in the export block in install.sh"; return 1; }
}

@test "install.sh: AWG_HOST_IP derived AFTER AWG_ALLOCATED_IP (line ordering)" {
    alloc_line=$(grep -n 'AWG_ALLOCATED_IP=\$(awg_extract' install.sh | head -1 | cut -d: -f1)
    host_line=$(grep -n 'AWG_HOST_IP="\${AWG_ALLOCATED_IP%%' install.sh | head -1 | cut -d: -f1)
    [ -n "$alloc_line" ] || { echo "AWG_ALLOCATED_IP extraction line not found"; return 1; }
    [ -n "$host_line"  ] || { echo "AWG_HOST_IP derivation line not found"; return 1; }
    [ "$host_line" -gt "$alloc_line" ] \
        || { echo "AWG_HOST_IP (L$host_line) must follow AWG_ALLOCATED_IP (L$alloc_line)"; return 1; }
}

# -------------------------------------------------------------------------
# Template structural checks
# -------------------------------------------------------------------------

@test "docker-compose.yml.tpl: SFU_METRICS_BIND uses {{AWG_HOST_IP}}" {
    grep -q 'SFU_METRICS_BIND:.*{{AWG_HOST_IP}}' docker-compose.yml.tpl \
        || { echo "SFU_METRICS_BIND placeholder not updated to AWG_HOST_IP"; return 1; }
}

@test "docker-compose.yml.tpl: SFU_RELAY_API_BIND uses {{AWG_HOST_IP}}" {
    grep -q 'SFU_RELAY_API_BIND:.*{{AWG_HOST_IP}}' docker-compose.yml.tpl \
        || { echo "SFU_RELAY_API_BIND placeholder not updated to AWG_HOST_IP"; return 1; }
}

@test "docker-compose.yml.tpl: SFU_METRICS_BIND does NOT use raw {{AWG_ALLOCATED_IP}}" {
    if grep -q 'SFU_METRICS_BIND:.*{{AWG_ALLOCATED_IP}}' docker-compose.yml.tpl; then
        echo "REGRESSION: SFU_METRICS_BIND uses {{AWG_ALLOCATED_IP}} — will render with /24 suffix"; return 1
    fi
}

@test "docker-compose.yml.tpl: SFU_RELAY_API_BIND does NOT use raw {{AWG_ALLOCATED_IP}}" {
    if grep -q 'SFU_RELAY_API_BIND:.*{{AWG_ALLOCATED_IP}}' docker-compose.yml.tpl; then
        echo "REGRESSION: SFU_RELAY_API_BIND uses {{AWG_ALLOCATED_IP}} — will render with /24 suffix"; return 1
    fi
}

# -------------------------------------------------------------------------
# Render correctness: value is bare IP, no slash (getaddrinfo-safe)
# -------------------------------------------------------------------------

@test "render: SFU_METRICS_BIND has no slash when AWG_HOST_IP=10.9.0.7 (CIDR input)" {
    tmp_out=$(mktemp)

    # Simulate production input: AWG_ALLOCATED_IP with CIDR, AWG_HOST_IP stripped
    export AWG_HOST_IP="10.9.0.7"
    export AWG_ALLOCATED_IP="10.9.0.7/24"  # kept for other consumers, not used by SFU bind
    _populate_render_env
    render_template "tests/fixtures/install-render/compose.tpl" "$tmp_out"

    bind_line=$(grep 'SFU_METRICS_BIND:' "$tmp_out" | head -1)
    rm -f "$tmp_out"

    if echo "$bind_line" | grep -qF '/'; then
        echo "REGRESSION: rendered SFU_METRICS_BIND contains slash: $bind_line"; return 1
    fi
    echo "$bind_line" | grep -qE '"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' \
        || { echo "rendered SFU_METRICS_BIND not a bare IP: $bind_line"; return 1; }
}

@test "render: SFU_RELAY_API_BIND has no slash when AWG_HOST_IP=10.9.0.7 (CIDR input)" {
    tmp_out=$(mktemp)

    export AWG_HOST_IP="10.9.0.7"
    export AWG_ALLOCATED_IP="10.9.0.7/24"
    _populate_render_env
    render_template "tests/fixtures/install-render/compose.tpl" "$tmp_out"

    bind_line=$(grep 'SFU_RELAY_API_BIND:' "$tmp_out" | head -1)
    rm -f "$tmp_out"

    if echo "$bind_line" | grep -qF '/'; then
        echo "REGRESSION: rendered SFU_RELAY_API_BIND contains slash: $bind_line"; return 1
    fi
    echo "$bind_line" | grep -qE '"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' \
        || { echo "rendered SFU_RELAY_API_BIND not a bare IP: $bind_line"; return 1; }
}

# Populate the minimal env needed for render_template to succeed on compose.tpl.
# Values are test fixtures only — not real secrets.
_populate_render_env() {
    export PARTNER_ID="testpeer"
    export PARTNER_DOMAIN="test.example.com"
    export BACKEND_ENDPOINT="1.2.3.4:5349"
    export BACKEND_HOST="1.2.3.4"
    export BACKEND_PORT="5349"
    export AWG_MOTHERLY_IP="10.9.0.2"
    export HY2_FALLBACK_HOST="host.docker.internal"
    export HY2_FALLBACK_PORT="18443"
    export TURN_SECRET="test-secret"
    export REALITY_UUID="d529dee6-3cdd-4079-95d1-f8801722147c"
    export REALITY_PUBLIC_KEY="U6ea044JJjgiCjQAnYEBqBBlkeSqrQaLq3lcjnN2EFk"
    export REALITY_SHORT_ID="abcd1234"
    export REALITY_SERVER_NAME="www.samsung.com"
    export REALITY_ENCRYPTION="mlkem768x25519plus.native.0rtt.fXgOoxcW"
    export TURNS_SUBDOMAIN="api-test01"
    export PUBLIC_IP="1.2.3.4"
    export PRIVATE_IP=""
    export EXTERNAL_IP_LINE="1.2.3.4"
    export IMAGE_VERSION="stable"
    export SFU_UDP_PORT="7878"
    export SFU_METRICS_PORT="9317"
    export SFU_EDGE_ID="testpeer1"
    export OTEL_EXPORTER_OTLP_ENDPOINT=""
    export SFU_SIGNING_PUBLIC_KEY="-----BEGIN PUBLIC KEY-----\nMCowBQYDK2VwAyEAZiwaWp+FJ1sGprGGS69mq+sB6nhwOMi24xGSGfgdXNo=\n-----END PUBLIC KEY-----\n"
    export RELAY_JWT_SECRET="test-relay-secret"
    export SIGNALING_SFU_SECRET="test-signaling-secret"
    export HYSTERIA2_SERVER=""
    export HYSTERIA2_PORT="51822"
    export HYSTERIA2_AUTH=""
    export HYSTERIA2_OBFS=""
    export HYSTERIA2_SOCKS_PORT="18891"
    export NAIVE_SERVER=""
    export NAIVE_PORT="44433"
    export NAIVE_USER=""
    export NAIVE_PASS=""
    export NAIVE_SOCKS_PORT="18892"
    export HY2_SERVER=""
    export HY2_AUTH_PASS=""
    export HY2_OBFS_PASS=""
    export HY2_LOCAL_LISTEN=""
    export HY2_REMOTE_BACKEND=""
}
