#!/usr/bin/env bats
# Phase 1 Task 1 — render_template() generic mustache renderer

setup() {
  cd "$BATS_TEST_DIRNAME/.."
  # shellcheck source=../channel-render-lib.sh
  source ./channel-render-lib.sh
}

@test "render_template substitutes single-line vars" {
  export PARTNER_ID=edge-b
  export PARTNER_DOMAIN=edge-b.example
  export BACKEND_HOST=203.0.113.10
  export BACKEND_PORT=5349
  export SFU_SIGNING_PUBLIC_KEY="some-key"
  unset NONEXISTENT_VAR
  out=$(mktemp)
  render_template tests/fixtures/render-template/input.tpl "$out"
  grep -q "^partner_id: edge-b$" "$out"
  grep -q "^domain: edge-b.example$" "$out"
  grep -q "^backend: 203.0.113.10:5349$" "$out"
  grep -q "^pem: some-key$" "$out"
  grep -q "^empty: $" "$out"
  rm -f "$out"
}

@test "render_template treats unset vars as empty string" {
  unset PARTNER_ID PARTNER_DOMAIN BACKEND_HOST BACKEND_PORT SFU_SIGNING_PUBLIC_KEY NONEXISTENT_VAR
  out=$(mktemp)
  render_template tests/fixtures/render-template/input.tpl "$out"
  grep -q "^partner_id: $" "$out"
  grep -q "^backend: :$" "$out"
  rm -f "$out"
}

@test "render_template preserves literal dollar signs and percent signs" {
  out=$(mktemp)
  render_template tests/fixtures/render-template/input.tpl "$out"
  grep -F 'literal-percent: 100%' "$out"
  grep -F 'literal-dollar: $HOME' "$out"
  rm -f "$out"
}

@test "render_template handles multi-line PEM (closes hydrate bug class)" {
  export SFU_SIGNING_PUBLIC_KEY=$'-----BEGIN PUBLIC KEY-----\nLINE1\nLINE2\n-----END PUBLIC KEY-----'
  out=$(mktemp)
  render_template tests/fixtures/render-template/input.tpl "$out"
  # Extract the PEM block (line after "pem: " through next blank or non-PEM line)
  # and compare verbatim with newlines preserved.
  expected=$'pem: -----BEGIN PUBLIC KEY-----\nLINE1\nLINE2\n-----END PUBLIC KEY-----'
  actual=$(awk '/^pem: /{flag=1} flag{print} /END PUBLIC KEY/{flag=0}' "$out")
  [ "$actual" = "$expected" ]
  rm -f "$out"
}

@test "render_template fails cleanly on missing source" {
  out=$(mktemp)
  run render_template /nonexistent/path.tpl "$out"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "source not found" ]]
  rm -f "$out"
}
