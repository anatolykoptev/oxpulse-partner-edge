#!/usr/bin/env bash
# tests/test_install_version_file.sh
#
# Verifies that the VERSION file is installed to the canonical share path
# /usr/local/share/oxpulse-partner-edge/VERSION during first install (via
# lib/install-systemd.sh) and during upgrades (via upgrade.sh sync_host_scripts).
#
# Root cause: oxpulse-channels-health-report.sh:96 defaults _VERSION_FILE to
# /usr/local/share/oxpulse-partner-edge/VERSION; no script installed it there,
# so installer_version was always absent from health-report payloads on first
# install.  hydrate.sh X-Installer-Version header works because hydrate runs
# from $src_dir where VERSION is present; the health-reporter runs post-boot
# without src_dir context.
#
# Test method: static analysis (grep patterns) — same pattern as
# test_install_defaults_conf.sh.  Does NOT execute install.sh (requires root).
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
INSTALL_SYSTEMD="$REPO_ROOT/lib/install-systemd.sh"
# sync_host_scripts/snapshot_host_scripts/restore_host_scripts moved to
# lib/host-scripts-lib.sh (Phase 4 strangler-harden, task p4) — upgrade.sh
# now only holds thin forwarders, so Cases 4/5/6/8 below (which assert on the
# real VERSION-handling logic) check the lib file instead of upgrade.sh.
HOST_SCRIPTS_LIB="$REPO_ROOT/lib/host-scripts-lib.sh"
RELEASE_YML="$REPO_ROOT/.github/workflows/release.yml"
VERSION_FILE="$REPO_ROOT/VERSION"

FAIL=0
pass() { echo "OK: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }

CANONICAL_PATH="/usr/local/share/oxpulse-partner-edge/VERSION"

# ── Case 1: VERSION file exists in repo root ──────────────────────────────────
echo "==> Case 1: VERSION file exists in repo root"
if [[ -f "$VERSION_FILE" ]]; then
	pass "VERSION exists in repo root"
else
	fail "VERSION missing from repo root"
fi

# ── Case 2: lib/install-systemd.sh installs VERSION to canonical share path ───
echo "==> Case 2: lib/install-systemd.sh installs VERSION to canonical share path"
if grep -q "$CANONICAL_PATH" "$INSTALL_SYSTEMD" 2>/dev/null; then
	pass "install-systemd.sh references canonical path $CANONICAL_PATH"
else
	fail "install-systemd.sh does not install VERSION to $CANONICAL_PATH"
fi

# ── Case 3: lib/install-systemd.sh creates the share dir (install -d) ─────────
echo "==> Case 3: lib/install-systemd.sh creates parent dir for VERSION"
# The /usr/local/share/oxpulse-partner-edge dir must be created before the file write.
# Either a dedicated install -d line or reuse of an existing install -d suffices.
# The path is built from a variable now (#530: it was hardcoded six times, which
# is how the installer suite ran green while writing to a real system path).  So
# accept either spelling — but ALSO require that the variable defaults to the
# canonical path, otherwise this check would pass over a variable pointing
# anywhere at all.
_mkdir_ok=0
if grep -qE 'install -d.*(oxpulse-partner-edge|\$_share_dir)' "$INSTALL_SYSTEMD" 2>/dev/null; then
	if grep -q 'oxpulse-partner-edge' "$INSTALL_SYSTEMD" 2>/dev/null \
		&& grep -qE '_share_dir="\$\{OXPULSE_SHARE_DIR:-/usr/local/share/oxpulse-partner-edge\}"' "$INSTALL_SYSTEMD" 2>/dev/null; then
		_mkdir_ok=1
	elif grep -q 'install -d.*oxpulse-partner-edge' "$INSTALL_SYSTEMD" 2>/dev/null; then
		_mkdir_ok=1   # literal form, pre-#530
	fi
fi
if [ "$_mkdir_ok" -eq 1 ]; then
	pass "install-systemd.sh creates the oxpulse-partner-edge share dir"
else
	fail "install-systemd.sh does not mkdir /usr/local/share/oxpulse-partner-edge before installing VERSION"
fi

# ── Case 4: lib/host-scripts-lib.sh sync_host_scripts installs VERSION ────────
echo "==> Case 4: lib/host-scripts-lib.sh sync_host_scripts installs VERSION to canonical path"
# The path may be expressed as a literal or as $PREFIX_SHARE/oxpulse-partner-edge/VERSION.
# Both forms are valid; the canonical segment is the suffix.
if grep -q 'oxpulse-partner-edge/VERSION' "$HOST_SCRIPTS_LIB" 2>/dev/null; then
	pass "lib/host-scripts-lib.sh references oxpulse-partner-edge/VERSION path"
else
	fail "lib/host-scripts-lib.sh sync_host_scripts does not install VERSION to $CANONICAL_PATH"
fi

# ── Case 5: lib/host-scripts-lib.sh snapshot_host_scripts saves VERSION ───────
echo "==> Case 5: lib/host-scripts-lib.sh snapshot_host_scripts saves VERSION (rollback safety)"
# snapshot saves into snap_dir/share-config/; check that VERSION appears near
# snapshot_host_scripts context.
if awk '/snapshot_host_scripts\(\)/,/^}/' "$HOST_SCRIPTS_LIB" | grep "VERSION" >/dev/null; then
	pass "snapshot_host_scripts captures VERSION"
else
	fail "snapshot_host_scripts does not save VERSION — rollback will miss it"
fi

# ── Case 6: lib/host-scripts-lib.sh restore_host_scripts restores VERSION ─────
echo "==> Case 6: lib/host-scripts-lib.sh restore_host_scripts restores VERSION (rollback path)"
if awk '/restore_host_scripts\(\)/,/^}/' "$HOST_SCRIPTS_LIB" | grep "VERSION" >/dev/null; then
	pass "restore_host_scripts restores VERSION"
else
	fail "restore_host_scripts does not restore VERSION — rollback leaves stale version on disk"
fi

# ── Case 7: release.yml stages VERSION as a release asset ─────────────────────
echo "==> Case 7: release.yml stages VERSION as a release asset"
# Asset lines in the release.yml upload list have the form "            VERSION \" (with
# trailing backslash + space).  We match that exact indent+filename pattern and exclude
# env-var assignment lines (VERSION=...).
_version_asset_lines=$(grep -cE '^[[:space:]]+VERSION[[:space:]]*\\' "$RELEASE_YML" 2>/dev/null || echo 0)
if [[ "$_version_asset_lines" -ge 1 ]]; then
	pass "release.yml includes VERSION in upload/sha256 list ($RELEASE_YML)"
else
	fail "release.yml does not stage VERSION — sync_host_scripts curl fetch will 404 on tagged releases"
fi

# ── Case 8: lib/host-scripts-lib.sh dry-run logs VERSION install ──────────────
echo "==> Case 8: lib/host-scripts-lib.sh dry-run branch of sync_host_scripts mentions VERSION"
if grep -q 'dry-run.*VERSION\|VERSION.*dry-run' "$HOST_SCRIPTS_LIB" 2>/dev/null; then
	pass "lib/host-scripts-lib.sh dry-run branch mentions VERSION"
else
	fail "lib/host-scripts-lib.sh dry-run branch does not log VERSION install — operator dry-run output is incomplete"
fi

# ── Result ────────────────────────────────────────────────────────────────────
if [[ $FAIL -ne 0 ]]; then
	echo "FAIL: test_install_version_file — $FAIL check(s) failed"
	exit 1
fi
echo "PASS: test_install_version_file — all 8 cases verified"
