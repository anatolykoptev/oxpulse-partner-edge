#!/bin/bash
# Regression: install.sh keygen delegation to opec
#
# Phase 5.3: partner-cli keygen removed. install.sh now delegates ALL reality
# and AWG keypair generation to `opec secrets reality-keygen` / `opec secrets
# awg-keygen`. Idempotency and partial-state guards are handled inside opec
# (tested by Rust unit tests in crates/opec/tests/secrets_reality_{unit,native}.rs
# and crates/opec/tests/secrets_awg_{unit,native}.rs).
#
# This test verifies the install.sh-level wiring:
#   Case 1: reality keygen block invokes `opec secrets reality-keygen`
#   Case 2: awg keygen block invokes `opec secrets awg-keygen`
#   Case 3: --force-keygen / --rotate-identity maps to opec --rotate in both reality and AWG blocks
#   Case 4: dry-run block mentions opec invocation (not partner-cli)
#   Case 5: install.sh syntax check
#
# Test method: static analysis of install.sh.
# We do NOT execute install.sh (it requires root + real infra).
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
INSTALL="$REPO_ROOT/install.sh"

[[ -f "$INSTALL" ]] || { echo "FAIL: install.sh not found at $INSTALL"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Extract the Reality keygen block: from REALITY_PRIV_PATH= to the end of the
# REALITY_UUID assignment (includes both dry-run and live paths).
awk '/^REALITY_PRIV_PATH=/ { capture=1 } capture { print } capture && /REALITY_UUID=/ { exit }' \
    "$INSTALL" > "$TMP/reality_block.txt"

[[ -s "$TMP/reality_block.txt" ]] \
    || { echo "FAIL: could not locate Reality keygen block in install.sh"; exit 1; }

# Extract the AWG keygen block: from AWG_PRIV_PATH= onwards.
awk '/^AWG_PRIV_PATH=/ { capture=1 } capture { print } capture && /AWG_PUBKEY=/ { exit }' \
    "$INSTALL" > "$TMP/awg_block.txt"

[[ -s "$TMP/awg_block.txt" ]] \
    || { echo "FAIL: could not locate AWG keygen block in install.sh"; exit 1; }

# ── Case 1: Reality keygen block delegates to opec ─────────────────────────
grep -qE 'opec.*reality-keygen|reality-keygen.*--out-dir' "$TMP/reality_block.txt" \
    || { echo "FAIL [case1]: reality keygen block does not invoke opec secrets reality-keygen"; exit 1; }

# Must NOT invoke partner-cli keygen (retired in Phase 5.3).
if grep -q 'partner-cli keygen' "$TMP/reality_block.txt"; then
    echo "FAIL [case1]: reality keygen block still references partner-cli keygen (must be removed)"
    exit 1
fi

# ── Case 2: AWG keygen block delegates to opec ─────────────────────────────
grep -qE 'opec.*awg-keygen|awg-keygen.*--out-dir' "$TMP/awg_block.txt" \
    || { echo "FAIL [case2]: awg keygen block does not invoke opec secrets awg-keygen"; exit 1; }

# Must NOT invoke wg genkey (retired in Phase 5.3).
if grep -qE '\bwg\b.*genkey' "$TMP/awg_block.txt"; then
    echo "FAIL [case2]: awg keygen block still references wg genkey (must be removed)"
    exit 1
fi

# ── Case 3: --force-keygen maps to --rotate passed to opec ─────────────────
# The arg parser must still accept --force-keygen / --rotate-identity.
grep -qE -- '--force-keygen|--rotate-identity' "$INSTALL" \
    || { echo "FAIL [case3]: install.sh does not accept --force-keygen or --rotate-identity flag"; exit 1; }

# The reality keygen block must pass --rotate to opec when FORCE_KEYGEN=1.
grep -qE 'FORCE_KEYGEN.*--rotate|--rotate.*FORCE_KEYGEN' "$TMP/reality_block.txt" \
    || { echo "FAIL [case3]: reality keygen block does not pass --rotate to opec when FORCE_KEYGEN=1"; exit 1; }

# The awg keygen block must pass --rotate to opec when FORCE_KEYGEN=1.
grep -qE 'FORCE_KEYGEN.*--rotate|--rotate.*FORCE_KEYGEN' "$TMP/awg_block.txt" \
    || { echo "FAIL [case3]: awg keygen block does not pass --rotate to opec when FORCE_KEYGEN=1"; exit 1; }

# ── Case 4: Dry-run block references opec, not partner-cli ─────────────────
grep -qiE 'dry.run.*opec|opec.*reality-keygen' "$TMP/reality_block.txt" \
    || { echo "FAIL [case4]: dry-run block in reality keygen does not mention opec"; exit 1; }

if grep -qE 'dry.run.*partner-cli' "$TMP/reality_block.txt"; then
    echo "FAIL [case4]: dry-run block still mentions partner-cli keygen"
    exit 1
fi

# ── Case 5: Syntax check ────────────────────────────────────────────────────
bash -n "$INSTALL" \
    || { echo "FAIL: install.sh has syntax errors"; exit 1; }

echo "OK: install.sh keygen delegation to opec — all 5 cases verified"
