#!/usr/bin/env bats
# Regression guard for tunnel-snippet reverse_proxy ordering.
#
# Current architecture (2026-05-21): the pool has 4 upstreams in lb_policy=first
# order:
#   1. {{AWG_MOTHERLY_IP}}:8907     CH2 — AWG-direct via socat bridge (fastest)
#   2. xray-client:3080             CH1 — VLESS+Reality tunnel
#   3. {{HY2_FALLBACK_HOST}}:{{HY2_FALLBACK_PORT}}  CH3 — Hysteria2 QUIC fallback
#   4. 127.0.0.1:{{NAIVE_SOCKS_PORT}}              CH5 — naive forward proxy (deferred)
#
# Historical regression (PR #158, 571e4de): primary upstream was set to
# {{AWG_MOTHERLY_IP}}:{{BACKEND_PORT}} which rendered as 10.9.0.2:5349 — the
# VLESS-Reality TLS port, NOT HTTP. Result: every HTTPS request returned 503.
# The :5349 ban remains. Port 8907 is the socat-bridged HTTP path on hub —
# verified 2026-05-21 returning 200 OK on edge-c/edge-d/edge-a.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TPL="$REPO_ROOT/Caddyfile.tpl"
}

render_tpl() {
  sed \
    -e "s|{{PARTNER_DOMAIN}}|test.example|g" \
    -e "s|{{TURNS_SUBDOMAIN}}|turns|g" \
    -e "s|{{AWG_MOTHERLY_IP}}|10.9.0.2|g" \
    -e "s|{{BACKEND_PORT}}|8907|g" \
    -e "s|{{HY2_FALLBACK_HOST}}|host.docker.internal|g" \
    -e "s|{{HY2_FALLBACK_PORT}}|18443|g" \
    "$TPL"
}

@test "tunnel_upstream snippet: primary upstream is AWG mesh 10.9.0.2:8907 (CH2 socat bridge)" {
  # The primary upstream MUST be the AWG mesh address on :8907 — hub's
  # oxpulse-awg-bridge.service socat that forwards to docker-proxy of oxpulse-chat.
  # CH2 is the fastest path (~300 ms RTT) and bypasses the 16 KB TCP cap that
  # kills CH1 reality on RU mobile ISPs.
  rendered=$(render_tpl)
  echo "$rendered" | grep -qF 'reverse_proxy {args[0]} 10.9.0.2:8907 xray-client:3080' || {
    echo "FAIL: tunnel_upstream snippet does not start with 10.9.0.2:8907 xray-client:3080" >&2
    echo "      Found upstream lines:" >&2
    echo "$rendered" | grep 'reverse_proxy' >&2
    return 1
  }
}

@test "tunnel_upstream_default snippet: primary upstream is AWG mesh 10.9.0.2:8907 (CH2)" {
  # Same check for the no-args SPA fallback snippet.
  rendered=$(render_tpl)
  echo "$rendered" | grep -qE '^[[:space:]]+reverse_proxy 10\.9\.0\.2:8907 xray-client:3080' || {
    echo "FAIL: tunnel_upstream_default does not start with 10.9.0.2:8907 xray-client:3080" >&2
    echo "      Found upstream lines:" >&2
    echo "$rendered" | grep 'reverse_proxy' >&2
    return 1
  }
}

@test "rendered Caddyfile: :5349 does NOT appear as an HTTP upstream (TLS-only VLESS entry)" {
  # Port 5349 on motherly is TLS-only vless-reality. It must never appear as an
  # HTTP reverse_proxy target — that would cause immediate connection failure.
  rendered=$(render_tpl)
  if echo "$rendered" | grep 'reverse_proxy' | grep -qF ':5349'; then
    echo "FAIL: :5349 found as reverse_proxy upstream — this is the VLESS-reality TLS port, not HTTP" >&2
    echo "      Offending lines:" >&2
    echo "$rendered" | grep 'reverse_proxy' | grep ':5349' >&2
    return 1
  fi
}

@test "Caddyfile.tpl source: tunnel snippet pool order is CH2,CH1,CH3,CH5" {
  # Verifies the placeholder order in the template source matches the documented
  # 4-channel waterfall. Reordering without intent breaks the lb_policy=first
  # fallback chain and is a regression.
  if ! grep -qF 'reverse_proxy {args[0]} {{AWG_MOTHERLY_IP}}:8907 xray-client:3080 {{HY2_FALLBACK_HOST}}:{{HY2_FALLBACK_PORT}} 127.0.0.1:{{NAIVE_SOCKS_PORT}}' "$TPL"; then
    echo "FAIL: tunnel_upstream snippet pool order changed; expected CH2,CH1,CH3,CH5" >&2
    grep 'reverse_proxy' "$TPL" >&2
    return 1
  fi
  if ! grep -qF 'reverse_proxy {{AWG_MOTHERLY_IP}}:8907 xray-client:3080 {{HY2_FALLBACK_HOST}}:{{HY2_FALLBACK_PORT}} 127.0.0.1:{{NAIVE_SOCKS_PORT}}' "$TPL"; then
    echo "FAIL: tunnel_upstream_default snippet pool order changed; expected CH2,CH1,CH3,CH5" >&2
    grep 'reverse_proxy' "$TPL" >&2
    return 1
  fi
}
