#!/usr/bin/env bats
# Phase 6 — release pipeline publishes install.sh as partner-edge-installer.sh.
# bootstrap.sh retired (was broken contract: required partner-edge-<VERSION>.tar.gz
# release asset that release.yml never built — 39 consecutive releases shipped a
# 404'ing one-command install). Live edges were provisioned via undocumented side
# path: curl install.sh from raw.githubusercontent.com directly. This PR makes
# that the published path.

setup() {
  cd "$BATS_TEST_DIRNAME/.."
}

@test "install.sh exists at repo root and is executable" {
  [ -x install.sh ]
}

@test "bootstrap.sh has been retired" {
  [ ! -e bootstrap.sh ]
}

@test "release.yml stages install.sh as partner-edge-installer.sh" {
  grep -qE 'cp[[:space:]]+install\.sh[[:space:]]+partner-edge-installer\.sh' .github/workflows/release.yml
}

@test "release.yml does NOT reference bootstrap.sh" {
  ! grep -qE 'bootstrap\.sh' .github/workflows/release.yml
}

@test "release.yml SHA256SUMS line covers partner-edge-installer.sh" {
  grep -A2 -E 'sha256sum' .github/workflows/release.yml | grep -q 'partner-edge-installer.sh'
}

@test "install.sh first line is bash shebang (guards against wrong-file rename)" {
  # If anyone ever moves the installer to a different file (e.g. installer.py),
  # release.yml would silently publish that as partner-edge-installer.sh.
  # Shebang anchor guarantees we keep shipping a bash script.
  head -1 install.sh | grep -qE '^#!/usr/bin/env bash$|^#!/bin/bash$'
}

@test "release.yml stages opec-amd64" {
  grep -qE 'opec-amd64' .github/workflows/release.yml
}

@test "release.yml stages opec-arm64" {
  grep -qE 'opec-arm64' .github/workflows/release.yml
}

@test "release.yml stages lib/install-preflight.sh as install-preflight.sh asset" {
  grep -qE 'cp[[:space:]]+lib/install-preflight\.sh[[:space:]]+install-preflight\.sh' .github/workflows/release.yml
}

@test "release.yml stages lib/install-deps.sh as install-deps.sh asset" {
  grep -qE 'cp[[:space:]]+lib/install-deps\.sh[[:space:]]+install-deps\.sh' .github/workflows/release.yml
}

@test "release.yml SHA256SUMS line covers lib modules" {
  grep -A12 -E 'sha256sum' .github/workflows/release.yml | grep -q 'install-preflight.sh'
  grep -A12 -E 'sha256sum' .github/workflows/release.yml | grep -q 'install-deps.sh'
}

@test "release.yml uploads lib modules to GitHub release" {
  grep -A12 'gh release upload' .github/workflows/release.yml | grep -q 'install-preflight.sh'
  grep -A12 'gh release upload' .github/workflows/release.yml | grep -q 'install-deps.sh'
}

@test "release.yml stages lib/install-network.sh as install-network.sh asset" {
    grep -qE 'cp[[:space:]]+lib/install-network\.sh[[:space:]]+install-network\.sh' .github/workflows/release.yml
}

@test "release.yml SHA256SUMS line covers install-network.sh" {
    grep -A14 -E 'sha256sum' .github/workflows/release.yml | grep -q 'install-network.sh'
}

@test "release.yml uploads install-network.sh to GitHub release" {
    grep -A14 'gh release upload' .github/workflows/release.yml | grep -q 'install-network.sh'
}

@test "release.yml stages lib/install-healthcheck.sh as install-healthcheck.sh asset" {
  grep -qE 'cp[[:space:]]+lib/install-healthcheck\.sh[[:space:]]+install-healthcheck\.sh' .github/workflows/release.yml
}

@test "release.yml SHA256SUMS line covers install-healthcheck.sh (Phase 4.6)" {
  grep -A20 -E 'sha256sum' .github/workflows/release.yml | grep -q 'install-healthcheck.sh'
}

@test "release.yml uploads install-healthcheck.sh to GitHub release" {
  grep -A20 'gh release upload' .github/workflows/release.yml | grep -q 'install-healthcheck.sh'
}

@test "release.yml stages lib/install-systemd.sh as install-systemd.sh asset" {
  grep -qE 'cp[[:space:]]+lib/install-systemd\.sh[[:space:]]+install-systemd\.sh' .github/workflows/release.yml
}

@test "release.yml SHA256SUMS line covers install-systemd.sh (Phase 4.7)" {
  grep -A25 -E 'sha256sum' .github/workflows/release.yml | grep -q 'install-systemd.sh'
}

@test "release.yml uploads install-systemd.sh to GitHub release" {
  grep -A25 'gh release upload' .github/workflows/release.yml | grep -q 'install-systemd.sh'
}

@test "release.yml stages lib/install-args.sh as install-args.sh asset" {
  grep -qE 'cp[[:space:]]+lib/install-args\.sh[[:space:]]+install-args\.sh' .github/workflows/release.yml
}

@test "release.yml SHA256SUMS line covers install-args.sh (Phase 4.9)" {
  grep -A30 -E 'sha256sum' .github/workflows/release.yml | grep -q 'install-args.sh'
}

@test "release.yml uploads install-args.sh to GitHub release" {
  grep -A30 'gh release upload' .github/workflows/release.yml | grep -q 'install-args.sh'
}

# ---------------------------------------------------------------------------
# Bug 15: uninstall.sh must be staged, checksummed, and uploaded in release.yml
# ---------------------------------------------------------------------------

@test "Bug15: release.yml stages uninstall.sh as a release asset" {
	# Must have a `cp uninstall.sh  uninstall.sh` line in Stage artifacts block
	grep -qE 'cp[[:space:]]+uninstall\.sh[[:space:]]+uninstall\.sh' .github/workflows/release.yml
}

@test "Bug15: release.yml SHA256SUMS block covers uninstall.sh" {
	# sha256sum block must list uninstall.sh
	grep -q 'uninstall\.sh' .github/workflows/release.yml
	# Verify it appears specifically in the sha256sum block context
	awk '/sha256sum/,/> SHA256SUMS/' .github/workflows/release.yml | grep -q 'uninstall\.sh'
}

@test "Bug15: release.yml uploads uninstall.sh to GitHub release" {
	# gh release upload block must include uninstall.sh
	awk '/gh release upload/,/--clobber/' .github/workflows/release.yml | grep -q 'uninstall\.sh'
}
