#!/bin/bash
# Structural validation of cert-reload systemd units.
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
UNITS="$REPO_ROOT/systemd"

[ -f "$UNITS/oxpulse-partner-cert-watch.path" ] \
  || { echo "FAIL: .path unit missing"; exit 1; }
[ -f "$UNITS/oxpulse-partner-cert-watch.service" ] \
  || { echo "FAIL: .service unit missing"; exit 1; }

# .path watches the correct Caddy ACME cert location with placeholders
grep -qF 'PathChanged=/var/lib/docker/volumes/oxpulse-partner-edge_caddy-data/_data/caddy/certificates/acme-v02.api.letsencrypt.org-directory/{{TURNS_SUBDOMAIN}}.{{PARTNER_DOMAIN}}/{{TURNS_SUBDOMAIN}}.{{PARTNER_DOMAIN}}.crt' \
  "$UNITS/oxpulse-partner-cert-watch.path" \
  || { echo "FAIL: PathChanged directive wrong or missing"; exit 1; }

grep -q 'Unit=oxpulse-partner-cert-watch.service' "$UNITS/oxpulse-partner-cert-watch.path" \
  || { echo "FAIL: Unit= reference missing in .path"; exit 1; }

# .service invokes docker exec with SIGUSR2 to coturn
grep -qF 'ExecStart=/usr/bin/docker exec oxpulse-partner-coturn kill -USR2 1' \
  "$UNITS/oxpulse-partner-cert-watch.service" \
  || { echo "FAIL: ExecStart wrong or missing"; exit 1; }

grep -q '^Type=oneshot' "$UNITS/oxpulse-partner-cert-watch.service" \
  || { echo "FAIL: Type=oneshot missing"; exit 1; }

# Basic systemd unit render sanity
sed -e 's/{{TURNS_SUBDOMAIN}}/turns/g' -e 's/{{PARTNER_DOMAIN}}/example.test/g' \
  "$UNITS/oxpulse-partner-cert-watch.path" | grep '^PathChanged=/var/lib/docker/' >/dev/null \
  || { echo "FAIL: placeholder substitution malformed"; exit 1; }

echo "PASS: cert-watch systemd units + placeholder rendering"
