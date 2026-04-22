#!/bin/bash
# Verify install.sh wires cert-watch units.
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-/home/user/src/oxpulse-partner-edge}"
INSTALL="$REPO_ROOT/deploy/partner-edge/install.sh"

grep -q 'TURNS_SUBDOMAIN' "$INSTALL" \
  || { echo "FAIL: TURNS_SUBDOMAIN var not introduced"; exit 1; }
grep -q 'oxpulse-partner-cert-watch.path' "$INSTALL" \
  || { echo "FAIL: .path unit install step missing"; exit 1; }
grep -q 'oxpulse-partner-cert-watch.service' "$INSTALL" \
  || { echo "FAIL: .service unit install step missing"; exit 1; }
grep -q 'systemctl enable .*oxpulse-partner-cert-watch.path' "$INSTALL" \
  || { echo "FAIL: enable path unit step missing"; exit 1; }
grep -qE 'sed .*\{\{TURNS_SUBDOMAIN\}\}' "$INSTALL" \
  || { echo "FAIL: TURNS_SUBDOMAIN placeholder substitution missing"; exit 1; }

# Syntax check
bash -n "$INSTALL" || { echo "FAIL: install.sh has syntax errors"; exit 1; }

echo "PASS: install.sh wires cert-watch units"
