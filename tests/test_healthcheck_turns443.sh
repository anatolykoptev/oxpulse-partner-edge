#!/bin/bash
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-/home/krolik/src/oxpulse-partner-edge}"
HC="$REPO_ROOT/healthcheck.sh"
INST="$REPO_ROOT/install.sh"

grep -q 'TURNS-443 handshake' "$HC" || { echo "FAIL: 9th probe label missing"; exit 1; }
# The probe uses `openssl s_client` with SNI (-servername) targeting the TURNS
# subdomain. The command is split across two lines (line continuation), so
# assert the two elements separately rather than with a single-line regex.
grep -q 'openssl s_client' "$HC" || { echo "FAIL: openssl s_client probe missing"; exit 1; }
grep -qE -- '-servername .*TURNS_SUBDOMAIN' "$HC" || { echo "FAIL: probe SNI (-servername TURNS_SUBDOMAIN) missing"; exit 1; }
grep -q 'Verify return code: 0' "$HC" || { echo "FAIL: TLS verify check missing"; exit 1; }
grep -q 'SKIP.*TURNS_SUBDOMAIN' "$HC" || { echo "FAIL: skip branch for upgrade-from-v0.1.x missing"; exit 1; }

# install.env contains TURNS_SUBDOMAIN somewhere
grep -q 'TURNS_SUBDOMAIN' "$INST" || { echo "FAIL: install.sh does not reference TURNS_SUBDOMAIN"; exit 1; }

bash -n "$HC" || { echo "FAIL: healthcheck.sh syntax error"; exit 1; }
bash -n "$INST" || { echo "FAIL: install.sh syntax error"; exit 1; }

echo "PASS"
