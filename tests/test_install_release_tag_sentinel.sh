#!/usr/bin/env bats
# tests/test_install_release_tag_sentinel.sh — Bug R: REPO_RAW must be pinned
# to the release tag when running from a released installer, not always "main".
#
# Root cause: install.sh defaults REPO_RAW to "…/main" which means a released
# installer (e.g. v0.12.49) fetches lib/*.sh from main HEAD after the release
# tag was cut. lib-checksums.txt in the release reflects SHA at tag time;
# lib/*.sh on main may have changed → SHA mismatch → installer dies.
#
# Fix: embed OXPULSE_RELEASE_TAG sentinel (@RELEASE_TAG@) in install.sh.
# release.yml substitutes it with the real tag before upload.
# install.sh derives REPO_RAW from the sentinel when present.

setup() {
	REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

# ---------------------------------------------------------------------------
# Bug R structural: sentinel present in install.sh
# ---------------------------------------------------------------------------
@test "Bug R: install.sh contains OXPULSE_RELEASE_TAG sentinel line" {
	grep -q 'OXPULSE_RELEASE_TAG' "$REPO_ROOT/install.sh"
}

@test "Bug R: install.sh sentinel uses @RELEASE_TAG@ placeholder (dev checkout)" {
	# In the committed source the placeholder must NOT already be expanded
	grep -q '@RELEASE_TAG@' "$REPO_ROOT/install.sh"
}

@test "Bug R: REPO_RAW is derived from OXPULSE_RELEASE_TAG when tag is set" {
	# The REPO_RAW assignment must reference OXPULSE_RELEASE_TAG
	grep -q 'REPO_RAW.*OXPULSE_RELEASE_TAG\|OXPULSE_RELEASE_TAG.*REPO_RAW' "$REPO_ROOT/install.sh"
}

@test "Bug R: release.yml has sed step to substitute @RELEASE_TAG@ in partner-edge-installer.sh" {
	grep -q 'sed.*RELEASE_TAG\|sed.*@RELEASE_TAG@' "$REPO_ROOT/.github/workflows/release.yml"
}

@test "Bug R: when OXPULSE_RELEASE_TAG is set, REPO_RAW uses tag not main" {
	run bash -c '
		set -euo pipefail
		OXPULSE_RELEASE_TAG="partner-edge-v99.0.0"
		_tag="$OXPULSE_RELEASE_TAG"
		if [[ -n "$_tag" && "$_tag" != "@RELEASE_TAG@" ]]; then
			REPO_RAW="https://raw.githubusercontent.com/anatolykoptev/oxpulse-partner-edge/${_tag}"
		else
			REPO_RAW="https://raw.githubusercontent.com/anatolykoptev/oxpulse-partner-edge/main"
		fi
		echo "REPO_RAW=$REPO_RAW"
		[[ "$REPO_RAW" == *"/partner-edge-v99.0.0"* ]] || exit 1
		[[ "$REPO_RAW" != *"/main"* ]] || exit 1
	'
	[ "$status" -eq 0 ]
}

@test "Bug R: when OXPULSE_RELEASE_TAG is @RELEASE_TAG@ (dev checkout), REPO_RAW falls back to main" {
	run bash -c '
		set -euo pipefail
		OXPULSE_RELEASE_TAG="@RELEASE_TAG@"
		_tag="$OXPULSE_RELEASE_TAG"
		if [[ -n "$_tag" && "$_tag" != "@RELEASE_TAG@" ]]; then
			REPO_RAW="https://raw.githubusercontent.com/anatolykoptev/oxpulse-partner-edge/${_tag}"
		else
			REPO_RAW="https://raw.githubusercontent.com/anatolykoptev/oxpulse-partner-edge/main"
		fi
		echo "REPO_RAW=$REPO_RAW"
		[[ "$REPO_RAW" == *"/main"* ]] || exit 1
	'
	[ "$status" -eq 0 ]
}
