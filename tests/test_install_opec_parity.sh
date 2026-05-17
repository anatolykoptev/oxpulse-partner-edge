#!/usr/bin/env bats
# Phase 2 Task 6 — install.sh must expose render_with_opec_or_fallback() and
# use it for xray/coturn/naive call sites. The fallback branch (opec NOT on
# PATH) must produce byte-identical output to the Phase-1 golden fixtures.

setup() {
  cd "$BATS_TEST_DIRNAME/.."
  # shellcheck source=../channel-render-lib.sh
  source ./channel-render-lib.sh
}

set_frozen_vars() {
  PARTNER_ID=zvonilka
  DOMAIN=zvonilka.net
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
  SFU_UDP_PORT=7878
  SFU_METRICS_PORT=9317
  SFU_EDGE_ID=zvonilka1
  OTEL_EXPORTER_OTLP_ENDPOINT=
  SFU_SIGNING_PUBLIC_KEY='-----BEGIN PUBLIC KEY-----\nMCowBQYDK2VwAyEAZiwaWp+FJ1sGprGGS69mq+sB6nhwOMi24xGSGfgdXNo=\n-----END PUBLIC KEY-----\n'
  RELAY_JWT_SECRET=test-relay-jwt-secret
  SIGNALING_SFU_SECRET=test-signaling-sfu-secret
  HYSTERIA2_SERVER=
  HYSTERIA2_PORT=51822
  HYSTERIA2_AUTH=
  HYSTERIA2_OBFS=
  HYSTERIA2_SOCKS_PORT=18891
  HY2_SERVER=
  HY2_AUTH_PASS=
  HY2_OBFS_PASS=
  HY2_LOCAL_LISTEN=
  HY2_REMOTE_BACKEND=
  NAIVE_SERVER=
  NAIVE_PORT=44433
  NAIVE_USER=
  NAIVE_PASS=
  NAIVE_SOCKS_PORT=18892
}

mirror_install_exports() {
  PARTNER_DOMAIN="$DOMAIN"
  export PARTNER_ID PARTNER_DOMAIN BACKEND_ENDPOINT BACKEND_HOST BACKEND_PORT \
         TURN_SECRET \
         REALITY_UUID REALITY_PUBLIC_KEY REALITY_SHORT_ID REALITY_SERVER_NAME \
         REALITY_ENCRYPTION TURNS_SUBDOMAIN \
         PUBLIC_IP PRIVATE_IP EXTERNAL_IP_LINE \
         IMAGE_VERSION \
         SFU_UDP_PORT SFU_METRICS_PORT SFU_EDGE_ID \
         OTEL_EXPORTER_OTLP_ENDPOINT \
         SFU_SIGNING_PUBLIC_KEY RELAY_JWT_SECRET SIGNALING_SFU_SECRET \
         HYSTERIA2_SERVER HYSTERIA2_PORT HYSTERIA2_AUTH HYSTERIA2_OBFS HYSTERIA2_SOCKS_PORT \
         NAIVE_SERVER NAIVE_PORT NAIVE_USER NAIVE_PASS NAIVE_SOCKS_PORT \
         HY2_SERVER HY2_AUTH_PASS HY2_OBFS_PASS HY2_LOCAL_LISTEN HY2_REMOTE_BACKEND
}

@test "install.sh exposes render_with_opec_or_fallback helper" {
  grep -qE 'render_with_opec_or_fallback\(\)' install.sh
}

@test "install.sh calls render_with_opec_or_fallback for xray" {
  grep -qE 'render_with_opec_or_fallback[[:space:]]+xray' install.sh
}

@test "install.sh calls render_with_opec_or_fallback for coturn" {
  grep -qE 'render_with_opec_or_fallback[[:space:]]+coturn' install.sh
}

@test "install.sh calls render_with_opec_or_fallback for naive" {
  grep -qE 'render_with_opec_or_fallback[[:space:]]+naive' install.sh
}

@test "install.sh calls render_with_opec_or_fallback for compose" {
  grep -qE 'render_with_opec_or_fallback[[:space:]]+compose' install.sh
}

@test "install.sh calls render_with_opec_or_fallback for caddy" {
  grep -qE 'render_with_opec_or_fallback[[:space:]]+caddy' install.sh
}

@test "install.sh no longer has bare render_template calls for stage templates" {
  ! grep -qE 'render_template[[:space:]]+"\$stage/' install.sh
}

# Fallback branch (opec NOT on PATH) — byte-identical to pre-Phase-2 behaviour.
# Sources the helper body from install.sh, strips opec PATH, exercises fallback.
@test "fallback branch produces byte-identical xray output" {
  set_frozen_vars
  mirror_install_exports
  # Extract and source render_with_opec_or_fallback from install.sh
  eval "$(awk '/^render_with_opec_or_fallback\(\) \{/,/^\}/' install.sh)"
  out=$(mktemp)
  # PATH without opec forces the fallback branch
  PATH=/usr/bin:/bin render_with_opec_or_fallback xray \
    tests/fixtures/install-render/xray.tpl "$out"
  diff -u tests/fixtures/install-render/expected/xray.txt "$out"
  rm -f "$out"
}

@test "install.sh sources lib/install-preflight.sh module" {
    grep -qE '_install_lib_source[[:space:]]+install-preflight\.sh' install.sh
}

@test "install.sh sources lib/install-deps.sh module" {
    grep -qE '_install_lib_source[[:space:]]+install-deps\.sh' install.sh
}

@test "install.sh calls preflight_run instead of inline Step 1" {
    grep -qE '^preflight_run$' install.sh
}

@test "install.sh calls deps_install instead of inline Step 2" {
    grep -qE '^deps_install$' install.sh
}

@test "install.sh no longer inlines OS_FAMILY detection" {
    ! grep -qE '\*\" debian \"\*\|\*\" ubuntu \"\*\) OS_FAMILY=debian' install.sh
}
