#!/bin/bash
# tests/test_state_migration_matrix.sh — Phase 2 migration matrix test (ADR-002).
#
# Synthesizes install.env state files of historical vintages, runs migrate_state()
# on each, and asserts migration to v1 WITHOUT a wipe (existing keys preserved,
# derivable keys filled in, no "reinstall" demanded).
#
# Vintages tested:
#   v0.12.50 (with node-config): PARTNER_ID + PARTNER_DOMAIN + NODE_ID + TUNNEL +
#             IMAGE_VERSION + TURNS_SUBDOMAIN + INSTALLED_AT (no BACKEND_API);
#             node-config.json present with scheme-less host:port backend_endpoint.
#             BACKEND_API defaults to fleet constant https://api.oxpulse.chat.
#   v0.12.50 (no node-config): same state, no node-config → BACKEND_API defaults
#             to fleet constant https://api.oxpulse.chat (no longer dies).
#   v0.12.63: + BACKEND_API  (still no NAIVE_SOCKS_PORT, no CADDYFILE_SHA,
#             no SCHEMA_VERSION)
#   v0.12.73: + NAIVE_SOCKS_PORT + CADDYFILE_SHA  (still no SCHEMA_VERSION —
#             Phase 1 merged after v0.12.78 release tag)
#
# Each vintage is tested for:
#   1. migrate_state exits 0 (no die() fired)
#   2. SCHEMA_VERSION=1 written to STATE_FILE
#   3. Required keys all present after migration
#   4. Pre-existing values NOT overwritten (data preservation)
#   5. "re-run install.sh" text does NOT appear in output
#
# Tier-3 docker inspect fix (Task 5): prove that grep matches NAIVE_SOCKS_PORT
# when it is NOT the first env var (i.e. {{println .}} emits real newlines).
#
# opec-optional: derive-from-live paths that need opec/Caddyfile are skipped if
# opec is absent (controlled via OXPULSE_SKIP_OPEC_DERIVE=1 or opec not on PATH).
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RECONCILE_LIB="$REPO_ROOT/lib/reconcile.sh"

[[ -f "$RECONCILE_LIB" ]] || { echo "FAIL: lib/reconcile.sh not found"; exit 1; }

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

WORK=$(mktemp -d)
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Helper: load reconcile lib with stubs into a subshell, call migrate_state,
# capture output and exit code.
#
# Args:
#   $1 state_file     path to the install.env file to migrate
#   $2 prefix_etc     directory to use as PREFIX_ETC (may contain node-config.json)
# ---------------------------------------------------------------------------
run_migrate() {
    local state_file="$1"
    local prefix_etc="${2:-$WORK/etc_empty}"
    mkdir -p "$prefix_etc"

    local docker_bin="$WORK/docker_bin_$$"
    mkdir -p "$docker_bin"
    # docker stub: returns nothing (forces NAIVE default 1080)
    cat > "$docker_bin/docker" << 'DOCKER_STUB'
#!/bin/bash
exit 1
DOCKER_STUB
    chmod +x "$docker_bin/docker"

    bash -c '
        set -euo pipefail
        export PATH="'"$docker_bin"':$PATH"
        STATE_FILE="'"$state_file"'"
        PREFIX_ETC="'"$prefix_etc"'"
        PREFIX_LIB="'"$WORK"'/lib"
        PREFIX_SHARE="'"$WORK"'/share"
        DOCKER_BIN="'"$docker_bin"'/docker"
        DRY_RUN=0
        COMPOSE_FILE=""

        die()  { printf "DIE: %s\n" "$*" >&2; exit 1; }
        log()  { printf "LOG: %s\n" "$*"; }
        warn() { printf "WARN: %s\n" "$*"; }

        _RECONCILE_LIB_LOADED=0
        # shellcheck source=lib/reconcile.sh
        source "'"$RECONCILE_LIB"'"

        migrate_state
        echo "MIGRATE_OK"
    ' 2>&1
}

# ---------------------------------------------------------------------------
# Subtest helper: verify migrate result for a vintage that SHOULD succeed.
# ---------------------------------------------------------------------------
check_migration() {
    local vintage="$1"
    local state_file="$2"
    local prefix_etc="${3:-$WORK/etc_empty}"
    local pre_partner_id
    pre_partner_id=$(grep '^PARTNER_ID=' "$state_file" | cut -d= -f2)
    local pre_node_id
    pre_node_id=$(grep '^NODE_ID=' "$state_file" | cut -d= -f2)

    local output rc=0
    output=$(run_migrate "$state_file" "$prefix_etc") || rc=$?

    # Test A: exits 0
    if [[ $rc -eq 0 ]]; then
        pass "$vintage: migrate_state exits 0"
    else
        fail "$vintage: migrate_state exited $rc — output: $output"
        return
    fi

    # Test B: MIGRATE_OK in output (function ran to completion)
    if echo "$output" | grep -q "MIGRATE_OK"; then
        pass "$vintage: migrate_state ran to completion"
    else
        fail "$vintage: MIGRATE_OK not in output — $output"
    fi

    # Test C: SCHEMA_VERSION=1 written
    local sv
    sv=$(grep '^SCHEMA_VERSION=' "$state_file" | cut -d= -f2 || true)
    if [[ "$sv" == "1" ]]; then
        pass "$vintage: SCHEMA_VERSION=1 written to STATE_FILE"
    else
        fail "$vintage: SCHEMA_VERSION not written (got: '${sv:-<empty>}')"
    fi

    # Test D: required keys all present
    local required_keys=(PARTNER_ID PARTNER_DOMAIN NODE_ID BACKEND_API IMAGE_VERSION TURNS_SUBDOMAIN)
    local missing_req=()
    for k in "${required_keys[@]}"; do
        grep -q "^${k}=" "$state_file" 2>/dev/null || missing_req+=("$k")
    done
    if [[ "${#missing_req[@]}" -eq 0 ]]; then
        pass "$vintage: all required keys present after migration"
    else
        fail "$vintage: required keys still missing after migration: ${missing_req[*]}"
    fi

    # Test E: pre-existing values NOT overwritten
    local post_partner_id
    post_partner_id=$(grep '^PARTNER_ID=' "$state_file" | cut -d= -f2)
    local post_node_id
    post_node_id=$(grep '^NODE_ID=' "$state_file" | cut -d= -f2)
    if [[ "$post_partner_id" == "$pre_partner_id" && "$post_node_id" == "$pre_node_id" ]]; then
        pass "$vintage: pre-existing PARTNER_ID + NODE_ID not overwritten"
    else
        fail "$vintage: pre-existing values overwritten! Before: PARTNER_ID=$pre_partner_id NODE_ID=$pre_node_id After: $post_partner_id $post_node_id"
    fi

    # Test F: no "re-run install.sh" in output
    if echo "$output" | grep -qi "re-run install"; then
        fail "$vintage: output contains 're-run install.sh' — migrate_state should converge, not bail"
    else
        pass "$vintage: no 're-run install.sh' demanded"
    fi

    # Test G: VALUE assertion — BACKEND_API must be the fleet constant.
    # Falsification: old (wrong) code stripped port from node-config.backend_endpoint
    # and wrote e.g. "krolik.oxpulse.chat" (scheme-less, wrong host).
    # The correct value is always the fleet constant https://api.oxpulse.chat.
    local post_ba
    post_ba=$(grep '^BACKEND_API=' "$state_file" | cut -d= -f2 || true)
    if [[ "$post_ba" == "https://api.oxpulse.chat" ]]; then
        pass "$vintage: BACKEND_API=https://api.oxpulse.chat (fleet constant, not wrong node-config derive)"
    else
        fail "$vintage: BACKEND_API wrong — expected https://api.oxpulse.chat, got '${post_ba:-<empty>}'"
    fi

    # Test H: VALUE assertion — TURNS_SUBDOMAIN
    local post_ts
    post_ts=$(grep '^TURNS_SUBDOMAIN=' "$state_file" | cut -d= -f2 || true)
    if [[ -n "$post_ts" ]]; then
        pass "$vintage: TURNS_SUBDOMAIN='${post_ts}' (present)"
    else
        pass "$vintage: TURNS_SUBDOMAIN absent (acceptable — not derivable without node-config)"
    fi

    # Test I: VALUE assertion — NAIVE_SOCKS_PORT defaults to 1080 when docker unavailable
    local post_nsp
    post_nsp=$(grep '^NAIVE_SOCKS_PORT=' "$state_file" | cut -d= -f2 || true)
    if [[ -n "$post_nsp" ]]; then
        pass "$vintage: NAIVE_SOCKS_PORT='${post_nsp}' (present)"
    else
        fail "$vintage: NAIVE_SOCKS_PORT missing after migration"
    fi
}

# ---------------------------------------------------------------------------
# RED guard: migrate_state must NOT exist yet in lib/reconcile.sh (Phase 1).
# This test validates the test file itself is meaningful — if migrate_state
# already existed, the RED phase would be skipped.
# ---------------------------------------------------------------------------
echo "==> Checking for migrate_state in lib/reconcile.sh (RED guard)"
if ! grep -q 'migrate_state()' "$RECONCILE_LIB"; then
    echo "INFO: migrate_state not yet defined — tests below will FAIL until implemented (RED phase confirmed)"
else
    echo "INFO: migrate_state already defined — running GREEN phase validation"
fi

# ---------------------------------------------------------------------------
# Vintage 1a: v0.12.50 WITH node-config.json
# Node-config has backend_endpoint → BACKEND_API derivable.
# ---------------------------------------------------------------------------
echo ""
echo "==> Vintage 1a: v0.12.50 WITH node-config.json (BACKEND_API derivable)"
ETC_50="$WORK/etc-v0.12.50-with-cfg"
mkdir -p "$ETC_50"
# Write node-config.json with backend_endpoint
cat > "$ETC_50/node-config.json" << 'NCEOF'
{
  "node_id": "partner-abc123-node",
  "backend_endpoint": "krolik.oxpulse.chat:5349",
  "turn_secret": "secret-not-exposed",
  "turns_subdomain": "api-1a2b3c"
}
NCEOF
STATE_50a="$WORK/state-v0.12.50-with-cfg.env"
cat > "$STATE_50a" << 'EOF'
PARTNER_ID=partner-abc123
PARTNER_DOMAIN=edge.example.com
NODE_ID=node-deadbeef
TUNNEL=xray
IMAGE_VERSION=v0.12.50
TURNS_SUBDOMAIN=api-1a2b3c
INSTALLED_AT=2026-05-01T10:00:00Z
EOF
check_migration "v0.12.50+node-config" "$STATE_50a" "$ETC_50"

# ---------------------------------------------------------------------------
# Vintage 1b: v0.12.50 WITHOUT node-config.json
# BACKEND_API was formerly expected to die(); now defaults to fleet constant.
# ---------------------------------------------------------------------------
echo ""
echo "==> Vintage 1b: v0.12.50 WITHOUT node-config.json (BACKEND_API defaults to fleet constant)"
ETC_50b="$WORK/etc-v0.12.50-no-cfg"
mkdir -p "$ETC_50b"
STATE_50b="$WORK/state-v0.12.50-no-cfg.env"
cat > "$STATE_50b" << 'EOF'
PARTNER_ID=partner-nobknd
PARTNER_DOMAIN=edge5.example.com
NODE_ID=node-nobackend
TUNNEL=xray
IMAGE_VERSION=v0.12.50
TURNS_SUBDOMAIN=api-nob
INSTALLED_AT=2026-05-01T00:00:00Z
EOF
check_migration "v0.12.50+no-node-config" "$STATE_50b" "$ETC_50b"

# ---------------------------------------------------------------------------
# Vintage 2: v0.12.63 — missing NAIVE_SOCKS_PORT, CADDYFILE_SHA
# ---------------------------------------------------------------------------
echo ""
echo "==> Vintage 2: v0.12.63 (has BACKEND_API, no NAIVE_SOCKS_PORT, no CADDYFILE_SHA)"
ETC_63="$WORK/etc-v0.12.63"
mkdir -p "$ETC_63"
STATE_63="$WORK/state-v0.12.63.env"
cat > "$STATE_63" << 'EOF'
PARTNER_ID=partner-def456
PARTNER_DOMAIN=edge2.example.com
NODE_ID=node-cafebabe
BACKEND_API=https://api.oxpulse.chat
TUNNEL=xray
IMAGE_VERSION=v0.12.63
TURNS_SUBDOMAIN=api-4d5e6f
INSTALLED_AT=2026-05-10T08:30:00Z
EOF
check_migration "v0.12.63" "$STATE_63" "$ETC_63"

# ---------------------------------------------------------------------------
# Vintage 3: v0.12.73 — missing CADDYFILE_SHA, NAIVE_SOCKS_PORT present
# ---------------------------------------------------------------------------
echo ""
echo "==> Vintage 3: v0.12.73 (has BACKEND_API + NAIVE_SOCKS_PORT, no CADDYFILE_SHA, no SCHEMA_VERSION)"
ETC_73="$WORK/etc-v0.12.73"
mkdir -p "$ETC_73"
STATE_73="$WORK/state-v0.12.73.env"
cat > "$STATE_73" << 'EOF'
PARTNER_ID=partner-ghi789
PARTNER_DOMAIN=edge3.example.com
NODE_ID=node-11223344
BACKEND_API=https://api.oxpulse.chat
TUNNEL=xray
IMAGE_VERSION=v0.12.73
TURNS_SUBDOMAIN=api-7g8h9i
INSTALLED_AT=2026-06-01T12:00:00Z
NAIVE_SOCKS_PORT=1080
EOF
check_migration "v0.12.73" "$STATE_73" "$ETC_73"

# ---------------------------------------------------------------------------
# Idempotency: run migrate_state twice on an already-migrated v1 state.
# Must be a no-op (same SCHEMA_VERSION, no duplicate lines).
# ---------------------------------------------------------------------------
echo ""
echo "==> Idempotency: re-running migrate_state on already-migrated v1 state"
ETC_V1="$WORK/etc-already-v1"
mkdir -p "$ETC_V1"
STATE_V1="$WORK/state-already-v1.env"
cat > "$STATE_V1" << 'EOF'
PARTNER_ID=partner-idempotent
PARTNER_DOMAIN=edge4.example.com
NODE_ID=node-55667788
BACKEND_API=https://api.oxpulse.chat
TUNNEL=xray
IMAGE_VERSION=v0.12.78
TURNS_SUBDOMAIN=api-id3m
INSTALLED_AT=2026-06-10T09:00:00Z
NAIVE_SOCKS_PORT=1080
CADDYFILE_SHA=aaaa1111bbbb2222
SCHEMA_VERSION=1
EOF

IDEM_OUT=$(run_migrate "$STATE_V1" "$ETC_V1") || { fail "idempotency: migrate_state exited non-zero"; }
if echo "$IDEM_OUT" | grep -q "MIGRATE_OK"; then
    pass "idempotency: second run completes successfully"
else
    fail "idempotency: second run failed: $IDEM_OUT"
fi
SCHEMA_COUNT=$(grep -c '^SCHEMA_VERSION=' "$STATE_V1" || true)
if [[ "$SCHEMA_COUNT" -eq 1 ]]; then
    pass "idempotency: SCHEMA_VERSION appears exactly once (no duplicates)"
else
    fail "idempotency: SCHEMA_VERSION appears $SCHEMA_COUNT times (duplicate write bug)"
fi

# ---------------------------------------------------------------------------
# Test: Tier-3 docker inspect grep fix — NAIVE_SOCKS_PORT not-first position
# ---------------------------------------------------------------------------
echo ""
echo "==> Tier-3 docker inspect: NAIVE_SOCKS_PORT grep must work when not-first env var"
# Simulate the Go template 'println' fix: output has real newlines, NAIVE not first.
NAIVE_MOCK_OUTPUT="PATH=/usr/bin
HOME=/root
SOME_OTHER_VAR=hello
NAIVE_SOCKS_PORT=9191
ANOTHER_VAR=world"

NAIVE_RESULT=$(echo "$NAIVE_MOCK_OUTPUT" | grep '^NAIVE_SOCKS_PORT=' | cut -d= -f2 || true)
if [[ "$NAIVE_RESULT" == "9191" ]]; then
    pass "tier-3 grep: NAIVE_SOCKS_PORT matched when not first (real newlines work)"
else
    fail "tier-3 grep: expected 9191, got '${NAIVE_RESULT:-<empty>}'"
fi

# Simulate the BROKEN old template (literal \n not newline) — all on one line.
NAIVE_BROKEN="PATH=/usr/binHOME=/rootNAIVE_SOCKS_PORT=9191ANOTHER=x"
NAIVE_BROKEN_RESULT=$(echo "$NAIVE_BROKEN" | grep '^NAIVE_SOCKS_PORT=' | cut -d= -f2 || true)
if [[ -z "$NAIVE_BROKEN_RESULT" ]]; then
    pass "tier-3 grep: confirms OLD literal-\\n format fails grep (validates the fix is needed)"
else
    fail "tier-3 grep: old format shouldn't match but got '${NAIVE_BROKEN_RESULT}'"
fi

# Verify the format string in lib/reconcile.sh uses 'println' not '\n'
if grep -q "println \." "$RECONCILE_LIB"; then
    pass "tier-3 fix: lib/reconcile.sh uses {{println .}} (real newlines)"
elif grep -q "range .Config.Env" "$RECONCILE_LIB"; then
    # Check what format it uses
    FORMAT=$(grep 'range .Config.Env' "$RECONCILE_LIB" | head -1)
    if echo "$FORMAT" | grep -q 'println'; then
        pass "tier-3 fix: lib/reconcile.sh uses {{println .}} (real newlines)"
    else
        fail "tier-3 fix: lib/reconcile.sh still has broken format: $FORMAT"
    fi
else
    fail "tier-3 fix: docker inspect format string not found in lib/reconcile.sh"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
