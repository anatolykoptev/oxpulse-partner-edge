#!/usr/bin/env bats
# tests/test_release_pipeline_enable_hy2.sh — C2 gate.
#
# Asserts that oxpulse-partner-edge-enable-hy2 is wired into release.yml:
#   1. sha256sum block includes the file
#   2. gh release upload includes the file
#
# File lives at repo root (no cp staging needed — same pattern as
# oxpulse-partner-edge-ru-subnets-update).
#
# Bats <1.5 compat: no bats_require_minimum_version, no `run !`.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    RELEASE_YML="$REPO_ROOT/.github/workflows/release.yml"
}

# ── sha256sum block ───────────────────────────────────────────────────────────

@test "release.yml sha256sum block covers oxpulse-partner-edge-enable-hy2" {
    awk '/sha256sum/,/> SHA256SUMS/' "$RELEASE_YML" \
        | grep -q 'oxpulse-partner-edge-enable-hy2'
}

# ── gh release upload block ───────────────────────────────────────────────────

@test "release.yml gh release upload includes oxpulse-partner-edge-enable-hy2" {
    awk '/gh release upload/,/--clobber/' "$RELEASE_YML" \
        | grep -q 'oxpulse-partner-edge-enable-hy2'
}

# ── no cp staging needed (file at repo root) ─────────────────────────────────

@test "release.yml does NOT stage enable-hy2 via cp (already at root)" {
    # If cp appears for this file, it would be wrong (matches split-routing root pattern).
    result=$(grep -cE 'cp[[:space:]].*oxpulse-partner-edge-enable-hy2' "$RELEASE_YML" || true)
    [ "$result" = "0" ]
}

# ── script file exists at repo root ──────────────────────────────────────────

@test "oxpulse-partner-edge-enable-hy2 exists at repo root" {
    [ -f "$REPO_ROOT/oxpulse-partner-edge-enable-hy2" ]
}

@test "oxpulse-partner-edge-enable-hy2 is executable" {
    [ -x "$REPO_ROOT/oxpulse-partner-edge-enable-hy2" ]
}
