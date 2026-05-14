#!/bin/bash
# oxpulse-geoip-refresh.sh — monthly DB-IP mmdb refresh for Caddy maxmind_geolocation.
#
# Downloads dbip-country-lite-{YYYY-MM}.mmdb.gz from db-ip.com (free tier,
# CC-BY 4.0, no API key required), gunzips, and atomically replaces the
# existing file. Atomic rename ensures Caddy never reads a half-written file.
#
# Invoked by geoip-refresh.timer (monthly, 1st of month + random jitter).
# Also called directly by install.sh on first provisioning.
#
# DB-IP free tier URL pattern: https://download.db-ip.com/free/dbip-country-lite-{YM}.mmdb.gz
# where YM = YYYY-MM (current month). New file is published on ~1st of each month.
set -euo pipefail

GEOIP_DIR="${GEOIP_DIR:-/var/lib/geoip}"
MMDB_PATH="${GEOIP_DIR}/dbip-country-lite.mmdb"
LOG="${LOG:-/var/log/oxpulse-geoip-refresh.log}"

ts()  { date -Iseconds; }
log() { echo "$(ts) $*" | tee -a "$LOG"; }

YM=$(date -u +%Y-%m)
URL="https://download.db-ip.com/free/dbip-country-lite-${YM}.mmdb.gz"

log "geoip-refresh: downloading ${URL}"

mkdir -p "$GEOIP_DIR"

TMP=$(mktemp "${GEOIP_DIR}/dbip-country-lite.mmdb.XXXXXX.tmp")
# Ensure temp file is cleaned up on any exit.
trap 'rm -f "${TMP}" "${TMP}.gz"' EXIT

curl -fsSL --retry 3 --retry-delay 5 --max-time 60 "$URL" -o "${TMP}.gz"
gunzip -f "${TMP}.gz"

# Sanity: file must be non-empty (guard against empty 200 from db-ip CDN edge).
if [[ ! -s "$TMP" ]]; then
    log "geoip-refresh: ERROR downloaded file is empty — aborting"
    exit 1
fi

chmod 644 "$TMP"
# Atomic rename — Caddy's mmdb reader reopens on SIGHUP or next request,
# so the swap is transparent; no Caddy restart required.
mv "$TMP" "$MMDB_PATH"

log "geoip-refresh: OK → ${MMDB_PATH} ($(stat -c %s "$MMDB_PATH") bytes)"
