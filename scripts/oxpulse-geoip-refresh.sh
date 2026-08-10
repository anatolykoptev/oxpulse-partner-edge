#!/bin/bash
# oxpulse-geoip-refresh.sh — monthly DB-IP mmdb refresh for Caddy maxmind_geolocation.
#
# Downloads dbip-country-lite-{YYYY-MM}.mmdb.gz from db-ip.com (free tier,
# CC-BY 4.0, no API key required), gunzips, and atomically replaces the
# existing file. Atomic rename ensures Caddy never reads a half-written file.
#
# Invoked by geoip-refresh.timer (DAILY + random jitter — see the timer's own
# comment for why a monthly schedule silently stopped running altogether), and
# directly by install.sh on first provisioning. Daily is cheap because this
# script exits before downloading anything once the current month is installed.
#
# DB-IP free tier URL pattern: https://download.db-ip.com/free/dbip-country-lite-{YM}.mmdb.gz
# where YM = YYYY-MM (current month). New file is published on ~1st of each month.
#
# THE MONTH-BOUNDARY RACE (measured 2026-08-11, cost: a month of stale geo data)
# "~1st of each month" is not a guarantee about the time of day. The timer fires
# on the 1st with jitter; on 2026-08-01 at 03:40 UTC+2 the 2026-08 file did not
# exist yet and db-ip answered 404. `curl --retry` does not retry a 404 — it is
# not a transient error — the unit is Type=oneshot with no Restart=, and the
# timer is MONTHLY. So one lost race froze the database until September:
# oxpulse-geoip-refresh.service sat `failed` on ruoxp and cheburator for ten
# days with nothing watching, ruoxp's mmdb was June data, and rvpn's was from
# 20 May. By the time anyone looked the 2026-08 URL returned 200.
#
# Hence the fallback below: if the current month is not published yet, take the
# previous month. Month-old country data is a rounding error next to a database
# that stops updating entirely, and tomorrow's run picks up the new file.
set -euo pipefail

GEOIP_DIR="${GEOIP_DIR:-/var/lib/geoip}"
MMDB_PATH="${GEOIP_DIR}/dbip-country-lite.mmdb"
# Which month the installed file actually came from. mtime cannot answer that:
# a file installed on 20 May carries a May mtime whether it holds May data or a
# fallback to April, and any touch destroys the answer entirely.
STAMP="${GEOIP_DIR}/.installed-month"
LOG="${LOG:-/var/log/oxpulse-geoip-refresh.log}"

ts()  { date -Iseconds; }
log() { echo "$(ts) $*" | tee -a "$LOG"; }

YM=$(date -u +%Y-%m)
# First day of this month minus one day = some day in the previous month.
YM_PREV=$(date -u -d "$(date -u +%Y-%m-01) -1 day" +%Y-%m)

mkdir -p "$GEOIP_DIR"

# Already holding this month's file: nothing to do. This is what makes a DAILY
# schedule free — ~29 of every 30 runs stop here without touching the network.
# Deliberately not `--force`-able by accident: pass FORCE=1 to re-download.
if [[ "${FORCE:-0}" != 1 && -s "$MMDB_PATH" && "$(cat "$STAMP" 2>/dev/null)" == "$YM" ]]; then
    log "geoip-refresh: ${YM} already installed — nothing to do"
    exit 0
fi

TMP=$(mktemp "${GEOIP_DIR}/dbip-country-lite.mmdb.XXXXXX.tmp")
# Ensure temp file is cleaned up on any exit.
trap 'rm -f "${TMP}" "${TMP}.gz"' EXIT

# Downloads one month's file into $TMP. Returns non-zero WITHOUT aborting the
# script, so the caller can fall back — which is the whole point.
try_month() {
    local ym="$1"
    local url="https://download.db-ip.com/free/dbip-country-lite-${ym}.mmdb.gz"
    log "geoip-refresh: downloading ${url}"
    rm -f "${TMP}" "${TMP}.gz"
    if ! curl -fsSL --retry 3 --retry-delay 5 --max-time 60 "$url" -o "${TMP}.gz"; then
        log "geoip-refresh: ${ym} is not available"
        return 1
    fi
    if ! gunzip -f "${TMP}.gz"; then
        log "geoip-refresh: ${ym} failed to decompress"
        return 1
    fi
    # Sanity: file must be non-empty (guard against empty 200 from db-ip CDN edge).
    if [[ ! -s "$TMP" ]]; then
        log "geoip-refresh: ${ym} downloaded empty — rejecting"
        return 1
    fi
    return 0
}

INSTALLED_YM="$YM"
if ! try_month "$YM"; then
    log "geoip-refresh: ${YM} not published yet — falling back to ${YM_PREV}"
    if ! try_month "$YM_PREV"; then
        log "geoip-refresh: ERROR neither ${YM} nor ${YM_PREV} could be fetched — aborting"
        exit 1
    fi
    # Record the month actually installed, NOT the one asked for: the stamp must
    # stay != $YM so tomorrow's run retries the current month instead of
    # concluding it is already here.
    INSTALLED_YM="$YM_PREV"
fi

chmod 644 "$TMP"
# Atomic rename — Caddy's mmdb reader reopens on SIGHUP or next request,
# so the swap is transparent; no Caddy restart required.
mv "$TMP" "$MMDB_PATH"
# Only after the file is in place — a stamp written earlier would claim a month
# that a failed rename never delivered, and the daily run would skip forever.
echo "$INSTALLED_YM" > "$STAMP"

log "geoip-refresh: OK → ${MMDB_PATH} (${INSTALLED_YM}, $(stat -c %s "$MMDB_PATH") bytes)"
