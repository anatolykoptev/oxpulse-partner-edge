#!/bin/bash
# tests/test_refresh_metric_sink_gauge_atomic.sh — P1 of the 2026-07-08
# refresh-lib-extraction-strangler plan: emit_gauge / _emit_prom_gauge_file
# (lib/metric-sink-lib.sh) must be ATOMIC, and observably IDENTICAL in output
# format to the pre-extraction non-atomic emit_gauge on the happy path.
#
# Pre-extraction, oxpulse-partner-edge-refresh.sh's emit_gauge wrote via a
# plain `printf ... > "$prom_file"` — no tmp+mv. A write failure mid-persist
# (disk full, quota, permission) would leave the gauge file truncated or
# half-written, which node_exporter's textfile collector treats as a parse
# error and drops. The architecture council (ADR-7) required the extracted
# emit_gauge to close that gap by adopting lib/reconcile.sh's
# `_reconcile_emit_prom_gauge` atomic tmp+mv shape.
#
# Test 1: happy-path output is BYTE-FOR-BYTE identical to the old emit_gauge's
#         `# TYPE %s gauge\n%s{%s} %s\n` format.
# Test 2: a forced write failure (textfile dir made read-only, so creating the
#         `.tmp.$$` sibling fails) must leave a pre-existing gauge file
#         byte-for-byte UNCHANGED — the atomicity proof. Mirrors the pattern
#         in tests/test_refresh_sfu_key_apply.sh's C13 (forced mktemp failure
#         leaves sfu-keys.env untouched).
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LIB="$REPO_ROOT/lib/metric-sink-lib.sh"

[[ -f "$LIB" ]] || { echo "FAIL: $LIB not found"; exit 1; }

pass() { echo "OK: $*"; }
fail() { echo "FAIL: $*"; exit 1; }

# shellcheck source=lib/metric-sink-lib.sh
source "$LIB"

# ── Test 1: happy-path format is byte-for-byte identical to the pre-extraction
#    non-atomic emit_gauge ────────────────────────────────────────────────────
T1=$(mktemp -d)
trap 'rm -rf "$T1"' EXIT

PARTNER_EDGE_TEXTFILE_DIR="$T1" emit_gauge partner_edge_sfu_pubkey_applied 'partner_id="node-a"' "1"

GAUGE_FILE="$T1/partner_edge_sfu_pubkey_applied.prom"
[[ -f "$GAUGE_FILE" ]] || fail "test1: $GAUGE_FILE not created by emit_gauge"

EXPECTED=$'# TYPE partner_edge_sfu_pubkey_applied gauge\npartner_edge_sfu_pubkey_applied{partner_id="node-a"} 1'
ACTUAL=$(cat "$GAUGE_FILE")
[[ "$ACTUAL" == "$EXPECTED" ]] \
    || fail "test1: gauge output does not match the old emit_gauge's exact '# TYPE %s gauge\\n%s{%s} %s\\n' format; got: $(cat "$GAUGE_FILE")"

pass "test1: emit_gauge happy-path output is byte-for-byte identical to the pre-extraction '# TYPE %s gauge\\n%s{%s} %s\\n' format"

trap - EXIT
rm -rf "$T1"

# ── Test 2: forced write failure leaves a pre-existing gauge file untouched ──
T2=$(mktemp -d)
trap 'chmod u+w "$T2" 2>/dev/null || true; rm -rf "$T2"' EXIT

BEFORE_CONTENT=$'# TYPE partner_edge_sfu_pubkey_applied gauge\npartner_edge_sfu_pubkey_applied{partner_id="node-a"} 1\n'
printf '%s' "$BEFORE_CONTENT" > "$T2/partner_edge_sfu_pubkey_applied.prom"
BEFORE_SHA=$(sha256sum "$T2/partner_edge_sfu_pubkey_applied.prom" | awk '{print $1}')

# Deterministic stand-in for disk-full/permission/quota mid-write: strip the
# directory's write bit so creating the "${_f}.tmp.$$" sibling fails. The
# real writer runs as a non-root user in this test harness (verified: tests
# must not run as root — root ignores directory write-bit denial), so this
# reliably fails the create.
if [[ "$(id -u)" -eq 0 ]]; then
    fail "test2 setup: this test must not run as root (chmod-based write-denial is a no-op for root)"
fi
chmod 0555 "$T2"

PARTNER_EDGE_TEXTFILE_DIR="$T2" emit_gauge partner_edge_sfu_pubkey_applied 'partner_id="node-a"' "0" \
    || fail "test2: emit_gauge must not propagate a write failure to the caller (non-fatal contract)"

chmod u+w "$T2"

AFTER_SHA=$(sha256sum "$T2/partner_edge_sfu_pubkey_applied.prom" | awk '{print $1}')
[[ "$AFTER_SHA" == "$BEFORE_SHA" ]] \
    || fail "test2: gauge file content CHANGED despite a forced write failure — the write is not atomic (tmp+mv), a mid-write failure can leave a truncated/wrong file; before=$BEFORE_SHA after=$AFTER_SHA"

# No stray tmp file left behind (the tmp+mv contract cleans up on failure).
STRAY_TMP=$(find "$T2" -maxdepth 1 -name '*.tmp.*' 2>/dev/null)
[[ -z "$STRAY_TMP" ]] \
    || fail "test2: stray tmp file left behind after a forced write failure: $STRAY_TMP"

pass "test2: a forced write failure (read-only textfile dir) leaves the pre-existing gauge file byte-for-byte unchanged (atomic tmp+mv), no stray tmp file"

trap - EXIT
chmod u+w "$T2" 2>/dev/null || true
rm -rf "$T2"

# ── Test 3: _emit_prom_gauge_file's own-file-per-gauge naming matches
#    emit_gauge's basename=NAME.prom convention (the "thin wrapper" contract)
T3=$(mktemp -d)
trap 'rm -rf "$T3"' EXIT

PARTNER_EDGE_TEXTFILE_DIR="$T3" _emit_prom_gauge_file "partner_edge_sfu_pubkey_applied.prom" \
    partner_edge_sfu_pubkey_applied "1" 'partner_id="node-b"'
PARTNER_EDGE_TEXTFILE_DIR="$T3" emit_gauge partner_edge_other_gauge 'partner_id="node-b"' "1"

[[ -f "$T3/partner_edge_sfu_pubkey_applied.prom" ]] \
    || fail "test3: _emit_prom_gauge_file did not write to the expected basename"
[[ -f "$T3/partner_edge_other_gauge.prom" ]] \
    || fail "test3: emit_gauge's basename=NAME.prom wrapping does not match _emit_prom_gauge_file's own-file-per-gauge convention"

pass "test3: emit_gauge is a thin basename=NAME.prom wrapper over _emit_prom_gauge_file (own-file-per-gauge preserved)"

trap - EXIT
rm -rf "$T3"

# ── Syntax check ──────────────────────────────────────────────────────────────
bash -n "$LIB" || fail "lib/metric-sink-lib.sh has syntax errors"
pass "syntax check clean"

echo ""
echo "All tests passed."
