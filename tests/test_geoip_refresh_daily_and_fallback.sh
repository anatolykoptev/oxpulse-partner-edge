#!/bin/bash
# tests/test_geoip_refresh_daily_and_fallback.sh
#
# The geo database stopped updating for 82 days on rvpn and nobody noticed,
# because every failure in this path is SILENT: the file simply stays as it was.
# Both mechanisms are covered here.
#
#   1. THE SCHEDULE. oxpulse-geoip-refresh.timer is in upgrade.sh's
#      _HOST_SCRIPT_RESTART_UNITS, and restarting a Persistent= timer rewrites
#      its stamp in /var/lib/systemd/timers — systemd then believes the job just
#      ran and cancels every missed occurrence. Measured 2026-08-11: rvpn's
#      stamp read "Aug 7 20:05", the same second as another restarted timer's,
#      while its mmdb was the one installed on 20 May. Any period LONGER than
#      the upgrade interval is a job that never runs, so the timer must be
#      daily.
#   2. THE MONTH BOUNDARY. db-ip publishes during the 1st; a fire at 03:40 gets
#      404, and curl does not retry a 404. The script falls back to the previous
#      month — and must then record the month it ACTUALLY installed, or the
#      daily run reads "this month is here" and never picks up the real file.
#
# Cases:
#   1. current month already installed  → NO network call at all (this is what
#      makes daily free; without it, 8 MB per node per day)
#   2. no stamp                          → downloads, stamps the current month
#   3. current month 404s                → installs the previous month AND
#      stamps the PREVIOUS month, so tomorrow retries
#   4. every month fails                 → no stamp is written, non-zero exit
#   5. FORCE=1                           → downloads even when the stamp matches
#   6. the timer is daily, not monthly
set -uo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SCRIPT="$REPO_ROOT/scripts/oxpulse-geoip-refresh.sh"
TIMER="$REPO_ROOT/systemd/oxpulse-geoip-refresh.timer"
[[ -f "$SCRIPT" ]] || { echo "FAIL: $SCRIPT not found"; exit 1; }

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

YM=$(date -u +%Y-%m)
YM_PREV=$(date -u -d "$(date -u +%Y-%m-01) -1 day" +%Y-%m)

setup() {
	TMP="$(mktemp -d)"; BIN="$TMP/bin"; mkdir -p "$BIN" "$TMP/geoip"
	# curl: succeeds only for a month listed in $AVAILABLE, and records the try.
	cat > "$BIN/curl" <<'CURL'
#!/bin/bash
url=""; out=""
while [[ $# -gt 0 ]]; do
  case "$1" in -o) out="$2"; shift 2;; http*) url="$1"; shift;; *) shift;; esac
done
ym=$(sed 's/.*dbip-country-lite-\([0-9-]*\)\.mmdb\.gz/\1/' <<<"$url")
echo "$ym" >> "$CURL_LOG"
grep -qw "$ym" <<<"$AVAILABLE" || exit 22        # 404, exactly as db-ip answers
printf 'MMDB-BYTES-FOR-%s' "$ym" > "$out"
CURL
	# gunzip: our "archive" is already plain, so just drop the suffix.
	cat > "$BIN/gunzip" <<'GUNZIP'
#!/bin/bash
f="${!#}"
mv -f "$f" "${f%.gz}"
GUNZIP
	chmod +x "$BIN/curl" "$BIN/gunzip"
	export PATH="$BIN:$PATH"
	export CURL_LOG="$TMP/curl.log"; : > "$CURL_LOG"
	export GEOIP_DIR="$TMP/geoip" LOG="$TMP/geoip.log"
	unset FORCE
}
teardown() { rm -rf "$TMP"; }
run_it()  { bash "$SCRIPT" >"$TMP/out" 2>&1; echo $?; }
tries()   { wc -l < "$CURL_LOG" | tr -d ' '; }
stamp()   { cat "$TMP/geoip/.installed-month" 2>/dev/null; }

echo ""
echo "=== oxpulse-geoip-refresh.sh ==="

# 1 — the current month is already here: do not touch the network
setup; export AVAILABLE="$YM $YM_PREV"
echo "already-installed" > "$TMP/geoip/dbip-country-lite.mmdb"
echo "$YM" > "$TMP/geoip/.installed-month"
rc=$(run_it)
[[ "$(tries)" == 0 && "$rc" == 0 ]] && pass "current month installed → no download at all" \
	|| fail "downloaded $(tries) time(s) with the current month already installed (rc=$rc)"
teardown

# 2 — nothing installed: download and stamp
setup; export AVAILABLE="$YM $YM_PREV"
rc=$(run_it)
[[ "$rc" == 0 ]] && grep -q "MMDB-BYTES-FOR-$YM" "$TMP/geoip/dbip-country-lite.mmdb" 2>/dev/null \
	&& pass "no stamp → downloads the current month" || fail "did not install the current month (rc=$rc)"
[[ "$(stamp)" == "$YM" ]] && pass "records the month it installed" || fail "stamp is '$(stamp)', expected $YM"
teardown

# 3 — the month-boundary race: fall back, and stamp the month ACTUALLY installed
setup; export AVAILABLE="$YM_PREV"          # the current month 404s, as on 01 Aug
rc=$(run_it)
grep -q "MMDB-BYTES-FOR-$YM_PREV" "$TMP/geoip/dbip-country-lite.mmdb" 2>/dev/null \
	&& pass "current month 404 → falls back to the previous month" \
	|| fail "no fallback: the database would have stayed frozen for a month (rc=$rc)"
[[ "$(stamp)" == "$YM_PREV" ]] \
	&& pass "stamps the FALLBACK month, so tomorrow retries the current one" \
	|| fail "stamp is '$(stamp)', expected $YM_PREV — stamping $YM would freeze it on old data"
# ...and prove that "tomorrow" really does retry: same state, now published.
export AVAILABLE="$YM $YM_PREV"; : > "$CURL_LOG"
run_it >/dev/null
grep -q "MMDB-BYTES-FOR-$YM" "$TMP/geoip/dbip-country-lite.mmdb" 2>/dev/null \
	&& pass "the next daily run picks up the current month once published" \
	|| fail "never recovered to the current month"
teardown

# 4 — everything fails: no stamp, non-zero exit
setup; export AVAILABLE=""
rc=$(run_it)
[[ "$rc" != 0 ]] && pass "no month available → non-zero exit" || fail "reported success having installed nothing"
[[ -z "$(stamp)" ]] && pass "a failed run writes no stamp" \
	|| fail "stamped '$(stamp)' without installing anything — the daily run would skip forever"
teardown

# 5 — FORCE
setup; export AVAILABLE="$YM $YM_PREV"
echo x > "$TMP/geoip/dbip-country-lite.mmdb"; echo "$YM" > "$TMP/geoip/.installed-month"
FORCE=1 bash "$SCRIPT" >/dev/null 2>&1
[[ "$(tries)" -ge 1 ]] && pass "FORCE=1 re-downloads" || fail "FORCE=1 did nothing"
teardown

# 6 — the schedule itself
if grep -qE '^OnCalendar=daily$' "$TIMER"; then
	pass "the timer is daily"
else
	fail "the timer is not daily — an upgrade restart rewrites a Persistent stamp and cancels every missed run, so any period longer than the upgrade interval never fires (rvpn: 82 days)"
fi

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
