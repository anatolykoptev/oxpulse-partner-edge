#!/bin/bash
set -euo pipefail
HC="/home/user/src/oxpulse-partner-edge/healthcheck.sh"
INST="/home/user/src/oxpulse-partner-edge/install.sh"

grep -q 'TURNS-443 handshake' "$HC" || { echo "FAIL: 9th probe label missing"; exit 1; }
grep -qE 'openssl s_client.*servername.*TURNS_SUBDOMAIN' "$HC" || { echo "FAIL: probe command wrong"; exit 1; }
grep -q 'Verify return code: 0' "$HC" || { echo "FAIL: TLS verify check missing"; exit 1; }
grep -q 'SKIP.*TURNS_SUBDOMAIN' "$HC" || { echo "FAIL: skip branch for upgrade-from-v0.1.x missing"; exit 1; }

# install.env contains TURNS_SUBDOMAIN somewhere
grep -q 'TURNS_SUBDOMAIN' "$INST" || { echo "FAIL: install.sh does not reference TURNS_SUBDOMAIN"; exit 1; }

bash -n "$HC" || { echo "FAIL: healthcheck.sh syntax error"; exit 1; }
bash -n "$INST" || { echo "FAIL: install.sh syntax error"; exit 1; }

echo "PASS"
