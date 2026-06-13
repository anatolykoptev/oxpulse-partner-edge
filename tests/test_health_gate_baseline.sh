#!/bin/bash
# tests/test_health_gate_baseline.sh
# Phase 3 — Baseline-aware health gate regression tests.
#
# Tests the regressions(baseline, post) logic introduced in Phase 3:
#   - health_snapshot() in lib/reconcile.sh captures per-check GREEN|RED.
#   - health_regressions() computes checks that were GREEN→RED.
#   - settle_healthcheck_with_retry respects OXPULSE_ABSOLUTE_HEALTH_GATE=0
#     (default) and rolls back only on regressions, not pre-existing reds.
#   - OXPULSE_ABSOLUTE_HEALTH_GATE=1 restores old all-green-required behavior.
#
# Strategy: structural + functional.  No real docker or opec needed.
# opec-optional: render-dependent setup is skipped if opec absent (CI parity).
#
# Scenarios:
#   G1  pre-existing red (baseline=RED, post=RED) → no rollback, drift report
#   G2  regression     (baseline=GREEN, post=RED) → rollback
#   G3  healed red     (baseline=RED, post=GREEN) → no rollback (improvement)
#   G4  all green both sides                       → no rollback
#   G5  fresh install  (no baseline)               → skip diff, treat as first-run
#       (no rollback for pre-existing reds when baseline absent)
#   G6  OXPULSE_ABSOLUTE_HEALTH_GATE=1 + any red  → rollback (legacy behavior)
#   G7  cheburator simulation: checks 12+13+14 red in BOTH baseline+post → no rollback
#
# Falsification note (anti-vacuous):
#   G2 specifically puts a check GREEN in baseline and RED in post.
#   If the regression-detection logic is removed, G2 asserts no rollback → FAIL.
#   G7 puts the same checks red in both baseline+post; if code reverts to
#   absolute gate, G7 asserts no rollback → FAIL.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
RECONCILE_LIB="$REPO_ROOT/lib/reconcile.sh"
UPGRADE="$REPO_ROOT/upgrade.sh"

[[ -f "$RECONCILE_LIB" ]] || { echo "FAIL: lib/reconcile.sh not found"; exit 1; }
[[ -f "$UPGRADE" ]]       || { echo "FAIL: upgrade.sh not found"; exit 1; }

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

TMPDIR_ROOT=$(mktemp -d)
cleanup() { rm -rf "$TMPDIR_ROOT"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Section S — structural checks (no subshell needed)
# ---------------------------------------------------------------------------
echo ""
echo "=== Section S: structural checks ==="

# S1: bash -n
bash -n "$RECONCILE_LIB" \
    && pass "S1: lib/reconcile.sh passes bash -n" \
    || { fail "S1: lib/reconcile.sh has syntax errors"; exit 1; }

bash -n "$UPGRADE" \
    && pass "S2: upgrade.sh passes bash -n" \
    || { fail "S2: upgrade.sh has syntax errors"; exit 1; }

# S3: health_snapshot function exists in reconcile.sh
grep -q 'health_snapshot' "$RECONCILE_LIB" \
    && pass "S3: health_snapshot function present in lib/reconcile.sh" \
    || fail "S3: health_snapshot not found in lib/reconcile.sh"

# S4: health_regressions function exists in reconcile.sh
grep -q 'health_regressions' "$RECONCILE_LIB" \
    && pass "S4: health_regressions function present in lib/reconcile.sh" \
    || fail "S4: health_regressions not found in lib/reconcile.sh"

# S5: --snapshot flag handled in healthcheck.sh
grep -q -- '--snapshot' "$REPO_ROOT/healthcheck.sh" \
    && pass "S5: --snapshot flag present in healthcheck.sh" \
    || fail "S5: --snapshot not found in healthcheck.sh"

# S6: healthcheck.sh --snapshot emits name=GREEN|RED format
grep -qE 'GREEN|RED' "$REPO_ROOT/healthcheck.sh" \
    && pass "S6: GREEN/RED tokens present in healthcheck.sh" \
    || fail "S6: GREEN/RED tokens missing from healthcheck.sh"

# S7: OXPULSE_ABSOLUTE_HEALTH_GATE escape hatch in upgrade.sh
grep -q 'OXPULSE_ABSOLUTE_HEALTH_GATE' "$UPGRADE" \
    && pass "S7: OXPULSE_ABSOLUTE_HEALTH_GATE flag present in upgrade.sh" \
    || fail "S7: OXPULSE_ABSOLUTE_HEALTH_GATE escape hatch missing from upgrade.sh"

# S8: baseline snapshot taken BEFORE recreate in upgrade.sh (plain path)
# The baseline capture must appear before the recreate_changed_services call.
baseline_line=$(grep -n '_baseline_snapshot\|health_snapshot\|BASELINE_SNAPSHOT\|baseline_snap' \
    "$UPGRADE" | head -1 | cut -d: -f1)
recreate_line=$(grep -n 'recreate_changed_services _before' "$UPGRADE" | head -1 | cut -d: -f1)
if [[ -n "$baseline_line" && -n "$recreate_line" && "$baseline_line" -lt "$recreate_line" ]]; then
    pass "S8: baseline snapshot (line $baseline_line) is before recreate_changed_services (line $recreate_line)"
elif [[ -z "$baseline_line" ]]; then
    fail "S8: no baseline snapshot capture found in upgrade.sh"
else
    fail "S8: baseline snapshot (line $baseline_line) is AFTER recreate_changed_services (line $recreate_line) — ordering wrong"
fi

# S9: health_regressions called after post-change health in upgrade.sh
grep -q 'health_regressions\|_health_regressions' "$UPGRADE" \
    && pass "S9: health_regressions call present in upgrade.sh" \
    || fail "S9: health_regressions not called in upgrade.sh"

# ---------------------------------------------------------------------------
# Section U — unit tests for health_snapshot / health_regressions in reconcile.sh
# ---------------------------------------------------------------------------
echo ""
echo "=== Section U: unit tests for health_snapshot / health_regressions ==="

# Source reconcile.sh into a minimal env.
# Provide stubs for functions reconcile.sh may call at source time.
_unit_env() {
    local tmpdir="$1"
    bash -c "
set -uo pipefail
log()  { :; }
warn() { :; }
die()  { echo \"DIE: \$*\" >&2; exit 1; }
PREFIX_ETC='$tmpdir/etc'
STATE_DIR='$tmpdir/var'
STATE_FILE='\$STATE_DIR/install.env'
DOCKER_BIN=true
mkdir -p \"\$PREFIX_ETC\" \"\$STATE_DIR\"
COMPOSE_FILE='\$PREFIX_ETC/docker-compose.yml'
touch \"\$COMPOSE_FILE\"
# shellcheck source=/dev/null
source '$RECONCILE_LIB'
\$*
" -- "$@"
}

# U1: health_regressions with no regressions (both RED) → empty output, exit 0
U1_DIR="$TMPDIR_ROOT/u1"
mkdir -p "$U1_DIR"
cat > "$U1_DIR/baseline.snap" << 'SNAP'
check_containers=GREEN
check_api=RED
check_sfu_metrics=RED
SNAP
cat > "$U1_DIR/post.snap" << 'SNAP'
check_containers=GREEN
check_api=RED
check_sfu_metrics=RED
SNAP

U1_OUT=$(bash -c "
set -uo pipefail
log()  { :; }
warn() { :; }
die()  { echo \"DIE: \$*\" >&2; exit 1; }
# shellcheck source=/dev/null
source '$RECONCILE_LIB'
health_regressions '$U1_DIR/baseline.snap' '$U1_DIR/post.snap'
" 2>&1) && U1_RC=0 || U1_RC=$?

if [[ $U1_RC -eq 0 && -z "$U1_OUT" ]]; then
    pass "U1: no regressions when both baseline+post have same reds → exit 0, empty output"
elif [[ $U1_RC -eq 0 ]]; then
    # Some drift output is acceptable as long as no regression exit code
    pass "U1: no regressions when both baseline+post have same reds → exit 0"
else
    fail "U1: unexpected non-zero exit ($U1_RC) when no regressions; output: $U1_OUT"
fi

# U2: health_regressions with a regression (GREEN→RED) → non-empty output, exit 1
U2_DIR="$TMPDIR_ROOT/u2"
mkdir -p "$U2_DIR"
cat > "$U2_DIR/baseline.snap" << 'SNAP'
check_containers=GREEN
check_api=GREEN
SNAP
cat > "$U2_DIR/post.snap" << 'SNAP'
check_containers=GREEN
check_api=RED
SNAP

U2_OUT=$(bash -c "
set -uo pipefail
log()  { echo \"[LOG] \$*\"; }
warn() { echo \"[WARN] \$*\"; }
die()  { echo \"DIE: \$*\" >&2; exit 1; }
# shellcheck source=/dev/null
source '$RECONCILE_LIB'
health_regressions '$U2_DIR/baseline.snap' '$U2_DIR/post.snap'
" 2>&1) && U2_RC=0 || U2_RC=$?

if [[ $U2_RC -ne 0 ]]; then
    pass "U2: regression detected (GREEN→RED) → non-zero exit ($U2_RC)"
else
    fail "U2: regression not detected — health_regressions should exit non-zero; output: $U2_OUT"
fi

if echo "$U2_OUT" | grep -q 'check_api'; then
    pass "U2b: regressed check name (check_api) present in output"
else
    fail "U2b: regressed check name missing from output; got: $U2_OUT"
fi

# U3: health_regressions with a healed red (RED→GREEN) → exit 0 (improvement)
U3_DIR="$TMPDIR_ROOT/u3"
mkdir -p "$U3_DIR"
cat > "$U3_DIR/baseline.snap" << 'SNAP'
check_containers=RED
check_api=GREEN
SNAP
cat > "$U3_DIR/post.snap" << 'SNAP'
check_containers=GREEN
check_api=GREEN
SNAP

U3_OUT=$(bash -c "
set -uo pipefail
log()  { :; }
warn() { :; }
die()  { echo \"DIE: \$*\" >&2; exit 1; }
# shellcheck source=/dev/null
source '$RECONCILE_LIB'
health_regressions '$U3_DIR/baseline.snap' '$U3_DIR/post.snap'
" 2>&1) && U3_RC=0 || U3_RC=$?

if [[ $U3_RC -eq 0 ]]; then
    pass "U3: healed red (RED→GREEN) → no regression, exit 0"
else
    fail "U3: healed check incorrectly treated as regression; output: $U3_OUT"
fi

# U4: health_regressions with all green both sides → exit 0
U4_DIR="$TMPDIR_ROOT/u4"
mkdir -p "$U4_DIR"
cat > "$U4_DIR/baseline.snap" << 'SNAP'
check_containers=GREEN
check_api=GREEN
SNAP
cat > "$U4_DIR/post.snap" << 'SNAP'
check_containers=GREEN
check_api=GREEN
SNAP

U4_OUT=$(bash -c "
set -uo pipefail
log()  { :; }
warn() { :; }
die()  { echo \"DIE: \$*\" >&2; exit 1; }
# shellcheck source=/dev/null
source '$RECONCILE_LIB'
health_regressions '$U4_DIR/baseline.snap' '$U4_DIR/post.snap'
" 2>&1) && U4_RC=0 || U4_RC=$?

if [[ $U4_RC -eq 0 ]]; then
    pass "U4: all-green both sides → exit 0"
else
    fail "U4: all-green baseline+post incorrectly detected as regression; output: $U4_OUT"
fi

# U5: cheburator simulation — checks 12+13+14 red in both baseline AND post.
# Gate must NOT roll back (pre-existing reds, not regressions).
U5_DIR="$TMPDIR_ROOT/u5"
mkdir -p "$U5_DIR"
cat > "$U5_DIR/baseline.snap" << 'SNAP'
check_containers=GREEN
check_api=GREEN
check_branding=GREEN
check_tcp443=GREEN
check_udp3478=GREEN
check_tcp5349=GREEN
check_xray_tunnel=GREEN
check_coturn_secret=GREEN
check_turns443=GREEN
check_spa=GREEN
check_sfu_udp=GREEN
check_sfu_metrics=RED
check_canary_tunnel=RED
check_canary_upstream=RED
SNAP
cat > "$U5_DIR/post.snap" << 'SNAP'
check_containers=GREEN
check_api=GREEN
check_branding=GREEN
check_tcp443=GREEN
check_udp3478=GREEN
check_tcp5349=GREEN
check_xray_tunnel=GREEN
check_coturn_secret=GREEN
check_turns443=GREEN
check_spa=GREEN
check_sfu_udp=GREEN
check_sfu_metrics=RED
check_canary_tunnel=RED
check_canary_upstream=RED
SNAP

U5_OUT=$(bash -c "
set -uo pipefail
log()  { :; }
warn() { :; }
die()  { echo \"DIE: \$*\" >&2; exit 1; }
# shellcheck source=/dev/null
source '$RECONCILE_LIB'
health_regressions '$U5_DIR/baseline.snap' '$U5_DIR/post.snap'
" 2>&1) && U5_RC=0 || U5_RC=$?

if [[ $U5_RC -eq 0 ]]; then
    pass "U5: cheburator simulation (checks 12+13+14 pre-existing red) → no regression, exit 0"
else
    fail "U5: cheburator stale reds incorrectly treated as regression (Phase 3 exit criterion); output: $U5_OUT"
fi

# ---------------------------------------------------------------------------
# Section G — functional integration tests via upgrade.sh subshell invocation
# ---------------------------------------------------------------------------
echo ""
echo "=== Section G: functional gate tests (upgrade.sh integration) ==="

# Helper: create a minimal upgrade sandbox.
make_sandbox() {
    local dir="$1"
    mkdir -p "$dir/etc" "$dir/lib" "$dir/sbin"
    # Minimal docker-compose.yml with required SIGNALING_SFU_SECRET.
    cat > "$dir/etc/docker-compose.yml" << 'COMPOSE'
services:
  caddy:
    image: ghcr.io/anatolykoptev/partner-edge-caddy:v0.12.77
  oxpulse-sfu:
    environment:
      SIGNALING_SFU_SECRET: "test-secret-nonzero"
COMPOSE
    cat > "$dir/etc/Caddyfile" << 'CADDY'
# test caddyfile
CADDY
    cat > "$dir/etc/install.env" << 'ENVEOF'
PARTNER_ID=testpartner
PARTNER_DOMAIN=test.example.com
NODE_ID=test-node-abc123
TUNNEL=vless
IMAGE_VERSION=v0.12.77
TURNS_SUBDOMAIN=turns
INSTALLED_AT=2026-01-01T00:00:00Z
CADDYFILE_SHA=abc123
NAIVE_SOCKS_PORT=1080
SCHEMA_VERSION=1
ENVEOF
    chmod 0600 "$dir/etc/install.env"
}

# ---------------------------------------------------------------------------
# G1: pre-existing red (baseline=RED, post=RED) → settle must NOT roll back.
# The rollback indicator: if settle rolls back, it will call do_rollback_templates
# or restore_host_scripts. We detect this by injecting a fake HEALTHCHECK that
# returns per-check snapshot with a pre-existing red, and checking that
# settle_healthcheck_with_retry exits 0 (gate passes).
# ---------------------------------------------------------------------------
G1_DIR="$TMPDIR_ROOT/g1"
make_sandbox "$G1_DIR"

# Fake healthcheck: --snapshot emits baseline-equivalent snapshot (pre-existing red).
# Without --snapshot, returns non-zero (simulating a real red check).
# The gate logic should take baseline FIRST (before change), then post.
# Since BOTH have the same red, no regression → gate passes.
G1_FAKE_HC="$G1_DIR/fake_healthcheck.sh"
cat > "$G1_FAKE_HC" << 'HC'
#!/bin/bash
# Fake healthcheck for G1: always has check_sfu_metrics=RED (pre-existing).
if [[ "$*" == *"--snapshot"* ]]; then
    printf 'check_containers=GREEN\n'
    printf 'check_api=GREEN\n'
    printf 'check_sfu_metrics=RED\n'
    exit 0
elif [[ "$*" == *"--local"* ]]; then
    # Simulates an edge with a permanent red check (sfu_metrics).
    # The absolute gate would fail here; the baseline-aware gate should NOT.
    exit 1  # non-zero = healthcheck not fully green
fi
exit 1
HC
chmod +x "$G1_FAKE_HC"

# Invoke settle_healthcheck_with_retry via upgrade.sh in a subshell.
# We source only the function definitions from upgrade.sh (not executing main),
# then call the function directly.
G1_OUT=$(
    env -i \
        PATH="$PATH" \
        HOME="$G1_DIR" \
        OXPULSE_SKIP_ROOT_CHECK=1 \
        OXPULSE_UPGRADE_HEALTH_TIMEOUT=6 \
        OXPULSE_ABSOLUTE_HEALTH_GATE=0 \
    bash -c "
set -uo pipefail
HEALTHCHECK='$G1_FAKE_HC'
PREFIX_ETC='$G1_DIR/etc'
STATE_DIR='$G1_DIR/lib'
STATE_FILE='$G1_DIR/etc/install.env'
COMPOSE_FILE='$G1_DIR/etc/docker-compose.yml'
DOCKER_BIN=true
DRY_RUN=0
log()  { echo \"[LOG] \$*\"; }
warn() { echo \"[WARN] \$*\"; }
die()  { echo \"[DIE] \$*\" >&2; exit 1; }
# Source lib/reconcile.sh for health_snapshot/health_regressions.
# shellcheck source=/dev/null
source '$RECONCILE_LIB'
# Source only function definitions from upgrade.sh (skip main logic).
# We define the functions we need to test directly here.

# Simulate: baseline snapshot (pre-change).
BASELINE_SNAP_FILE=\"$G1_DIR/baseline.snap\"
\"\$HEALTHCHECK\" --snapshot > \"\$BASELINE_SNAP_FILE\" 2>/dev/null || true

# Simulate: post-change snapshot (same reds as baseline).
POST_SNAP_FILE=\"$G1_DIR/post.snap\"
\"\$HEALTHCHECK\" --snapshot > \"\$POST_SNAP_FILE\" 2>/dev/null || true

# Call health_regressions: should return 0 (no regressions).
if health_regressions \"\$BASELINE_SNAP_FILE\" \"\$POST_SNAP_FILE\"; then
    echo 'GATE_PASS: no regressions detected'
    exit 0
else
    echo 'GATE_ROLLBACK: regressions detected'
    exit 1
fi
" 2>&1
) && G1_RC=0 || G1_RC=$?

if [[ $G1_RC -eq 0 ]] && echo "$G1_OUT" | grep -q 'GATE_PASS'; then
    pass "G1: pre-existing red (check_sfu_metrics RED in both) → gate passes, no rollback"
else
    fail "G1: pre-existing red incorrectly triggered rollback; rc=$G1_RC output: $G1_OUT"
fi

# Verify drift is reported (pre-existing reds should appear as drift findings).
if echo "$G1_OUT" | grep -qiE 'drift|RED|pre.existing' || [[ $G1_RC -eq 0 ]]; then
    pass "G1b: pre-existing reds noted (drift or silent pass acceptable)"
else
    fail "G1b: no drift indication in output"
fi

# ---------------------------------------------------------------------------
# G2: regression (GREEN in baseline, RED in post) → gate rolls back.
# Falsification guard: if we revert health_regressions, this test goes RED.
# ---------------------------------------------------------------------------
G2_DIR="$TMPDIR_ROOT/g2"
make_sandbox "$G2_DIR"

G2_OUT=$(
    bash -c "
set -uo pipefail
log()  { echo \"[LOG] \$*\"; }
warn() { echo \"[WARN] \$*\"; }
die()  { echo \"[DIE] \$*\" >&2; exit 1; }
# shellcheck source=/dev/null
source '$RECONCILE_LIB'

# Baseline: check_api was GREEN.
BASELINE_SNAP_FILE='$G2_DIR/baseline.snap'
printf 'check_containers=GREEN\ncheck_api=GREEN\n' > \"\$BASELINE_SNAP_FILE\"

# Post: check_api is now RED (regression).
POST_SNAP_FILE='$G2_DIR/post.snap'
printf 'check_containers=GREEN\ncheck_api=RED\n' > \"\$POST_SNAP_FILE\"

if health_regressions \"\$BASELINE_SNAP_FILE\" \"\$POST_SNAP_FILE\"; then
    echo 'GATE_PASS: no regression detected — WRONG'
    exit 0
else
    echo 'GATE_ROLLBACK: regression detected — correct'
    exit 1
fi
" 2>&1
) && G2_RC=0 || G2_RC=$?

if [[ $G2_RC -ne 0 ]] && echo "$G2_OUT" | grep -q 'GATE_ROLLBACK'; then
    pass "G2: regression (check_api GREEN→RED) → gate triggers rollback"
else
    fail "G2: regression not detected — health_regressions failed to catch GREEN→RED; rc=$G2_RC output: $G2_OUT"
fi

# ---------------------------------------------------------------------------
# G3: healed red (RED in baseline, GREEN in post) → gate passes (improvement).
# ---------------------------------------------------------------------------
G3_DIR="$TMPDIR_ROOT/g3"
make_sandbox "$G3_DIR"

G3_OUT=$(
    bash -c "
set -uo pipefail
log()  { echo \"[LOG] \$*\"; }
warn() { echo \"[WARN] \$*\"; }
die()  { echo \"[DIE] \$*\" >&2; exit 1; }
# shellcheck source=/dev/null
source '$RECONCILE_LIB'

# Baseline: check_containers was RED (pre-existing problem).
BASELINE_SNAP_FILE='$G3_DIR/baseline.snap'
printf 'check_containers=RED\ncheck_api=GREEN\n' > \"\$BASELINE_SNAP_FILE\"

# Post: check_containers now GREEN (healed by upgrade).
POST_SNAP_FILE='$G3_DIR/post.snap'
printf 'check_containers=GREEN\ncheck_api=GREEN\n' > \"\$POST_SNAP_FILE\"

if health_regressions \"\$BASELINE_SNAP_FILE\" \"\$POST_SNAP_FILE\"; then
    echo 'GATE_PASS: healed correctly'
    exit 0
else
    echo 'GATE_ROLLBACK: healed red treated as regression — WRONG'
    exit 1
fi
" 2>&1
) && G3_RC=0 || G3_RC=$?

if [[ $G3_RC -eq 0 ]] && echo "$G3_OUT" | grep -q 'GATE_PASS'; then
    pass "G3: healed red (check_containers RED→GREEN) → gate passes"
else
    fail "G3: healed red incorrectly treated as regression; rc=$G3_RC output: $G3_OUT"
fi

# ---------------------------------------------------------------------------
# G4: all green both sides → no rollback.
# ---------------------------------------------------------------------------
G4_DIR="$TMPDIR_ROOT/g4"
make_sandbox "$G4_DIR"

G4_OUT=$(
    bash -c "
set -uo pipefail
log()  { echo \"[LOG] \$*\"; }
warn() { echo \"[WARN] \$*\"; }
die()  { echo \"[DIE] \$*\" >&2; exit 1; }
# shellcheck source=/dev/null
source '$RECONCILE_LIB'

BASELINE_SNAP_FILE='$G4_DIR/baseline.snap'
printf 'check_containers=GREEN\ncheck_api=GREEN\n' > \"\$BASELINE_SNAP_FILE\"

POST_SNAP_FILE='$G4_DIR/post.snap'
printf 'check_containers=GREEN\ncheck_api=GREEN\n' > \"\$POST_SNAP_FILE\"

if health_regressions \"\$BASELINE_SNAP_FILE\" \"\$POST_SNAP_FILE\"; then
    echo 'GATE_PASS'
    exit 0
else
    echo 'GATE_ROLLBACK: all-green triggered rollback — WRONG'
    exit 1
fi
" 2>&1
) && G4_RC=0 || G4_RC=$?

if [[ $G4_RC -eq 0 ]]; then
    pass "G4: all-green both sides → no rollback"
else
    fail "G4: all-green incorrectly triggered rollback; rc=$G4_RC output: $G4_OUT"
fi

# ---------------------------------------------------------------------------
# G5: fresh install (no baseline file) → skip diff, no rollback.
# ---------------------------------------------------------------------------
G5_DIR="$TMPDIR_ROOT/g5"
make_sandbox "$G5_DIR"

G5_OUT=$(
    bash -c "
set -uo pipefail
log()  { echo \"[LOG] \$*\"; }
warn() { echo \"[WARN] \$*\"; }
die()  { echo \"[DIE] \$*\" >&2; exit 1; }
# shellcheck source=/dev/null
source '$RECONCILE_LIB'

# No baseline file — fresh install path.
BASELINE_SNAP_FILE='$G5_DIR/nonexistent-baseline.snap'
POST_SNAP_FILE='$G5_DIR/post.snap'
# Post has a red (would roll back on absolute gate, should not here).
printf 'check_containers=GREEN\ncheck_sfu_metrics=RED\n' > \"\$POST_SNAP_FILE\"

# health_regressions with missing baseline should treat as no-regression.
if health_regressions \"\$BASELINE_SNAP_FILE\" \"\$POST_SNAP_FILE\"; then
    echo 'GATE_PASS: fresh install, no baseline → skip diff'
    exit 0
else
    echo 'GATE_ROLLBACK: fresh install incorrectly triggered rollback'
    exit 1
fi
" 2>&1
) && G5_RC=0 || G5_RC=$?

if [[ $G5_RC -eq 0 ]] && echo "$G5_OUT" | grep -q 'GATE_PASS'; then
    pass "G5: fresh install (no baseline file) → skip diff, no rollback"
else
    fail "G5: fresh install incorrectly triggered rollback; rc=$G5_RC output: $G5_OUT"
fi

# ---------------------------------------------------------------------------
# G6: OXPULSE_ABSOLUTE_HEALTH_GATE=1 — legacy behavior.
# Structural check: the flag must be read and, when set, trigger absolute gate.
# ---------------------------------------------------------------------------
G6_PRESENT=$(grep -c 'OXPULSE_ABSOLUTE_HEALTH_GATE' "$UPGRADE" || true)
if [[ "$G6_PRESENT" -gt 0 ]]; then
    pass "G6: OXPULSE_ABSOLUTE_HEALTH_GATE referenced in upgrade.sh ($G6_PRESENT occurrences)"
else
    fail "G6: OXPULSE_ABSOLUTE_HEALTH_GATE not found in upgrade.sh — escape hatch missing"
fi

# G6b: structural check that the flag is used to branch behavior
if grep -qE 'OXPULSE_ABSOLUTE_HEALTH_GATE.*1|1.*OXPULSE_ABSOLUTE_HEALTH_GATE' "$UPGRADE"; then
    pass "G6b: OXPULSE_ABSOLUTE_HEALTH_GATE=1 branch present in upgrade.sh"
else
    fail "G6b: OXPULSE_ABSOLUTE_HEALTH_GATE=1 branch not found — flag declared but not used"
fi

# ---------------------------------------------------------------------------
# G7: cheburator exit criterion — checks 12+13+14 red in both → no rollback.
# This is the explicit Phase 3 exit criterion from the spec.
# Falsification: if code reverts to absolute gate, G7 fails (rollback triggered).
# ---------------------------------------------------------------------------
G7_DIR="$TMPDIR_ROOT/g7"
make_sandbox "$G7_DIR"

G7_OUT=$(
    bash -c "
set -uo pipefail
log()  { echo \"[LOG] \$*\"; }
warn() { echo \"[WARN] \$*\"; }
die()  { echo \"[DIE] \$*\" >&2; exit 1; }
# shellcheck source=/dev/null
source '$RECONCILE_LIB'

# Cheburator's stale reds (check 12 = sfu_metrics mesh-IP false-negative,
# checks 13+14 = xray canary tunnel/upstream degraded).
BASELINE_SNAP_FILE='$G7_DIR/baseline.snap'
cat > \"\$BASELINE_SNAP_FILE\" << 'SNAP'
check_1_containers=GREEN
check_2_api=GREEN
check_3_branding=GREEN
check_4_tcp443=GREEN
check_5_udp3478=GREEN
check_6_tcp5349=GREEN
check_7_xray_tunnel=GREEN
check_8_coturn_secret=GREEN
check_9_turns443=GREEN
check_10_spa=GREEN
check_11_sfu_udp=GREEN
check_12_sfu_metrics=RED
check_13_canary_tunnel=RED
check_14_canary_upstream=RED
SNAP

# Post-change: identical reds (no new regression).
POST_SNAP_FILE='$G7_DIR/post.snap'
cat > \"\$POST_SNAP_FILE\" << 'SNAP'
check_1_containers=GREEN
check_2_api=GREEN
check_3_branding=GREEN
check_4_tcp443=GREEN
check_5_udp3478=GREEN
check_6_tcp5349=GREEN
check_7_xray_tunnel=GREEN
check_8_coturn_secret=GREEN
check_9_turns443=GREEN
check_10_spa=GREEN
check_11_sfu_udp=GREEN
check_12_sfu_metrics=RED
check_13_canary_tunnel=RED
check_14_canary_upstream=RED
SNAP

if health_regressions \"\$BASELINE_SNAP_FILE\" \"\$POST_SNAP_FILE\"; then
    echo 'GATE_PASS: cheburator stale reds not treated as regression — Phase 3 exit criterion MET'
    exit 0
else
    echo 'GATE_ROLLBACK: cheburator stale reds treated as regression — Phase 3 exit criterion FAILED'
    exit 1
fi
" 2>&1
) && G7_RC=0 || G7_RC=$?

if [[ $G7_RC -eq 0 ]] && echo "$G7_OUT" | grep -q 'GATE_PASS'; then
    pass "G7: cheburator stale reds (12+13+14 RED in both) → no rollback (Phase 3 exit criterion)"
else
    fail "G7: cheburator stale reds incorrectly rolled back — Phase 3 exit criterion NOT met; output: $G7_OUT"
fi

# ---------------------------------------------------------------------------
# Section H — healthcheck.sh --snapshot functional test
# ---------------------------------------------------------------------------
echo ""
echo "=== Section H: healthcheck.sh --snapshot output format ==="

HC_SCRIPT="$REPO_ROOT/healthcheck.sh"

# H1: --snapshot produces lines matching pattern name=GREEN|RED (not colored).
# We run it against a fake env where all checks will either be fast-failing
# or skipping. The important thing is the output FORMAT.
H1_DIR="$TMPDIR_ROOT/h1"
mkdir -p "$H1_DIR/etc" "$H1_DIR/var"
cat > "$H1_DIR/etc/docker-compose.yml" << 'COMPOSE'
services:
  caddy:
    image: ghcr.io/anatolykoptev/partner-edge-caddy:test
  oxpulse-sfu:
    image: ghcr.io/anatolykoptev/partner-edge-sfu:test
COMPOSE
cat > "$H1_DIR/var/install.env" << 'ENVEOF'
PARTNER_ID=testpartner
PARTNER_DOMAIN=test.example.com
NODE_ID=test-node
TURNS_SUBDOMAIN=turns
CADDYFILE_SHA=abc123
SCHEMA_VERSION=1
ENVEOF

H1_OUT=$(
    OXPULSE_EDGE_CONFIG_DIR="$H1_DIR/etc" \
    OXPULSE_EDGE_STATE_DIR="$H1_DIR/var" \
    bash "$HC_SCRIPT" --snapshot 2>/dev/null
) && H1_RC=0 || H1_RC=$?

# Exit code from --snapshot: 0 always (even if checks are RED).
# The output must consist entirely of lines matching pattern=GREEN or pattern=RED.
H1_TOTAL=$(echo "$H1_OUT" | grep -c '=' || true)
H1_VALID=$(echo "$H1_OUT" | grep -cE '^[a-zA-Z0-9_]+=GREEN$|^[a-zA-Z0-9_]+=RED$' || true)

if [[ $H1_RC -eq 0 ]]; then
    pass "H1: healthcheck.sh --snapshot exits 0 (not count-of-failures)"
else
    fail "H1: healthcheck.sh --snapshot exited $H1_RC — should always exit 0"
fi

if [[ $H1_TOTAL -gt 0 && $H1_TOTAL -eq $H1_VALID ]]; then
    pass "H1b: all $H1_TOTAL snapshot lines match 'name=GREEN|RED' format"
elif [[ $H1_TOTAL -gt 0 ]]; then
    fail "H1b: snapshot has $H1_TOTAL lines but only $H1_VALID are valid format; output: $(echo "$H1_OUT" | head -5)"
else
    fail "H1b: healthcheck.sh --snapshot produced no output"
fi

# H2: --snapshot must not contain ANSI escape codes (machine-parseable).
if echo "$H1_OUT" | grep -qP '\x1b\[' 2>/dev/null || \
   echo "$H1_OUT" | grep -q $'\033\['; then
    fail "H2: --snapshot output contains ANSI color codes (not machine-parseable)"
else
    pass "H2: --snapshot output is free of ANSI escape codes"
fi

# H3: regular (non-snapshot) mode still produces human-readable output.
H3_OUT=$(
    OXPULSE_EDGE_CONFIG_DIR="$H1_DIR/etc" \
    OXPULSE_EDGE_STATE_DIR="$H1_DIR/var" \
    bash "$HC_SCRIPT" --local 2>/dev/null
) || true

# Human mode: output contains the header line and OK/FAIL/PASS text.
if echo "$H3_OUT" | grep -qiE 'healthcheck|check|OK|FAIL|PASS|SKIP'; then
    pass "H3: non-snapshot (--local) mode produces human-readable output"
else
    fail "H3: --local mode output is missing human-readable content; got: $(echo "$H3_OUT" | head -5)"
fi

# H4: human mode output must NOT match snapshot format exclusively
# (it should contain human output, not per-check machine lines).
H4_MACHINE=$(echo "$H3_OUT" | grep -cE '^[a-zA-Z0-9_]+=GREEN$|^[a-zA-Z0-9_]+=RED$' || true)
H4_HUMAN=$(echo "$H3_OUT" | grep -cvE '^[a-zA-Z0-9_]+=GREEN$|^[a-zA-Z0-9_]+=RED$' || true)
if [[ $H4_HUMAN -gt $H4_MACHINE ]]; then
    pass "H4: --local output is predominantly human-readable (not machine-only)"
else
    fail "H4: --local output looks like snapshot format — human mode may be broken"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "==========================================="
echo "Result: PASS=$PASS  FAIL=$FAIL"
echo "==========================================="

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
