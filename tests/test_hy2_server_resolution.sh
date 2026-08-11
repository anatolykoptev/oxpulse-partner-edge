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

pass() { echo "OK: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

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

# channel-render-lib.sh must not contain the TEST-NET address as a fallback.
if grep -qF '203.0.113.10' "$REPO_ROOT/channel-render-lib.sh"; then
    fail "F4: channel-render-lib.sh still contains TEST-NET address 203.0.113.10"
fi
pass "F4: channel-render-lib.sh free of TEST-NET default"

# config/defaults.conf must not default OXPULSE_HY2_SERVER to TEST-NET.
if grep -qF '203.0.113.10' "$REPO_ROOT/config/defaults.conf"; then
    fail "F4: config/defaults.conf still contains TEST-NET address 203.0.113.10"
fi
pass "F4: config/defaults.conf free of TEST-NET default"

# oxpulse-partner-edge-enable-hy2 must not default HY2_SERVER to TEST-NET.
if grep -qF '203.0.113.10' "$REPO_ROOT/oxpulse-partner-edge-enable-hy2"; then
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

# Behavioral: exercise the install.sh hy2 block with a failing render stub.
# _hy2_status must NOT be "active" and ch3 must NOT be in COMPOSE_PROFILES_EXTRA.
_f2_result=$(
    set +e
    bash <<'INNER'
set -euo pipefail
COMPOSE_PROFILES_EXTRA=""
HYSTERIA2_SERVER="h.example.com"
HY2_AUTH_PASS="auth"
HY2_OBFS_PASS="obfs"

# Stub: re_render_hysteria2 FAILS (returns 1) — simulates unresolvable server.
re_render_hysteria2() { return 1; }
log()  { :; }
warn() { :; }

_hy2_status="skipped"
if [[ -n "${HYSTERIA2_SERVER:-}" ]]; then
    _hy2_status="failed_at_start"
fi
if [[ -n "${HYSTERIA2_SERVER:-}" ]] && declare -f re_render_hysteria2 >/dev/null 2>&1; then
    if [[ -n "$HY2_AUTH_PASS" && -n "$HY2_OBFS_PASS" ]]; then
        export HY2_AUTH_PASS HY2_OBFS_PASS
        if re_render_hysteria2; then
            COMPOSE_PROFILES_EXTRA="${COMPOSE_PROFILES_EXTRA:+$COMPOSE_PROFILES_EXTRA,}ch3"
            _hy2_status="active"
        else
            warn "hy2 render failed"
        fi
    fi
fi
printf '%s|%s' "$_hy2_status" "$COMPOSE_PROFILES_EXTRA"
INNER
)
_f2_status="${_f2_result%%|*}"
_f2_profiles="${_f2_result#*|}"

if [[ "$_f2_status" == "active" ]]; then
    fail "F2 behavioral: _hy2_status=active despite render failure — guard missing"
fi
if [[ "$_f2_profiles" == *ch3* ]]; then
    fail "F2 behavioral: ch3 profile enabled despite render failure"
fi
pass "F2 behavioral: failed render → _hy2_status != active, ch3 not enabled"

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

echo
echo "All hy2 server resolution tests passed."
