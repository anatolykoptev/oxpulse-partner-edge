#!/bin/bash
# E2E acceptance test for partner-edge v0.2.0 Variant A' (caddy-l4 unified).
# Run AFTER install.sh completes on a provisioned partner VM.
#
# Usage:
#   sudo bash test_e2e_a_prime.sh <test-domain> <turns-subdomain> [<image-version>]
#
#   <test-domain>        Partner DNS domain with A-record pointing at THIS host
#   <turns-subdomain>    TURNS subdomain — must also have A-record → this host
#   <image-version>      Optional image tag (default: v0.2.0-rc1)
#
# Pre-requirements (operator responsibility):
#   - Fresh Debian 12 / Ubuntu 22.04+ / Alma 9+ VM with public IPv4
#   - DNS A records:
#       <test-domain>               → this host's public IP
#       <turns-subdomain>.<domain>  → this host's public IP
#   - Ports 80, 443, 3478/tcp+udp, 5349, 49152-65535/udp open
#   - Root access
#
# Expected duration: 5-10 minutes (dominated by Docker image pulls + ACME).
# Exit codes: 0 = all acceptance gates pass; non-zero = failure (see logs).

set -euo pipefail

TEST_DOMAIN="${1:?Usage: $0 <test-domain> <turns-subdomain> [<image-version>]}"
TURNS_SUB="${2:?Usage: $0 <test-domain> <turns-subdomain> [<image-version>]}"
IMAGE_VERSION="${3:-v0.2.0-rc1}"

if [ "$(id -u)" != "0" ]; then
  echo "FAIL: must run as root"
  exit 2
fi

log() { echo "[$(date +%T)] $*"; }

# ─── 1. DNS preflight ───────────────────────────────────────────────────────
log "1/7 DNS preflight"
HOST_IP=$(curl -fsS --max-time 10 https://ifconfig.me)
for name in "$TEST_DOMAIN" "$TURNS_SUB.$TEST_DOMAIN"; do
  resolved=$(dig +short "$name" | tail -1)
  if [ "$resolved" != "$HOST_IP" ]; then
    echo "FAIL: $name resolves to '$resolved', expected $HOST_IP"
    exit 1
  fi
done
log "  DNS OK — both names resolve to $HOST_IP"

# ─── 2. Run install.sh ──────────────────────────────────────────────────────
log "2/7 Running install.sh (image version: $IMAGE_VERSION)"
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
INSTALL="$SCRIPT_DIR/../install.sh"
[ -f "$INSTALL" ] || { echo "FAIL: install.sh not found at $INSTALL"; exit 1; }

# Set TURNS_SUBDOMAIN env so install.sh writes correct value to install.env
TURNS_SUBDOMAIN="$TURNS_SUB" bash "$INSTALL" \
  --domain="$TEST_DOMAIN" \
  --partner-id=test-e2e \
  --image-version="$IMAGE_VERSION" \
  --manual-config=<(cat <<EOF
{
  "node_id": "test-e2e-$(date +%s)",
  "backend_endpoint": "krolik.oxpulse.chat:5349",
  "turn_secret": "test-secret-not-for-prod",
  "reality_uuid": "00000000-0000-0000-0000-000000000000",
  "reality_public_key": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
  "reality_short_id": "deadbeef",
  "reality_server_name": "www.samsung.com"
}
EOF
)

log "  install.sh exited 0"

# ─── 3. Wait for services to settle + ACME cert provisioning ────────────────
log "3/7 Wait for ACME cert for $TURNS_SUB.$TEST_DOMAIN (up to 120s)"
VOL_PATH="/var/lib/docker/volumes/oxpulse-partner-edge_caddy-data/_data/caddy/certificates/acme-v02.api.letsencrypt.org-directory/$TURNS_SUB.$TEST_DOMAIN/$TURNS_SUB.$TEST_DOMAIN.crt"
for i in $(seq 1 24); do
  if [ -f "$VOL_PATH" ]; then
    log "  ACME cert present after ${i}*5s"
    break
  fi
  sleep 5
done
if [ ! -f "$VOL_PATH" ]; then
  echo "FAIL: ACME cert never appeared at $VOL_PATH"
  docker compose -f /etc/oxpulse-partner-edge/docker-compose.yml logs caddy 2>&1 | tail -30
  exit 1
fi

# ─── 4. Healthcheck (all 9 probes) ──────────────────────────────────────────
log "4/7 Run healthcheck — all 9 probes"
if ! /usr/local/sbin/oxpulse-partner-edge-healthcheck; then
  echo "FAIL: healthcheck reported failures"
  exit 1
fi

# ─── 5. JA3S capture (for later hardening tuning) ───────────────────────────
log "5/7 Capture JA3S fingerprints (advisory — not gating)"
for sni in "$TEST_DOMAIN" "$TURNS_SUB.$TEST_DOMAIN"; do
  log "  SNI: $sni"
  timeout 5 openssl s_client -connect "$sni:443" -servername "$sni" </dev/null 2>&1 \
    | grep -E "(Protocol|Cipher|Verify return code)" | head -5 \
    | sed 's/^/    /'
done

# ─── 6. Confirm no H3 UDP listener (R1 Layer 0) ─────────────────────────────
log "6/7 Verify UDP :443 closed (H3 drop)"
if ss -lnu | awk '{print $5}' | grep -qE ":443$"; then
  echo "FAIL: UDP :443 listener present — H3 drop regressed"
  exit 1
fi
log "  UDP :443 closed — H3 drop intact"

# ─── 7. Confirm Via/Alt-Svc absent in response ──────────────────────────────
log "7/7 Verify Via/Alt-Svc headers stripped (R1 Layer 0)"
headers=$(curl -sI --max-time 10 "https://$TEST_DOMAIN/")
if echo "$headers" | grep -qi '^via:'; then
  echo "FAIL: Via header leaked"
  echo "$headers" | grep -i via
  exit 1
fi
if echo "$headers" | grep -qi '^alt-svc:'; then
  echo "FAIL: Alt-Svc header leaked"
  echo "$headers" | grep -i alt-svc
  exit 1
fi
log "  Via + Alt-Svc stripped"

echo
echo "╔════════════════════════════════════════════════════════╗"
echo "║  E2E acceptance PASS for Variant A' on $TEST_DOMAIN"
echo "╚════════════════════════════════════════════════════════╝"
