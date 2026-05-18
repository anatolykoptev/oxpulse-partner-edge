#!/usr/bin/env bash
# Phase 5.5 MAJOR 1 — hydrate/update/refresh fail-soft full wiring.
#
# The spec shipped render_channel_soft + CHANNELS_FAILED + compose-strip to
# install.sh in PR #186 but did NOT wire them into hydrate.sh / update.sh /
# oxpulse-partner-edge-refresh.sh. This test covers:
#
#   Case 1: lib/render-channel-lib.sh exists with render_channel_soft(), _in_array(),
#           CHANNELS_FAILED=(), and compose_strip_failed_channels()
#   Case 2: install.sh sources lib/render-channel-lib.sh (no longer defines inline)
#   Case 3: hydrate.sh sources lib/render-channel-lib.sh and uses render_channel_soft
#           for xray and naive channel renders
#   Case 4: update.sh sources lib/render-channel-lib.sh and uses render_channel_soft
#           for channel renders
#   Case 5: oxpulse-partner-edge-refresh.sh sources lib/render-channel-lib.sh and
#           uses render_channel_soft for channels_version re-render
#   Case 6: lib/install-systemd.sh installs lib/render-channel-lib.sh to PREFIX_SBIN
#   Case 7: release.yml stages lib/render-channel-lib.sh as a release asset
#
#   Behavioral Case 8: render_channel_soft() from lib/render-channel-lib.sh
#           behaves identically to the original in install.sh (appends to CHANNELS_FAILED)
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LIB_RENDER="$REPO_ROOT/lib/render-channel-lib.sh"
INSTALL="$REPO_ROOT/install.sh"
HYDRATE="$REPO_ROOT/hydrate.sh"
UPDATE="$REPO_ROOT/update.sh"
REFRESH="$REPO_ROOT/oxpulse-partner-edge-refresh.sh"
INSTALL_SYSTEMD="$REPO_ROOT/lib/install-systemd.sh"
RELEASE_YML="$REPO_ROOT/.github/workflows/release.yml"

FAIL=0
pass() { echo "OK: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }

# ── Case 1: lib/render-channel-lib.sh exists with required symbols ───────────
echo "==> Case 1: lib/render-channel-lib.sh exists with required symbols"
if [[ ! -f "$LIB_RENDER" ]]; then
	fail "lib/render-channel-lib.sh does not exist"
else
	pass "lib/render-channel-lib.sh exists"

	if grep -q 'render_channel_soft()' "$LIB_RENDER"; then
		pass "  render_channel_soft() defined in lib/render-channel-lib.sh"
	else
		fail "  render_channel_soft() missing from lib/render-channel-lib.sh"
	fi

	if grep -q '_in_array()' "$LIB_RENDER"; then
		pass "  _in_array() defined in lib/render-channel-lib.sh"
	else
		fail "  _in_array() missing from lib/render-channel-lib.sh"
	fi

	if grep -q 'CHANNELS_FAILED=()' "$LIB_RENDER"; then
		pass "  CHANNELS_FAILED=() declared in lib/render-channel-lib.sh"
	else
		fail "  CHANNELS_FAILED=() declaration missing from lib/render-channel-lib.sh"
	fi

	if grep -q 'compose_strip_failed_channels\|strip.*failed.*channel\|CHANNELS_FAILED.*compose' "$LIB_RENDER"; then
		pass "  compose strip helper present in lib/render-channel-lib.sh"
	else
		fail "  compose strip helper missing from lib/render-channel-lib.sh"
	fi
fi

# ── Case 2: install.sh sources lib/render-channel-lib.sh ─────────────────────
echo "==> Case 2: install.sh sources lib/render-channel-lib.sh"
if grep -qE 'source.*render-channel-lib|\..*render-channel-lib' "$INSTALL"; then
	pass "install.sh sources lib/render-channel-lib.sh"
else
	fail "install.sh does not source lib/render-channel-lib.sh"
fi

# ── Case 3: hydrate.sh uses render_channel_soft ───────────────────────────────
echo "==> Case 3: hydrate.sh sources lib/render-channel-lib.sh and uses render_channel_soft"
if grep -qE 'source.*render-channel-lib|\..*render-channel-lib' "$HYDRATE"; then
	pass "hydrate.sh sources lib/render-channel-lib.sh"
else
	fail "hydrate.sh does not source lib/render-channel-lib.sh"
fi
if grep -q 'render_channel_soft' "$HYDRATE"; then
	pass "hydrate.sh uses render_channel_soft"
else
	fail "hydrate.sh does not use render_channel_soft for channel renders"
fi

# ── Case 4: update.sh uses render_channel_soft ────────────────────────────────
echo "==> Case 4: update.sh sources lib/render-channel-lib.sh and uses render_channel_soft"
if grep -qE 'source.*render-channel-lib|\..*render-channel-lib' "$UPDATE"; then
	pass "update.sh sources lib/render-channel-lib.sh"
else
	fail "update.sh does not source lib/render-channel-lib.sh"
fi
if grep -q 'render_channel_soft' "$UPDATE"; then
	pass "update.sh uses render_channel_soft"
else
	fail "update.sh does not use render_channel_soft for channel renders"
fi

# ── Case 5: refresh.sh sources lib/render-channel-lib.sh ─────────────────────
echo "==> Case 5: refresh.sh sources lib/render-channel-lib.sh and uses render_channel_soft"
if grep -qE 'source.*render-channel-lib|\..*render-channel-lib' "$REFRESH"; then
	pass "refresh.sh sources lib/render-channel-lib.sh"
else
	fail "refresh.sh does not source lib/render-channel-lib.sh"
fi
if grep -q 'render_channel_soft' "$REFRESH"; then
	pass "refresh.sh uses render_channel_soft"
else
	fail "refresh.sh does not use render_channel_soft"
fi

# ── Case 6: install-systemd.sh installs lib/render-channel-lib.sh ────────────
echo "==> Case 6: lib/install-systemd.sh installs render-channel-lib.sh to PREFIX_SBIN"
if grep -q 'render-channel-lib.sh' "$INSTALL_SYSTEMD"; then
	pass "install-systemd.sh references render-channel-lib.sh"
else
	fail "install-systemd.sh does not install render-channel-lib.sh"
fi

# ── Case 7: release.yml stages lib/render-channel-lib.sh ─────────────────────
echo "==> Case 7: release.yml stages lib/render-channel-lib.sh"
if grep -q 'render-channel-lib' "$RELEASE_YML"; then
	pass "release.yml references render-channel-lib.sh"
else
	fail "release.yml does not stage render-channel-lib.sh"
fi

# ── Case 8: behavioral — render_channel_soft appends to CHANNELS_FAILED ──────
echo "==> Case 8: behavioral — render_channel_soft appends to CHANNELS_FAILED on opec failure"
if [[ -f "$LIB_RENDER" ]]; then
	# Source the lib with a stubbed opec that always fails for 'xray'
	(
		# Stub opec, log/warn/die, PREFIX_LIB
		opec() { return 1; }
		export -f opec
		PREFIX_LIB=/tmp
		log()  { true; }
		warn() { true; }
		die()  { exit 1; }
		export PREFIX_LIB
		export -f log warn die
		# shellcheck source=/dev/null
		source "$LIB_RENDER"
		# Reset CHANNELS_FAILED after sourcing (sourcing sets it to ())
		CHANNELS_FAILED=()
		set +e
		render_channel_soft xray /tmp/xray.tpl /tmp/xray-out.json 2>/dev/null
		if [[ ${#CHANNELS_FAILED[@]} -eq 1 && "${CHANNELS_FAILED[0]}" == "xray" ]]; then
			echo "BEHAVIORAL_OK"
		else
			echo "BEHAVIORAL_FAIL: expected CHANNELS_FAILED=(xray) got: ${CHANNELS_FAILED[*]:-<empty>}"
		fi
	) > /tmp/render_channel_soft_test.out 2>&1 || true
	if grep -q "BEHAVIORAL_OK" /tmp/render_channel_soft_test.out; then
		pass "render_channel_soft appends 'xray' to CHANNELS_FAILED on opec failure"
	else
		output=$(cat /tmp/render_channel_soft_test.out 2>/dev/null || echo "(no output)")
		fail "render_channel_soft behavioral test failed: $output"
	fi
	rm -f /tmp/render_channel_soft_test.out
else
	fail "lib/render-channel-lib.sh not found — skipping behavioral test"
fi

# ── Result ───────────────────────────────────────────────────────────────────
if [[ $FAIL -ne 0 ]]; then
	echo "FAIL: one or more Phase 5.5 MAJOR 1 tests failed"
	exit 1
fi
echo "PASS: Phase 5.5 MAJOR 1 — hydrate/update/refresh fail-soft wiring — all 8 cases verified"
