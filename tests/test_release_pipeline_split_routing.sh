#!/usr/bin/env bats
# tests/test_release_pipeline_split_routing.sh — CL-B gate.
#
# Asserts that all 7 split-routing artifacts are wired into release.yml:
#   1. oxpulse-partner-edge-split-routing.sh         (repo root, no cp needed)
#   2. oxpulse-partner-edge-split-disable.sh         (repo root, no cp needed)
#   3. oxpulse-partner-edge-ru-subnets-update        (repo root, no cp needed)
#   4. install-split-routing.sh                      (from lib/; needs cp)
#   5. oxpulse-partner-edge-split-routing.service    (from systemd/; needs cp)
#   6. oxpulse-partner-edge-ru-subnets-update.service (from systemd/; needs cp)
#   7. oxpulse-partner-edge-ru-subnets-update.timer  (from systemd/; needs cp)
#
# Also asserts install-split-routing.sh is in the lib-checksums.txt generator.
#
# Bats <1.5 compat: no bats_require_minimum_version, no `run !`.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  RELEASE_YML="$REPO_ROOT/.github/workflows/release.yml"
}

# ── cp staging (files that need cp from subdir) ──────────────────────────────

@test "release.yml stages systemd/oxpulse-partner-edge-split-routing.service via cp" {
  grep -qE 'cp[[:space:]]+systemd/oxpulse-partner-edge-split-routing\.service' "$RELEASE_YML"
}

@test "release.yml stages systemd/oxpulse-partner-edge-ru-subnets-update.service via cp" {
  grep -qE 'cp[[:space:]]+systemd/oxpulse-partner-edge-ru-subnets-update\.service' "$RELEASE_YML"
}

@test "release.yml stages systemd/oxpulse-partner-edge-ru-subnets-update.timer via cp" {
  grep -qE 'cp[[:space:]]+systemd/oxpulse-partner-edge-ru-subnets-update\.timer' "$RELEASE_YML"
}

@test "release.yml stages lib/install-split-routing.sh via cp" {
  grep -qE 'cp[[:space:]]+lib/install-split-routing\.sh' "$RELEASE_YML"
}

# ── lib-checksums.txt generator ──────────────────────────────────────────────

@test "release.yml includes install-split-routing.sh in lib-checksums.txt generation" {
  # Must appear inside the (cd lib && sha256sum ...) block
  awk '/cd lib && sha256sum/,/\) > lib\/lib-checksums\.txt/' "$RELEASE_YML" \
    | grep -q 'install-split-routing\.sh'
}

# ── sha256sum block ───────────────────────────────────────────────────────────

@test "release.yml sha256sum block covers oxpulse-partner-edge-split-routing.sh" {
  awk '/sha256sum/,/> SHA256SUMS/' "$RELEASE_YML" | grep -q 'oxpulse-partner-edge-split-routing\.sh'
}

@test "release.yml sha256sum block covers oxpulse-partner-edge-split-disable.sh" {
  awk '/sha256sum/,/> SHA256SUMS/' "$RELEASE_YML" | grep -q 'oxpulse-partner-edge-split-disable\.sh'
}

@test "release.yml sha256sum block covers oxpulse-partner-edge-ru-subnets-update" {
  awk '/sha256sum/,/> SHA256SUMS/' "$RELEASE_YML" | grep -q 'oxpulse-partner-edge-ru-subnets-update'
}

@test "release.yml sha256sum block covers install-split-routing.sh" {
  awk '/sha256sum/,/> SHA256SUMS/' "$RELEASE_YML" | grep -q 'install-split-routing\.sh'
}

@test "release.yml sha256sum block covers oxpulse-partner-edge-split-routing.service" {
  awk '/sha256sum/,/> SHA256SUMS/' "$RELEASE_YML" | grep -q 'oxpulse-partner-edge-split-routing\.service'
}

@test "release.yml sha256sum block covers oxpulse-partner-edge-ru-subnets-update.service" {
  awk '/sha256sum/,/> SHA256SUMS/' "$RELEASE_YML" | grep -q 'oxpulse-partner-edge-ru-subnets-update\.service'
}

@test "release.yml sha256sum block covers oxpulse-partner-edge-ru-subnets-update.timer" {
  awk '/sha256sum/,/> SHA256SUMS/' "$RELEASE_YML" | grep -q 'oxpulse-partner-edge-ru-subnets-update\.timer'
}

# ── gh release upload block ───────────────────────────────────────────────────

@test "release.yml gh release upload includes oxpulse-partner-edge-split-routing.sh" {
  awk '/gh release upload/,/--clobber/' "$RELEASE_YML" | grep -q 'oxpulse-partner-edge-split-routing\.sh'
}

@test "release.yml gh release upload includes oxpulse-partner-edge-split-disable.sh" {
  awk '/gh release upload/,/--clobber/' "$RELEASE_YML" | grep -q 'oxpulse-partner-edge-split-disable\.sh'
}

@test "release.yml gh release upload includes oxpulse-partner-edge-ru-subnets-update" {
  awk '/gh release upload/,/--clobber/' "$RELEASE_YML" | grep -q 'oxpulse-partner-edge-ru-subnets-update'
}

@test "release.yml gh release upload includes install-split-routing.sh" {
  awk '/gh release upload/,/--clobber/' "$RELEASE_YML" | grep -q 'install-split-routing\.sh'
}

@test "release.yml gh release upload includes oxpulse-partner-edge-split-routing.service" {
  awk '/gh release upload/,/--clobber/' "$RELEASE_YML" | grep -q 'oxpulse-partner-edge-split-routing\.service'
}

@test "release.yml gh release upload includes oxpulse-partner-edge-ru-subnets-update.service" {
  awk '/gh release upload/,/--clobber/' "$RELEASE_YML" | grep -q 'oxpulse-partner-edge-ru-subnets-update\.service'
}

@test "release.yml gh release upload includes oxpulse-partner-edge-ru-subnets-update.timer" {
  awk '/gh release upload/,/--clobber/' "$RELEASE_YML" | grep -q 'oxpulse-partner-edge-ru-subnets-update\.timer'
}

# ── awg-params-agent service unit (post-apply hook wiring) ───────────────────

@test "release.yml stages systemd/oxpulse-awg-params-agent.service via cp" {
  grep -q 'cp systemd/oxpulse-awg-params-agent\.service' "$RELEASE_YML"
}

@test "release.yml sha256sum block covers oxpulse-awg-params-agent.service" {
  # Must be in the sha256sum input list so its integrity is pinned to the release.
  awk '/sha256sum/,/>.*SHA256SUMS/' "$RELEASE_YML" | grep -q 'oxpulse-awg-params-agent\.service'
}

@test "release.yml gh release upload includes oxpulse-awg-params-agent.service" {
  awk '/gh release upload/,/--clobber/' "$RELEASE_YML" | grep -q 'oxpulse-awg-params-agent\.service'
}
