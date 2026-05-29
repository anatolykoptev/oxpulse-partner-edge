#!/usr/bin/env bash
# tests/test_channels_health_installer_version_body.sh
#
# Verifies that oxpulse-channels-health-report.sh includes installer_version
# in the --dry-run JSON payload when a VERSION file is present, and omits it
# when the file is absent or empty.
#
# Test method: behavioral (runs the script with --dry-run and stubs).
# Follows the exact pattern established in test_channels_health_report.sh.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SCRIPT="$REPO_ROOT/oxpulse-channels-health-report.sh"

[[ -f "$SCRIPT" ]] || { echo "FAIL: reporter script not found at $SCRIPT"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

PASS=0
FAIL=0

ok()   { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# ---------- helper: create stub bin dir ----------
make_bin() {
    local dir="$1"
    for cmd in bash sh date printf cat tee cp mv mkdir chmod install sleep \
                sed grep head tail wc stat cut tr expr test awk dirname realpath; do
        local loc
        loc=$(command -v "$cmd" 2>/dev/null || true)
        [[ -n "$loc" ]] && ln -sf "$loc" "$dir/$cmd"
    done
    printf '#!/bin/sh\nexit 0\n' > "$dir/ping"; chmod +x "$dir/ping"
    printf '#!/bin/sh\nexit 0\n' > "$dir/nc";   chmod +x "$dir/nc"
    if command -v jq >/dev/null 2>&1; then
        ln -sf "$(command -v jq)" "$dir/jq"
    fi
    if command -v openssl >/dev/null 2>&1; then
        ln -sf "$(command -v openssl)" "$dir/openssl"
    fi
    # curl stub: no-op (dry-run never calls it)
    printf '#!/bin/sh\nprintf "200"\nexit 0\n' > "$dir/curl"; chmod +x "$dir/curl"
    cat > "$dir/systemctl" <<'STUB'
#!/bin/sh
exit 0
STUB
    chmod +x "$dir/systemctl"
}

write_node_config() {
    local dir="$1"; shift
    local channels="${1:-}"
    local cfg
    if [[ -n "$channels" ]]; then
        cfg=$(printf '{"node_id":"test-node","channels":[%s]}' "$channels")
    else
        cfg='{"node_id":"test-node","channels":[]}'
    fi
    printf '%s\n' "$cfg" > "$dir/node-config.json"
}

echo "test_channels_health_installer_version_body.sh"
echo

# ── Test 1: VERSION file present → installer_version in JSON payload ──────────
T1=$(mktemp -d)
trap 'rm -rf "$T1"' EXIT

make_bin "$T1"
mkdir -p "$T1/etc"
write_node_config "$T1/etc" '{"id":"ch1"}'

# Create VERSION file in standard install path
VERSION_DIR="$T1/share"
mkdir -p "$VERSION_DIR"
printf '0.12.72  # x-release-please-version\n' > "$VERSION_DIR/VERSION"

# docker stub: xray ss -ltn succeeds
cat > "$T1/docker" <<'STUB'
#!/bin/bash
if [[ "$*" == *"ss -ltn"* ]]; then
    echo "LISTEN 0 128 0.0.0.0:3080 0.0.0.0:*"
    exit 0
fi
exit 1
STUB
chmod +x "$T1/docker"

set +e
OUTPUT1=$(PATH="$T1:/usr/bin:/bin" \
    _NODE_CONFIG="$T1/etc/node-config.json" \
    _TOKEN_LIB=/nonexistent \
    OXPULSE_SERVICE_TOKEN="stkn_test" \
    _VERSION_FILE="$VERSION_DIR/VERSION" \
    bash "$SCRIPT" --dry-run 2>/dev/null)
EXIT1=$?
set -e

if printf '%s\n' "$OUTPUT1" | jq -e 'select(.installer_version == "0.12.72")' >/dev/null 2>&1; then
    ok "test1: installer_version=0.12.72 in JSON when VERSION file present"
else
    fail "test1: installer_version missing or wrong; output: $OUTPUT1"
fi

trap - EXIT
rm -rf "$T1"

# ── Test 2: VERSION file absent → no installer_version field in payload ────────
T2=$(mktemp -d)
trap 'rm -rf "$T2"' EXIT

make_bin "$T2"
mkdir -p "$T2/etc"
write_node_config "$T2/etc" '{"id":"ch1"}'

cat > "$T2/docker" <<'STUB'
#!/bin/bash
if [[ "$*" == *"ss -ltn"* ]]; then
    echo "LISTEN 0 128 0.0.0.0:3080 0.0.0.0:*"
    exit 0
fi
exit 1
STUB
chmod +x "$T2/docker"

set +e
OUTPUT2=$(PATH="$T2:/usr/bin:/bin" \
    _NODE_CONFIG="$T2/etc/node-config.json" \
    _TOKEN_LIB=/nonexistent \
    OXPULSE_SERVICE_TOKEN="stkn_test" \
    _VERSION_FILE="/nonexistent/VERSION" \
    bash "$SCRIPT" --dry-run 2>/dev/null)
EXIT2=$?
set -e

if printf '%s\n' "$OUTPUT2" | jq -e 'has("installer_version") | not' >/dev/null 2>&1; then
    ok "test2: installer_version absent from JSON when VERSION file missing"
else
    fail "test2: installer_version should be absent when VERSION file missing; output: $OUTPUT2"
fi

trap - EXIT
rm -rf "$T2"

# ── Test 3: OXPULSE_INSTALLER_VERSION env override takes precedence ────────────
T3=$(mktemp -d)
trap 'rm -rf "$T3"' EXIT

make_bin "$T3"
mkdir -p "$T3/etc"
write_node_config "$T3/etc" '{"id":"ch1"}'

# VERSION file has one version, env override has another
VERSION_DIR3="$T3/share"
mkdir -p "$VERSION_DIR3"
printf '0.12.50  # x-release-please-version\n' > "$VERSION_DIR3/VERSION"

cat > "$T3/docker" <<'STUB'
#!/bin/bash
if [[ "$*" == *"ss -ltn"* ]]; then
    echo "LISTEN 0 128 0.0.0.0:3080 0.0.0.0:*"
    exit 0
fi
exit 1
STUB
chmod +x "$T3/docker"

set +e
OUTPUT3=$(PATH="$T3:/usr/bin:/bin" \
    _NODE_CONFIG="$T3/etc/node-config.json" \
    _TOKEN_LIB=/nonexistent \
    OXPULSE_SERVICE_TOKEN="stkn_test" \
    _VERSION_FILE="$VERSION_DIR3/VERSION" \
    OXPULSE_INSTALLER_VERSION="0.12.99-override" \
    bash "$SCRIPT" --dry-run 2>/dev/null)
EXIT3=$?
set -e

if printf '%s\n' "$OUTPUT3" | jq -e 'select(.installer_version == "0.12.99-override")' >/dev/null 2>&1; then
    ok "test3: OXPULSE_INSTALLER_VERSION env override takes precedence over VERSION file"
else
    fail "test3: expected installer_version=0.12.99-override; output: $OUTPUT3"
fi

trap - EXIT
rm -rf "$T3"

# ── Test 4: empty VERSION file → installer_version absent ────────────────────
T4=$(mktemp -d)
trap 'rm -rf "$T4"' EXIT

make_bin "$T4"
mkdir -p "$T4/etc"
write_node_config "$T4/etc" '{"id":"ch1"}'

VERSION_DIR4="$T4/share"
mkdir -p "$VERSION_DIR4"
# Empty VERSION file
printf '' > "$VERSION_DIR4/VERSION"

cat > "$T4/docker" <<'STUB'
#!/bin/bash
if [[ "$*" == *"ss -ltn"* ]]; then
    echo "LISTEN 0 128 0.0.0.0:3080 0.0.0.0:*"
    exit 0
fi
exit 1
STUB
chmod +x "$T4/docker"

set +e
OUTPUT4=$(PATH="$T4:/usr/bin:/bin" \
    _NODE_CONFIG="$T4/etc/node-config.json" \
    _TOKEN_LIB=/nonexistent \
    OXPULSE_SERVICE_TOKEN="stkn_test" \
    _VERSION_FILE="$VERSION_DIR4/VERSION" \
    bash "$SCRIPT" --dry-run 2>/dev/null)
EXIT4=$?
set -e

if printf '%s\n' "$OUTPUT4" | jq -e 'has("installer_version") | not' >/dev/null 2>&1; then
    ok "test4: installer_version absent from JSON when VERSION file is empty"
else
    fail "test4: installer_version should be absent with empty VERSION file; output: $OUTPUT4"
fi

trap - EXIT
rm -rf "$T4"

# ── Test 5: version with comment stripped to semver only ──────────────────────
# VERSION file: "0.12.72  # x-release-please-version"
# Payload should have "0.12.72", not the full line with comment.
T5=$(mktemp -d)
trap 'rm -rf "$T5"' EXIT

make_bin "$T5"
mkdir -p "$T5/etc"
write_node_config "$T5/etc" '{"id":"ch1"}'

VERSION_DIR5="$T5/share"
mkdir -p "$VERSION_DIR5"
printf '0.12.72  # x-release-please-version\n' > "$VERSION_DIR5/VERSION"

cat > "$T5/docker" <<'STUB'
#!/bin/bash
if [[ "$*" == *"ss -ltn"* ]]; then
    echo "LISTEN 0 128 0.0.0.0:3080 0.0.0.0:*"
    exit 0
fi
exit 1
STUB
chmod +x "$T5/docker"

set +e
OUTPUT5=$(PATH="$T5:/usr/bin:/bin" \
    _NODE_CONFIG="$T5/etc/node-config.json" \
    _TOKEN_LIB=/nonexistent \
    OXPULSE_SERVICE_TOKEN="stkn_test" \
    _VERSION_FILE="$VERSION_DIR5/VERSION" \
    bash "$SCRIPT" --dry-run 2>/dev/null)
EXIT5=$?
set -e

GOT_VER=$(printf '%s\n' "$OUTPUT5" | jq -r 'select(has("installer_version")) | .installer_version' 2>/dev/null | head -1)
if [[ "$GOT_VER" == "0.12.72" ]]; then
    ok "test5: installer_version is bare semver '0.12.72' (comment stripped by awk)"
else
    fail "test5: expected installer_version='0.12.72', got='$GOT_VER'; output: $OUTPUT5"
fi

trap - EXIT
rm -rf "$T5"

# ---------- syntax check ----------
bash -n "$SCRIPT" && ok "syntax check: oxpulse-channels-health-report.sh"

echo
if [[ "$FAIL" -eq 0 ]]; then
    echo "PASS: all $PASS checks passed"
    exit 0
else
    echo "FAIL: $FAIL check(s) failed ($PASS passed)"
    exit 1
fi
