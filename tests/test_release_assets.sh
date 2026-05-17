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
