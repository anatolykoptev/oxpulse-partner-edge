#!/bin/bash
# tests/test_healthcheck_xray_reality_wedge.sh — healthcheck.sh check 7 must go
# RED when the xray client is wedged on REALITY auth.
#
# Silent in production otherwise: when central rejects our ClientHello it
# forwards the TCP session to its dest, so the xray socket stays ESTABLISHED
# (the old check 7 passed) while every connection dies with "REALITY: received
# real certificate" (randomized-fingerprint wedge, 2026-10-12).
#
# `docker` is a PATH shim: `exec` succeeds (an ESTABLISHED socket exists) and
# `logs` replays $WEDGE_LINES copies of the failure signature.
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
  logs) for ((i = 0; i < ${WEDGE_LINES:-0}; i++)); do
          echo "[Error] transport/internet/reality: REALITY: received real certificate (potential MITM or redirection)"
        done; exit 0 ;;
esac
exit 1
DOCKER
chmod +x "$TMP/bin/docker"

check7() {   # wedge-line-count -> prints GREEN|RED
	WEDGE_LINES="$1" PATH="$TMP/bin:$PATH" OXPULSE_EDGE_CONFIG_DIR="$TMP/conf" \
		OXPULSE_EDGE_STATE_DIR="$TMP/none" bash "$HC" --snapshot --local 2>/dev/null \
		| sed -n 's/^check_07_xray_tunnel=//p'
}

FAIL=0
[[ "$(check7 0)" == GREEN ]]  && echo "PASS: ESTABLISHED + clean log -> GREEN" || { echo "FAIL: clean xray not GREEN"; FAIL=1; }
[[ "$(check7 4)" == GREEN ]]  && echo "PASS: 4 stray signature lines (< 5) -> GREEN" || { echo "FAIL: 4 lines flagged"; FAIL=1; }
[[ "$(check7 12)" == RED ]]   && echo "PASS: ESTABLISHED but REALITY auth failing -> RED" || { echo "FAIL: wedged xray still GREEN (the vacuous old check 7)"; FAIL=1; }
exit "$FAIL"
