#!/bin/bash
# Golden-file test for Caddyfile.tpl rendering.
# Renders the template with opec render caddy (Phase 1: single render authority),
# runs through `caddy adapt --pretty` to produce canonical JSON, diffs against
# the stored golden JSON. Passes only when JSON output is byte-identical.
#
# Phase 1 change: render path switched from sed substitution to `opec render
# caddy` — the SAME path used by reconcile_caddy_surface at runtime. This
# eliminates the CI-vs-runtime drift that caused the original golden to have
# {{NAIVE_SOCKS_PORT}} literally in it.
#
# Invariant: pure refactor must NOT alter the adapted JSON at all.
# Any intentional change MUST regenerate the golden (see regenerate block below).
#
# Regenerate:
#   REGEN=1 bash tests/test_caddyfile_golden.sh
#
# Requires: docker daemon (for caddy adapt), opec on PATH or OPEC_BIN env.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$REPO_ROOT/tests/fixtures"
GOLDEN_JSON="$FIXTURES/caddyfile-golden-v0.13.0.json"
IMAGE="${CADDY_IMAGE:-ghcr.io/anatolykoptev/partner-edge-caddy:latest}"

# Locate opec: OPEC_BIN env override → PATH → cargo target (krolik dev box).
if [[ -n "${OPEC_BIN:-}" ]]; then
  OPEC="$OPEC_BIN"
elif command -v opec >/dev/null 2>&1; then
  OPEC=opec
else
  # Dev-box fallback: locate the release binary in cargo target dir.
  _cargo_target=$(
    cd "$REPO_ROOT" && git rev-parse --git-common-dir 2>/dev/null | xargs dirname 2>/dev/null || true)
  _opec_bin=""
  for _d in \
      /mnt/cargo/oxpulse-partner-edge-shared-*/release/opec \
      "$_cargo_target/target/release/opec" \
      "$(pwd)/target/release/opec"; do
    for f in $_d; do
      if [[ -x "$f" ]]; then _opec_bin="$f"; break 2; fi
    done
  done
  OPEC="${_opec_bin}"
fi

if [[ -z "${OPEC:-}" ]] || ! "$OPEC" --version >/dev/null 2>&1; then
  echo "SKIP: opec not available (OPEC_BIN or PATH) — set OPEC_BIN=/path/to/opec to run" >&2
  exit 0
fi

if ! docker info >/dev/null 2>&1; then
  echo "SKIP: docker daemon unreachable" >&2
  exit 0
fi

TMP_DIR=$(mktemp -d)
TMP_RENDERED="$TMP_DIR/Caddyfile"
TMP_JSON="$TMP_DIR/caddy.json"
trap 'rm -rf "$TMP_DIR"' EXIT

# Test inputs — all 6 Caddyfile.tpl placeholders set.
# __CADDYFILE_SHA__ is a post-render computed value (not an env placeholder).
export PARTNER_DOMAIN="test.example"
export TURNS_SUBDOMAIN="api-abc.test.example"
export AWG_MOTHERLY_IP="${AWG_MOTHERLY_IP_TEST:-10.9.0.2}"
export HY2_FALLBACK_HOST="${HY2_FALLBACK_HOST_TEST:-host.docker.internal}"
export HY2_FALLBACK_PORT="${HY2_FALLBACK_PORT_TEST:-18443}"
export NAIVE_SOCKS_PORT="${NAIVE_SOCKS_PORT_TEST:-1080}"

# Render via opec (single render authority — same path as reconcile_caddy_surface).
if ! "$OPEC" render caddy --tpl "$REPO_ROOT/Caddyfile.tpl" --out "$TMP_RENDERED" 2>&1; then
  echo "FAIL: opec render caddy failed" >&2
  exit 1
fi

# Verify completeness guard: no {{X}} should survive opec render.
LEFTOVER=$(grep -oE '\{\{[A-Z0-9_]+\}\}' "$TMP_RENDERED" 2>/dev/null || true)
if [[ -n "$LEFTOVER" ]]; then
  echo "FAIL: opec render left unsubstituted placeholders: $LEFTOVER" >&2
  exit 1
fi

# Substitute __CADDYFILE_SHA__ (matches reconcile_caddy_surface and install.sh).
_sha=$(sha256sum "$TMP_RENDERED" | awk '{print $1}')
sed -i "s|__CADDYFILE_SHA__|${_sha}|g" "$TMP_RENDERED"

# Produce canonical JSON via caddy adapt.
docker run --rm \
  -v "$TMP_RENDERED:/etc/caddy/Caddyfile:ro" \
  "$IMAGE" \
  caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile --pretty \
  2>/dev/null > "$TMP_JSON"

if [[ "${REGEN:-0}" == "1" ]]; then
  cp "$TMP_JSON" "$GOLDEN_JSON"
  echo "REGEN: golden JSON updated at $GOLDEN_JSON (opec render path, all 6 placeholders substituted)"
  exit 0
fi

if ! diff -u "$GOLDEN_JSON" "$TMP_JSON"; then
  echo "FAIL: rendered Caddyfile JSON differs from golden $GOLDEN_JSON" >&2
  echo "      Run: REGEN=1 bash tests/test_caddyfile_golden.sh  to update if change is intentional." >&2
  exit 1
fi

echo "PASS: Caddyfile.tpl renders (via opec) to byte-identical JSON vs golden $GOLDEN_JSON"
