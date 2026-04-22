#!/usr/bin/env bash
# healthcheck.sh — 8-point verification for the partner-edge bundle.
# Exit 0 = all green, nonzero = count of failed checks.
#
# Flags:
#   --local   Skip external HTTPS checks (use for post-install before DNS).
#
# Layout expected at /etc/oxpulse-partner-edge/ (overridable):
#   docker-compose.yml  Caddyfile  xray-client.json  coturn.conf
set -uo pipefail

CONF_DIR="${OXPULSE_EDGE_CONFIG_DIR:-/etc/oxpulse-partner-edge}"
STATE_DIR="${OXPULSE_EDGE_STATE_DIR:-/var/lib/oxpulse-partner-edge}"
COMPOSE_FILE="$CONF_DIR/docker-compose.yml"
STATE_FILE="$STATE_DIR/install.env"

LOCAL_ONLY=0
for arg in "$@"; do
	case "$arg" in
		--local) LOCAL_ONLY=1 ;;
		-h|--help)
			sed -n '2,12p' "$0"; exit 0 ;;
		*) echo "unknown arg: $arg" >&2; exit 2 ;;
	esac
done

[[ -r "$COMPOSE_FILE" ]] || { echo "missing: $COMPOSE_FILE" >&2; exit 2; }
DOMAIN=""
if [[ -r "$STATE_FILE" ]]; then
	# shellcheck disable=SC1090
	. "$STATE_FILE"
	DOMAIN="${PARTNER_DOMAIN:-}"
	TURNS_SUBDOMAIN="${TURNS_SUBDOMAIN:-}"
fi

FAIL=0
check() {
	local label=$1
	shift
	printf '  %-48s' "$label"
	if "$@" >/dev/null 2>&1; then
		printf '\033[32mOK\033[0m\n'
	else
		printf '\033[31mFAIL\033[0m\n'
		FAIL=$((FAIL + 1))
	fi
}

echo "oxpulse partner-edge healthcheck (domain=${DOMAIN:-<unknown>})"
echo

# --- 1. Containers up + healthy ---
check "1. containers up (caddy, xray, coturn, sfu)" bash -c '
	out=$(docker compose -f '"$COMPOSE_FILE"' ps --format json 2>/dev/null)
	[[ -z "$out" ]] && exit 1
	# Every line is a service; all must be "running".
	echo "$out" | python3 -c "
import json, sys
ok = True
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    d = json.loads(line)
    if d.get(\"State\") != \"running\": ok = False
sys.exit(0 if ok else 1)
"
'

# --- 2. API reachable ---
if [[ $LOCAL_ONLY -eq 1 || -z "$DOMAIN" ]]; then
	check "2. API /api/health (local probe via caddy)" bash -c '
		docker compose -f "'"$COMPOSE_FILE"'" exec -T caddy wget -qSO- --tries=1 --timeout=5 \
			--header="Host: '"${DOMAIN:-localhost}"'" http://127.0.0.1/api/health 2>&1 | grep -qE "HTTP/.* (200|301|302)"
	'
else
	check "2. https://$DOMAIN/api/health → 2xx" bash -c '
		code=$(curl -fso /dev/null -w "%{http_code}" --max-time 8 "https://'"$DOMAIN"'/api/health" || true)
		[[ "$code" =~ ^2 ]]
	'
fi

# --- 3. Branding endpoint returns matching partner_id ---
if [[ $LOCAL_ONLY -eq 1 || -z "$DOMAIN" ]]; then
	# Branding API needs backend (Task 3) — in local mode we just probe the route exists.
	check "3. branding endpoint reachable (local)" bash -c '
		docker compose -f "'"$COMPOSE_FILE"'" exec -T caddy wget -qSO- --tries=1 --timeout=5 \
			--header="Host: '"${DOMAIN:-localhost}"'" http://127.0.0.1/api/branding 2>&1 | grep -qE "HTTP/"
	'
else
	check "3. /api/branding partner_id=${PARTNER_ID:-?}" bash -c '
		resp=$(curl -fsS --max-time 8 "https://'"$DOMAIN"'/api/branding" || true)
		echo "$resp" | grep -q "\"partner_id\":\"'"${PARTNER_ID:-}"'\""
	'
fi

# --- 4. TCP 443 listening ---
check "4. TCP 443 listening (caddy)" bash -c 'ss -ltn | grep -q ":443 "'

# --- 5. UDP 3478 listening ---
check "5. UDP 3478 listening (coturn)" bash -c 'ss -lun | grep -q ":3478 "'

# --- 6. TCP 5349 listening ---
check "6. TCP 5349 listening (coturn TURNS)" bash -c 'ss -ltn | grep -q ":5349 "'

# --- 7. xray-client has an outbound ESTABLISHED connection ---
check "7. xray-client tunnel established" bash -c '
	docker exec oxpulse-partner-xray sh -c "
		(ss -tn state established 2>/dev/null || netstat -tn 2>/dev/null | grep ESTABLISHED) | head -1 | grep -q .
	"
'

# --- 8. Coturn shared-secret matches rendered config ---
check "8. coturn secret matches config" bash -c '
	expected=$(awk -F= "/^static-auth-secret=/ {print \$2; exit}" "'"$CONF_DIR"'/coturn.conf" || true)
	[[ -z "$expected" ]] && exit 1
	# Verify the running container loaded the same file (compare by size + head).
	running=$(docker exec oxpulse-partner-coturn awk -F= "/^static-auth-secret=/ {print \$2; exit}" /etc/coturn/turnserver.conf 2>/dev/null || true)
	[[ -n "$running" && "$running" = "$expected" ]]
'

# --- 9. TURNS on :443 — TLS handshake against turns-sub.DOMAIN ---
# `pipefail` + `timeout N openssl | grep -q` is a trap: after the handshake
# succeeds openssl blocks on the half-open socket until `timeout` kills it
# with exit 124 — which pipefail then propagates even though grep already
# matched. Capture openssl output to a file first, then grep independently.
echo -n "9. TURNS-443 handshake: "
if [ -z "${TURNS_SUBDOMAIN:-}" ]; then
	echo "SKIP — TURNS_SUBDOMAIN not set in install.env (upgrade from v0.1.x?)"
else
	_handshake_out=$(mktemp)
	timeout 10 openssl s_client -connect "${TURNS_SUBDOMAIN}.${DOMAIN}:443" \
		-servername "${TURNS_SUBDOMAIN}.${DOMAIN}" </dev/null >"$_handshake_out" 2>/dev/null || true
	if grep -q "Verify return code: 0 (ok)" "$_handshake_out"; then
		echo "PASS"
	else
		echo "FAIL"
		FAIL=$((FAIL + 1))
	fi
	rm -f "$_handshake_out"
fi

# --- 10. SPA served on GET / ---
# After removing the @probe cover decoy (2026-04-20), every GET / must
# return the SPA HTML directly — no decoy, no handler branching. Buffer
# the response into a variable because piping straight into `grep -q`
# loses body after the first match via SIGPIPE.
check "10. SPA served on GET / (HTML body)" bash -c '
	out=$(docker compose -f "'"$COMPOSE_FILE"'" exec -T caddy wget -qSO- \
		--tries=1 --timeout=5 \
		--header="Host: '"${DOMAIN:-localhost}"'" http://127.0.0.1/ 2>&1)
	echo "$out" | grep -qE "HTTP/.* 200" \
		&& echo "$out" | grep -qiE "<html|<!doctype"
'

# --- 11. SFU UDP media port listening (M2.1) ---
# SFU binds SFU_UDP_PORT on 0.0.0.0 in host netns — ss from the host sees it.
SFU_UDP_PORT="${SFU_UDP_PORT:-7878}"
check "11. UDP ${SFU_UDP_PORT} listening (sfu media)" bash -c '
	ss -lun | grep -qE ":'"${SFU_UDP_PORT}"' "
'

# --- 12. SFU /metrics responds 200 (M1.5 endpoint) ---
SFU_METRICS_PORT="${SFU_METRICS_PORT:-8878}"
check "12. SFU /metrics → 200" bash -c '
	code=$(curl -fso /dev/null -w "%{http_code}" --max-time 5 \
		"http://127.0.0.1:'"${SFU_METRICS_PORT}"'/metrics" || true)
	[[ "$code" == "200" ]]
'

echo
if [[ $FAIL -eq 0 ]]; then
	echo "All 12 checks passed."
	exit 0
else
	echo "$FAIL check(s) failed."
	exit "$FAIL"
fi
