#!/usr/bin/env bash
# tests/test_channels_health_ch0_skip.sh — the naive/ch0 channel must hit the
# honest "not yet wired on edge — skipping" branch, not the "unknown channel"
# catch-all.
#
# RCA (T15, wiring_dark/high/certain): install.sh's PROTOCOL_ID_MAP defaults
# unmapped protocols (incl. naive) to id="ch0" (install.sh:~875-893), and the
# ch0/naive channel container ships on the edge (COMPOSE_PROFILES_EXTRA ch5,
# install.sh:1385). But the health-report dispatcher's ch5*|ch6*) skip case
# never matched ch0 — it fell to the `*)` catch-all and logged "unknown
# channel — skipping", which reads as a misroute/config error rather than a
# deployed-but-unprobed channel. No probe_ch0/probe_naive exists anywhere
# (grep -rn 'probe_ch5|probe_naive|probe_ch0' == 0) — the real probe is
# Escalation #3. This test locks in the honest-skip routing only.
#
# Does NOT require bats — same pass/fail/ok/fail pattern as
# test_channels_health_report.sh (plain bash, no external test runner).
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SCRIPT="$REPO_ROOT/oxpulse-channels-health-report.sh"

[[ -f "$SCRIPT" ]] || { echo "FAIL: reporter script not found at $SCRIPT"; exit 1; }

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
    printf '#!/bin/sh\nprintf "200"\nexit 0\n' > "$dir/curl"; chmod +x "$dir/curl"
    cat > "$dir/systemctl" <<'STUB'
#!/bin/sh
exit 0
STUB
    chmod +x "$dir/systemctl"
    cat > "$dir/docker" <<'STUB'
#!/bin/bash
if [[ "$*" == *"ss -ltn"* ]]; then
    echo "LISTEN 0 128 0.0.0.0:3080 0.0.0.0:*"
    exit 0
fi
exit 1
STUB
    chmod +x "$dir/docker"
}

# ---------- helper: minimal node-config.json ----------
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

echo "test_channels_health_ch0_skip.sh"
echo

# ── Test 1 (RED/repro): id=ch0 alone → honest "not yet wired" skip, ─────────
#    NOT the "unknown channel" catch-all.
T1=$(mktemp -d)
trap 'rm -rf "$T1"' EXIT

make_bin "$T1"
mkdir -p "$T1/etc"
write_node_config "$T1/etc" '{"id":"ch0"}'

set +e
STDERR1=$(PATH="$T1:/usr/bin:/bin" \
    _NODE_CONFIG="$T1/etc/node-config.json" \
    _TOKEN_LIB=/nonexistent \
    OXPULSE_SERVICE_TOKEN="stkn_test" \
    bash "$SCRIPT" --dry-run 2>&1 >/dev/null)
set -e

if printf '%s\n' "$STDERR1" | grep -q 'ch0 not yet wired on edge — skipping'; then
    ok "test1: id=ch0 → honest 'not yet wired' skip"
else
    fail "test1: expected 'ch0 not yet wired on edge — skipping'; got: $STDERR1"
fi

if printf '%s\n' "$STDERR1" | grep -qi "unknown channel"; then
    fail "test1: id=ch0 must NOT hit the 'unknown channel' catch-all"
else
    ok "test1: id=ch0 does not hit the 'unknown channel' catch-all"
fi

trap - EXIT
rm -rf "$T1"

# ── Test 2: id=naive (literal alias, defensive) → same honest skip ─────────
T2=$(mktemp -d)
trap 'rm -rf "$T2"' EXIT

make_bin "$T2"
mkdir -p "$T2/etc"
write_node_config "$T2/etc" '{"id":"naive"}'

set +e
STDERR2=$(PATH="$T2:/usr/bin:/bin" \
    _NODE_CONFIG="$T2/etc/node-config.json" \
    _TOKEN_LIB=/nonexistent \
    OXPULSE_SERVICE_TOKEN="stkn_test" \
    bash "$SCRIPT" --dry-run 2>&1 >/dev/null)
set -e

if printf '%s\n' "$STDERR2" | grep -q 'naive not yet wired on edge — skipping'; then
    ok "test2: id=naive → honest 'not yet wired' skip"
else
    fail "test2: expected 'naive not yet wired on edge — skipping'; got: $STDERR2"
fi

if printf '%s\n' "$STDERR2" | grep -qi "unknown channel"; then
    fail "test2: id=naive must NOT hit the 'unknown channel' catch-all"
else
    ok "test2: id=naive does not hit the 'unknown channel' catch-all"
fi

trap - EXIT
rm -rf "$T2"

# ── Test 3: no regression — ch1-ch4 still probed, ch0 present alongside ────
#    them is skipped and produces no JSON payload of its own.
T3=$(mktemp -d)
trap 'rm -rf "$T3"' EXIT

make_bin "$T3"
mkdir -p "$T3/etc"
write_node_config "$T3/etc" '{"id":"ch1"},{"id":"ch2"},{"id":"ch3"},{"id":"ch0"}'

set +e
OUTPUT3=$(PATH="$T3:/usr/bin:/bin" \
    _NODE_CONFIG="$T3/etc/node-config.json" \
    _TOKEN_LIB=/nonexistent \
    OXPULSE_SERVICE_TOKEN="stkn_test" \
    bash "$SCRIPT" --dry-run 2>/dev/null)
set -e

COUNT3=$(printf '%s\n' "$OUTPUT3" | grep -c '"channel_name"' 2>/dev/null || echo 0)
if [[ "$COUNT3" -eq 3 ]]; then
    ok "test3: ch1/ch2/ch3 still probed (3 entries), ch0 contributes no payload"
else
    fail "test3: expected 3 channel entries (ch1/ch2/ch3), got $COUNT3; output: $OUTPUT3"
fi

if printf '%s\n' "$OUTPUT3" | grep -qE '"channel_name":"ch0"'; then
    fail "test3: ch0 must not appear in JSON output (no probe exists yet)"
else
    ok "test3: ch0 correctly absent from JSON output"
fi

trap - EXIT
rm -rf "$T3"

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
