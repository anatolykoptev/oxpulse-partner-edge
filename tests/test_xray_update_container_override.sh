#!/bin/bash
# test_xray_update_container_override.sh — verify OXPULSE_XRAY_CONTAINER / OXPULSE_XRAY_IMAGE
# env overrides are respected by oxpulse-xray-update.sh.
set -euo pipefail

SCRIPT="$(dirname "$0")/../scripts/oxpulse-xray-update.sh"
PASS=0; FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# ---------------------------------------------------------------------------
# Shared mock docker — records all invocations, emulates minimal outputs.
# ---------------------------------------------------------------------------
setup_docker_mock() {
    local mock_dir="$1"
    # target_container and target_image are documented for callers' clarity;
    # the mock returns fixed digests regardless of which image/container is queried.
    # shellcheck disable=SC2034
    local target_container="$2"
    # shellcheck disable=SC2034
    local target_image="$3"

    mkdir -p "$mock_dir"
    cat > "$mock_dir/docker" <<MOCK
#!/bin/bash
echo "docker \$*" >> "$mock_dir/calls.log"
cmd="\$1"; shift
case "\$cmd" in
  inspect)
    fmt=""
    for a in "\$@"; do
      case "\$a" in --format*) fmt="\${a#--format=}"; fmt="\${fmt#\'}" ; fmt="\${fmt%\'}" ;; esac
    done
    # First inspect call (running container) → return a digest
    # Second inspect call (image after pull) → return different digest (triggers update)
    case "\$fmt" in
      '{{.Image}}')   echo "sha256:aaa111" ;;
      '{{.Id}}')      echo "sha256:bbb222" ;;
      '{{index .Config.Labels "oxpulse.version"}}') echo "test-ver" ;;
      *) echo "" ;;
    esac
    ;;
  pull) echo "Pulling from $target_image" ;;
  rm)   echo "removed" ;;
  run)  echo "started" ;;
  logs) echo "mock logs" ;;
  *)    echo "" ;;
esac
exit 0
MOCK
    chmod +x "$mock_dir/docker"
}

# ---------------------------------------------------------------------------
# Shared mock ss — always reports port 3080 open so smoke passes.
# ---------------------------------------------------------------------------
setup_ss_mock() {
    local mock_dir="$1"
    cat > "$mock_dir/ss" <<'SSMOCK'
#!/bin/bash
echo "LISTEN 0 128 0.0.0.0:3080 0.0.0.0:*"
SSMOCK
    chmod +x "$mock_dir/ss"
}

# ---------------------------------------------------------------------------
# Test 1: default values — container name must be oxpulse-partner-xray
# ---------------------------------------------------------------------------
t1_dir=$(mktemp -d)
trap 'rm -rf "$t1_dir"' EXIT

setup_docker_mock "$t1_dir" "oxpulse-partner-xray" "ghcr.io/anatolykoptev/partner-edge-xray:stable"
setup_ss_mock "$t1_dir"

# Provide a minimal xray.env so the script doesn't bail on missing env file
echo "" > "$t1_dir/xray.env"

# Run without overrides; redirect LOG to temp file
LOG="$t1_dir/update.log" \
ENV_FILE="$t1_dir/xray.env" \
PATH="$t1_dir:$PATH" \
bash "$SCRIPT" > "$t1_dir/stdout.log" 2>&1 || true

if grep -q "running image:" "$t1_dir/update.log" 2>/dev/null; then
    pass "default: script ran and logged running image"
else
    fail "default: script did not log 'running image:'"
fi

if grep -q "oxpulse-partner-xray" "$t1_dir/calls.log" 2>/dev/null; then
    pass "default: docker called with oxpulse-partner-xray"
else
    fail "default: docker NOT called with oxpulse-partner-xray (calls: $(cat "$t1_dir/calls.log" 2>/dev/null || echo none))"
fi

# ---------------------------------------------------------------------------
# Test 2: env override — OXPULSE_XRAY_CONTAINER=xyz OXPULSE_XRAY_IMAGE=acme/foo:1
# ---------------------------------------------------------------------------
t2_dir=$(mktemp -d)
trap 'rm -rf "$t1_dir" "$t2_dir"' EXIT

setup_docker_mock "$t2_dir" "xyz" "acme/foo:1"
setup_ss_mock "$t2_dir"
echo "" > "$t2_dir/xray.env"

OXPULSE_XRAY_CONTAINER=xyz \
OXPULSE_XRAY_IMAGE=acme/foo:1 \
LOG="$t2_dir/update.log" \
ENV_FILE="$t2_dir/xray.env" \
PATH="$t2_dir:$PATH" \
bash "$SCRIPT" > "$t2_dir/stdout.log" 2>&1 || true

if grep -q "running image:" "$t2_dir/update.log" 2>/dev/null; then
    pass "override: script ran and logged running image"
else
    fail "override: script did not log 'running image:' (log: $(cat "$t2_dir/update.log" 2>/dev/null || echo none))"
fi

if grep -q "xyz" "$t2_dir/calls.log" 2>/dev/null; then
    pass "override: docker called with container name 'xyz'"
else
    fail "override: docker NOT called with 'xyz' (calls: $(cat "$t2_dir/calls.log" 2>/dev/null || echo none))"
fi

if grep -q "acme/foo:1" "$t2_dir/calls.log" 2>/dev/null; then
    pass "override: docker called with image 'acme/foo:1'"
else
    fail "override: docker NOT called with 'acme/foo:1' (calls: $(cat "$t2_dir/calls.log" 2>/dev/null || echo none))"
fi

# ---------------------------------------------------------------------------
# Test 3: env file override — values loaded from xray-update.env
# ---------------------------------------------------------------------------
t3_dir=$(mktemp -d)
trap 'rm -rf "$t1_dir" "$t2_dir" "$t3_dir"' EXIT

setup_docker_mock "$t3_dir" "xray-reality" "teddysun/xray:26.4.25"
setup_ss_mock "$t3_dir"
echo "" > "$t3_dir/xray.env"

# Write the env override file
mkdir -p "$t3_dir/etc-override"
cat > "$t3_dir/etc-override/xray-update.env" <<'EOF'
OXPULSE_XRAY_CONTAINER=xray-reality
OXPULSE_XRAY_IMAGE=teddysun/xray:26.4.25
EOF

XRAY_UPDATE_ENV_FILE="$t3_dir/etc-override/xray-update.env" \
LOG="$t3_dir/update.log" \
ENV_FILE="$t3_dir/xray.env" \
PATH="$t3_dir:$PATH" \
bash "$SCRIPT" > "$t3_dir/stdout.log" 2>&1 || true

if grep -q "xray-reality" "$t3_dir/calls.log" 2>/dev/null; then
    pass "env-file: docker called with 'xray-reality'"
else
    fail "env-file: docker NOT called with 'xray-reality' (calls: $(cat "$t3_dir/calls.log" 2>/dev/null || echo none))"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
