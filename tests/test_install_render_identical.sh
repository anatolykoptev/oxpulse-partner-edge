#!/usr/bin/env bats
# Phase 1 Task 2 — render_template() byte-identical to install.sh's current render()
# for all 6 template targets.

setup() {
  cd "$BATS_TEST_DIRNAME/.."
  # shellcheck source=../channel-render-lib.sh
  source ./channel-render-lib.sh
  # shellcheck source=fixtures/install-render/frozen-env.sh
  source ./tests/fixtures/install-render/frozen-env.sh
}

render_one() {
  local kind=$1
  out=$(mktemp)
  render_template "tests/fixtures/install-render/${kind}.tpl" "$out"
  diff -u "tests/fixtures/install-render/expected/${kind}.txt" "$out"
  rm -f "$out"
}

@test "render_template byte-identical: docker-compose.yml"  { render_one compose; }
@test "render_template byte-identical: Caddyfile"           { render_one caddy; }
@test "render_template byte-identical: xray-client.json"    { render_one xray; }
@test "render_template byte-identical: coturn.conf"         { render_one coturn; }
@test "render_template byte-identical: hysteria2-client.yaml" { render_one hy2; }
@test "render_template byte-identical: naive-client.json"   { render_one naive; }
