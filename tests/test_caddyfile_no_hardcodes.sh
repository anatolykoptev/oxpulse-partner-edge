#!/usr/bin/env bats
# Verifies that Caddyfile.tpl does not contain hardcoded infrastructure
# IPs/ports and that the rendered output contains correct upstreams.
#
# Fix PR #158 regression: primary tunnel upstream is xray-client:3080 (local
# dokodemo-door container), NOT {{AWG_MOTHERLY_IP}}:{{BACKEND_PORT}} which
# rendered as 10.9.0.2:5349 — the TLS-only VLESS-reality entry on motherly.
#
# Test 1 — source template must NOT contain bare 10.9.0.2 in any form (except comments).
# Test 2 — source template must NOT contain bare host.docker.internal:18443.
# Test 3 — rendered Caddyfile tunnel upstreams use xray-client:3080 as primary.
# Test 4 — rendered Caddyfile contains host.docker.internal:18443 as HY2 fallback.
# Test 5 — HY2 fallback host override renders correctly.
# Test 6 — HY2 fallback placeholder present in template.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TPL="$REPO_ROOT/Caddyfile.tpl"
}

render_tpl() {
  local hy2_host="${1:-host.docker.internal}"
  local hy2_port="${2:-18443}"
  sed \
    -e "s|{{PARTNER_DOMAIN}}|test.example|g" \
    -e "s|{{TURNS_SUBDOMAIN}}|turns|g" \
    -e "s|{{HY2_FALLBACK_HOST}}|${hy2_host}|g" \
    -e "s|{{HY2_FALLBACK_PORT}}|${hy2_port}|g" \
    "$TPL"
}

@test "Caddyfile.tpl source does not contain bare 10.9.0.2 (AWG mesh address)" {
  run grep -F '10.9.0.2' "$TPL"
  [ "$status" -ne 0 ] || {
    echo "FAIL: literal 10.9.0.2 found in Caddyfile.tpl — tunnel upstreams must use xray-client:3080" >&2
    return 1
  }
}

@test "Caddyfile.tpl source does not contain bare host.docker.internal:18443 in upstream blocks" {
  # Note: host.docker.internal:5349 (coturn TURNS proxy) is intentional — only the
  # tunnel upstream port 18443 must be extracted to a placeholder.
  run grep -F 'host.docker.internal:18443' "$TPL"
  [ "$status" -ne 0 ] || {
    echo "FAIL: literal host.docker.internal:18443 found in Caddyfile.tpl — use {{HY2_FALLBACK_HOST}}:{{HY2_FALLBACK_PORT}}" >&2
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

@test "rendered Caddyfile contains host.docker.internal:18443 as HY2 fallback" {
  rendered=$(render_tpl)
  echo "$rendered" | grep -qF 'host.docker.internal:18443'
}

@test "operator override: HY2_FALLBACK_HOST renders custom fallback host" {
  rendered=$(render_tpl "custom-hy2.example.com" "18443")
  echo "$rendered" | grep -qF 'custom-hy2.example.com:18443' || {
    echo "FAIL: expected custom-hy2.example.com:18443 in rendered output" >&2
    return 1
  }
  # Default host must NOT appear in fallback position
  ! echo "$rendered" | grep -qF 'host.docker.internal:18443' || {
    echo "FAIL: default host.docker.internal:18443 still present after override" >&2
    return 1
  }
}

@test "Caddyfile.tpl placeholders present: HY2_FALLBACK_HOST, HY2_FALLBACK_PORT" {
  grep -qF '{{HY2_FALLBACK_HOST}}' "$TPL"
  grep -qF '{{HY2_FALLBACK_PORT}}' "$TPL"
}
