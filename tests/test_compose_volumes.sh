#!/bin/bash
# Verify docker-compose.yml.tpl wires caddy-data into coturn read-only
# + confirms UDP 443 (H3) removal from Task 0.2.
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-/home/krolik/src/oxpulse-partner-edge}"
TPL="$REPO_ROOT/docker-compose.yml.tpl"

# caddy-data volume mounted read-only in coturn service
grep -q 'caddy-data:/data:ro' "$TPL" \
  || { echo "FAIL: caddy-data not mounted read-only into coturn"; exit 1; }

# UDP 443 must NOT be mapped (Task 0.2 drop verified not regressed)
grep -qE '"443:443/udp"' "$TPL" \
  && { echo "FAIL: UDP 443 mapping reappeared (regression of Task 0.2)"; exit 1; } || true

# conf.d bind-mount must be present in caddy service so the import slot is functional
grep -q './conf.d:/etc/oxpulse-partner-edge/conf.d:ro' "$TPL" \
  || { echo "FAIL: conf.d not mounted into caddy container (operator override slot non-functional)"; exit 1; }

echo "PASS: compose volumes + H3 drop + conf.d mount"
