#!/bin/bash
# Regression: install.sh + hydrate.sh must ship cover/cover.html and the
# healthcheck must include a live probe of GET / so a root-URL misconfig is
# loud (edge-c outage 2026-04-20 = silent 404 on partner root URL).
#
# NOTE: the @probe cover *decoy* was removed 2026-04-20 (it interacted badly
# with the Service Worker) — GET / now serves the SPA directly (healthcheck
# check_10_spa). cover.html is STILL shipped for backwards-compat with the
# /etc/oxpulse-partner-edge/cover bind mount, so this test still guards that
# the asset is fetched + placed and that GET / is probed.
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
INSTALL="$REPO_ROOT/install.sh"
HYDRATE="$REPO_ROOT/hydrate.sh"
HEALTH="$REPO_ROOT/healthcheck.sh"

# install.sh fetches the cover asset and copies it into the rendered output dir.
grep -q 'fetch_tpl cover/cover.html' "$INSTALL" \
  || { echo "FAIL: install.sh does not fetch cover/cover.html"; exit 1; }
grep -q 'install -m 0644 .*cover/cover.html .*cover_out_dir/cover.html' "$INSTALL" \
  || grep -q 'install -m 0644 "\$stage/cover/cover.html" "\$cover_out_dir/cover.html"' "$INSTALL" \
  || { echo "FAIL: install.sh does not place cover.html into output dir"; exit 1; }

# hydrate.sh (snapshot+clone path) also places the cover asset.
grep -q 'cover/cover.html' "$HYDRATE" \
  || { echo "FAIL: hydrate.sh does not handle cover/cover.html"; exit 1; }

# healthcheck.sh probes GET / (check_10) so a root-URL misconfig surfaces as a
# red check. Post cover-decoy removal (2026-04-20) this probe asserts the SPA
# is served on GET /.
grep -q 'SPA served on GET /' "$HEALTH" \
  || { echo "FAIL: healthcheck.sh missing GET / probe (check_10_spa)"; exit 1; }
grep -q 'All checks passed' "$HEALTH" \
  || { echo "FAIL: healthcheck.sh summary line missing"; exit 1; }

# Syntax check on touched scripts.
bash -n "$INSTALL"  || { echo "FAIL: install.sh has syntax errors"; exit 1; }
bash -n "$HYDRATE"  || { echo "FAIL: hydrate.sh has syntax errors"; exit 1; }
bash -n "$HEALTH"   || { echo "FAIL: healthcheck.sh has syntax errors"; exit 1; }

# End-to-end: dry-run install.sh and confirm cover.html lands in the rendered
# tree. install.sh's render path now REQUIRES the `opec` binary (Phase 4.4
# removed the bash render fallback), so run the dry-run e2e only when opec is
# resolvable (on PATH or bundled alongside install.sh); otherwise skip it — the
# structural checks above are the primary coverage.
if command -v opec >/dev/null 2>&1 || ls "$REPO_ROOT"/opec-* >/dev/null 2>&1; then
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
  echo "PASS: install.sh + hydrate.sh ship cover.html (structural + dry-run), healthcheck probes it"
else
  echo "SKIP (dry-run e2e): opec binary not available — structural checks passed"
  echo "PASS: install.sh + hydrate.sh ship cover.html (structural), healthcheck probes it"
fi
