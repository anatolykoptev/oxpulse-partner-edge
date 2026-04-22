#!/bin/bash
# Regression: install.sh + hydrate.sh must ship cover/cover.html so Caddy
# file_server can serve the DPI-probe decoy on GET /. Missing file =
# silent 404 on partner root URL (rvpn outage 2026-04-20). Healthcheck
# must also include a live probe of GET / so the misconfig is loud.
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-/home/krolik/src/oxpulse-partner-edge}"
INSTALL="$REPO_ROOT/deploy/partner-edge/install.sh"
HYDRATE="$REPO_ROOT/deploy/partner-edge/hydrate.sh"
HEALTH="$REPO_ROOT/deploy/partner-edge/healthcheck.sh"

# install.sh fetches the cover asset and copies it into the rendered output dir.
grep -q 'fetch_tpl cover/cover.html' "$INSTALL" \
  || { echo "FAIL: install.sh does not fetch cover/cover.html"; exit 1; }
grep -q 'install -m 0644 .*cover/cover.html .*cover_out_dir/cover.html' "$INSTALL" \
  || grep -q 'install -m 0644 "\$stage/cover/cover.html" "\$cover_out_dir/cover.html"' "$INSTALL" \
  || { echo "FAIL: install.sh does not place cover.html into output dir"; exit 1; }

# hydrate.sh (snapshot+clone path) also places the cover asset.
grep -q 'cover/cover.html' "$HYDRATE" \
  || { echo "FAIL: hydrate.sh does not handle cover/cover.html"; exit 1; }

# healthcheck.sh probes GET / so a missing cover surfaces as a red check.
grep -q 'cover served on GET /' "$HEALTH" \
  || { echo "FAIL: healthcheck.sh missing GET / cover probe (check #10)"; exit 1; }
grep -q 'All 10 checks passed' "$HEALTH" \
  || { echo "FAIL: healthcheck.sh count not bumped to 10"; exit 1; }

# Syntax check on touched scripts.
bash -n "$INSTALL"  || { echo "FAIL: install.sh has syntax errors"; exit 1; }
bash -n "$HYDRATE"  || { echo "FAIL: hydrate.sh has syntax errors"; exit 1; }
bash -n "$HEALTH"   || { echo "FAIL: healthcheck.sh has syntax errors"; exit 1; }

# End-to-end: dry-run install.sh and confirm cover.html lands in the rendered tree.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
out=$(cd "$TMP" && bash "$INSTALL" \
  --domain=cover.test.local --partner-id=covertest \
  --manual-config=/dev/stdin --dry-run <<'JSON' 2>&1
{"node_id":"t","backend_endpoint":"backend.test:443","turn_secret":"x","reality_uuid":"00000000-0000-0000-0000-000000000000","reality_public_key":"x","reality_short_id":"deadbeef","reality_server_name":"www.example.com","reality_encryption":""}
JSON
) || { echo "FAIL: install.sh --dry-run exited non-zero"; echo "$out"; exit 1; }

dryroot=$(echo "$out" | sed -n 's|.*rendered → \(/tmp/[^/]*\)/docker-compose.yml.*|\1|p' | head -1)
[ -n "$dryroot" ] || { echo "FAIL: could not extract dryroot from install.sh output"; echo "$out"; exit 1; }
[ -s "$dryroot/cover/cover.html" ] \
  || { echo "FAIL: cover.html not present at $dryroot/cover/cover.html"; ls -la "$dryroot/" "$dryroot/cover/" 2>&1; exit 1; }
grep -q 'Site under construction' "$dryroot/cover/cover.html" \
  || { echo "FAIL: cover.html has wrong content"; exit 1; }

echo "PASS: install.sh + hydrate.sh ship cover.html, healthcheck probes it"
