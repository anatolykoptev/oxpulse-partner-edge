#!/usr/bin/env bash
# Unit tests for scripts/read-xhttp.py helper.
#
# Tests:
#   1. All 6 fields present at channels[0].xray.xhttp.* → correct values returned.
#   2. Fields absent from xhttp.* → --default values returned.
#   3. Legacy shape: flat channels[0].xray.mode (no xhttp key) → second-priority path.
#   4. xmux legacy shape: channels[0].xray.xmux (no xhttp.xmux) → second-priority.
#   5. Corrupt JSON → exit 2, stderr contains "cannot parse".
#   6. No channels[] (flat legacy schema) → all defaults returned.
#   7. channels[0].protocol != vless-reality → all defaults returned.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$REPO_ROOT/scripts/read-xhttp.py"

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not installed"; exit 0; }

[[ -f "$HELPER" ]] || { echo "FAIL: $HELPER not found"; exit 1; }
[[ -x "$HELPER" ]] || { echo "FAIL: $HELPER not executable"; exit 1; }

FAIL=0
TMPDIR_TESTS=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TESTS"' EXIT

_assert_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then
        echo "  OK: $label = '$got'"
    else
        echo "FAIL: $label: expected '$want', got '$got'"
        FAIL=1
    fi
}

# ---------------------------------------------------------------------------
# Fixture 1: all 6 fields present at deep channels[0].xray.xhttp.* path
# ---------------------------------------------------------------------------
echo "==> Test 1: all 6 fields present at channels[0].xray.xhttp.*"
FULL_CFG="$TMPDIR_TESTS/full.json"
cat > "$FULL_CFG" << 'EOF'
{
  "node_id": "test-1",
  "channels": [
    {
      "protocol": "vless-reality",
      "host": "192.0.2.1",
      "port": 5349,
      "xray": {
        "uuid": "00000000-0000-4000-8000-000000000001",
        "mode": "stream-one",
        "xhttp": {
          "mode": "packet-up",
          "path": "/custom-path",
          "xmux": {
            "maxConcurrency": 8,
            "cMaxReuseTimes": 128,
            "cMaxLifetimeMs": 30000
          },
          "extra": {
            "xPaddingBytes": "200-2000"
          }
        }
      }
    }
  ]
}
EOF

_assert_eq "mode"             "$("$HELPER" "$FULL_CFG" mode --default stream-one)"             "packet-up"
_assert_eq "path"             "$("$HELPER" "$FULL_CFG" path --default /xh)"                   "/custom-path"
_assert_eq "xmux_concurrency" "$("$HELPER" "$FULL_CFG" xmux_concurrency --default 1 --type int)"  "8"
_assert_eq "xmux_reuse"       "$("$HELPER" "$FULL_CFG" xmux_reuse --default 64 --type int)"       "128"
_assert_eq "xmux_lifetime"    "$("$HELPER" "$FULL_CFG" xmux_lifetime --default 15000 --type int)" "30000"
_assert_eq "padding"          "$("$HELPER" "$FULL_CFG" padding --default 100-1000)"               "200-2000"

# ---------------------------------------------------------------------------
# Fixture 2: xhttp subtree absent → all defaults returned
# ---------------------------------------------------------------------------
echo "==> Test 2: xhttp subtree absent → defaults"
BARE_CFG="$TMPDIR_TESTS/bare.json"
cat > "$BARE_CFG" << 'EOF'
{
  "node_id": "test-2",
  "channels": [
    {
      "protocol": "vless-reality",
      "host": "192.0.2.1",
      "port": 5349,
      "xray": {
        "uuid": "00000000-0000-4000-8000-000000000002"
      }
    }
  ]
}
EOF

_assert_eq "mode default"             "$("$HELPER" "$BARE_CFG" mode --default stream-one)"             "stream-one"
_assert_eq "path default"             "$("$HELPER" "$BARE_CFG" path --default /xh)"                   "/xh"
_assert_eq "xmux_concurrency default" "$("$HELPER" "$BARE_CFG" xmux_concurrency --default 1 --type int)"  "1"
_assert_eq "xmux_reuse default"       "$("$HELPER" "$BARE_CFG" xmux_reuse --default 64 --type int)"       "64"
_assert_eq "xmux_lifetime default"    "$("$HELPER" "$BARE_CFG" xmux_lifetime --default 15000 --type int)" "15000"
_assert_eq "padding default"          "$("$HELPER" "$BARE_CFG" padding --default 100-1000)"               "100-1000"

# ---------------------------------------------------------------------------
# Fixture 3: legacy shape — channels[0].xray.mode set (no xhttp.mode key)
# → second-priority fallback for mode field
# ---------------------------------------------------------------------------
echo "==> Test 3: legacy shape channels[0].xray.mode → second-priority"
LEGACY_CFG="$TMPDIR_TESTS/legacy.json"
cat > "$LEGACY_CFG" << 'EOF'
{
  "node_id": "test-3",
  "channels": [
    {
      "protocol": "vless-reality",
      "host": "192.0.2.1",
      "port": 5349,
      "xray": {
        "uuid": "00000000-0000-4000-8000-000000000003",
        "mode": "stream-up",
        "xmux": {
          "maxConcurrency": 4,
          "cMaxReuseTimes": 32,
          "cMaxLifetimeMs": 8000
        }
      }
    }
  ]
}
EOF

_assert_eq "legacy mode fallback"  "$("$HELPER" "$LEGACY_CFG" mode --default stream-one)"  "stream-up"

# ---------------------------------------------------------------------------
# Fixture 4: xmux at channels[0].xray.xmux (no xhttp.xmux) → second-priority
# ---------------------------------------------------------------------------
echo "==> Test 4: xmux at channels[0].xray.xmux (no xhttp.xmux) → second-priority"

_assert_eq "legacy xmux_concurrency" "$("$HELPER" "$LEGACY_CFG" xmux_concurrency --default 1 --type int)"  "4"
_assert_eq "legacy xmux_reuse"       "$("$HELPER" "$LEGACY_CFG" xmux_reuse --default 64 --type int)"       "32"
_assert_eq "legacy xmux_lifetime"    "$("$HELPER" "$LEGACY_CFG" xmux_lifetime --default 15000 --type int)" "8000"

# ---------------------------------------------------------------------------
# Test 5: corrupt JSON → exit 2, stderr contains "cannot parse"
# ---------------------------------------------------------------------------
echo "==> Test 5: corrupt JSON → exit 2, stderr 'cannot parse'"
CORRUPT="$TMPDIR_TESTS/corrupt.json"
printf '{not valid json' > "$CORRUPT"

EXIT_CODE=0
STDERR_OUT=$("$HELPER" "$CORRUPT" mode --default stream-one 2>&1 1>/dev/null) || EXIT_CODE=$?
_assert_eq "corrupt exit code" "$EXIT_CODE" "2"
if [[ "$STDERR_OUT" == *"cannot parse"* ]]; then
    echo "  OK: stderr contains 'cannot parse'"
else
    echo "FAIL: stderr missing 'cannot parse'; got: $STDERR_OUT"
    FAIL=1
fi

# ---------------------------------------------------------------------------
# Test 6: no channels[] (flat legacy schema) → all defaults
# ---------------------------------------------------------------------------
echo "==> Test 6: no channels[] → all defaults"
FLAT_CFG="$TMPDIR_TESTS/flat.json"
cat > "$FLAT_CFG" << 'EOF'
{
  "node_id": "test-6",
  "reality_uuid": "00000000-0000-4000-8000-000000000006",
  "reality_public_key": "pk6",
  "backend_endpoint": "192.0.2.6:5349"
}
EOF

_assert_eq "no-channels mode default"    "$("$HELPER" "$FLAT_CFG" mode --default stream-one)"             "stream-one"
_assert_eq "no-channels path default"    "$("$HELPER" "$FLAT_CFG" path --default /xh)"                   "/xh"
_assert_eq "no-channels xmux_con"        "$("$HELPER" "$FLAT_CFG" xmux_concurrency --default 1 --type int)"  "1"
_assert_eq "no-channels padding default" "$("$HELPER" "$FLAT_CFG" padding --default 100-1000)"               "100-1000"

# ---------------------------------------------------------------------------
# Test 7: channels[0].protocol != vless-reality → all defaults
# ---------------------------------------------------------------------------
echo "==> Test 7: protocol != vless-reality → all defaults"
OTHER_PROTO="$TMPDIR_TESTS/other-proto.json"
cat > "$OTHER_PROTO" << 'EOF'
{
  "node_id": "test-7",
  "channels": [
    {
      "protocol": "hysteria2",
      "host": "192.0.2.7",
      "port": 443,
      "xray": {
        "xhttp": {
          "mode": "packet-up",
          "path": "/should-not-appear"
        }
      }
    }
  ]
}
EOF

_assert_eq "wrong-proto mode default" "$("$HELPER" "$OTHER_PROTO" mode --default stream-one)"  "stream-one"
_assert_eq "wrong-proto path default" "$("$HELPER" "$OTHER_PROTO" path --default /xh)"         "/xh"

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------
if [[ $FAIL -ne 0 ]]; then
    echo "FAIL: one or more read-xhttp.py tests failed"
    exit 1
fi
echo "PASS: all read-xhttp.py tests passed"
