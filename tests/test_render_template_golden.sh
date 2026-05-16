#!/usr/bin/env bats
# Phase 1 Task 1 — render_template() generic mustache renderer

setup() {
  cd "$BATS_TEST_DIRNAME/.."
  # shellcheck source=../channel-render-lib.sh
  source ./channel-render-lib.sh
}

@test "render_template substitutes single-line vars" {
  export PARTNER_ID=zvonilka
  export PARTNER_DOMAIN=zvonilka.net
  export BACKEND_HOST=192.9.243.148
  export BACKEND_PORT=5349
  export SFU_SIGNING_PUBLIC_KEY="some-key"
  unset NONEXISTENT_VAR
  out=$(mktemp)
  render_template tests/fixtures/render-template/input.tpl "$out"
  grep -q "^partner_id: zvonilka$" "$out"
  grep -q "^domain: zvonilka.net$" "$out"
  grep -q "^backend: 192.9.243.148:5349$" "$out"
  grep -q "^pem: some-key$" "$out"
  grep -q "^empty: $" "$out"
}

@test "render_template treats unset vars as empty string" {
  unset PARTNER_ID PARTNER_DOMAIN BACKEND_HOST BACKEND_PORT SFU_SIGNING_PUBLIC_KEY NONEXISTENT_VAR
  out=$(mktemp)
  render_template tests/fixtures/render-template/input.tpl "$out"
  grep -q "^partner_id: $" "$out"
  grep -q "^backend: :$" "$out"
}

@test "render_template preserves literal dollar signs and percent signs" {
  out=$(mktemp)
  render_template tests/fixtures/render-template/input.tpl "$out"
  grep -F 'literal-percent: 100%' "$out"
  grep -F 'literal-dollar: $HOME' "$out"
}

@test "render_template handles multi-line PEM (closes hydrate bug class)" {
  export SFU_SIGNING_PUBLIC_KEY=$'-----BEGIN PUBLIC KEY-----\nLINE1\nLINE2\n-----END PUBLIC KEY-----'
  out=$(mktemp)
  render_template tests/fixtures/render-template/input.tpl "$out"
  grep -F "BEGIN PUBLIC KEY" "$out"
  grep -F "LINE1" "$out"
  grep -F "LINE2" "$out"
  grep -F "END PUBLIC KEY" "$out"
}

@test "render_template fails cleanly on missing source" {
  out=$(mktemp)
  ! render_template /nonexistent/path.tpl "$out"
}
