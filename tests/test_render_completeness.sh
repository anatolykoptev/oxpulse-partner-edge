#!/bin/bash
# tests/test_render_completeness.sh — Phase 1 CI guard (S1).
#
# Verifies that every {{PLACEHOLDER}} in Caddyfile.tpl has env-export coverage
# in install.sh + upgrade.sh, so the runtime completeness guard can never pass
# a broken render to a live edge.
#
# Tests:
#   1. Caddyfile.tpl — all {{VAR}} have export in install.sh or upgrade.sh.
#   2. RED guard: a fake {{UNCOVERED_VAR_RECONCILE_TEST}} is caught as missing.
#   3. The 6 expected Caddyfile.tpl placeholders are all present and covered.
#   4. assert_no_unresolved_placeholders (lib/reconcile.sh) fires on leftover.
#   5. lib/reconcile.sh primitives: atomic_swap, mark_restart dedup.
#
# Scope: Caddyfile.tpl only (Phase 1; other surfaces are Phase 4).
# channel-render-lib.sh-managed templates (hysteria2, xray, coturn) are tested
# by their own existing tests.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$REPO_ROOT/install.sh"
UPGRADE="$REPO_ROOT/upgrade.sh"
RECONCILE_LIB_SH="$REPO_ROOT/lib/reconcile.sh"

[[ -f "$INSTALL" ]] || { echo "FAIL: install.sh not found"; exit 1; }
[[ -f "$UPGRADE" ]] || { echo "FAIL: upgrade.sh not found"; exit 1; }

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Extract all {{VAR}} placeholders from a file.
tpl_placeholders() {
    grep -oE '\{\{[A-Z][A-Z0-9_]*\}\}' "$1" 2>/dev/null | sort -u || true
}

# Check that VAR has export coverage in install.sh or upgrade.sh.
# Handles multi-line export blocks (VAR on continuation lines following export).
# Returns 0 (true) if covered, 1 if not.
var_is_exported() {
    local var="$1"
    # Concat continuation lines (backslash at end) and grep for the var.
    # This handles:  export VAR1 \
    #                       VAR2 \
    #                       VAR3
    local _joined
    for f in "$INSTALL" "$UPGRADE" "$RECONCILE_LIB_SH"; do
        _joined=$(sed ':a;N;$!ba;s/\\\n/ /g' "$f" 2>/dev/null || true)
        echo "$_joined" | grep -E "\bexport\b[^#\n]*\b${var}\b" >/dev/null && return 0
        # Also: explicit assignment line (VAR=...) even if separate from export
        grep -qE "^\s*${var}=" "$f" 2>/dev/null && return 0
        # Also: export VAR=... form
        grep -qE "\bexport\b\s*${var}=" "$f" 2>/dev/null && return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
# Test 1: Caddyfile.tpl — all {{VAR}} have export coverage
# ---------------------------------------------------------------------------
echo "==> Test 1: Caddyfile.tpl {{VAR}} export coverage in install.sh/upgrade.sh/lib/reconcile.sh"
CADDY_TPL="$REPO_ROOT/Caddyfile.tpl"
[[ -f "$CADDY_TPL" ]] || { fail "Caddyfile.tpl not found"; echo "Results: $PASS passed, $FAIL failed"; exit 1; }

missing_exports=()
while IFS= read -r placeholder; do
    [[ -n "$placeholder" ]] || continue
    var="${placeholder//\{/}"; var="${var//\}/}"
    if ! var_is_exported "$var"; then
        missing_exports+=("{{$var}}")
    fi
done < <(tpl_placeholders "$CADDY_TPL")

if [[ "${#missing_exports[@]}" -eq 0 ]]; then
    caddy_vars=$(tpl_placeholders "$CADDY_TPL" | tr '\n' ' ')
    pass "all Caddyfile.tpl placeholders exported: $caddy_vars"
else
    fail "Caddyfile.tpl: missing export for: ${missing_exports[*]}"
fi

# ---------------------------------------------------------------------------
# Test 2: RED guard — fake {{UNCOVERED_VAR_RECONCILE_TEST}} causes failure
# ---------------------------------------------------------------------------
echo "==> Test 2: RED guard — fake placeholder is caught as missing"
FAKE_MISSING=0
var="UNCOVERED_VAR_RECONCILE_TEST_XYZ"
var_is_exported "$var" && FAKE_MISSING=0 || FAKE_MISSING=1

if [[ $FAKE_MISSING -eq 1 ]]; then
    pass "RED guard: UNCOVERED_VAR_RECONCILE_TEST_XYZ correctly flagged as missing"
else
    fail "RED guard: var_is_exported returned true for a fake var — check is broken"
fi

# ---------------------------------------------------------------------------
# Test 3: the 6 expected Caddyfile.tpl placeholders are present and covered
# ---------------------------------------------------------------------------
echo "==> Test 3: Caddyfile.tpl 6-placeholder presence + coverage"
EXPECTED_CADDY_VARS=(
    "PARTNER_DOMAIN"
    "TURNS_SUBDOMAIN"
    "AWG_MOTHERLY_IP"
    "HY2_FALLBACK_HOST"
    "HY2_FALLBACK_PORT"
    "NAIVE_SOCKS_PORT"
)
caddy_issues=()
for var in "${EXPECTED_CADDY_VARS[@]}"; do
    if ! grep -qF "{{${var}}}" "$CADDY_TPL" 2>/dev/null; then
        caddy_issues+=("{{${var}}} missing from Caddyfile.tpl")
    fi
    if ! var_is_exported "$var"; then
        caddy_issues+=("$var not exported in install.sh/upgrade.sh/lib/reconcile.sh")
    fi
done
if [[ "${#caddy_issues[@]}" -eq 0 ]]; then
    pass "all 6 Caddyfile.tpl placeholders present and exported"
else
    fail "Caddyfile.tpl 6-placeholder coverage: ${caddy_issues[*]}"
fi

# ---------------------------------------------------------------------------
# Test 4: assert_no_unresolved_placeholders (lib/reconcile.sh) runtime guard
# ---------------------------------------------------------------------------
echo "==> Test 4: assert_no_unresolved_placeholders fires on leftover {{X}}"

RECONCILE_LIB="$REPO_ROOT/lib/reconcile.sh"
[[ -f "$RECONCILE_LIB" ]] || { fail "lib/reconcile.sh not found"; echo "Results: $PASS passed, $FAIL failed"; exit 1; }

T4_TMP=$(mktemp -d)
RENDERED_WITH_LEFTOVER="$T4_TMP/leftover.conf"
RENDERED_CLEAN="$T4_TMP/clean.conf"
cleanup4() { rm -rf "$T4_TMP"; }
trap cleanup4 EXIT

printf 'site domain.example {\n  reverse_proxy 127.0.0.1:8080\n}\n{{LEFTOVER_PLACEHOLDER}}\n' \
    > "$RENDERED_WITH_LEFTOVER"
printf 'site domain.example {\n  reverse_proxy 127.0.0.1:8080\n}\n' \
    > "$RENDERED_CLEAN"

ASSERT_RC=0
ASSERT_OUT=$(
    bash -c '
        set -euo pipefail
        die() { printf "ERR %s\n" "$*" >&2; exit 1; }
        log() { printf "==> %s\n" "$*" >&2; }
        warn() { printf "!! %s\n" "$*" >&2; }
        _RECONCILE_LIB_LOADED=0
        # shellcheck source=lib/reconcile.sh
        source "'"$RECONCILE_LIB"'"
        assert_no_unresolved_placeholders "'"$RENDERED_WITH_LEFTOVER"'"
    ' 2>&1
) || ASSERT_RC=$?

if [[ $ASSERT_RC -ne 0 ]] && echo "$ASSERT_OUT" | grep -i "LEFTOVER_PLACEHOLDER" >/dev/null; then
    pass "assert_no_unresolved_placeholders: fires and names the leftover placeholder"
else
    fail "assert_no_unresolved_placeholders: did NOT fire (rc=$ASSERT_RC, out=$ASSERT_OUT)"
fi

CLEAN_RC=0
CLEAN_OUT=$(
    bash -c '
        set -euo pipefail
        die() { printf "ERR %s\n" "$*" >&2; exit 1; }
        log() { printf "==> %s\n" "$*" >&2; }
        warn() { printf "!! %s\n" "$*" >&2; }
        _RECONCILE_LIB_LOADED=0
        # shellcheck source=lib/reconcile.sh
        source "'"$RECONCILE_LIB"'"
        assert_no_unresolved_placeholders "'"$RENDERED_CLEAN"'"
    ' 2>&1
) || CLEAN_RC=$?

if [[ $CLEAN_RC -eq 0 ]]; then
    pass "assert_no_unresolved_placeholders: passes on fully-rendered clean file"
else
    fail "assert_no_unresolved_placeholders: falsely fired on clean file (rc=$CLEAN_RC, out=$CLEAN_OUT)"
fi

# ---------------------------------------------------------------------------
# Test 5: lib/reconcile.sh primitives: atomic_swap, mark_restart dedup
# ---------------------------------------------------------------------------
echo "==> Test 5: lib/reconcile.sh primitives (atomic_swap, mark_restart dedup)"

T5_TMP=$(mktemp -d)
T5_SRC="$T5_TMP/src.txt"
T5_DST="$T5_TMP/dst.txt"
printf 'hello world\n' > "$T5_SRC"
printf 'old content\n' > "$T5_DST"
cleanup5() { rm -rf "$T5_TMP"; }
trap 'cleanup4; cleanup5' EXIT

T5_RC=0
T5_OUT=$(
    bash -c '
        set -euo pipefail
        die() { printf "ERR %s\n" "$*" >&2; exit 1; }
        log() { printf "==> %s\n" "$*" >&2; }
        warn() { printf "!! %s\n" "$*" >&2; }
        _RECONCILE_LIB_LOADED=0
        source "'"$RECONCILE_LIB"'"

        atomic_swap "'"$T5_DST"'" "'"$T5_SRC"'" 0644
        content=$(cat "'"$T5_DST"'")
        [[ "$content" == "hello world" ]] || die "atomic_swap: wrong content: $content"

        mark_restart "unit-a.service"
        mark_restart "unit-b.service"
        mark_restart "unit-a.service"
        [[ "$_RECONCILE_RESTART_UNITS" == "unit-a.service unit-b.service" ]] \
            || die "dedup failed: $_RECONCILE_RESTART_UNITS"

        echo "PRIMITIVES_OK"
    ' 2>&1
) || T5_RC=$?

if [[ $T5_RC -eq 0 ]] && echo "$T5_OUT" | grep "PRIMITIVES_OK" >/dev/null; then
    pass "atomic_swap and mark_restart dedup work correctly"
else
    fail "lib primitives smoke test failed (rc=$T5_RC): $T5_OUT"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
