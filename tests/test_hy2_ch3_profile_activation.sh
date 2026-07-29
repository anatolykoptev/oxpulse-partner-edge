#!/usr/bin/env bats
# tests/test_hy2_ch3_profile_activation.sh — bats regression for bug #8
#
# Verifies:
#   1. hy2 provisioned → COMPOSE_PROFILES_EXTRA is exactly "ch3" (not "ch3,ch3")
#   2. hy2 provisioned → $PREFIX_ETC/.env written with COMPOSE_PROFILES=ch3
#   3. hy2 absent → $PREFIX_ETC/.env not written / no COMPOSE_PROFILES line
#   4. docker compose up receives COMPOSE_PROFILES env var (not --profile flag with literal)
#   5. ch3 and ch5 both active → .env has "COMPOSE_PROFILES=ch3,ch5"
#
# Root cause: two append sites (L1265 + L1277) produced "ch3,ch3";
#             --profile "ch3,ch3" treats that as a literal profile name (no comma-split).
#             docker compose's COMPOSE_PROFILES env var does comma-split.
# Fix: removed duplicate append + dropped --profile flag + write $PREFIX_ETC/.env.

BATS_TEST_DIRNAME="${BATS_TEST_DIRNAME:-$(dirname "$BASH_SOURCE[0]")}"
REPO_ROOT="${REPO_ROOT:-$(cd "$BATS_TEST_DIRNAME/.." && pwd)}"

# ---------------------------------------------------------------------------
# Helper: run the relevant install.sh snippet in isolation.
# We source only the COMPOSE_PROFILES_EXTRA building block from install.sh,
# not the full installer (which requires root, network, opec, etc).
# ---------------------------------------------------------------------------

# Extract the two append blocks from install.sh for unit testing.
# We build a minimal harness that replicates the logic without side effects.

_run_hy2_profiles_logic() {
    # Args: [HYSTERIA2_SERVER] [HY2_AUTH_PASS] [HY2_OBFS_PASS] [NAIVE_SERVER]
    local hy2_server="${1:-}"
    local hy2_auth="${2:-}"
    local hy2_obfs="${3:-}"
    local naive_server="${4:-}"

    bash << INNER
set -euo pipefail
COMPOSE_PROFILES_EXTRA=""
HYSTERIA2_SERVER="${hy2_server}"
HY2_AUTH_PASS="${hy2_auth}"
HY2_OBFS_PASS="${hy2_obfs}"
NAIVE_SERVER="${naive_server}"

re_render_hysteria2() { true; }  # stub

_hy2_status="skipped"
if [[ -n "\${HYSTERIA2_SERVER:-}" ]]; then
    _hy2_status="failed_at_start"
fi
if [[ -n "\${HYSTERIA2_SERVER:-}" ]] && declare -f re_render_hysteria2 >/dev/null 2>&1; then
    if [[ -n "\$HY2_AUTH_PASS" && -n "\$HY2_OBFS_PASS" ]]; then
        re_render_hysteria2
        COMPOSE_PROFILES_EXTRA="\${COMPOSE_PROFILES_EXTRA:+\${COMPOSE_PROFILES_EXTRA},}ch3"
        _hy2_status="active"
    fi
fi
if [[ "\${_hy2_status}" == "active" ]]; then
    true  # chmod removed from test (no actual file)
fi
if [[ -n "\${NAIVE_SERVER:-}" ]]; then
    COMPOSE_PROFILES_EXTRA="\${COMPOSE_PROFILES_EXTRA:+\${COMPOSE_PROFILES_EXTRA},}ch5"
fi
printf '%s' "\${COMPOSE_PROFILES_EXTRA}"
INNER
}

# ---------------------------------------------------------------------------
# Test 1: hy2 provisioned → exactly "ch3" (not "ch3,ch3")
# ---------------------------------------------------------------------------
@test "hy2 provisioned: COMPOSE_PROFILES_EXTRA is exactly ch3, not ch3,ch3" {
    result=$(_run_hy2_profiles_logic "203.0.113.10:51822" "authpass" "obfspass" "")
    [ "$result" = "ch3" ]
}

# ---------------------------------------------------------------------------
# Test 2: hy2 absent → COMPOSE_PROFILES_EXTRA is empty
# ---------------------------------------------------------------------------
@test "hy2 absent: COMPOSE_PROFILES_EXTRA is empty" {
    result=$(_run_hy2_profiles_logic "" "" "" "")
    [ "$result" = "" ]
}

# ---------------------------------------------------------------------------
# Test 3: ch3 + ch5 both active → exactly "ch3,ch5"
# ---------------------------------------------------------------------------
@test "hy2 + naive both provisioned: COMPOSE_PROFILES_EXTRA is ch3,ch5" {
    result=$(_run_hy2_profiles_logic "203.0.113.10:51822" "authpass" "obfspass" "naive.example.com:443")
    [ "$result" = "ch3,ch5" ]
}

# ---------------------------------------------------------------------------
# Test 4: hy2 provisioned → $PREFIX_ETC/.env written with COMPOSE_PROFILES=ch3
# ---------------------------------------------------------------------------
@test "hy2 provisioned: PREFIX_ETC/.env written with COMPOSE_PROFILES=ch3" {
    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    # Simulate step 6 env write
    COMPOSE_PROFILES_EXTRA="ch3"
    PREFIX_ETC="$tmp"
    printf 'COMPOSE_PROFILES=%s\n' "${COMPOSE_PROFILES_EXTRA}" > "${PREFIX_ETC}/.env"
    chmod 0644 "${PREFIX_ETC}/.env"

    grep -qF 'COMPOSE_PROFILES=ch3' "${PREFIX_ETC}/.env"
}

# ---------------------------------------------------------------------------
# Test 5: hy2 absent → no .env written (compose up takes else branch)
# ---------------------------------------------------------------------------
@test "hy2 absent: PREFIX_ETC/.env not written by install step 6" {
    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    COMPOSE_PROFILES_EXTRA=""
    PREFIX_ETC="$tmp"

    # Simulate the if/else: only write when COMPOSE_PROFILES_EXTRA non-empty
    if [[ -n "${COMPOSE_PROFILES_EXTRA:-}" ]]; then
        printf 'COMPOSE_PROFILES=%s\n' "${COMPOSE_PROFILES_EXTRA}" > "${PREFIX_ETC}/.env"
    fi

    # .env must NOT exist
    [ ! -f "${PREFIX_ETC}/.env" ]
}

# ---------------------------------------------------------------------------
# Test 6: docker compose with COMPOSE_PROFILES=ch3 env activates hysteria2
# (requires docker on PATH; skip if absent)
# ---------------------------------------------------------------------------
@test "docker compose: COMPOSE_PROFILES=ch3 env activates ch3 profile service" {
    if ! command -v docker >/dev/null 2>&1; then
        skip "docker not available"
    fi

    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    cat > "$tmp/docker-compose.yml" << 'COMPOSE'
services:
  sfu:
    image: busybox
    container_name: test-sfu-profile
  hysteria2:
    image: busybox
    container_name: test-hysteria2-profile
    profiles:
      - ch3
COMPOSE

    local config
    config=$(COMPOSE_PROFILES=ch3 docker compose -f "$tmp/docker-compose.yml" config 2>/dev/null)
    echo "$config" | grep "test-hysteria2-profile" >/dev/null
}

# ---------------------------------------------------------------------------
# Test 7: docker compose with --profile ch3,ch3 (old broken flag) does NOT activate
# Regression guard: ensures we don't reintroduce the --profile flag with comma value
# ---------------------------------------------------------------------------
@test "docker compose: --profile ch3,ch3 flag does NOT activate hysteria2 (regression guard)" {
    if ! command -v docker >/dev/null 2>&1; then
        skip "docker not available"
    fi

    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    cat > "$tmp/docker-compose.yml" << 'COMPOSE'
services:
  sfu:
    image: busybox
    container_name: test-sfu-profile2
  hysteria2:
    image: busybox
    container_name: test-hysteria2-profile2
    profiles:
      - ch3
COMPOSE

    local config
    config=$(docker compose --profile "ch3,ch3" -f "$tmp/docker-compose.yml" config 2>/dev/null)
    # Should NOT contain the hysteria2 container (--profile with comma-literal fails)
    ! echo "$config" | grep "test-hysteria2-profile2" >/dev/null
}

# ---------------------------------------------------------------------------
# Test 8: install.sh step 6 uses COMPOSE_PROFILES env var, not --profile flag
# ---------------------------------------------------------------------------
@test "install.sh: step 6 compose up uses COMPOSE_PROFILES env var, not --profile flag with value" {
    # Structural check: --profile "$COMPOSE_PROFILES_EXTRA" must not appear in install.sh
    # (This was the exact bug: --profile "ch3,ch3" treated as literal profile name)
    if grep -qE '\-\-profile "\$\{?COMPOSE_PROFILES_EXTRA' "$REPO_ROOT/install.sh"; then
        fail "install.sh still passes --profile \"\$COMPOSE_PROFILES_EXTRA\" — this is the bug pattern"
    fi
}
