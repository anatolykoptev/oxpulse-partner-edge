#!/bin/bash
# tests/test_healthcheck_xray_reality_wedge.sh — healthcheck.sh check 7 must go
# RED when the xray client is wedged on REALITY auth.
#
# Silent in production otherwise: when central rejects our ClientHello it
# forwards the TCP session to its dest, so the xray socket stays ESTABLISHED
# (the old check 7 passed) while every connection dies with "REALITY: received
# real certificate" (randomized-fingerprint wedge, 2026-10-12).
#
# `docker` is a PATH shim: `exec` succeeds (an ESTABLISHED socket exists),
# `inspect` reports $STARTED_AGO seconds of uptime, and `logs --since Ns` replays
# $WEDGE_LINES copies of the failure signature, each stamped $LINE_AGE seconds old
# and filtered by the requested window like the real daemon does.
# Needs GNU date (healthcheck.sh uses `date -d`): run on Linux, as CI does.
set -uo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
HC="$REPO_ROOT/healthcheck.sh"
[[ -f "$HC" ]] || { echo "FAIL: $HC not found"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/conf"
: > "$TMP/conf/docker-compose.yml"
cat > "$TMP/bin/docker" <<'DOCKER'
#!/bin/bash
case "$1" in
  exec) exit 0 ;;
  inspect) date -u -d "@$(( $(date +%s) - ${STARTED_AGO:-9999} ))" +%Y-%m-%dT%H:%M:%S.000000000Z; exit 0 ;;
  logs) win="${3%s}"; now=$(date +%s)
        for ((i = 0; i < ${WEDGE_LINES:-0}; i++)); do
          (( now - ${LINE_AGE:-1} >= now - win )) || continue
          echo "[Error] transport/internet/reality: REALITY: received real certificate (potential MITM or redirection)"
        done; exit 0 ;;
esac
exit 1
DOCKER
chmod +x "$TMP/bin/docker"

check7() {   # wedge-line-count [started-ago] [line-age] -> prints GREEN|RED
	WEDGE_LINES="$1" STARTED_AGO="${2:-9999}" LINE_AGE="${3:-1}" PATH="$TMP/bin:$PATH" \
		OXPULSE_EDGE_CONFIG_DIR="$TMP/conf" OXPULSE_EDGE_STATE_DIR="$TMP/none" \
		bash "$HC" --snapshot --local 2>/dev/null | sed -n 's/^check_07_xray_tunnel=//p'
}

FAIL=0
expect() {   # description want got
	if [[ "$3" == "$2" ]]; then echo "PASS: $1"; else echo "FAIL: $1 (want $2, got '$3')"; FAIL=1; fi
}
expect "ESTABLISHED + clean log -> GREEN"                         GREEN "$(check7 0)"
expect "threshold: 4 signature lines (< 5) -> GREEN"              GREEN "$(check7 4)"
expect "threshold: 5 signature lines (= 5) -> RED"                RED   "$(check7 5)"
expect "ESTABLISHED but REALITY auth failing (12) -> RED"         RED   "$(check7 12)"
# docker logs survive a restart: lines 100s old belong to the previous process
# when the container is 30s old, and must not keep check 7 RED.
expect "uptime bound: previous process's lines ignored -> GREEN"  GREEN "$(check7 12 30 100)"
expect "uptime bound: this process's own lines still count -> RED" RED  "$(check7 12 30 10)"
exit "$FAIL"
