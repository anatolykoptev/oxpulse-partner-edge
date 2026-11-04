#!/usr/bin/env bats
# Verifies that Caddyfile.tpl does not contain hardcoded infrastructure
# IPs/ports and that the rendered output contains correct upstreams.
#
# Fix PR #158 regression: primary tunnel upstream is xray-client:3080 (local
# dokodemo-door container), NOT {{AWG_MOTHERLY_IP}}:{{BACKEND_PORT}} which
# rendered as 10.9.0.2:5349 — the TLS-only VLESS-reality entry on motherly.
#
# Test 1 — source template must NOT contain bare 10.9.0.2 in any form (except comments).
# Test 2 — source template must NOT contain host.docker.internal:18443 (CH3 retired).
# Test 3 — rendered Caddyfile tunnel upstreams use xray-client:3080 as primary.
# Test 4 — rendered Caddyfile has no hysteria2 fallback upstream.
# Test 5 — template carries no HY2_FALLBACK placeholders.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TPL="$REPO_ROOT/Caddyfile.tpl"
}

render_tpl() {
  sed \
    -e "s|{{PARTNER_DOMAIN}}|test.example|g" \
    -e "s|{{TURNS_SUBDOMAIN}}|turns|g" \
    "$TPL"
}

@test "Caddyfile.tpl source does not contain bare 10.9.0.2 (AWG mesh address)" {
  run grep -F '10.9.0.2' "$TPL"
  [ "$status" -ne 0 ] || {
    echo "FAIL: literal 10.9.0.2 found in Caddyfile.tpl — tunnel upstreams must use xray-client:3080" >&2
    return 1
  }
}

@test "Caddyfile.tpl source does not contain host.docker.internal:18443 (CH3 hysteria2 retired)" {
  # Note: host.docker.internal:5349 (coturn TURNS proxy) is intentional.
  run grep -F 'host.docker.internal:18443' "$TPL"
  [ "$status" -ne 0 ] || {
    echo "FAIL: literal host.docker.internal:18443 found in Caddyfile.tpl — the hysteria2 upstream is retired" >&2
    return 1
  }
}

@test "rendered Caddyfile tunnel upstreams use xray-client:3080 as primary" {
  rendered=$(render_tpl)
  echo "$rendered" | grep -qF 'xray-client:3080' || {
    echo "FAIL: xray-client:3080 not found in rendered Caddyfile — tunnel primary upstream broken" >&2
    return 1
  }
}

@test "rendered Caddyfile has no hysteria2 fallback upstream" {
  rendered=$(render_tpl)
  ! echo "$rendered" | grep -qF ':18443' || {
    echo "FAIL: :18443 (retired hysteria2 forwarder) still rendered as an upstream" >&2
    return 1
  }
}

@test "Caddyfile.tpl carries no HY2_FALLBACK placeholders" {
  ! grep -qF 'HY2_FALLBACK' "$TPL" || {
    echo "FAIL: HY2_FALLBACK_* placeholder still in Caddyfile.tpl" >&2
    return 1
  }
}
