#!/usr/bin/env bats
# Regression guard: primary reverse_proxy upstream in tunnel snippets must be
# xray-client:3080 (local dokodemo-door container that wraps HTTP in VLESS and
# tunnels through awg0 to motherly's xray-server).
#
# Regression introduced: PR #158 commit 571e4de changed the upstream to
# {{AWG_MOTHERLY_IP}}:{{BACKEND_PORT}} which renders as 10.9.0.2:5349 —
# motherly's public VLESS-reality entry (TLS-only, NOT HTTP). Over AWG mesh
# backend does not bind :5349 at all (only :8907 is open on the mesh interface).
# Result: every HTTPS request returns 503 on all live partner edges.
# Live confirmed: ru.oxpulse.chat v0.12.38. Likely caused zvonilka silent>24h alert.

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

@test "tunnel_upstream snippet: primary upstream is xray-client:3080 (not AWG mesh address)" {
  # The primary upstream MUST be the local xray-client container on :3080.
  # If this fails, the Caddyfile.tpl contains the wrong upstream (regression PR #158).
  rendered=$(render_tpl)
  echo "$rendered" | grep -qF 'reverse_proxy {args[0]} xray-client:3080' || {
    echo "FAIL: tunnel_upstream snippet does not use xray-client:3080 as primary upstream" >&2
    echo "      Found upstream lines:" >&2
    echo "$rendered" | grep 'reverse_proxy' >&2
    return 1
  }
}

@test "tunnel_upstream_default snippet: primary upstream is xray-client:3080 (not AWG mesh address)" {
  # Same check for the no-args SPA fallback snippet.
  rendered=$(render_tpl)
  # The default snippet has no {args[0]}, starts directly with the upstream host
  echo "$rendered" | grep -qE '^[[:space:]]+reverse_proxy xray-client:3080' || {
    echo "FAIL: tunnel_upstream_default snippet does not use xray-client:3080 as primary upstream" >&2
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

@test "Caddyfile.tpl source: tunnel snippet lines must not contain {{AWG_MOTHERLY_IP}} (primary upstream regression guard)" {
  # Template source must specify xray-client:3080 directly in the two tunnel
  # snippet reverse_proxy lines (L78 and L96 at time of regression).
  # {{AWG_MOTHERLY_IP}} in those specific lines = regression.
  # Note: AWG_MOTHERLY_IP may still exist elsewhere (e.g. exports, comments) — only
  # reverse_proxy directive lines are checked.
  if grep -E '^\s+reverse_proxy.*\{\{AWG_MOTHERLY_IP\}\}' "$TPL"; then
    echo "FAIL: {{AWG_MOTHERLY_IP}} found in a reverse_proxy directive in Caddyfile.tpl" >&2
    echo "      Primary upstream must be xray-client:3080, not an AWG mesh address" >&2
    return 1
  fi
}
