#!/usr/bin/env bats
# Phase 1 Task 3 — render_template() consistency check on hydrate cloud-init
# path + PEM bug-class closure.
#
# Tests 1-6: render_template output is stable across the 6 .tpl files used
# by hydrate.sh's cloud-init first-boot. These are baseline regression tests
# — fixtures generated via render_template itself. ASCII parity to install.sh's
# deleted python3 render is independently validated by
# tests/test_install_render_identical.sh (the algorithm is identical).
#
# Test 7: PEM bug-class closure — the deleted sed-based render in hydrate.sh
# could not handle multi-line PEM values (would produce 'sed: unterminated
# `s' command'). render_template handles them verbatim. This is the critical
# spec proof for Task 3.

setup() {
  cd "$BATS_TEST_DIRNAME/.."
  # shellcheck source=../channel-render-lib.sh
  source ./channel-render-lib.sh
}

# Plain shell vars matching hydrate.sh's state mid-render.
# PEM held as single-line ASCII to match the render_template baseline.
# render_template replaces ALL {{VAR}} with env value (empty if unset);
# vars not provided by the backend (SFU_*, OTEL_*, SIGNALING_*, HY2_*)
# are exported empty so they become "" in both baseline and post-refactor.
set_frozen_vars() {
  PARTNER_ID=zvonilka
  PARTNER_DOMAIN=zvonilka.net
  BACKEND_ENDPOINT=192.9.243.148:5349
  BACKEND_HOST=192.9.243.148
  BACKEND_PORT=5349
  TURN_SECRET=test-turn-secret-deadbeef
  REALITY_UUID=d529dee6-3cdd-4079-95d1-f8801722147c
  REALITY_PUBLIC_KEY=U6ea044JJjgiCjQAnYEBqBBlkeSqrQaLq3lcjnN2EFk
  REALITY_SHORT_ID=abcd1234
  REALITY_SERVER_NAME=www.samsung.com
  REALITY_ENCRYPTION=mlkem768x25519plus.native.0rtt.fXgOoxcW
  TURNS_SUBDOMAIN=api-test01
  PUBLIC_IP=157.22.204.190
  PRIVATE_IP=
  EXTERNAL_IP_LINE=157.22.204.190
  IMAGE_VERSION=stable
  RELAY_JWT_SECRET=test-relay-jwt-secret
  HYSTERIA2_SERVER=
  HYSTERIA2_PORT=51822
  HYSTERIA2_AUTH=
  HYSTERIA2_OBFS=
  # HYSTERIA2_SOCKS_PORT omitted (T3 NIT): no {{HYSTERIA2_SOCKS_PORT}} in any .tpl
  NAIVE_SERVER=
  NAIVE_PORT=44433
  NAIVE_USER=
  NAIVE_PASS=
  NAIVE_SOCKS_PORT=18892
  # Vars not provided by hydrate.sh's backend response — empty defaults.
  # render_template (unlike the old sed render) replaces these with "",
  # which is correct: SFU_* are provisioned by install.sh later, not cloud-init.
  SFU_UDP_PORT=
  SFU_METRICS_PORT=
  SFU_EDGE_ID=
  OTEL_EXPORTER_OTLP_ENDPOINT=
  SFU_SIGNING_PUBLIC_KEY=single-line-ascii-pem-stand-in
  SIGNALING_SFU_SECRET=
  HY2_SERVER=
  HY2_AUTH_PASS=
  HY2_OBFS_PASS=
  HY2_LOCAL_LISTEN=
  HY2_REMOTE_BACKEND=
}

# Mirror hydrate.sh's export wall (synchronised with the wall added in T3).
# Must exactly match the export statement inserted into hydrate.sh.
mirror_hydrate_exports() {
  export PARTNER_ID PARTNER_DOMAIN BACKEND_ENDPOINT BACKEND_HOST BACKEND_PORT \
         TURN_SECRET \
         REALITY_UUID REALITY_PUBLIC_KEY REALITY_SHORT_ID REALITY_SERVER_NAME \
         REALITY_ENCRYPTION TURNS_SUBDOMAIN \
         PUBLIC_IP PRIVATE_IP EXTERNAL_IP_LINE \
         IMAGE_VERSION \
         RELAY_JWT_SECRET \
         HYSTERIA2_SERVER HYSTERIA2_PORT HYSTERIA2_AUTH HYSTERIA2_OBFS \
         NAIVE_SERVER NAIVE_PORT NAIVE_USER NAIVE_PASS NAIVE_SOCKS_PORT \
         SFU_UDP_PORT SFU_METRICS_PORT SFU_EDGE_ID OTEL_EXPORTER_OTLP_ENDPOINT \
         SFU_SIGNING_PUBLIC_KEY SIGNALING_SFU_SECRET \
         HY2_SERVER HY2_AUTH_PASS HY2_OBFS_PASS HY2_LOCAL_LISTEN HY2_REMOTE_BACKEND
}

render_one() {
  local kind=$1
  set_frozen_vars
  mirror_hydrate_exports
  out=$(mktemp)
  render_template "tests/fixtures/install-render/${kind}.tpl" "$out"
  diff -u "tests/fixtures/hydrate-render/expected/${kind}.txt" "$out"
  rm -f "$out"
}

@test "hydrate render byte-identical: docker-compose.yml (ASCII)" { render_one compose; }
@test "hydrate render byte-identical: Caddyfile (ASCII)"          { render_one caddy; }
@test "hydrate render byte-identical: xray-client.json (ASCII)"   { render_one xray; }
@test "hydrate render byte-identical: coturn.conf (ASCII)"        { render_one coturn; }
@test "hydrate render byte-identical: hysteria2-client.yaml (ASCII)" { render_one hy2; }
@test "hydrate render byte-identical: naive-client.json (ASCII)"  { render_one naive; }

@test "hydrate render_template handles multi-line PEM (bug-class closure)" {
  set_frozen_vars
  mirror_hydrate_exports
  SFU_SIGNING_PUBLIC_KEY=$'-----BEGIN PUBLIC KEY-----\nLINE1\nLINE2\n-----END PUBLIC KEY-----'
  export SFU_SIGNING_PUBLIC_KEY
  out=$(mktemp)
  render_template tests/fixtures/install-render/compose.tpl "$out"
  # Verbatim multi-line block compare — catches order shuffles or {{ residue
  # that 4-line grep -F would miss. python3 -c extracts the first complete
  # PEM block from the rendered file so the comparison is indentation-agnostic
  # (the block may appear inside a yaml quoted string with leading whitespace).
  expected=$'-----BEGIN PUBLIC KEY-----\nLINE1\nLINE2\n-----END PUBLIC KEY-----'
  actual=$(python3 -c "
import re, sys
content = open(sys.argv[1]).read()
m = re.search(r'(-----BEGIN PUBLIC KEY-----.*?-----END PUBLIC KEY-----)', content, re.DOTALL)
print(m.group(1) if m else '', end='')
" "$out")
  [ "$actual" = "$expected" ]
  rm -f "$out"
}
