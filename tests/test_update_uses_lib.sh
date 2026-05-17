#!/usr/bin/env bats
# Phase 1 Task 4 — update.sh must delegate xray render to
# channel-render-lib::re_render_xray(), not duplicate inline.

setup() {
  cd "$BATS_TEST_DIRNAME/.."
}

@test "update.sh sources channel-render-lib.sh" {
  grep -E 'source.*channel-render-lib\.sh|^\. .*channel-render-lib\.sh' update.sh
}

@test "update.sh calls re_render_xray" {
  grep -E '\bre_render_xray\b' update.sh
}

@test "update.sh does not duplicate sed REALITY_UUID substitution" {
  # Old impl had: sed -e "s|{{REALITY_UUID}}|..." inline.
  # After refactor, that substitution lives ONLY in channel-render-lib.sh::re_render_xray.
  ! grep -qE '\{\{REALITY_UUID\}\}' update.sh
}

@test "update.sh does not embed inline xray channels[0].xray.uuid parser" {
  # The python3 channel parsing for xray uuid lives in the lib only.
  ! grep -qE "channels.*xray.*uuid" update.sh
}

@test "update.sh shell syntax is valid" {
  bash -n update.sh
}

@test "update.sh post-flight compares pre/post hash for render freshness" {
  # Hash compare guards against re_render_xray soft-fail returning 0
  # without writing. Stale .bak.* would mask this; hash compare doesn't.
  grep -qE '_pre_hash.*_post_hash|_post_hash.*_pre_hash' update.sh
}
