#!/bin/bash
# Behavioral regression: keys fetch failure must NOT suppress heartbeat POST.
#
# Production incident 2026-05-13: all 3 partner edges firing
# PartnerEdgeStaleHeartbeat >24h. Root cause: keys fetch `|| die` at line
# 67-68 aborted the script via set -euo pipefail BEFORE heartbeat POST
# reached lines 99-103. DNS failure on any partner host caused last_seen_at
# to go stale for 24h+ on EVERY daily run.
#
# Heartbeat is an observability liveness signal — it must survive keys
# fetch failure. Key rotation is best-effort (will retry tomorrow).
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SCRIPT="$REPO_ROOT/oxpulse-partner-edge-refresh.sh"

[[ -f "$SCRIPT" ]] || { echo "FAIL: refresh script not found at $SCRIPT"; exit 1; }

pass() { echo "OK: $*"; }
fail() { echo "FAIL: $*"; exit 1; }

# Helper: create a stub bin dir with essential POSIX utilities.
# mktemp: needed by emit_metric's atomic state/prom-file rewrite (PR review
# MED-4 on #328 — the fixed sink persists cumulative counter state via
# mktemp+mv instead of a naive `>>` append).
make_bin() {
    local dir="$1"
    for cmd in bash sh date printf cat tee cp mv mkdir chmod install sleep \
                sed grep head tail wc stat cut tr expr test mktemp; do
        local loc
        loc=$(command -v "$cmd" 2>/dev/null || true)
        if [[ -n "$loc" ]]; then ln -sf "$loc" "$dir/$cmd"; fi
    done
    cat > "$dir/systemctl" <<'STUB'
#!/bin/sh
exit 0
STUB
    chmod +x "$dir/systemctl"
}

# ── Test 1: keys fetch fails → heartbeat still fires → exit 0 ─────────────────
T1=$(mktemp -d)
trap 'rm -rf "$T1"' EXIT

make_bin "$T1"

# jq stub: real jq required for JSON parsing in heartbeat path
if command -v jq >/dev/null 2>&1; then
    ln -sf "$(command -v jq)" "$T1/jq"
else
    fail "test1 setup: real jq required on test host"
fi

HEARTBEAT_MARKER="$T1/heartbeat_fired"

# curl stub:
#   - GET /api/partner/keys → fail with exit 6 (DNS error)
#   - POST /api/partner/heartbeat → success, write marker file
# Note: stub uses only bash builtins to avoid PATH resolution issues
# with the restricted test PATH where `grep`/`printf` may be stubs.
cat > "$T1/curl" <<CURLSTUB
#!/bin/bash
# Detect heartbeat via bash [[ =~ ]] — no external grep needed
for arg in "\$@"; do
    if [[ "\$arg" == *partner/heartbeat* ]]; then
        echo '{"ok":true}'
        echo '200'
        : > "$HEARTBEAT_MARKER"
        exit 0
    fi
done
# Not heartbeat → simulate DNS failure on keys fetch
echo 'curl: (6) Could not resolve host' >&2
exit 6
CURLSTUB
chmod +x "$T1/curl"

# Minimal node-config.json
mkdir -p "$T1/etc"
printf '{"node_id":"test-node-001"}\n' > "$T1/etc/node-config.json"
mkdir -p "$T1/var"

set +e
PATH="$T1" \
    LOG_FILE="$T1/refresh.log" \
    PARTNER_EDGE_PREFIX_ETC="$T1/etc" \
    PARTNER_EDGE_PREFIX_LIB="$T1/var" \
    OXPULSE_BACKEND_URL="http://broken-dns-hostname.invalid" \
    bash "$SCRIPT" >"$T1/out.txt" 2>&1
EXIT1=$?
set -e

[[ $EXIT1 -eq 0 ]] \
    || fail "test1: script must exit 0 even when keys fetch fails (got exit $EXIT1); output: $(cat "$T1/out.txt")"

[[ -f "$HEARTBEAT_MARKER" ]] \
    || fail "test1: heartbeat curl was never called despite keys fetch failure; output: $(cat "$T1/out.txt")"

pass "test1: keys fetch failure → script exits 0 and heartbeat still fires"

trap - EXIT
rm -rf "$T1"

# ── Test 2: keys fetch fails → textfile counter emitted ───────────────────────
T2=$(mktemp -d)
trap 'rm -rf "$T2"' EXIT

make_bin "$T2"

if command -v jq >/dev/null 2>&1; then
    ln -sf "$(command -v jq)" "$T2/jq"
else
    fail "test2 setup: real jq required on test host"
fi

TEXTFILE_DIR="$T2/textfile"
mkdir -p "$TEXTFILE_DIR"

cat > "$T2/curl" <<CURLSTUB2
#!/bin/bash
for arg in "\$@"; do
    if [[ "\$arg" == *partner/heartbeat* ]]; then
        echo '{"ok":true}'
        echo '200'
        exit 0
    fi
done
echo 'curl: (6) Could not resolve host' >&2
exit 6
CURLSTUB2
chmod +x "$T2/curl"

mkdir -p "$T2/etc"
printf '{"node_id":"test-node-002"}\n' > "$T2/etc/node-config.json"
mkdir -p "$T2/var"

set +e
PATH="$T2" \
    LOG_FILE="$T2/refresh.log" \
    PARTNER_EDGE_PREFIX_ETC="$T2/etc" \
    PARTNER_EDGE_PREFIX_LIB="$T2/var" \
    PARTNER_EDGE_TEXTFILE_DIR="$TEXTFILE_DIR" \
    OXPULSE_BACKEND_URL="http://broken-dns-hostname.invalid" \
    bash "$SCRIPT" >"$T2/out.txt" 2>&1
EXIT2=$?
set -e

[[ $EXIT2 -eq 0 ]] \
    || fail "test2: script must exit 0 when keys fetch fails (got exit $EXIT2)"

PROM_FILE="$TEXTFILE_DIR/partner_edge.prom"
[[ -f "$PROM_FILE" ]] \
    || fail "test2: $PROM_FILE not created after keys fetch failure; output: $(cat "$T2/out.txt")"

grep -q 'partner_edge_keys_fetch_failure_total' "$PROM_FILE" \
    || fail "test2: partner_edge_keys_fetch_failure_total not found in $PROM_FILE; got: $(cat "$PROM_FILE")"

grep -q 'test-node-002' "$PROM_FILE" \
    || fail "test2: partner_id label missing from metric; got: $(cat "$PROM_FILE")"

pass "test2: keys fetch failure → textfile metric partner_edge_keys_fetch_failure_total emitted"

trap - EXIT
rm -rf "$T2"

# ── Test 3: heartbeat fails → textfile counter emitted ───────────────────────
T3=$(mktemp -d)
trap 'rm -rf "$T3"' EXIT

make_bin "$T3"

if command -v jq >/dev/null 2>&1; then
    ln -sf "$(command -v jq)" "$T3/jq"
else
    fail "test3 setup: real jq required on test host"
fi

TEXTFILE_DIR3="$T3/textfile"
mkdir -p "$TEXTFILE_DIR3"

# Keys fetch succeeds, heartbeat returns 500
cat > "$T3/curl" <<CURLSTUB3
#!/bin/bash
for arg in "\$@"; do
    if [[ "\$arg" == *partner/heartbeat* ]]; then
        echo '{"error":"internal"}'
        echo '500'
        exit 0
    fi
done
# Keys endpoint returns minimal valid JSON
echo '{"version":"v1","sfu_signing_public_key":"","channels_version":"c1","reality_public_key":"pk","reality_encryption":"enc","reality_server_names":[]}'
exit 0
CURLSTUB3
chmod +x "$T3/curl"

mkdir -p "$T3/etc"
printf '{"node_id":"test-node-003"}\n' > "$T3/etc/node-config.json"
mkdir -p "$T3/var"
echo "v1" > "$T3/var/keys-version"
echo "c1" > "$T3/var/channels-version"

set +e
PATH="$T3" \
    LOG_FILE="$T3/refresh.log" \
    PARTNER_EDGE_PREFIX_ETC="$T3/etc" \
    PARTNER_EDGE_PREFIX_LIB="$T3/var" \
    PARTNER_EDGE_TEXTFILE_DIR="$TEXTFILE_DIR3" \
    OXPULSE_BACKEND_URL="http://localhost-stub.invalid" \
    bash "$SCRIPT" >"$T3/out.txt" 2>&1
EXIT3=$?
set -e

[[ $EXIT3 -eq 0 ]] \
    || fail "test3: script must exit 0 on heartbeat 500 (got exit $EXIT3); output: $(cat "$T3/out.txt")"

PROM_FILE3="$TEXTFILE_DIR3/partner_edge.prom"
[[ -f "$PROM_FILE3" ]] \
    || fail "test3: $PROM_FILE3 not created after heartbeat 500; output: $(cat "$T3/out.txt")"

grep -q 'partner_edge_heartbeat_failure_total' "$PROM_FILE3" \
    || fail "test3: partner_edge_heartbeat_failure_total not found in $PROM_FILE3; got: $(cat "$PROM_FILE3")"

pass "test3: heartbeat 500 → textfile metric partner_edge_heartbeat_failure_total emitted"

trap - EXIT
rm -rf "$T3"

# ── Syntax check ──────────────────────────────────────────────────────────────
bash -n "$SCRIPT" \
    || fail "refresh script has syntax errors"
pass "syntax check clean"

echo ""
echo "All tests passed."
