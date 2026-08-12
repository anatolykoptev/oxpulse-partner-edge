#!/usr/bin/env bash
# tests/test_hydrate_hy2_render.sh — behavioural test for hydrate.sh's hy2
# channel render path.
#
# The prior hy2 block in hydrate.sh called re_render_hysteria2 directly but
# never set HY2_AUTH_PASS / HY2_OBFS_PASS — the register response does not
# carry them (the backend's RegistrationOk has no hysteria2_auth/obfs fields;
# those names are read by hydrate.sh:188-189 but are always empty). The
# actual hy2 credentials come from GET /api/partner/hy2-credentials, the same
# authenticated endpoint install.sh uses. Without that fetch, re_render_hysteria2
# returns 1 (channel-render-lib.sh:430-433), no file is written, and — because
# the block did not append to CHANNELS_FAILED — the hysteria2 service survives
# in docker-compose.yml with a bind mount pointing at a non-existent file (docker
# then mounts an empty directory as config.yaml).
#
# This test exercises hydrate_render_hy2 (extracted from the inline block) in
# hydrate's actual variable context: it sources the real channel-render-lib.sh
# and render-channel-lib.sh, mocks curl for the hy2-credentials API call, and
# asserts the two outcomes the fix establishes:
#
#   1. SUCCESS: with credentials fetched, re_render_hysteria2 writes the file
#      with the right values.
#   2. FAILURE + COMPOSE-STRIP: without credentials, re_render_hysteria2 fails,
#      "hysteria2" is appended to CHANNELS_FAILED, and compose_strip_failed_channels
#      removes the service block so no bind mount points at a missing file.
#
# Falsification:
#   F1 — revert the credential fetch (remove the curl + jq mapping in
#        hydrate_render_hy2) → HY2_AUTH_PASS/HY2_OBFS_PASS stay empty →
#        re_render_hysteria2 returns 1 → test 1 fails (file not written).
#   F2 — remove the CHANNELS_FAILED append → test 2 fails (hysteria2 not in
#        CHANNELS_FAILED, compose_strip is a no-op, service survives).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

FAIL=0
pass() { echo "OK: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }

# ── shared setup ─────────────────────────────────────────────────────────────
#
# Sources the REAL channel-render-lib.sh and render-channel-lib.sh so the
# test exercises the actual re_render_hysteria2 + compose_strip_failed_channels
# code, not a stub. Mocks curl and read_service_token so no network or token
# file is needed.

setup_env() {
    TMP="$(mktemp -d)"
    MOCKS="$TMP/mocks"
    mkdir -p "$MOCKS" "$TMP/etc" "$TMP/tpl"

    # Copy the real hy2 template into the temp tpl dir.
    cp "$REPO_ROOT/hysteria2-client.yaml.tpl" "$TMP/tpl/"

    # Mock curl: the test controls the response via CURL_MODE env var.
    #   CURL_MODE=ok   → returns {"auth_pass":"TEST_AUTH","obfs_pass":"TEST_OBFS"}
    #   CURL_MODE=fail → exits 22 (curl -f fails on HTTP error)
    #   CURL_MODE=503  → exits 22 (simulates backend 503)
    cat >"$MOCKS/curl" <<'MOCK'
#!/usr/bin/env bash
case "${CURL_MODE:-ok}" in
    ok)
        printf '{"auth_pass":"TEST_AUTH","obfs_pass":"TEST_OBFS"}'
        exit 0
        ;;
    fail|503)
        exit 22
        ;;
    *)
        exit 22
        ;;
esac
MOCK
    chmod +x "$MOCKS/curl"

    # Mock read_service_token: return a fake token so hydrate_render_hy2 can
    # call the hy2-credentials endpoint.
    cat >"$MOCKS/token-lib.sh" <<'MOCK'
#!/usr/bin/env bash
read_service_token() {
    printf 'stkn_TEST_TOKEN'
    return 0
}
MOCK
    chmod +x "$MOCKS/token-lib.sh"

    # Export the variables hydrate.sh sets up before calling hydrate_render_hy2.
    export HYSTERIA2_SERVER="203.0.113.10:51822"
    export HYSTERIA2_PORT="51822"
    export BACKEND_URL="https://oxpulse.chat"
    export PREFIX_ETC="$TMP/etc"
    export PREFIX_LIB="$TMP/lib"
    export TPL_DIR="$TMP/tpl"
    export OXPULSE_REPO_DIR="$TMP/tpl"
    export HY2_OUTPUT_PATH="$TMP/etc/hysteria2-client.yaml"
    export HY2_LOCAL_LISTEN="0.0.0.0:18443"
    export HY2_REMOTE_BACKEND="127.0.0.1:8907"
    export PATH="$MOCKS:$PATH"
    # CURL_MODE controls the mock curl; must be exported so the subprocess sees it.
    export CURL_MODE="${CURL_MODE:-ok}"

    # Source the real render libs.
    # shellcheck source=/dev/null
    source "$MOCKS/token-lib.sh"
    # shellcheck source=/dev/null
    source "$REPO_ROOT/channel-render-lib.sh"
    # shellcheck source=/dev/null
    source "$REPO_ROOT/lib/render-channel-lib.sh"
    # shellcheck source=/dev/null
    source "$REPO_ROOT/lib/hydrate-hy2.sh"
}

teardown_env() {
    [[ -n "${TMP:-}" ]] && rm -rf "$TMP"
}

# ── test 1: SUCCESS — credentials fetched, file written with right values ───
echo "==> test 1: hydrate_render_hy2 fetches creds and writes hysteria2-client.yaml"
CURL_MODE=ok
setup_env
# Clear any inherited creds so the function must fetch them.
unset HY2_AUTH_PASS HY2_OBFS_PASS OXPULSE_HY2_AUTH_PASS OXPULSE_HY2_OBFS_PASS

if hydrate_render_hy2; then
    if [[ -f "$HY2_OUTPUT_PATH" ]]; then
        _auth=$(grep '^auth:' "$HY2_OUTPUT_PATH" | sed -n "1p")
        _obfs=$(grep 'password:' "$HY2_OUTPUT_PATH" | sed -n "1p")
        if [[ "$_auth" == *'TEST_AUTH'* && "$_obfs" == *'TEST_OBFS'* ]]; then
            pass "hysteria2-client.yaml written with fetched credentials"
        else
            fail "hysteria2-client.yaml written but credentials wrong (auth='$_auth' obfs='$_obfs')"
        fi
    else
        fail "hydrate_render_hy2 returned 0 but $HY2_OUTPUT_PATH not written"
    fi
else
    fail "hydrate_render_hy2 failed despite credentials being available (CURL_MODE=ok)"
fi
teardown_env

# ── test 2: FAILURE + COMPOSE-STRIP — no creds, channel failed + stripped ───
echo "==> test 2: hydrate_render_hy2 fails cleanly and appends to CHANNELS_FAILED"
CURL_MODE=fail
setup_env
# Clear all credential sources — neither API nor env fallback provides creds.
unset HY2_AUTH_PASS HY2_OBFS_PASS OXPULSE_HY2_AUTH_PASS OXPULSE_HY2_OBFS_PASS

_ch_failed_before=${#CHANNELS_FAILED[@]}
if hydrate_render_hy2; then
    fail "hydrate_render_hy2 returned 0 despite no credentials (should fail)"
else
    pass "hydrate_render_hy2 returned non-zero (no credentials)"
fi
_ch_failed_after=${#CHANNELS_FAILED[@]}

# Assert "hysteria2-client" (the compose service name) was appended to CHANNELS_FAILED.
if (( _ch_failed_after > _ch_failed_before )); then
    if [[ " ${CHANNELS_FAILED[*]} " == *" hysteria2-client "* ]]; then
        pass "hysteria2-client appended to CHANNELS_FAILED"
    else
        fail "CHANNELS_FAILED grew but does not contain 'hysteria2-client' (got: ${CHANNELS_FAILED[*]})"
    fi
else
    fail "CHANNELS_FAILED not grown — compose-strip gap NOT closed (hysteria2 service will survive with a bind mount to a missing file)"
fi

# Assert compose_strip_failed_channels removes the hysteria2 service block.
cat >"$TMP/etc/docker-compose.yml" <<'COMPOSE'
services:
  xray-client:
    image: xray
  hysteria2-client:
    image: tobyxdd/hysteria:v2.8.2
    profiles: [ch3]
    volumes:
      - ./hysteria2-client.yaml:/etc/hysteria/config.yaml:ro
  caddy:
    image: caddy
COMPOSE

if compose_strip_failed_channels "$TMP/etc/docker-compose.yml" "${CHANNELS_FAILED[@]}"; then
    if grep -q 'hysteria2-client' "$TMP/etc/docker-compose.yml"; then
        fail "compose_strip_failed_channels did NOT remove hysteria2 service (bind mount to missing file survives)"
    else
        pass "compose_strip_failed_channels removed hysteria2 service block"
    fi
else
    fail "compose_strip_failed_channels returned non-zero"
fi
teardown_env

# ── test 3: env fallback — OXPULSE_HY2_AUTH_PASS used when API unavailable ──
echo "==> test 3: hydrate_render_hy2 falls back to OXPULSE_HY2_* env vars"
CURL_MODE=fail
setup_env
export OXPULSE_HY2_AUTH_PASS="ENV_AUTH"
export OXPULSE_HY2_OBFS_PASS="ENV_OBFS"
unset HY2_AUTH_PASS HY2_OBFS_PASS

if hydrate_render_hy2; then
    if [[ -f "$HY2_OUTPUT_PATH" ]]; then
        _auth=$(grep '^auth:' "$HY2_OUTPUT_PATH" | sed -n "1p")
        _obfs=$(grep 'password:' "$HY2_OUTPUT_PATH" | sed -n "1p")
        if [[ "$_auth" == *'ENV_AUTH'* && "$_obfs" == *'ENV_OBFS'* ]]; then
            pass "env fallback credentials written to hysteria2-client.yaml"
        else
            fail "file written but env fallback values wrong (auth='$_auth' obfs='$_obfs')"
        fi
    else
        fail "hydrate_render_hy2 returned 0 but file not written (env fallback)"
    fi
else
    fail "hydrate_render_hy2 failed despite env fallback creds being set"
fi
teardown_env

# ── result ───────────────────────────────────────────────────────────────────
# ---------------------------------------------------------------------------
# F3 — hydrate.sh must SURVIVE a failed hy2 render.
#
# hydrate_render_hy2 returns 1 on render failure BY CONTRACT: the caller is
# meant to notice, leave "hysteria2-client" in CHANNELS_FAILED, and let
# compose_strip_failed_channels drop the service block. But hydrate.sh runs
# under `set -euo pipefail` (line 16), so a BARE call makes that return fatal —
# the script dies before compose_strip runs, before the degraded-mode warning,
# and before steps 5-7. The fail-soft design would be defeated by its own
# caller, and the comment above the call would describe a strip that can never
# happen.
#
# The sibling channel renders are already guarded (`render_channel_soft ... ||
# warn`); this asserts the hy2 call is too. Extract the real block from
# hydrate.sh rather than replicating it — a replica cannot observe hydrate.sh
# changing.
# ---------------------------------------------------------------------------
_f3_block=$(mktemp)
awk '
    /^if \[\[ -n "\$\{HYSTERIA2_SERVER:-\}" \]\]; then$/ { cap=1 }
    cap { print; if ($0 ~ /^fi$/) exit }
' "$REPO_ROOT/hydrate.sh" > "$_f3_block"

if [[ ! -s "$_f3_block" ]]; then
    fail "F3: extraction produced an empty block — the awk pattern no longer matches hydrate.sh"
else
    grep -q 'hydrate_render_hy2' "$_f3_block" \
        || fail "F3: extracted block does not contain the hy2 call — extraction is wrong"

    _f3_out=$(
        set +e
        _F3_BLOCK="$_f3_block" bash 2>&1 <<'INNER'
set -euo pipefail
HYSTERIA2_SERVER="edge.example.net:51822"
CHANNELS_FAILED=()
warn() { echo "WARN $*"; }
log()  { :; }
# The render fails, exactly as it does when no endpoint or credentials resolve.
hydrate_render_hy2() {
    warn "  hysteria2-client.yaml render failed — continuing without hy2 channel"
    CHANNELS_FAILED+=("hysteria2-client")
    return 1
}
source "$_F3_BLOCK"
# Reached only if the failed render did NOT kill the script.
echo "SURVIVED failed=${#CHANNELS_FAILED[@]}"
INNER
    ) || true

    if [[ "$_f3_out" != *"SURVIVED"* ]]; then
        fail "F3: a failed hy2 render KILLED hydrate under set -e — compose_strip_failed_channels, the degraded warning and steps 5-7 never run. Got: $_f3_out"
    elif [[ "$_f3_out" != *"failed=1"* ]]; then
        fail "F3: survived but the channel was not recorded in CHANNELS_FAILED — compose strip would be a no-op. Got: $_f3_out"
    else
        pass "F3: a failed hy2 render is fail-soft — hydrate continues with the channel recorded"
    fi
fi
rm -f "$_f3_block"

# ---------------------------------------------------------------------------
# F4 — the lib-not-found fallback must mark the channel failed, not succeed.
#
# hydrate.sh sources lib/hydrate-hy2.sh and, if the file is missing from both
# the local and installed paths, defines a fallback stub. A stub that returns 0
# without appending to CHANNELS_FAILED tells the caller the render succeeded:
# compose_strip_failed_channels then leaves the hysteria2 service in
# docker-compose.yml with a bind mount pointing at a file that was never
# written — which is the exact gap this whole change exists to close.
#
# Delivery manifests make a missing lib unlikely, but "unlikely" and "reports
# success" are different properties, and this is the failure mode with no error.
# Exercise the REAL sourcing block from hydrate.sh with both paths absent.
# ---------------------------------------------------------------------------
_f4_block=$(mktemp)
awk '
    /^_hy2_lib_local=/ { cap=1 }
    cap { print; if ($0 ~ /^fi$/) exit }
' "$REPO_ROOT/hydrate.sh" > "$_f4_block"

if [[ ! -s "$_f4_block" ]]; then
    fail "F4: extraction produced an empty block — the awk pattern no longer matches hydrate.sh"
else
    grep -q 'hydrate_render_hy2' "$_f4_block" \
        || fail "F4: extracted block does not define the fallback — extraction is wrong"

    _f4_out=$(
        set +e
        _F4_BLOCK="$_f4_block" bash 2>&1 <<'INNER'
set -uo pipefail
CHANNELS_FAILED=()
warn() { echo "WARN $*"; }
log()  { :; }
# Point both candidate lib paths at somewhere that cannot contain the lib, so
# the fallback branch is the one that runs.
SCRIPT_DIR="/nonexistent-$$"
PREFIX_SBIN="/nonexistent-$$/sbin"
source "$_F4_BLOCK"
hydrate_render_hy2
rc=$?
echo "rc=$rc failed=${#CHANNELS_FAILED[@]} list=${CHANNELS_FAILED[*]:-none}"
INNER
    ) || true

    if [[ "$_f4_out" != *"rc=1"* ]]; then
        fail "F4: the lib-not-found stub reported SUCCESS — the caller will not strip the service, leaving a bind mount to a file that was never written. Got: $_f4_out"
    elif [[ "$_f4_out" != *"hysteria2-client"* ]]; then
        fail "F4: stub returned non-zero but did not record the channel — compose strip would be a no-op. Got: $_f4_out"
    else
        pass "F4: the lib-not-found fallback marks hy2 failed so the compose strip still runs"
    fi
fi
rm -f "$_f4_block"

if [[ $FAIL -ne 0 ]]; then
    echo "FAIL: hydrate hy2 render behavioural test — one or more checks failed"
    exit 1
fi
echo "PASS: hydrate hy2 render behavioural test — all checks passed"
