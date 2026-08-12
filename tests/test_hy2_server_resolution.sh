#!/usr/bin/env bash
# tests/test_hy2_server_resolution.sh — hy2 server endpoint resolution gate.
#
# Defect: re_render_hysteria2 (channel-render-lib.sh) resolved the server via
#   HY2_SERVER → OXPULSE_HY2_SERVER → 203.0.113.10:51822 (TEST-NET-3, RFC 5737).
# The backend returns the endpoint as HYSTERIA2_SERVER, which was NOT in the
# chain. config/defaults.conf also defaulted OXPULSE_HY2_SERVER to the same
# TEST-NET address, so the fallback was always reached. A new partner running
# install.sh got a dead hy2 channel and a success message — silent failure.
#
# This test file covers:
#   F1 — HYSTERIA2_SERVER reaches the rendered server: line (not TEST-NET).
#   F2 — install.sh guards the re_render_hysteria2 return value (call site).
#   F3 — renderer returns 1 + ERR when no server is resolvable (fail loud).
#   F4 — no TEST-NET default remains in the three carrier files.
#   F5 — upgrade.sh guards the re_render_hysteria2 return value (call site).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TPL="$REPO_ROOT/hysteria2-client.yaml.tpl"

FAIL=0
# `pass` prints only when no assertion has recorded a failure since the previous
# `pass` line.  While `fail` exited, an "OK:" after a "FAIL:" was structurally
# impossible; with recording assertions it is not, and an unconditional "OK:" is
# an affirmative claim about the very property that just failed — greppable, and
# the opposite of the truth.  The sibling test_hydrate_hy2_render.sh:152-154 gets
# this from if/else at every site; a boundary marker gives the same guarantee
# without restructuring 13 call sites.
_MARK=0
pass() {
    if [[ $FAIL -ne $_MARK ]]; then _MARK=$FAIL; return 0; fi
    echo "OK: $*"
}
# Assertion failure: record and continue so later sections still run.  The
# summary at the end of the file exits non-zero if any assertion fired.
# Matches the sibling test_hydrate_hy2_render.sh:38-40 shape.  A counter rather
# than a flag so `pass` can tell "a failure since my boundary" from "a failure
# earlier in the run".
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
# Setup/extraction guard: fatal.  Continuing past an empty extraction or a
# missing prerequisite runs every later test against garbage and buries the
# real cause under cascading noise.
fail_exit() { echo "FAIL: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# F1 — HYSTERIA2_SERVER honored by re_render_hysteria2
# ---------------------------------------------------------------------------
# Mutation target: restore the old chain
#   local server="${HY2_SERVER:-${OXPULSE_HY2_SERVER:-203.0.113.10:51822}}"
# (no HYSTERIA2_SERVER) → this test goes RED because the rendered server:
# line contains the TEST-NET address, not the HYSTERIA2_SERVER value.
# ---------------------------------------------------------------------------
echo "--- F1: HYSTERIA2_SERVER reaches rendered server: line ---"

_out_dir=$(mktemp -d)
trap 'rm -rf "$_out_dir"' EXIT
_hy2_out="$_out_dir/hysteria2-client.yaml"

# Source the render lib in a clean subshell, then call re_render_hysteria2
# with HYSTERIA2_SERVER set and HY2_SERVER / OXPULSE_HY2_SERVER explicitly
# unset — the exact state install.sh / upgrade.sh have (they carry
# HYSTERIA2_SERVER from the backend, never HY2_SERVER).
(
    set -euo pipefail
    # Purge all server vars so defaults.conf / environment cannot leak the
    # TEST-NET address into the resolution chain.
    unset HY2_SERVER OXPULSE_HY2_SERVER HYSTERIA2_SERVER
    # shellcheck source=../channel-render-lib.sh
    source "$REPO_ROOT/channel-render-lib.sh"
    # After sourcing, defaults.conf may have set OXPULSE_HY2_SERVER — purge again.
    unset OXPULSE_HY2_SERVER

    export OXPULSE_REPO_DIR="$REPO_ROOT"
    export HY2_OUTPUT_PATH="$_hy2_out"
    export HYSTERIA2_SERVER="edge.example-real.net:51822"
    export HY2_AUTH_PASS="auth-fixture"
    export HY2_OBFS_PASS="obfs-fixture"
    # Explicitly ensure HY2_SERVER is not set — the caller's variable is
    # HYSTERIA2_SERVER, not HY2_SERVER.
    unset HY2_SERVER

    re_render_hysteria2
)
_f1_rc=$?
[[ $_f1_rc -eq 0 ]] || fail "F1: re_render_hysteria2 returned $_f1_rc with HYSTERIA2_SERVER set"

if ! grep -qF 'server: "edge.example-real.net:51822"' "$_hy2_out"; then
    echo "   rendered server line:" >&2
    grep '^server:' "$_hy2_out" >&2 || echo "   (no server: line found)" >&2
    fail "F1: HYSTERIA2_SERVER did not reach rendered server: line (got TEST-NET or wrong value)"
fi
# Negative: the TEST-NET address must NOT appear.
if grep -qF '203.0.113.10' "$_hy2_out"; then
    fail "F1: TEST-NET address 203.0.113.10 found in rendered output — fallback was used"
fi
pass "F1: HYSTERIA2_SERVER reaches rendered server: line, no TEST-NET leak"

# ---------------------------------------------------------------------------
# F3 — renderer returns 1 + ERR when no server is resolvable
# ---------------------------------------------------------------------------
# Mutation target: restore the TEST-NET fallback → this test goes RED because
# re_render_hysteria2 returns 0 and writes the TEST-NET address instead of
# failing.
# ---------------------------------------------------------------------------
echo "--- F3: re_render_hysteria2 fails loud when no server resolvable ---"

_f3_out="$_out_dir/f3.yaml"
_f3_stderr="$_out_dir/f3-stderr.txt"

# Run in a subshell with all server vars purged; capture rc.
_f3_rc=$(
    unset HY2_SERVER OXPULSE_HY2_SERVER HYSTERIA2_SERVER
    # shellcheck source=../channel-render-lib.sh
    source "$REPO_ROOT/channel-render-lib.sh" 2>/dev/null
    unset OXPULSE_HY2_SERVER

    export OXPULSE_REPO_DIR="$REPO_ROOT"
    export HY2_OUTPUT_PATH="$_f3_out"
    export HY2_AUTH_PASS="auth-fixture"
    export HY2_OBFS_PASS="obfs-fixture"
    unset HY2_SERVER HYSTERIA2_SERVER OXPULSE_HY2_SERVER

    set +e
    re_render_hysteria2 2>"$_f3_stderr"
    echo $?
)
_f3_rc=$(echo "$_f3_rc" | tail -1)

if [[ "$_f3_rc" == "0" ]]; then
    fail "F3: re_render_hysteria2 returned 0 with no server resolvable — should fail loud"
fi
# The output file must NOT have been written with a fabricated endpoint.
if [[ -f "$_f3_out" ]] && grep -qF '203.0.113.10' "$_f3_out"; then
    fail "F3: re_render_hysteria2 wrote TEST-NET address despite no server — silent failure"
fi
# The error message must mention the server variable(s).
if ! grep -qiE 'server|endpoint|HY2_SERVER|HYSTERIA2_SERVER' "$_f3_stderr" 2>/dev/null; then
    fail "F3: re_render_hysteria2 did not log an error naming the missing server variable"
fi
pass "F3: re_render_hysteria2 returns non-zero + ERR when no server resolvable"

# ---------------------------------------------------------------------------
# F4 — no TEST-NET default remains in the three carrier files
# ---------------------------------------------------------------------------
# Mutation target: restore any of the three TEST-NET defaults → this test
# goes RED.
# ---------------------------------------------------------------------------
echo "--- F4: no TEST-NET default in carrier files ---"

# Each of these is an ABSENCE check, and `grep -qF` on a missing file returns
# non-zero exactly like a clean file — so a renamed or deleted carrier reports
# OK.  Assert the carrier exists first; the absence check is only meaningful
# once we know we read something.

# channel-render-lib.sh must not contain the TEST-NET address as a fallback.
if [[ ! -f "$REPO_ROOT/channel-render-lib.sh" ]]; then
    fail "F4: channel-render-lib.sh missing — an absence check cannot be satisfied by a missing file"
elif grep -qF '203.0.113.10' "$REPO_ROOT/channel-render-lib.sh"; then
    fail "F4: channel-render-lib.sh still contains TEST-NET address 203.0.113.10"
fi
pass "F4: channel-render-lib.sh free of TEST-NET default"

# config/defaults.conf must not default OXPULSE_HY2_SERVER to TEST-NET.
if [[ ! -f "$REPO_ROOT/config/defaults.conf" ]]; then
    fail "F4: config/defaults.conf missing — an absence check cannot be satisfied by a missing file"
elif grep -qF '203.0.113.10' "$REPO_ROOT/config/defaults.conf"; then
    fail "F4: config/defaults.conf still contains TEST-NET address 203.0.113.10"
fi
pass "F4: config/defaults.conf free of TEST-NET default"

# oxpulse-partner-edge-enable-hy2 must not default HY2_SERVER to TEST-NET.
if [[ ! -f "$REPO_ROOT/oxpulse-partner-edge-enable-hy2" ]]; then
    fail "F4: oxpulse-partner-edge-enable-hy2 missing — an absence check cannot be satisfied by a missing file"
elif grep -qF '203.0.113.10' "$REPO_ROOT/oxpulse-partner-edge-enable-hy2"; then
    fail "F4: oxpulse-partner-edge-enable-hy2 still contains TEST-NET address 203.0.113.10"
fi
pass "F4: oxpulse-partner-edge-enable-hy2 free of TEST-NET default"

# ---------------------------------------------------------------------------
# F2 — install.sh guards the re_render_hysteria2 return value (call site)
# ---------------------------------------------------------------------------
# Mutation target: revert install.sh to bare `re_render_hysteria2` followed by
# `_hy2_status="active"` (no if-guard) → this test goes RED.
# The mutation must touch install.sh, not the renderer.
# ---------------------------------------------------------------------------
echo "--- F2: install.sh guards re_render_hysteria2 return ---"

# Structural: install.sh must use `if re_render_hysteria2` (conditional), not
# a bare call followed by unconditional _hy2_status="active".
if ! grep -qE 'if[[:space:]]+re_render_hysteria2' "$REPO_ROOT/install.sh"; then
    fail "F2: install.sh does not guard re_render_hysteria2 with if (bare call — _hy2_status set unconditionally)"
fi
pass "F2: install.sh uses conditional on re_render_hysteria2 return"

# Behavioral: extract the REAL hy2 block from install.sh and execute it.
# Replaces the replica that silently drifted from install.sh (a replica cannot
# see a change to install.sh). Uses the same awk-extraction pattern as
# test_awg_params_agent_install.sh (WS4 guard tests) and
# test_install_honest_exit_gate.sh (sibling branch fix/install-tells-the-truth):
# track `; then`/`fi` depth to capture exactly the block. The `elif` at the
# tail must NOT increment depth (it is part of the same if/fi construct), so
# we exclude it from the `; then` counter.
_hy2_block="$_out_dir/install_hy2_block.sh"
awk '
    /&& declare -f re_render_hysteria2/ { cap=1 }
    cap {
        print
        if ($0 ~ /; then[[:space:]]*$/ && $0 !~ /^[[:space:]]*elif/) depth++
        if ($0 ~ /^[[:space:]]*fi[[:space:]]*$/) { depth--; if (depth==0) exit }
    }
' "$REPO_ROOT/install.sh" > "$_hy2_block"
[ -s "$_hy2_block" ] || fail_exit "F2: extraction produced empty file — pattern did not match install.sh"
# Couple test to real code: the extracted block must contain the guard.
grep -q 'if re_render_hysteria2' "$_hy2_block" \
    || fail "F2: extracted block missing the re_render_hysteria2 guard"

# --- F2 case A: render succeeds → _hy2_status=active, ch3 in profiles ---
_f2a_result=$(
    set +e
    _HY2_BLOCK="$_hy2_block" bash <<'INNER'
set -euo pipefail
COMPOSE_PROFILES_EXTRA=""
HYSTERIA2_SERVER="edge.example.net:51822"
BACKEND_API="https://api.oxpulse.chat"
stage="/tmp"

# Stubs: curl returns valid creds JSON; read_service_token returns a fake token.
curl() { printf '%s' '{"auth_pass":"auth-fixture","obfs_pass":"obfs-fixture"}'; }
read_service_token() { printf '%s' "fake-token"; }
log()  { :; }
warn() { :; }

# Stub: re_render_hysteria2 SUCCEEDS.
re_render_hysteria2() { return 0; }

_hy2_status="skipped"
if [[ -n "${HYSTERIA2_SERVER:-}" ]]; then
    _hy2_status="failed_at_start"
fi
source "$_HY2_BLOCK"
printf '%s|%s' "$_hy2_status" "$COMPOSE_PROFILES_EXTRA"
INNER
)
_f2a_status="${_f2a_result%%|*}"
_f2a_profiles="${_f2a_result#*|}"

if [[ "$_f2a_status" != "active" ]]; then
    fail "F2 case A: render succeeded but _hy2_status='$_f2a_status' (expected active)"
fi
if [[ "$_f2a_profiles" != *ch3* ]]; then
    fail "F2 case A: render succeeded but ch3 not in COMPOSE_PROFILES_EXTRA='$_f2a_profiles'"
fi
pass "F2 case A: render succeeds → _hy2_status=active, ch3 in profiles (real install.sh block)"

# --- F2 case B: render fails → _hy2_status NOT active, ch3 absent ---
# Capture the block's exit status too.  Without it this test is satisfied by an
# EMPTY capture: with the guard removed, `set -e` inside the block kills the
# inner shell before the status line, and "" is neither "active" nor contains
# ch3 — BOTH checks below are absence checks, so both pass while the bug is
# present (issue #603).
# No errexit bracket here on purpose: this harness runs `set -uo pipefail`
# (no -e), so a non-zero `var=$(...)` does not kill the shell and $? is
# captured correctly.  Adding `set -e` after the capture would LEAK errexit
# into the rest of the file.
_f2b_result=$(
    set +e
    _HY2_BLOCK="$_hy2_block" bash <<'INNER'
set -euo pipefail
COMPOSE_PROFILES_EXTRA=""
HYSTERIA2_SERVER="edge.example.net:51822"
BACKEND_API="https://api.oxpulse.chat"
stage="/tmp"

curl() { printf '%s' '{"auth_pass":"auth-fixture","obfs_pass":"obfs-fixture"}'; }
read_service_token() { printf '%s' "fake-token"; }
log()  { :; }
warn() { :; }

# Stub: re_render_hysteria2 FAILS (returns 1) — simulates unresolvable server.
re_render_hysteria2() { return 1; }

_hy2_status="skipped"
if [[ -n "${HYSTERIA2_SERVER:-}" ]]; then
    _hy2_status="failed_at_start"
fi
source "$_HY2_BLOCK"
printf '%s|%s' "$_hy2_status" "$COMPOSE_PROFILES_EXTRA"
INNER
)
_f2b_rc=$?
_f2b_status="${_f2b_result%%|*}"
_f2b_profiles="${_f2b_result#*|}"

if [[ $_f2b_rc -ne 0 ]]; then
    fail "F2 case B: the extracted install.sh block ABORTED (rc=$_f2b_rc) instead of degrading — the guard is missing and set -e killed the shell before it could report. The empty capture would satisfy every other assertion here."
fi
if [[ "$_f2b_status" == "active" ]]; then
    fail "F2 case B: render failed but _hy2_status=active — guard missing in real install.sh block"
fi
if [[ "$_f2b_profiles" == *ch3* ]]; then
    fail "F2 case B: render failed but ch3 in COMPOSE_PROFILES_EXTRA='$_f2b_profiles' — guard missing"
fi
pass "F2 case B: render fails → _hy2_status != active, ch3 absent (real install.sh block)"

# ---------------------------------------------------------------------------
# F5 — upgrade.sh guards the re_render_hysteria2 return value (call site)
# ---------------------------------------------------------------------------
# Mutation target: revert upgrade.sh to bare `re_render_hysteria2` followed by
# unconditional `log "hy2 channel refreshed"` → this test goes RED.
# ---------------------------------------------------------------------------
echo "--- F5: upgrade.sh guards re_render_hysteria2 return ---"

if ! grep -qE 'if[[:space:]]+re_render_hysteria2' "$REPO_ROOT/upgrade.sh"; then
    fail "F5: upgrade.sh does not guard re_render_hysteria2 with if (bare call — refreshed logged unconditionally)"
fi
pass "F5: upgrade.sh uses conditional on re_render_hysteria2 return"

# Behavioral: extract the REAL hy2 block from upgrade.sh and execute it.
# Same awk-extraction pattern; the block has no elif so the standard depth
# tracker works. The block spans a backslash-continuation on the if condition
# (`; then` is on the second line), which the tracker handles correctly.
_hy2_upgrade_block="$_out_dir/upgrade_hy2_block.sh"
awk '
    /if \[\[/ && /OXPULSE_HY2_AUTH_PASS/ { cap=1 }
    cap {
        print
        if ($0 ~ /; then[[:space:]]*$/) depth++
        if ($0 ~ /^[[:space:]]*fi[[:space:]]*$/) { depth--; if (depth==0) exit }
    }
' "$REPO_ROOT/upgrade.sh" > "$_hy2_upgrade_block"
[ -s "$_hy2_upgrade_block" ] || fail_exit "F5: extraction produced empty file — pattern did not match upgrade.sh"
grep -q 'if re_render_hysteria2' "$_hy2_upgrade_block" \
    || fail "F5: extracted block missing the re_render_hysteria2 guard"

# --- F5 case A: render succeeds → "hy2 channel refreshed" logged ---
_f5a_log=$(
    set +e
    _HY2_BLOCK="$_hy2_upgrade_block" bash <<'INNER'
set -euo pipefail
HY2_AUTH_PASS="auth-fixture"
HY2_OBFS_PASS="obfs-fixture"

log() { printf '%s\n' "$*"; }

re_render_hysteria2() { return 0; }

source "$_HY2_BLOCK"
INNER
)
if [[ "$_f5a_log" != *"hy2 channel refreshed"* ]]; then
    fail "F5 case A: render succeeded but 'hy2 channel refreshed' not logged — got: $_f5a_log"
fi
if [[ "$_f5a_log" == *"WARNING"* ]]; then
    fail "F5 case A: render succeeded but WARNING logged — got: $_f5a_log"
fi
pass "F5 case A: render succeeds → 'hy2 channel refreshed' logged (real upgrade.sh block)"

# --- F5 case B: render fails → WARNING logged, NOT "hy2 channel refreshed" ---
# NOT the same as F2 case B.  F5's first assertion below is a PRESENCE check
# ("WARNING" must appear), which an empty capture already breaks — so this case
# was never vacuous and caught the documented mutation on its own.  The rc check
# is belt-and-braces: it names the abort explicitly instead of reporting a
# missing WARNING line, which is a confusing way to describe a dead shell.
_f5b_log=$(
    set +e
    _HY2_BLOCK="$_hy2_upgrade_block" bash <<'INNER'
set -euo pipefail
HY2_AUTH_PASS="auth-fixture"
HY2_OBFS_PASS="obfs-fixture"

log() { printf '%s\n' "$*"; }

re_render_hysteria2() { return 1; }

source "$_HY2_BLOCK"
INNER
)
_f5b_rc=$?
if [[ $_f5b_rc -ne 0 ]]; then
    fail "F5 case B: the extracted upgrade.sh block ABORTED (rc=$_f5b_rc) instead of degrading — the guard is missing and set -e killed the shell. (The WARNING check below would also catch this; this line just names the cause.)"
fi
if [[ "$_f5b_log" != *"WARNING"* ]]; then
    fail "F5 case B: render failed but WARNING not logged — got: $_f5b_log"
fi
if [[ "$_f5b_log" == *"hy2 channel refreshed"* ]]; then
    fail "F5 case B: render failed but 'hy2 channel refreshed' logged — guard missing in real upgrade.sh block"
fi
pass "F5 case B: render fails → WARNING logged, success NOT logged (real upgrade.sh block)"

echo
echo "--- F6: upgrade.sh --templates-only exit code reflects a hy2 render failure ---"

# The `if re_render_hysteria2` guard added for F5 stops set -e from killing the
# refresh — deliberate, since xray is already re-rendered by then. But before
# that guard existed, a bare failing render exited non-zero, so the guard must
# not silently convert a failed refresh into exit 0: a cron or monitor checking
# only the status would read it as a clean run.
#
# Extract the whole --templates-only tail (credentials-if through `exit 0`),
# not just the render block that F5 covers — the exit decision lives after
# F5's closing `fi`.
_tmpl_tail="$_out_dir/upgrade_templates_tail.sh"
awk '
    /if \[\[/ && /OXPULSE_HY2_AUTH_PASS/ { cap=1 }
    cap { print; if ($0 ~ /^[[:space:]]*exit 0[[:space:]]*$/) exit }
' "$REPO_ROOT/upgrade.sh" > "$_tmpl_tail"
[ -s "$_tmpl_tail" ] || fail_exit "F6: extraction produced empty file — pattern did not match upgrade.sh"
# Anchored to the SAME pattern awk terminates on (:383).  An unanchored
# `exit 0` also matches any of the seven other `exit 0` lines in upgrade.sh, so
# when the terminator stops matching, awk runs to EOF and this guard passes over
# a ~1900-line tail — with F6 case A satisfied by any breakage, both cases then
# report OK at rc=0.  The guard's predicate must equal awk's, or it is blind to
# the one failure it exists to catch.
grep -qE '^[[:space:]]*exit 0[[:space:]]*$' "$_tmpl_tail" \
    || fail_exit "F6: extracted tail does not reach the exit — extraction is wrong"

# --- F6 case A: render FAILS -> must exit non-zero ---
_TMPL_TAIL="$_tmpl_tail" bash >/dev/null 2>&1 <<'INNER'
set -euo pipefail
HY2_AUTH_PASS="auth-fixture"
HY2_OBFS_PASS="obfs-fixture"
log() { printf '%s\n' "$*"; }
re_render_hysteria2() { return 1; }
source "$_TMPL_TAIL"
INNER
_f6a_rc=$?
if [[ $_f6a_rc -eq 0 ]]; then
    fail "F6 case A: hy2 render failed but --templates-only exited 0 — the exit code lies (rc=$_f6a_rc)"
fi
pass "F6 case A: render fails → --templates-only exits non-zero (rc=$_f6a_rc)"

# --- F6 case B: render SUCCEEDS -> must still exit 0 ---
_TMPL_TAIL="$_tmpl_tail" bash >/dev/null 2>&1 <<'INNER'
set -euo pipefail
HY2_AUTH_PASS="auth-fixture"
HY2_OBFS_PASS="obfs-fixture"
log() { printf '%s\n' "$*"; }
re_render_hysteria2() { return 0; }
source "$_TMPL_TAIL"
INNER
_f6b_rc=$?
if [[ $_f6b_rc -ne 0 ]]; then
    fail "F6 case B: render succeeded but --templates-only exited $_f6b_rc — a healthy refresh must exit 0"
fi
pass "F6 case B: render succeeds → --templates-only exits 0"

echo
echo "--- F7: endpoint resolves from node-config.json when no env var carries it ---"

# upgrade.sh --templates-only never sets HY2_SERVER or HYSTERIA2_SERVER: the
# name appears nowhere in that script except a warning message, and
# refetch_node_config writes node-config.json to disk without exporting any of
# its fields. install.sh only has the value because it reads
# `json_get hysteria2_server` from the fetched config.
#
# With the fabricated TEST-NET default removed, that leaves the upgrade refresh
# path unable to resolve an endpoint at all — honest, but non-functional. The
# renderer must therefore fall back to the node-config the fleet already keeps
# on disk, so every caller resolves the endpoint the same way.
_f7_dir=$(mktemp -d)
cat > "$_f7_dir/node-config.json" <<'JSON'
{"node_id":"probe-node","hysteria2_server":"from-node-config.example:51822"}
JSON
cp "$REPO_ROOT/hysteria2-client.yaml.tpl" "$_f7_dir/" 2>/dev/null \
    || fail_exit "F7: template not found at $REPO_ROOT/hysteria2-client.yaml.tpl"

_f7_out=$(
    set +e
    _F7_DIR="$_f7_dir" _F7_LIB="$REPO_ROOT/channel-render-lib.sh" bash <<'INNER' 2>&1
set -uo pipefail
log()  { :; }
warn() { :; }
# Every env source of the endpoint is absent — only node-config.json has it.
unset HY2_SERVER HYSTERIA2_SERVER OXPULSE_HY2_SERVER
export NODE_CFG="$_F7_DIR/node-config.json"
export OXPULSE_REPO_DIR="$_F7_DIR"
export HY2_OUTPUT_PATH="$_F7_DIR/hysteria2-client.yaml"
export HY2_AUTH_PASS="auth-fixture" HY2_OBFS_PASS="obfs-fixture"
source "$_F7_LIB" 2>/dev/null
re_render_hysteria2 || echo "RENDER_FAILED"
grep -E '^server' "$HY2_OUTPUT_PATH" 2>/dev/null || echo "NO_SERVER_LINE"
INNER
)

if [[ "$_f7_out" == *"from-node-config.example:51822"* ]]; then
    pass "F7: endpoint resolved from node-config.json when no env var carries it"
else
    fail "F7: endpoint did NOT resolve from node-config.json — upgrade --templates-only cannot refresh hy2. Got: $_f7_out"
fi
rm -rf "$_f7_dir"

# ---------------------------------------------------------------------------
# Summary — record-and-continue harness: exit non-zero if any assertion
# fired.  A harness that forgets this exit turns every failure into a green
# suite, which is a worse version of the bug this file was fixed to catch.
# ---------------------------------------------------------------------------
if [[ $FAIL -ne 0 ]]; then
    echo "FAIL: hy2 server resolution gate — one or more checks failed" >&2
    exit 1
fi
echo
echo "All hy2 server resolution tests passed."
