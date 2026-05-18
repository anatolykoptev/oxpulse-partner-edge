#!/usr/bin/env bash
# Regression: config/defaults.conf must be installed to the canonical share path
# and both consumers (channel-render-lib.sh, oxpulse-channels-health-report.sh)
# must agree on that path.
#
# Bug 8 (deferred from Phase 5.5): Two consumers expect defaults.conf at divergent
# paths:
#   channel-render-lib.sh:30  → /usr/local/share/oxpulse-partner-edge/config/defaults.conf
#   oxpulse-channels-health-report.sh:26 → /etc/oxpulse-partner-edge/config/defaults.conf
# Neither path is populated by any install lib.  On a live install, channel-render-lib.sh
# silently skips the source (else branch: no-op); health-reporter silently misses defaults.
#
# Fix: install to canonical path /usr/local/share/oxpulse-partner-edge/config/defaults.conf
# via lib/install-systemd.sh, and unify health-reporter to the same path.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
INSTALL_SYSTEMD="$REPO_ROOT/lib/install-systemd.sh"
CHANNEL_RENDER_LIB="$REPO_ROOT/channel-render-lib.sh"
HEALTH_REPORTER="$REPO_ROOT/oxpulse-channels-health-report.sh"
RELEASE_YML="$REPO_ROOT/.github/workflows/release.yml"
DEFAULTS_CONF="$REPO_ROOT/config/defaults.conf"

FAIL=0
pass() { echo "OK: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }

CANONICAL_PATH="/usr/local/share/oxpulse-partner-edge/config/defaults.conf"

# ── Case 1: config/defaults.conf exists in repo ──────────────────────────────
echo "==> Case 1: config/defaults.conf exists in repo"
if [[ -f "$DEFAULTS_CONF" ]]; then
	pass "config/defaults.conf exists"
else
	fail "config/defaults.conf missing from repo root"
fi

# ── Case 2: lib/install-systemd.sh installs defaults.conf to canonical path ──
echo "==> Case 2: lib/install-systemd.sh installs defaults.conf to canonical share path"
if grep -q "$CANONICAL_PATH" "$INSTALL_SYSTEMD" 2>/dev/null; then
	pass "install-systemd.sh references canonical path $CANONICAL_PATH"
else
	fail "install-systemd.sh does not install defaults.conf to $CANONICAL_PATH"
fi

# ── Case 3: install-systemd.sh creates the config dir (install -d) ───────────
echo "==> Case 3: lib/install-systemd.sh creates parent dir for defaults.conf"
if grep -q 'install -d.*oxpulse-partner-edge/config' "$INSTALL_SYSTEMD" 2>/dev/null; then
	pass "install-systemd.sh creates .../config dir"
else
	fail "install-systemd.sh does not mkdir .../config before installing defaults.conf"
fi

# ── Case 4: channel-render-lib.sh already uses canonical path ────────────────
echo "==> Case 4: channel-render-lib.sh looks up canonical share path"
if grep -q "$CANONICAL_PATH" "$CHANNEL_RENDER_LIB" 2>/dev/null; then
	pass "channel-render-lib.sh references canonical path"
else
	fail "channel-render-lib.sh does not reference $CANONICAL_PATH"
fi

# ── Case 5: oxpulse-channels-health-report.sh uses unified canonical path ────
echo "==> Case 5: oxpulse-channels-health-report.sh uses unified canonical path"
# Must NOT use /etc/oxpulse-partner-edge/config/defaults.conf as the primary path;
# must use the /usr/local/share/... canonical path.
if grep -q "/usr/local/share/oxpulse-partner-edge/config/defaults.conf" "$HEALTH_REPORTER" 2>/dev/null; then
	pass "health-reporter references canonical share path"
else
	actual=$(grep 'defaults.conf' "$HEALTH_REPORTER" | head -3 || echo "(not found)")
	fail "health-reporter does not reference canonical share path. Found: $actual"
fi

# ── Case 6: release.yml stages config/defaults.conf ────────────────────────
echo "==> Case 6: release.yml stages config/defaults.conf as release artifact"
if grep -q 'defaults.conf\|config/defaults' "$RELEASE_YML" 2>/dev/null; then
	pass "release.yml references defaults.conf"
else
	fail "release.yml does not stage config/defaults.conf"
fi

# ── Result ───────────────────────────────────────────────────────────────────
if [[ $FAIL -ne 0 ]]; then
	echo "FAIL: one or more defaults.conf install tests failed"
	exit 1
fi
echo "PASS: config/defaults.conf install + path unification — all 6 cases verified"
