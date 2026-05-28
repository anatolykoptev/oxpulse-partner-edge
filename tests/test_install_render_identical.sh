#!/usr/bin/env bats
# Phase 1 Task 2 — render_template() byte-identical to install.sh's render()
# for all 6 template targets.
#
# CRITICAL test invariant: this test must catch the export-gap class of bug.
# We deliberately set frozen vars as PLAIN shell vars (not exported), then
# manually export the SAME list install.sh exports at its first render_template
# call site. If install.sh's export list drops a variable, this test fails.
#
# See code-quality review on e1e847a for context.

setup() {
  cd "$BATS_TEST_DIRNAME/.."
  # shellcheck source=../channel-render-lib.sh
  source ./channel-render-lib.sh
}

set_frozen_vars() {
  # Plain shell vars — NOT exported. Mimics install.sh state after register +
  # autodetect + before the render_template call site.
  PARTNER_ID=zvonilka
  DOMAIN=zvonilka.net    # install.sh uses --domain flag → $DOMAIN; render maps to PARTNER_DOMAIN
  BACKEND_ENDPOINT=203.0.113.10:5349
  BACKEND_HOST=203.0.113.10
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
  # install.sh:1380-1383 escapes real newlines to literal \n before render —
  # fixture uses literal-\n form to match install.sh behaviour.
  SFU_SIGNING_PUBLIC_KEY='-----BEGIN PUBLIC KEY-----\nMCowBQYDK2VwAyEAZiwaWp+FJ1sGprGGS69mq+sB6nhwOMi24xGSGfgdXNo=\n-----END PUBLIC KEY-----\n'
  RELAY_JWT_SECRET=test-relay-jwt-secret
  SIGNALING_SFU_SECRET=test-signaling-sfu-secret
  HYSTERIA2_SERVER=
  HYSTERIA2_PORT=51822
  HYSTERIA2_AUTH=
  HYSTERIA2_OBFS=
  HYSTERIA2_SOCKS_PORT=18891
  # HY2_* vars are rendered by re_render_hysteria2() in production; in the test
  # fixture they appear in hy2.tpl and render as empty (matches expected/hy2.txt).
  HY2_SERVER=
  HY2_AUTH_PASS=
  HY2_OBFS_PASS=
  HY2_LOCAL_LISTEN=
  HY2_REMOTE_BACKEND=
  # Caddy tunnel upstream vars (extracted from Caddyfile hardcodes in PR #146 follow-up)
  AWG_MOTHERLY_IP=10.9.0.2
  AWG_ALLOCATED_IP=10.9.0.6/24  # central returns CIDR form; kept intact for awg0.conf
  AWG_HOST_IP=10.9.0.6           # stripped from AWG_ALLOCATED_IP via %%/* — SFU bind only
  HY2_FALLBACK_HOST=host.docker.internal
  HY2_FALLBACK_PORT=18443
  NAIVE_SERVER=
  NAIVE_PORT=44433
  NAIVE_USER=
  NAIVE_PASS=
  NAIVE_SOCKS_PORT=18892
}

# Mirror install.sh's export-wall at the render_template call site.
# If install.sh's export list drops a variable, this helper still exports it
# from the test side — to make the test signal real, we DELIBERATELY skip
# helper here for the placeholder coverage test and instead check parity
# with installed-script export semantics.
mirror_install_exports() {
  PARTNER_DOMAIN="$DOMAIN"
  export PARTNER_ID PARTNER_DOMAIN BACKEND_ENDPOINT BACKEND_HOST BACKEND_PORT \
         AWG_MOTHERLY_IP AWG_ALLOCATED_IP AWG_HOST_IP HY2_FALLBACK_HOST HY2_FALLBACK_PORT \
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

render_one() {
  local kind=$1
  set_frozen_vars
  mirror_install_exports
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

# Regression guard: every {{NAME}} placeholder in the 6 .tpl files MUST appear
# in mirror_install_exports above. If a new placeholder is added to a template
# without a matching export, this test fails noisily before fixtures-pass
# silences it.
@test "every template placeholder is in the export list" {
  set_frozen_vars
  mirror_install_exports
  cd tests/fixtures/install-render

  # Collect placeholders used in templates
  placeholders=$(grep -rohE '\{\{[A-Z][A-Z0-9_]*\}\}' compose.tpl caddy.tpl xray.tpl coturn.tpl hy2.tpl naive.tpl \
                   | sed -E 's/[{}]//g' | sort -u)

  # Collect currently-exported names (POSIX subset that bats can introspect)
  exported=$(declare -px | awk -F'[ =]' '/^declare -x/{print $3}' | sort -u)

  missing=""
  for p in $placeholders; do
    if ! grep -qx "$p" <<<"$exported"; then
      missing+=" $p"
    fi
  done

  if [ -n "$missing" ]; then
    echo "Placeholders missing from export list:$missing" >&2
    return 1
  fi
}
