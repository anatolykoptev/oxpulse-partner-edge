#!/bin/bash
# tests/test_coturn_skip_counter.sh — coturn consecutive-skip counter
#
# Verifies that lib/reconcile.sh correctly:
#   SK1  increments COTURN_SKIP_CONSECUTIVE in STATE_DIR/coturn-skip-count.env
#        on each converge cycle where _setup_coturn_render_env returns 2 (SKIP).
#   SK2  counter persists across multiple SKIP cycles (accumulates N → N+1 → …).
#   SK3  a successful coturn render (no-op sha-match) resets the counter to 0.
#   SK4  a successful coturn swap also resets the counter to 0.
#
# Falsification (RED proof):
#   SK1/SK2: if the increment block in reconcile_coturn_surface is removed, the
#            counter stays at 0 after a SKIP → SK1 assertion on count ≥ 1 fails.
#   SK3:     if the reset call on the no-op path is removed, the counter retains
#            its prior value after a successful render → SK3 assertion fails.
#
# Self-contained: runs in bash subshells with stub opec / docker / atomic_swap
# to avoid requiring the full edge stack.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LIB="$REPO_ROOT/lib/reconcile.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

[[ -f "$LIB" ]] || { echo "SKIP: lib/reconcile.sh not found"; exit 0; }

echo ""
echo "=== coturn consecutive-skip counter tests ==="

# ---------------------------------------------------------------------------
# SK1: first SKIP cycle writes COTURN_SKIP_CONSECUTIVE=1
# ---------------------------------------------------------------------------
_tmpdir=$(mktemp -d)
# shellcheck disable=SC2064
trap "rm -rf '$_tmpdir'" EXIT

_sk1_out=$(bash - << SHELLEOF 2>&1 || true
set -euo pipefail
REPO_ROOT=""
for _try in "\$PWD" "\$PWD/.." "\$HOME/src/oxpulse-partner-edge"; do
    [[ -f "\$_try/lib/reconcile.sh" ]] && { REPO_ROOT="\$_try"; break; }
done
LIB="\$REPO_ROOT/lib/reconcile.sh"
[[ -f "\$LIB" ]] || { echo "SKIP_NO_LIB"; exit 0; }

log()  { :; }
warn() { echo "[WARN] \$*" >&2; }
die()  { echo "[DIE] \$*" >&2; exit 1; }

# Stub opec so render path is never reached (SKIP comes from _setup_coturn).
opec() { return 0; }
export -f opec

PREFIX_ETC="$_tmpdir/etc"
STATE_DIR="$_tmpdir/state"
mkdir -p "\$PREFIX_ETC" "\$STATE_DIR"
# No coturn.conf.tpl, no installed coturn.conf, no STATE PUBLIC_IP → SKIP.
STATE_FILE="$_tmpdir/install.env"
cat > "\$STATE_FILE" << 'STATE'
PARTNER_DOMAIN=test.example.com
TURNS_SUBDOMAIN=api-test01
SCHEMA_VERSION=1
TURN_SECRET=test-secret
STATE
export PREFIX_ETC STATE_FILE STATE_DIR
export PARTNER_DOMAIN=test.example.com TURNS_SUBDOMAIN=api-test01
export TURN_SECRET=test-secret
export DOCKER_BIN="false"
export REPO_DIR="\$REPO_ROOT"

. "\$LIB"

# Supply a minimal tpl path so reconcile_coturn_surface reaches _setup_coturn.
_tpl="$_tmpdir/coturn.conf.tpl"
touch "\$_tpl"

# PUBLIC_IP absent → _setup_coturn_render_env returns 2 → SKIP path.
reconcile_coturn_surface "\$PREFIX_ETC" "\$_tpl" 2>/dev/null || true

# Read back the counter.
_skip_file="\$STATE_DIR/coturn-skip-count.env"
if [[ -f "\$_skip_file" ]]; then
    _count=\$(grep '^COTURN_SKIP_CONSECUTIVE=' "\$_skip_file" | cut -d= -f2 || true)
    echo "COUNT=\${_count:-0}"
else
    echo "COUNT=0"
fi
echo "DONE"
SHELLEOF
)

if echo "$_sk1_out" | grep "SKIP_NO_LIB" >/dev/null; then
    fail "SK1: lib/reconcile.sh not found"
elif echo "$_sk1_out" | grep "DONE" >/dev/null; then
    _count=$(echo "$_sk1_out" | grep '^COUNT=' | cut -d= -f2)
    if [[ "${_count:-0}" -ge 1 ]]; then
        pass "SK1: first SKIP writes COTURN_SKIP_CONSECUTIVE=${_count} (≥1)"
    else
        fail "SK1: COTURN_SKIP_CONSECUTIVE=${_count:-0} after first SKIP (expected ≥1)"
    fi
else
    fail "SK1: subshell crashed or reconcile_coturn_surface not found"
fi

# ---------------------------------------------------------------------------
# SK2: N consecutive SKIPs accumulate the counter (N → N+1)
# ---------------------------------------------------------------------------
_tmpdir2=$(mktemp -d)

_sk2_out=$(bash - << SHELLEOF 2>&1 || true
set -euo pipefail
REPO_ROOT=""
for _try in "\$PWD" "\$PWD/.." "\$HOME/src/oxpulse-partner-edge"; do
    [[ -f "\$_try/lib/reconcile.sh" ]] && { REPO_ROOT="\$_try"; break; }
done
LIB="\$REPO_ROOT/lib/reconcile.sh"
[[ -f "\$LIB" ]] || { echo "SKIP_NO_LIB"; exit 0; }

log()  { :; }
warn() { :; }
die()  { echo "[DIE] \$*" >&2; exit 1; }

opec() { return 0; }
export -f opec

PREFIX_ETC="$_tmpdir2/etc"
STATE_DIR="$_tmpdir2/state"
mkdir -p "\$PREFIX_ETC" "\$STATE_DIR"
STATE_FILE="$_tmpdir2/install.env"
cat > "\$STATE_FILE" << 'STATE'
PARTNER_DOMAIN=test.example.com
TURNS_SUBDOMAIN=api-test01
SCHEMA_VERSION=1
TURN_SECRET=test-secret
STATE
export PREFIX_ETC STATE_FILE STATE_DIR DOCKER_BIN="false"
export PARTNER_DOMAIN=test.example.com TURNS_SUBDOMAIN=api-test01
export TURN_SECRET=test-secret REPO_DIR="\$REPO_ROOT"

. "\$LIB"

_tpl="$_tmpdir2/coturn.conf.tpl"
touch "\$_tpl"

# Three consecutive SKIPs.
reconcile_coturn_surface "\$PREFIX_ETC" "\$_tpl" 2>/dev/null || true
reconcile_coturn_surface "\$PREFIX_ETC" "\$_tpl" 2>/dev/null || true
reconcile_coturn_surface "\$PREFIX_ETC" "\$_tpl" 2>/dev/null || true

_skip_file="\$STATE_DIR/coturn-skip-count.env"
_count=\$(grep '^COTURN_SKIP_CONSECUTIVE=' "\$_skip_file" 2>/dev/null | cut -d= -f2 || echo 0)
echo "COUNT=\${_count}"
echo "DONE"
SHELLEOF
)

rm -rf "$_tmpdir2"

if echo "$_sk2_out" | grep "SKIP_NO_LIB" >/dev/null; then
    fail "SK2: lib/reconcile.sh not found"
elif echo "$_sk2_out" | grep "DONE" >/dev/null; then
    _count=$(echo "$_sk2_out" | grep '^COUNT=' | cut -d= -f2)
    if [[ "${_count:-0}" -ge 3 ]]; then
        pass "SK2: 3 consecutive SKIPs → COTURN_SKIP_CONSECUTIVE=${_count} (accumulated)"
    else
        fail "SK2: 3 consecutive SKIPs → COTURN_SKIP_CONSECUTIVE=${_count:-0} (expected ≥3)"
    fi
else
    fail "SK2: subshell crashed"
fi

# ---------------------------------------------------------------------------
# SK3: successful render (no-op, sha unchanged) resets counter to 0
# ---------------------------------------------------------------------------
_tmpdir3=$(mktemp -d)

_sk3_out=$(bash - << SHELLEOF 2>&1 || true
set -euo pipefail
REPO_ROOT=""
for _try in "\$PWD" "\$PWD/.." "\$HOME/src/oxpulse-partner-edge"; do
    [[ -f "\$_try/lib/reconcile.sh" ]] && { REPO_ROOT="\$_try"; break; }
done
LIB="\$REPO_ROOT/lib/reconcile.sh"
[[ -f "\$LIB" ]] || { echo "SKIP_NO_LIB"; exit 0; }

log()  { :; }
warn() { :; }
die()  { echo "[DIE] \$*" >&2; exit 1; }

_SWAP_COUNT=0
atomic_swap() { _SWAP_COUNT=\$((_SWAP_COUNT+1)); }

# opec render coturn: writes a stable mock config to --out.
opec() {
    if [[ "\${1:-}" == "render" && "\${2:-}" == "coturn" ]]; then
        local _o=""
        local _i; for _i in "\$@"; do
            [[ "\${_out_next:-0}" == "1" ]] && _o="\$_i" && _out_next=0
            [[ "\$_i" == "--out" ]] && _out_next=1
        done
        [[ -n "\$_o" ]] && printf '# mock coturn\nstatic-auth-secret=test-secret\n' > "\$_o"
        return 0
    fi
    return 0
}
export -f opec

PREFIX_ETC="$_tmpdir3/etc"
STATE_DIR="$_tmpdir3/state"
mkdir -p "\$PREFIX_ETC" "\$STATE_DIR"
STATE_FILE="$_tmpdir3/install.env"
cat > "\$STATE_FILE" << 'STATE'
PARTNER_DOMAIN=test.example.com
TURNS_SUBDOMAIN=api-test01
SCHEMA_VERSION=1
TURN_SECRET=test-secret
PUBLIC_IP=1.2.3.4
STATE
export PREFIX_ETC STATE_FILE STATE_DIR DOCKER_BIN="false"
export PARTNER_DOMAIN=test.example.com TURNS_SUBDOMAIN=api-test01
export TURN_SECRET=test-secret PUBLIC_IP=1.2.3.4 REPO_DIR="\$REPO_ROOT"

. "\$LIB"

_tpl="$_tmpdir3/coturn.conf.tpl"
touch "\$_tpl"

# Seed the counter with a non-zero value to simulate prior SKIPs.
_write_coturn_skip_count 5 "\$STATE_DIR"

_skip_file="\$STATE_DIR/coturn-skip-count.env"
_before=\$(grep '^COTURN_SKIP_CONSECUTIVE=' "\$_skip_file" 2>/dev/null | cut -d= -f2 || echo 0)
echo "BEFORE=\${_before}"

# Run a successful render (PUBLIC_IP is available; sha-compare yields no-op swap).
reconcile_coturn_surface "\$PREFIX_ETC" "\$_tpl" 2>/dev/null || true

_after=\$(grep '^COTURN_SKIP_CONSECUTIVE=' "\$_skip_file" 2>/dev/null | cut -d= -f2 || echo -1)
echo "AFTER=\${_after}"
echo "DONE"
SHELLEOF
)

rm -rf "$_tmpdir3"

if echo "$_sk3_out" | grep "SKIP_NO_LIB" >/dev/null; then
    fail "SK3: lib/reconcile.sh not found"
elif echo "$_sk3_out" | grep "DONE" >/dev/null; then
    _before=$(echo "$_sk3_out" | grep '^BEFORE=' | cut -d= -f2)
    _after=$(echo "$_sk3_out"  | grep '^AFTER='  | cut -d= -f2)
    if [[ "${_before:-0}" -ge 5 && "${_after:-1}" -eq 0 ]]; then
        pass "SK3: successful render resets counter ${_before} → ${_after}"
    else
        fail "SK3: before=${_before:-?} after=${_after:-?} (expected before≥5, after=0)"
    fi
else
    fail "SK3: subshell crashed"
fi

# ---------------------------------------------------------------------------
# SK4: successful swap also resets counter to 0
# ---------------------------------------------------------------------------
_tmpdir4=$(mktemp -d)

_sk4_out=$(bash - << SHELLEOF 2>&1 || true
set -euo pipefail
REPO_ROOT=""
for _try in "\$PWD" "\$PWD/.." "\$HOME/src/oxpulse-partner-edge"; do
    [[ -f "\$_try/lib/reconcile.sh" ]] && { REPO_ROOT="\$_try"; break; }
done
LIB="\$REPO_ROOT/lib/reconcile.sh"
[[ -f "\$LIB" ]] || { echo "SKIP_NO_LIB"; exit 0; }

log()  { :; }
warn() { :; }
die()  { echo "[DIE] \$*" >&2; exit 1; }

# opec render coturn writes distinct content each call so the first call
# produces a new installed file (swap) and resets the counter.
_RENDER_COUNTER=0
opec() {
    if [[ "\${1:-}" == "render" && "\${2:-}" == "coturn" ]]; then
        local _o=""
        local _i; for _i in "\$@"; do
            [[ "\${_out_next:-0}" == "1" ]] && _o="\$_i" && _out_next=0
            [[ "\$_i" == "--out" ]] && _out_next=1
        done
        _RENDER_COUNTER=\$((_RENDER_COUNTER+1))
        [[ -n "\$_o" ]] && printf '# mock coturn run %d\nstatic-auth-secret=test-secret\n' "\$_RENDER_COUNTER" > "\$_o"
        return 0
    fi
    return 0
}
export -f opec

PREFIX_ETC="$_tmpdir4/etc"
STATE_DIR="$_tmpdir4/state"
mkdir -p "\$PREFIX_ETC" "\$STATE_DIR"
STATE_FILE="$_tmpdir4/install.env"
cat > "\$STATE_FILE" << 'STATE'
PARTNER_DOMAIN=test.example.com
TURNS_SUBDOMAIN=api-test01
SCHEMA_VERSION=1
TURN_SECRET=test-secret
PUBLIC_IP=1.2.3.4
STATE
export PREFIX_ETC STATE_FILE STATE_DIR DOCKER_BIN="false"
export PARTNER_DOMAIN=test.example.com TURNS_SUBDOMAIN=api-test01
export TURN_SECRET=test-secret PUBLIC_IP=1.2.3.4 REPO_DIR="\$REPO_ROOT"

. "\$LIB"

_tpl="$_tmpdir4/coturn.conf.tpl"
touch "\$_tpl"

# Seed counter with a non-zero value.
_write_coturn_skip_count 7 "\$STATE_DIR"

_skip_file="\$STATE_DIR/coturn-skip-count.env"
_before=\$(grep '^COTURN_SKIP_CONSECUTIVE=' "\$_skip_file" 2>/dev/null | cut -d= -f2 || echo 0)
echo "BEFORE=\${_before}"

# First render: no installed file → swap (distinct sha vs absent) → counter resets.
reconcile_coturn_surface "\$PREFIX_ETC" "\$_tpl" 2>/dev/null || true

_after=\$(grep '^COTURN_SKIP_CONSECUTIVE=' "\$_skip_file" 2>/dev/null | cut -d= -f2 || echo -1)
_installed_exists=0
[[ -f "\$PREFIX_ETC/coturn.conf" ]] && _installed_exists=1
echo "AFTER=\${_after}"
echo "INSTALLED=\${_installed_exists}"
echo "DONE"
SHELLEOF
)

rm -rf "$_tmpdir4"

if echo "$_sk4_out" | grep "SKIP_NO_LIB" >/dev/null; then
    fail "SK4: lib/reconcile.sh not found"
elif echo "$_sk4_out" | grep "DONE" >/dev/null; then
    _before=$(echo "$_sk4_out" | grep '^BEFORE='    | cut -d= -f2)
    _after=$(echo "$_sk4_out"  | grep '^AFTER='     | cut -d= -f2)
    _inst=$(echo "$_sk4_out"   | grep '^INSTALLED=' | cut -d= -f2)
    if [[ "${_before:-0}" -ge 7 && "${_inst:-0}" -eq 1 && "${_after:-1}" -eq 0 ]]; then
        pass "SK4: successful swap resets counter ${_before} → ${_after} (installed=${_inst})"
    else
        fail "SK4: before=${_before:-?} installed=${_inst:-?} after=${_after:-?} (expected before≥7, installed=1, after=0)"
    fi
else
    fail "SK4: subshell crashed"
fi

# ---------------------------------------------------------------------------
# SK5: genuine no-op (sha-match) resets counter to 0
#
# Pre-install a coturn.conf whose sha256 MATCHES the rendered mock output so
# the reconcile path hits the idempotency branch at reconcile.sh:1148 (the
# sha-equality guard) rather than the swap branch.  Counter must reset.
#
# Falsification: if the _write_coturn_skip_count 0 call at the no-op branch
# (reconcile.sh:1148) is removed, the counter retains its prior value after
# this reconcile → the assertion after≠0 fails → SK5 goes RED.
# ---------------------------------------------------------------------------
_tmpdir5=$(mktemp -d)

_sk5_out=$(bash - << SHELLEOF 2>&1 || true
set -euo pipefail
REPO_ROOT=""
for _try in "\$PWD" "\$PWD/.." "\$HOME/src/oxpulse-partner-edge"; do
    [[ -f "\$_try/lib/reconcile.sh" ]] && { REPO_ROOT="\$_try"; break; }
done
LIB="\$REPO_ROOT/lib/reconcile.sh"
[[ -f "\$LIB" ]] || { echo "SKIP_NO_LIB"; exit 0; }

log()  { :; }
warn() { :; }
die()  { echo "[DIE] \$*" >&2; exit 1; }

# Mock opec: writes a fixed, stable config every call so rendered sha == installed sha.
_MOCK_CONTENT='# mock coturn fixed
static-auth-secret=test-secret
'
opec() {
    if [[ "\${1:-}" == "render" && "\${2:-}" == "coturn" ]]; then
        local _o=""
        local _i; for _i in "\$@"; do
            [[ "\${_out_next:-0}" == "1" ]] && _o="\$_i" && _out_next=0
            [[ "\$_i" == "--out" ]] && _out_next=1
        done
        [[ -n "\$_o" ]] && printf '%s' "\$_MOCK_CONTENT" > "\$_o"
        return 0
    fi
    return 0
}
export -f opec

PREFIX_ETC="$_tmpdir5/etc"
STATE_DIR="$_tmpdir5/state"
mkdir -p "\$PREFIX_ETC" "\$STATE_DIR"
STATE_FILE="$_tmpdir5/install.env"
cat > "\$STATE_FILE" << 'STATE'
PARTNER_DOMAIN=test.example.com
TURNS_SUBDOMAIN=api-test05
SCHEMA_VERSION=1
TURN_SECRET=test-secret
PUBLIC_IP=1.2.3.4
STATE
export PREFIX_ETC STATE_FILE STATE_DIR DOCKER_BIN="false"
export PARTNER_DOMAIN=test.example.com TURNS_SUBDOMAIN=api-test05
export TURN_SECRET=test-secret PUBLIC_IP=1.2.3.4 REPO_DIR="\$REPO_ROOT"

. "\$LIB"

_tpl="$_tmpdir5/coturn.conf.tpl"
touch "\$_tpl"

# Pre-install coturn.conf with content that MATCHES the mock render output.
# This forces the sha-equality branch (no-op) not the swap branch.
printf '%s' "\$_MOCK_CONTENT" > "\$PREFIX_ETC/coturn.conf"

# Seed counter with a non-zero value to verify it gets reset.
_write_coturn_skip_count 9 "\$STATE_DIR"

_skip_file="\$STATE_DIR/coturn-skip-count.env"
_before=\$(grep '^COTURN_SKIP_CONSECUTIVE=' "\$_skip_file" 2>/dev/null | cut -d= -f2 || echo 0)
echo "BEFORE=\${_before}"

# Run: rendered sha == installed sha → no-op branch → reset.
reconcile_coturn_surface "\$PREFIX_ETC" "\$_tpl" 2>/dev/null || true

_after=\$(grep '^COTURN_SKIP_CONSECUTIVE=' "\$_skip_file" 2>/dev/null | cut -d= -f2 || echo -1)
echo "AFTER=\${_after}"
echo "DONE"
SHELLEOF
)

rm -rf "$_tmpdir5"

if echo "$_sk5_out" | grep "SKIP_NO_LIB" >/dev/null; then
    fail "SK5: lib/reconcile.sh not found"
elif echo "$_sk5_out" | grep "DONE" >/dev/null; then
    _before=$(echo "$_sk5_out" | grep '^BEFORE=' | cut -d= -f2)
    _after=$(echo "$_sk5_out"  | grep '^AFTER='  | cut -d= -f2)
    if [[ "${_before:-0}" -ge 9 && "${_after:-1}" -eq 0 ]]; then
        pass "SK5: genuine no-op (sha-match) resets counter ${_before} → ${_after}"
    else
        fail "SK5: before=${_before:-?} after=${_after:-?} (expected before≥9, after=0) — no-op reset missing?"
    fi
else
    fail "SK5: subshell crashed"
fi

# ---------------------------------------------------------------------------
# SK6: DRY_RUN=1 resets counter to 0
#
# When DRY_RUN=1 the reconcile function renders but does NOT swap; it still
# proves external-ip was resolved, so the counter must be reset.  This
# exercises the reset at reconcile.sh:1134.
#
# Falsification: if the _write_coturn_skip_count 0 call at the dry-run branch
# (reconcile.sh:1134) is removed, the counter retains its prior value →
# assertion after≠0 fails → SK6 goes RED.
# ---------------------------------------------------------------------------
_tmpdir6=$(mktemp -d)

_sk6_out=$(bash - << SHELLEOF 2>&1 || true
set -euo pipefail
REPO_ROOT=""
for _try in "\$PWD" "\$PWD/.." "\$HOME/src/oxpulse-partner-edge"; do
    [[ -f "\$_try/lib/reconcile.sh" ]] && { REPO_ROOT="\$_try"; break; }
done
LIB="\$REPO_ROOT/lib/reconcile.sh"
[[ -f "\$LIB" ]] || { echo "SKIP_NO_LIB"; exit 0; }

log()  { :; }
warn() { :; }
die()  { echo "[DIE] \$*" >&2; exit 1; }

opec() {
    if [[ "\${1:-}" == "render" && "\${2:-}" == "coturn" ]]; then
        local _o=""
        local _i; for _i in "\$@"; do
            [[ "\${_out_next:-0}" == "1" ]] && _o="\$_i" && _out_next=0
            [[ "\$_i" == "--out" ]] && _out_next=1
        done
        [[ -n "\$_o" ]] && printf '# mock coturn dry\nstatic-auth-secret=test-secret\n' > "\$_o"
        return 0
    fi
    return 0
}
export -f opec

PREFIX_ETC="$_tmpdir6/etc"
STATE_DIR="$_tmpdir6/state"
mkdir -p "\$PREFIX_ETC" "\$STATE_DIR"
STATE_FILE="$_tmpdir6/install.env"
cat > "\$STATE_FILE" << 'STATE'
PARTNER_DOMAIN=test.example.com
TURNS_SUBDOMAIN=api-test06
SCHEMA_VERSION=1
TURN_SECRET=test-secret
PUBLIC_IP=1.2.3.4
STATE
export PREFIX_ETC STATE_FILE STATE_DIR DOCKER_BIN="false"
export PARTNER_DOMAIN=test.example.com TURNS_SUBDOMAIN=api-test06
export TURN_SECRET=test-secret PUBLIC_IP=1.2.3.4 REPO_DIR="\$REPO_ROOT"
export DRY_RUN=1

. "\$LIB"

_tpl="$_tmpdir6/coturn.conf.tpl"
touch "\$_tpl"

# Seed counter; DRY_RUN=1 should still reset it.
_write_coturn_skip_count 3 "\$STATE_DIR"

_skip_file="\$STATE_DIR/coturn-skip-count.env"
_before=\$(grep '^COTURN_SKIP_CONSECUTIVE=' "\$_skip_file" 2>/dev/null | cut -d= -f2 || echo 0)
echo "BEFORE=\${_before}"

reconcile_coturn_surface "\$PREFIX_ETC" "\$_tpl" 2>/dev/null || true

_after=\$(grep '^COTURN_SKIP_CONSECUTIVE=' "\$_skip_file" 2>/dev/null | cut -d= -f2 || echo -1)
echo "AFTER=\${_after}"
echo "DONE"
SHELLEOF
)

rm -rf "$_tmpdir6"

if echo "$_sk6_out" | grep "SKIP_NO_LIB" >/dev/null; then
    fail "SK6: lib/reconcile.sh not found"
elif echo "$_sk6_out" | grep "DONE" >/dev/null; then
    _before=$(echo "$_sk6_out" | grep '^BEFORE=' | cut -d= -f2)
    _after=$(echo "$_sk6_out"  | grep '^AFTER='  | cut -d= -f2)
    if [[ "${_before:-0}" -ge 3 && "${_after:-1}" -eq 0 ]]; then
        pass "SK6: DRY_RUN=1 resets counter ${_before} → ${_after}"
    else
        fail "SK6: before=${_before:-?} after=${_after:-?} (expected before≥3, after=0) — dry-run reset missing?"
    fi
else
    fail "SK6: subshell crashed"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== Results: PASS=$PASS FAIL=$FAIL ==="
[[ "$FAIL" -eq 0 ]]

# SK5: mktemp failure must log a warning, not silently return 0
# Regression guard for #432
test_mktemp_failure_warns() {
    local fn_body
    fn_body=$(grep -A20 "^_write_coturn_skip_count()" "$LIB")
    echo "$fn_body" | grep "mktemp.*failed\|WARNING.*mktemp" >/dev/null \
        && pass "SK5: mktemp failure logs warning" \
        || fail "SK5: mktemp failure does not log warning"
}
test_mktemp_failure_warns
