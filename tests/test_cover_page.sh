#!/bin/bash
# cover.html backwards-compat guard.
#
# The @probe cover-decoy matcher was REMOVED from Caddyfile.tpl on 2026-04-20
# (it interacted badly with the Service Worker — SW cached the decoy as the "/"
# response; see the Caddyfile.tpl header comment). GET / now serves the SPA
# directly (healthcheck check_10_spa). cover.html is still shipped and
# bind-mounted at /srv/cover for backwards compatibility, but is unreachable.
#
# This test therefore guards the CURRENT reality (the original @probe-matcher
# assertions checked removed behavior and were dropped):
#   (a) cover.html is still shipped with the expected content,
#   (b) the compose bind mount is still present, and
#   (c) the @probe decoy stays REMOVED (regression guard on the SW-bug fix).
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-/home/user/src/oxpulse-partner-edge}"
CF="$REPO_ROOT/Caddyfile.tpl"
CV="$REPO_ROOT/cover/cover.html"
CP="$REPO_ROOT/docker-compose.yml.tpl"

[ -f "$CV" ] || { echo "FAIL: cover.html missing"; exit 1; }
grep -q '<title>Site under construction' "$CV" || { echo "FAIL: cover.html content wrong"; exit 1; }

# Backwards-compat bind mount still present.
grep -q './cover:/srv/cover:ro' "$CP" || { echo "FAIL: cover volume mount missing"; exit 1; }

# Regression guard: the @probe cover decoy must stay removed (SW-bug fix,
# 2026-04-20). Exclude comment lines — the header documents the removal and
# legitimately mentions "@probe".
if grep -vE '^[[:space:]]*#' "$CF" | grep -qE '@probe|handle @probe'; then
  echo "FAIL: @probe cover decoy re-introduced in Caddyfile.tpl (removed 2026-04-20 for SW bug)"
  exit 1
fi

echo "PASS: cover.html shipped + mounted (backwards-compat); @probe decoy stays removed"
