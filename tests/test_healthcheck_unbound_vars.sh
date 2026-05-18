#!/usr/bin/env bash
# Regression: healthcheck.sh must not have unbound variables under set -u.
#
# Bug 11 (live-edge 2026-05-18): SYSTEMD_DIR used at line ~292 without a
#   default; healthcheck runs standalone (systemd unit) without install.sh globals.
# Bug 12 (live-edge 2026-05-18): SFU_METRICS_PORT default was 8878 but live SFU
#   prometheus endpoint is :9317.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
HC="$REPO_ROOT/healthcheck.sh"

[[ -f "$HC" ]] || { echo "FAIL: healthcheck.sh not found at $HC"; exit 1; }

FAIL=0

pass() { echo "OK: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }

# ── Case 1: SYSTEMD_DIR has a :- default ────────────────────────────────────
echo "==> Case 1: SYSTEMD_DIR has a :- default in healthcheck.sh"
if grep -qE 'SYSTEMD_DIR=.*:-' "$HC"; then
	pass "SYSTEMD_DIR has :- default"
else
	fail "SYSTEMD_DIR does not have :- default — will be unbound under set -u"
fi

# ── Case 2: SFU_METRICS_PORT default is 9317 (not 8878) ─────────────────────
echo "==> Case 2: SFU_METRICS_PORT default is 9317"
if grep -qE 'SFU_METRICS_PORT.*:-\s*9317' "$HC"; then
	pass "SFU_METRICS_PORT default is 9317"
else
	# Show what we actually got for diagnosis
	actual=$(grep 'SFU_METRICS_PORT' "$HC" | head -3 || echo "(not found)")
	fail "SFU_METRICS_PORT default is not 9317. Found: $actual"
fi

# ── Result ───────────────────────────────────────────────────────────────────
if [[ $FAIL -ne 0 ]]; then
	echo "FAIL: healthcheck.sh unbound-var / wrong-port fixes not applied"
	exit 1
fi
echo "PASS: healthcheck.sh SYSTEMD_DIR default + SFU_METRICS_PORT 9317 — both verified"
