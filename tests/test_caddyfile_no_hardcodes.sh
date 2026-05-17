#!/usr/bin/env bats
# Verifies that Caddyfile.tpl no longer contains hardcoded infrastructure
# IPs/ports and that the rendered output substitutes them correctly.
#
# Test 1 — source template must NOT contain bare 10.9.0.2:8907 (only placeholder form).
# Test 2 — rendered Caddyfile with defaults produces expected 10.9.0.2:8907 and
#           host.docker.internal:18443 upstreams.
# Test 3 — operator override: AWG_MOTHERLY_IP_TEST=10.9.0.99 renders 10.9.0.99:8907.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TPL="$REPO_ROOT/Caddyfile.tpl"
}

render_tpl() {
  local awg_ip="${1:-10.9.0.2}"
  local backend_port="${2:-8907}"
  local hy2_host="${3:-host.docker.internal}"
  local hy2_port="${4:-18443}"
  sed \
    -e "s|{{PARTNER_DOMAIN}}|test.example|g" \
    -e "s|{{TURNS_SUBDOMAIN}}|turns|g" \
    -e "s|{{AWG_MOTHERLY_IP}}|${awg_ip}|g" \
    -e "s|{{BACKEND_PORT}}|${backend_port}|g" \
    -e "s|{{HY2_FALLBACK_HOST}}|${hy2_host}|g" \
    -e "s|{{HY2_FALLBACK_PORT}}|${hy2_port}|g" \
    "$TPL"
}

@test "Caddyfile.tpl source does not contain bare 10.9.0.2:8907" {
  run grep -F '10.9.0.2:8907' "$TPL"
  [ "$status" -ne 0 ] || {
    echo "FAIL: literal 10.9.0.2:8907 found in Caddyfile.tpl — use {{AWG_MOTHERLY_IP}}:{{BACKEND_PORT}}" >&2
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

@test "rendered Caddyfile with defaults contains 10.9.0.2:8907" {
  rendered=$(render_tpl)
  echo "$rendered" | grep -qF '10.9.0.2:8907'
}

@test "rendered Caddyfile with defaults contains host.docker.internal:18443" {
  rendered=$(render_tpl)
  echo "$rendered" | grep -qF 'host.docker.internal:18443'
}

@test "operator override: AWG_MOTHERLY_IP renders custom IP" {
  rendered=$(render_tpl "10.9.0.99" "8907" "host.docker.internal" "18443")
  echo "$rendered" | grep -qF '10.9.0.99:8907' || {
    echo "FAIL: expected 10.9.0.99:8907 in rendered output" >&2
    return 1
  }
  # Default IP must NOT appear
  ! echo "$rendered" | grep -qF '10.9.0.2:8907' || {
    echo "FAIL: default 10.9.0.2:8907 still present after override" >&2
    return 1
  }
}

@test "Caddyfile.tpl placeholders present: AWG_MOTHERLY_IP, BACKEND_PORT, HY2_FALLBACK_HOST, HY2_FALLBACK_PORT" {
  grep -qF '{{AWG_MOTHERLY_IP}}' "$TPL"
  grep -qF '{{BACKEND_PORT}}' "$TPL"
  grep -qF '{{HY2_FALLBACK_HOST}}' "$TPL"
  grep -qF '{{HY2_FALLBACK_PORT}}' "$TPL"
}
