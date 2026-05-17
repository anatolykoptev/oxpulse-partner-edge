#!/usr/bin/env bats
# Phase 2 Task 6 — install.sh must expose render_with_opec() and
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

@test "install.sh exposes render_with_opec helper" {
  grep -qE 'render_with_opec\(\)' install.sh
}

@test "install.sh calls render_with_opec for xray" {
  grep -qE 'render_with_opec[[:space:]]+xray' install.sh
}

@test "install.sh calls render_with_opec for coturn" {
  grep -qE 'render_with_opec[[:space:]]+coturn' install.sh
}

@test "install.sh calls render_with_opec for naive" {
  grep -qE 'render_with_opec[[:space:]]+naive' install.sh
}

@test "install.sh calls render_with_opec for compose" {
  grep -qE 'render_with_opec[[:space:]]+compose' install.sh
}

@test "install.sh calls render_with_opec for caddy" {
  grep -qE 'render_with_opec[[:space:]]+caddy' install.sh
}

@test "install.sh no longer has bare render_template calls for stage templates" {
  ! grep -qE 'render_template[[:space:]]+"\$stage/' install.sh
}

# Phase 4.4 removed the bash render_template fallback branch entirely.
# `render_with_opec` now die's loudly if `opec` is not on PATH.
@test "render_with_opec hard-fails without opec on PATH" {
  set_frozen_vars
  mirror_install_exports
  eval "$(awk '/^render_with_opec\(\) \{/,/^\}/' install.sh)"
  # Provide a die stub so the test can observe the exit instead of inheriting bats' set -e.
  die() { echo "die: $*" >&2; return 1; }
  out=$(mktemp)
  run env PATH=/usr/bin:/bin bash -c "
    die() { echo \"die: \$*\" >&2; exit 1; }
    $(awk '/^render_with_opec\(\) \{/,/^\}/' install.sh)
    render_with_opec xray '$BATS_TEST_DIRNAME/fixtures/install-render/xray.tpl' '$out'
  "
  rm -f "$out"
  [ "$status" -ne 0 ]
  [[ "$output" == *"opec binary not on PATH"* ]]
}

@test "install.sh sources lib/install-preflight.sh module" {
    grep -qE '_install_lib_source[[:space:]]+install-preflight\.sh' install.sh
}

@test "install.sh sources lib/install-deps.sh module" {
    grep -qE '_install_lib_source[[:space:]]+install-deps\.sh' install.sh
}

@test "install.sh calls preflight_run instead of inline Step 1" {
    grep -qE '^[[:space:]]*preflight_run([[:space:]]|$)' install.sh
}

@test "install.sh calls deps_install instead of inline Step 2" {
    grep -qE '^[[:space:]]*deps_install([[:space:]]|$)' install.sh
}

@test "install.sh no longer inlines OS_FAMILY detection" {
    ! grep -qE '\*\" debian \"\*\|\*\" ubuntu \"\*\) OS_FAMILY=debian' install.sh
}

@test "install.sh sources lib/install-network.sh module" {
    grep -qE '_install_lib_source[[:space:]]+install-network\.sh' install.sh
}

@test "install.sh calls network_run instead of inline Step 3" {
    grep -qE '^[[:space:]]*network_run([[:space:]]|$)' install.sh
}

@test "install.sh no longer inlines _detect_public_ipv4" {
    ! grep -qE '^_detect_public_ipv4\(\)' install.sh
}

@test "install.sh no longer inlines _detect_region" {
    ! grep -qE '^_detect_region\(\)' install.sh
}

@test "install.sh delegates reality-keygen to opec when OPEC_SECRETS_REALITY_KEYGEN!=0" {
    grep -qE 'OPEC_SECRETS_REALITY_KEYGEN' install.sh
    grep -qE 'opec[[:space:]]+secrets[[:space:]]+reality-keygen' install.sh
}

@test "install.sh preserves bash fallback for reality-keygen" {
    grep -qE 'partner-cli[[:space:]]+keygen' install.sh
}

@test "install.sh OPEC path honors DRY_RUN (no side-effect invocation)" {
    # The OPEC dispatcher must not call 'opec secrets reality-keygen' in
    # dry-run mode. Encoded as: there is a DRY_RUN check inside the OPEC branch
    # block that precedes the actual invocation.
    awk '/OPEC_SECRETS_REALITY_KEYGEN/,/^else$/' install.sh \
        | grep -qE 'DRY_RUN[[:space:]]*-eq[[:space:]]*1'
}

@test "install.sh OPEC path maps FORCE_KEYGEN to --rotate" {
    # --force-keygen / --rotate-identity flags set FORCE_KEYGEN=1; OPEC branch
    # must translate that to the --rotate flag so operator rotation works
    # regardless of which backend is active.
    awk '/OPEC_SECRETS_REALITY_KEYGEN/,/^else$/' install.sh \
        | grep -qE 'FORCE_KEYGEN[[:space:]]*-eq[[:space:]]*1.*--rotate|--rotate.*FORCE_KEYGEN'
}

@test "install.sh delegates awg-keygen to opec when OPEC_SECRETS_AWG_KEYGEN!=0" {
    grep -qE 'OPEC_SECRETS_AWG_KEYGEN' install.sh
    grep -qE 'opec[[:space:]]+secrets[[:space:]]+awg-keygen' install.sh
}

@test "install.sh preserves bash fallback for awg-keygen" {
    grep -qE 'wg[[:space:]]+genkey' install.sh
    grep -qE 'wg[[:space:]]+pubkey' install.sh
}

@test "install.sh OPEC awg path honors DRY_RUN" {
    awk '/OPEC_SECRETS_AWG_KEYGEN/,/^[[:space:]]*else[[:space:]]*$/' install.sh \
        | grep -qE 'DRY_RUN[[:space:]]*-eq[[:space:]]*1|dryrun-awg-pubkey-placeholder'
}

@test "install.sh OPEC awg path maps FORCE_KEYGEN to --rotate" {
    awk '/OPEC_SECRETS_AWG_KEYGEN/,/^[[:space:]]*else[[:space:]]*$/' install.sh \
        | grep -qE 'FORCE_KEYGEN[[:space:]]*-eq[[:space:]]*1.*--rotate|--rotate.*FORCE_KEYGEN'
}

# ---------------------------------------------------------------------------
# Phase 4.3c Task 4 — register POST delegation
# ---------------------------------------------------------------------------

@test "install.sh delegates register to opec when OPEC_SECRETS_REGISTER!=0" {
    grep -qE 'OPEC_SECRETS_REGISTER' install.sh
    grep -qE 'opec[[:space:]]+secrets[[:space:]]+register' install.sh
}

@test "install.sh preserves bash fallback for register" {
    grep -qE '/api/partner/register' install.sh
}

@test "install.sh OPEC register path sets NODE_ID from env-file" {
    awk '/OPEC_SECRETS_REGISTER/,/^[[:space:]]*else[[:space:]]*$/' install.sh \
        | grep -qE '\. "\$tmp_cfg\.env"|source[[:space:]]+"\$tmp_cfg\.env"'
}

@test "install.sh OPEC register path honors DRY_RUN" {
    awk '/OPEC_SECRETS_REGISTER/,/^[[:space:]]*else[[:space:]]*$/' install.sh \
        | grep -qE 'DRY_RUN[[:space:]]*-eq[[:space:]]*1'
}

@test "install.sh MANUAL_CONFIG bypasses OPEC register" {
    # MANUAL_CONFIG branch must precede OPEC_SECRETS_REGISTER dispatch
    grep -nE 'MANUAL_CONFIG|OPEC_SECRETS_REGISTER' install.sh \
        | awk -F: 'NR==1{first=$2} END{exit (first ~ /MANUAL_CONFIG/) ? 0 : 1}'
}

@test "install.sh AWG keygen block precedes register dispatch" {
    # AWG_PRIV_PATH assignment (or OPEC_SECRETS_AWG_KEYGEN gate) must appear
    # before OPEC_SECRETS_REGISTER block so AWG_PUB_PATH is ready for both paths.
    local awg_line reg_line
    awg_line=$(grep -nE 'AWG_PRIV_PATH="\$PREFIX_ETC' install.sh | head -1 | cut -d: -f1)
    reg_line=$(grep -nE 'OPEC_SECRETS_REGISTER' install.sh | head -1 | cut -d: -f1)
    [[ -n "$awg_line" && -n "$reg_line" && "$awg_line" -lt "$reg_line" ]]
}

@test "install.sh json_get block skipped when OPEC_REGISTER_USED is set" {
    grep -qE 'OPEC_REGISTER_USED' install.sh
}

# ---------------------------------------------------------------------------
# Phase 4.3d Task — sfu-signing-key delegation
# ---------------------------------------------------------------------------

@test "install.sh delegates sfu-signing-key to opec when OPEC_SECRETS_SFU_KEY!=0" {
    grep -qE 'OPEC_SECRETS_SFU_KEY' install.sh
    grep -qE 'opec[[:space:]]+secrets[[:space:]]+sfu-signing-key' install.sh
}

@test "install.sh preserves bash fallback for sfu-signing-key" {
    grep -qE 'api/partner/keys' install.sh
}

@test "install.sh OPEC sfu-signing-key path warns on failure (not die)" {
    awk '/OPEC_SECRETS_SFU_KEY/,/^[[:space:]]*else[[:space:]]*$/' install.sh \
        | grep -qE 'warn.*OPEC_SECRETS_SFU_KEY=0|warn.*sfu-signing-key'
}

# ---------------------------------------------------------------------------
# Phase 4.6 — healthcheck module delegation
# ---------------------------------------------------------------------------

@test "install.sh sources lib/install-healthcheck.sh module" {
    grep -qE '_install_lib_source[[:space:]]+install-healthcheck\.sh' install.sh
}

@test "install.sh calls healthcheck_run instead of inline [7/10]" {
    grep -qE '^[[:space:]]*healthcheck_run([[:space:]]|$)' install.sh
}

@test "install.sh no longer inlines [7/10] healthcheck log call" {
    ! grep -qE 'log.*\[7/10\].*waiting for healthcheck' install.sh
}
