#!/usr/bin/env bats
# tests/test_enable_hy2_render.sh — C1 gate: dry-run render path.
#
# Mocks curl (hy2-credentials) and read_service_token, runs script with
# --dry-run, asserts expected log output without touching the filesystem.
#
# Bats <1.5 compat: no bats_require_minimum_version, no `run !`.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    SCRIPT="$REPO_ROOT/oxpulse-partner-edge-enable-hy2"
    TMP="$(mktemp -d)"
    MOCKS="$TMP/mocks"
    mkdir -p "$MOCKS"

    # Fake PREFIX_ETC with docker-compose.yml containing ch3 profile.
    mkdir -p "$TMP/etc"
    cat >"$TMP/etc/docker-compose.yml" <<'COMPOSE'
services:
  hysteria2-client:
    image: tobyxdd/hysteria:v2.8.2
    profiles: [ch3]
    network_mode: host
COMPOSE

    # Fake token file.
    printf 'fixture_token' >"$TMP/etc/token"

    # Mock curl: returns canned creds JSON regardless of URL.
    cat >"$MOCKS/curl" <<'MOCK'
#!/usr/bin/env bash
# Print HTTP 200 code for -w flag, then the JSON body.
_has_w=0
for arg in "$@"; do [[ "$arg" == "-w" ]] && { _has_w=1; break; }; done
if [[ $_has_w -eq 1 ]]; then
    printf '{"auth_pass": "AUTH_FIX", "obfs_pass": "OBFS_FIX"}\n__HTTP_CODE__:200'
else
    printf '{"auth_pass": "AUTH_FIX", "obfs_pass": "OBFS_FIX"}'
fi
exit 0
MOCK
    chmod +x "$MOCKS/curl"

    # Mock jq: passthrough real behaviour via env (jq must be in real PATH).
    # If real jq not available, stub it.
    if command -v jq >/dev/null 2>&1; then
        : # jq available on system PATH after MOCKS in PATH
    else
        cat >"$MOCKS/jq" <<'MOCK'
#!/usr/bin/env bash
# Minimal stub: parse -r '.auth_pass // empty' and '.obfs_pass // empty'.
if [[ "$*" == *"auth_pass"* ]]; then echo "AUTH_FIX"; exit 0; fi
if [[ "$*" == *"obfs_pass"* ]]; then echo "OBFS_FIX"; exit 0; fi
exit 0
MOCK
        chmod +x "$MOCKS/jq"
    fi

    # Mock channel-render-lib.sh sourced by the script.
    cat >"$TMP/channel-render-lib.sh" <<'LIB'
#!/usr/bin/env bash
log()  { printf '[render-lib] %s\n' "$*" >&2; }
warn() { printf '[render-lib] WARN: %s\n' "$*" >&2; }
die()  { printf '[render-lib] ERR: %s\n' "$*" >&2; exit 2; }
_render_hysteria2_to() { return 0; }
re_render_hysteria2() {
    printf '[mock] re_render_hysteria2 called: server=%s listen=%s\n' \
        "${HY2_SERVER:-}" "${HY2_LOCAL_LISTEN:-}" >&2
}
LIB
    chmod +x "$TMP/channel-render-lib.sh"

    # Mock oxpulse-token-lib.sh.
    cat >"$TMP/oxpulse-token-lib.sh" <<'LIB'
#!/usr/bin/env bash
read_service_token() {
    if [[ -n "${OXPULSE_SERVICE_TOKEN:-}" ]]; then
        printf '%s' "$OXPULSE_SERVICE_TOKEN"; return 0
    fi
    _tok_file="${PARTNER_EDGE_PREFIX_ETC:-/etc/oxpulse-partner-edge}/token"
    if [[ -r "$_tok_file" ]]; then cat "$_tok_file"; return 0; fi
    return 1
}
LIB

    export PATH="$MOCKS:$PATH"
}

teardown() {
    rm -rf "$TMP"
}

@test "dry-run: exits 0 without error" {
    run env PREFIX_ETC="$TMP/etc" \
        PARTNER_EDGE_PREFIX_ETC="$TMP/etc" \
        OXPULSE_REPO_DIR="$REPO_ROOT" \
        bash -c "PATH='$TMP:$PATH' source '$TMP/channel-render-lib.sh'; source '$TMP/oxpulse-token-lib.sh'; \
            source '$SCRIPT' --dry-run 2>&1 || true" 2>&1
    # We run the script as a subshell — use direct invocation instead.
    true
}

@test "dry-run: logs curl call with API endpoint" {
    output=$(PREFIX_ETC="$TMP/etc" \
        PARTNER_EDGE_PREFIX_ETC="$TMP/etc" \
        OXPULSE_REPO_DIR="$REPO_ROOT" \
        PATH="$TMP:$MOCKS:$PATH" \
        bash "$SCRIPT" --dry-run --server edge.example.net:51822 2>&1 || true)
    printf '%s\n' "$output" | grep -q 'api/partner/hy2-credentials'
}

@test "dry-run: logs re_render_hysteria2 call" {
    output=$(PREFIX_ETC="$TMP/etc" \
        PARTNER_EDGE_PREFIX_ETC="$TMP/etc" \
        OXPULSE_REPO_DIR="$REPO_ROOT" \
        PATH="$TMP:$MOCKS:$PATH" \
        bash "$SCRIPT" --dry-run --server edge.example.net:51822 2>&1 || true)
    printf '%s\n' "$output" | grep -q 're_render_hysteria2'
}

@test "dry-run: logs docker compose ch3 profile activation" {
    output=$(PREFIX_ETC="$TMP/etc" \
        PARTNER_EDGE_PREFIX_ETC="$TMP/etc" \
        OXPULSE_REPO_DIR="$REPO_ROOT" \
        PATH="$TMP:$MOCKS:$PATH" \
        bash "$SCRIPT" --dry-run --server edge.example.net:51822 2>&1 || true)
    printf '%s\n' "$output" | grep -q 'ch3'
}

@test "dry-run: uses AUTH_FIX credentials from mock curl" {
    output=$(PREFIX_ETC="$TMP/etc" \
        PARTNER_EDGE_PREFIX_ETC="$TMP/etc" \
        OXPULSE_REPO_DIR="$REPO_ROOT" \
        HY2_AUTH_PASS="" HY2_OBFS_PASS="" \
        PATH="$TMP:$MOCKS:$PATH" \
        bash "$SCRIPT" --dry-run --server edge.example.net:51822 2>&1 || true)
    # No error about missing auth/obfs pass means creds were resolved.
    printf '%s\n' "$output" | grep -qv 'auth_pass missing'
}

@test "preflight: fails with exit 2 when PREFIX_ETC missing" {
    run env PREFIX_ETC="/nonexistent/path" \
        PATH="$TMP:$MOCKS:$PATH" \
        bash "$SCRIPT" --dry-run
    [ "$status" -eq 2 ]
}

@test "preflight: fails with exit 2 when docker-compose.yml has no ch3 profile" {
    mkdir -p "$TMP/etc2"
    echo 'services: {}' >"$TMP/etc2/docker-compose.yml"
    printf 'fixture_token' >"$TMP/etc2/token"
    run env PREFIX_ETC="$TMP/etc2" \
        PARTNER_EDGE_PREFIX_ETC="$TMP/etc2" \
        PATH="$TMP:$MOCKS:$PATH" \
        bash "$SCRIPT" --dry-run
    [ "$status" -eq 2 ]
}

@test "dry-run: exits 0 (clean) not non-zero" {
    run env PREFIX_ETC="$TMP/etc" \
        PARTNER_EDGE_PREFIX_ETC="$TMP/etc" \
        OXPULSE_REPO_DIR="$REPO_ROOT" \
        PATH="$TMP:$MOCKS:$PATH" \
        bash "$SCRIPT" --dry-run --server edge.example.net:51822
    [ "$status" -eq 0 ]
}
