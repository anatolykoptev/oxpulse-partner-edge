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
# --- 13. Canary: tunnel probe ---
check "13. canary /canary/tunnel → 2xx" bash -c '
	code=$(curl -fso /dev/null -w "%{http_code}" --max-time 5 \
		"http://127.0.0.1:9080/canary/tunnel" || true)
	[[ "$code" =~ ^2 ]]
'

# --- 14. Canary: upstream probe ---
check "14. canary /canary/upstream → 2xx" bash -c '
	code=$(curl -fso /dev/null -w "%{http_code}" --max-time 5 \
		"http://127.0.0.1:9080/canary/upstream" || true)
	[[ "$code" =~ ^2 ]]
'

# --- 15. Canary: config-hash matches install.env ---
# Warn-only: emergency operator edits survive but become visible in output.
echo -n "  15. CADDYFILE_SHA drift check:                    "
if [[ -z "${CADDYFILE_SHA:-}" ]]; then
	echo "SKIP -- CADDYFILE_SHA not set in install.env (pre-phase1 node?)"
else
	# FIX 6: disambiguate "endpoint down" from "hash drift" — both previously
	# emitted the same WARN with empty canary= which operators couldn't distinguish.
	_canary_hash=$(curl -fso- --max-time 5 "http://127.0.0.1:9080/canary/config-hash" 2>/dev/null || true)
	if [[ -z "$_canary_hash" ]]; then
		echo -e "\033[33mWARN\033[0m (canary endpoint unreachable -- port 9080 down? pre-Phase-1 node?)"
	elif [[ "$_canary_hash" == "$CADDYFILE_SHA" ]]; then
		echo -e "\033[32mOK\033[0m"
	else
		echo -e "\033[33mWARN\033[0m (drift: canary=$_canary_hash install.env=$CADDYFILE_SHA -- manual edit?)"
	fi
fi

# --- 16. hy2 container running + healthy (graceful on awg-only edges) ---
# In Phase 1.7 partial rollout, edges without hy2 provisioned are awg-only.
# Container absent = info (not fail). Container present but unhealthy = warn.
echo -n "  16. hy2 container healthy:                        "
_hy2_health=$(docker inspect -f '{{.State.Health.Status}}' oxpulse-partner-hy2 2>/dev/null || true)
_hy2_running=$(docker ps --filter name=oxpulse-partner-hy2 --format '{{.Names}}' 2>/dev/null | grep -c oxpulse-partner-hy2 || true)
if [[ "$_hy2_health" == "healthy" ]]; then
	echo -e "\033[32mOK\033[0m"
elif [[ "$_hy2_running" -gt 0 ]]; then
	echo -e "\033[33mWARN\033[0m (running but health status not 'healthy': ${_hy2_health:-unknown} — may be starting)"
else
	echo "INFO (hy2 container not deployed — awg-only mode, Phase 1.7 hy2 not provisioned)"
fi

# --- 17. Service token file: present and mode 0600 ---
# Skip-on-legacy: nodes predating Follow-up #2 PR-B won't have the file yet.
# Pass:          file present + mode 0600.
# Pass (legacy): file absent AND OXPULSE_SERVICE_TOKEN env not set.
# Fail:          file present but mode is not 0600.
echo -n "  17. service token file ($CONF_DIR/token):           "
_tok_file="$CONF_DIR/token"
_tok_env="${OXPULSE_SERVICE_TOKEN:-}"
if [[ -e "$_tok_file" ]]; then
	_tok_mode=$(stat -c '%a' "$_tok_file" 2>/dev/null || stat -f '%A' "$_tok_file" 2>/dev/null || echo "unknown")
	if [[ "$_tok_mode" == "600" ]]; then
		echo -e "\033[32mOK\033[0m"
	else
		echo -e "\033[31mFAIL\033[0m (mode=${_tok_mode}, expected 600 — fix: chmod 0600 $_tok_file)"
		FAIL=$((FAIL + 1))
	fi
elif [[ -n "$_tok_env" ]]; then
	echo "OK (env override — OXPULSE_SERVICE_TOKEN set)"
else
	echo "SKIP (no token file — legacy node or fresh node not yet registered)"
fi
unset _tok_file _tok_env _tok_mode

# --- 18. hy2 TCP forwarder listening on :18443 (only if container deployed) ---
if [[ "$_hy2_running" -gt 0 ]]; then
	check "18. TCP 18443 listening (hy2 forwarder)" bash -c '
		ss -ltnH 2>/dev/null | awk '"'"'{print $4}'"'"' | grep -qE ":18443$"
	'
fi

# --- 19. service-token authed probe → 2xx ---
# Catches "token rot": file missing, malformed, or revoked server-side.
# Skip-on-legacy: if no token file AND OXPULSE_SERVICE_TOKEN not set, node
# predates service-token provisioning — emit INFO and treat as pass.
echo -n "  19. service-token authed probe → 2xx:             "
_tok_file="$CONF_DIR/token"
_tok_env="${OXPULSE_SERVICE_TOKEN:-}"
if [[ ! -e "$_tok_file" && -z "$_tok_env" ]]; then
	echo "INFO (legacy node — no service token persisted)"
else
	# Read token: prefer token lib if installed, fall back to direct cat.
	_tok_lib="/usr/local/sbin/oxpulse-token-lib.sh"
	if [[ -r "$_tok_lib" ]]; then
		# shellcheck source=/dev/null
		_svc_token=$(PARTNER_EDGE_PREFIX_ETC="$CONF_DIR" \
			bash -c "source '$_tok_lib' && read_service_token" 2>/dev/null || true)
	else
		_svc_token=$(cat "$_tok_file" 2>/dev/null || true)
	fi
	if [[ -z "$_svc_token" ]]; then
		echo -e "\033[31mFAIL\033[0m (could not read token from $_tok_file — missing or empty)"
		FAIL=$((FAIL + 1))
	else
		_backend="${OXPULSE_BACKEND_URL:-https://oxpulse.chat}"
		_http_code=$(curl -fsS --max-time 8 \
			-H "Authorization: Bearer $_svc_token" \
			"${_backend%/}/api/partner/hy2-credentials" \
			-o /dev/null -w "%{http_code}" 2>/dev/null || echo "000")
		if [[ "$_http_code" == "200" || "$_http_code" == "503" ]]; then
			echo -e "\033[32mOK\033[0m (HTTP $_http_code — auth accepted)"
		else
			echo -e "\033[31mFAIL\033[0m (HTTP $_http_code — token rejected or endpoint unreachable)"
			echo "    Recovery: docker exec oxpulse-chat partner-cli rotate-service-token --node-id ${NODE_ID:-<NODE_ID>} --force"
			echo "    Then: scp the new value to this edge at /etc/oxpulse-partner-edge/token (mode 0600)"
			FAIL=$((FAIL + 1))
		fi
		unset _http_code _backend
	fi
	unset _svc_token _tok_lib
fi
unset _tok_file _tok_env

if [[ $FAIL -eq 0 ]]; then
	echo "All checks passed."
	exit 0
else
	echo "$FAIL check(s) failed."
	exit "$FAIL"
fi
