#!/bin/bash
# Verify the installer wires cert-watch units.
# The cert-watch install/enable/sed logic was extracted from install.sh into
# lib/install-systemd.sh (installer modularization); assert against the lib
# module that now owns it.
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SYSTEMD_LIB="$REPO_ROOT/lib/install-systemd.sh"

grep -q 'TURNS_SUBDOMAIN' "$SYSTEMD_LIB" \
  || { echo "FAIL: TURNS_SUBDOMAIN var not referenced"; exit 1; }
grep -q 'oxpulse-partner-cert-watch.path' "$SYSTEMD_LIB" \
  || { echo "FAIL: .path unit install step missing"; exit 1; }
grep -q 'oxpulse-partner-cert-watch.service' "$SYSTEMD_LIB" \
  || { echo "FAIL: .service unit install step missing"; exit 1; }
grep -q 'systemctl enable .*oxpulse-partner-cert-watch.path' "$SYSTEMD_LIB" \
  || { echo "FAIL: enable path unit step missing"; exit 1; }
grep -qE 'sed .*\{\{TURNS_SUBDOMAIN\}\}' "$SYSTEMD_LIB" \
  || { echo "FAIL: TURNS_SUBDOMAIN placeholder substitution missing"; exit 1; }

# Syntax check
bash -n "$SYSTEMD_LIB" || { echo "FAIL: lib/install-systemd.sh has syntax errors"; exit 1; }

echo "PASS: installer wires cert-watch units (lib/install-systemd.sh)"
