#!/usr/bin/env bash
# healthcheck.sh — 8-point verification for the partner-edge bundle.
# Exit 0 = all green, nonzero = count of failed checks.
#
# Flags:
#   --local    Skip external HTTPS checks (use for post-install before DNS).
#   --snapshot Emit machine-parseable per-check lines (name=GREEN|RED),
#              suppress human output, always exit 0.
#              Used by the Phase 3 baseline-aware health gate to capture
#              pre-change and post-change snapshots for regression diffing.
#
# Layout expected at /etc/oxpulse-partner-edge/ (overridable):
#   docker-compose.yml  Caddyfile  xray-client.json  coturn.conf
set -uo pipefail

CONF_DIR="${OXPULSE_EDGE_CONFIG_DIR:-/etc/oxpulse-partner-edge}"
STATE_DIR="${OXPULSE_EDGE_STATE_DIR:-/var/lib/oxpulse-partner-edge}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
COMPOSE_FILE="$CONF_DIR/docker-compose.yml"
STATE_FILE="$STATE_DIR/install.env"

LOCAL_ONLY=0
SNAPSHOT_MODE=0
for arg in "$@"; do
	case "$arg" in
		--local)    LOCAL_ONLY=1 ;;
		--snapshot) SNAPSHOT_MODE=1 ;;
		-h|--help)
			sed -n '2,14p' "$0"; exit 0 ;;
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

# check ID LABEL COMMAND... — run COMMAND; emit human or snapshot output.
# ID must be a stable machine identifier (e.g. check_01_containers).
check() {
	local _id="$1"
	local _label="$2"
	shift 2
	if [[ "$SNAPSHOT_MODE" -eq 1 ]]; then
		if "$@" >/dev/null 2>&1; then
			printf '%s=GREEN\n' "$_id"
		else
			printf '%s=RED\n' "$_id"
		fi
	else
		printf '  %-48s' "$_label"
		if "$@" >/dev/null 2>&1; then
			printf '\033[32mOK\033[0m\n'
		else
			printf '\033[31mFAIL\033[0m\n'
			FAIL=$((FAIL + 1))
		fi
	fi
}

# snap_emit ID STATUS [HUMAN_TEXT] — emit snapshot line or human text.
# STATUS is 0 (GREEN) or non-0 (RED).
# Used by inline checks that can't be wrapped with check().
snap_emit() {
	local _id="$1"
	local _status="$2"
	local _human="${3:-}"
	if [[ "$SNAPSHOT_MODE" -eq 1 ]]; then
		if [[ "$_status" -eq 0 ]]; then
			printf '%s=GREEN\n' "$_id"
		else
			printf '%s=RED\n' "$_id"
		fi
	else
		[[ -n "$_human" ]] && printf '%s' "$_human"
	fi
}

if [[ "$SNAPSHOT_MODE" -eq 0 ]]; then
	echo "oxpulse partner-edge healthcheck (domain=${DOMAIN:-<unknown>})"
	echo
fi

# --- 1. Containers up + healthy ---
check "check_01_containers" "1. containers up (caddy, xray, coturn, sfu)" bash -c '
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
	check "check_02_api" "2. API /api/health (local probe via caddy)" bash -c '
		docker compose -f "'"$COMPOSE_FILE"'" exec -T caddy wget -qSO- --tries=1 --timeout=5 \
			--header="Host: '"${DOMAIN:-localhost}"'" http://127.0.0.1/api/health 2>&1 | grep -qE "HTTP/.* (200|301|302)"
	'
else
	check "check_02_api" "2. https://$DOMAIN/api/health → 2xx" bash -c '
		code=$(curl -fso /dev/null -w "%{http_code}" --max-time 8 "https://'"$DOMAIN"'/api/health" || true)
		[[ "$code" =~ ^2 ]]
	'
fi

# --- 3. Branding endpoint returns matching partner_id ---
if [[ $LOCAL_ONLY -eq 1 || -z "$DOMAIN" ]]; then
	# Branding API needs backend (Task 3) — in local mode we just probe the route exists.
	check "check_03_branding" "3. branding endpoint reachable (local)" bash -c '
		docker compose -f "'"$COMPOSE_FILE"'" exec -T caddy wget -qSO- --tries=1 --timeout=5 \
			--header="Host: '"${DOMAIN:-localhost}"'" http://127.0.0.1/api/branding 2>&1 | grep -qE "HTTP/"
	'
else
	check "check_03_branding" "3. /api/branding partner_id=${PARTNER_ID:-?}" bash -c '
		resp=$(curl -fsS --max-time 8 "https://'"$DOMAIN"'/api/branding" || true)
		echo "$resp" | grep -q "\"partner_id\":\"'"${PARTNER_ID:-}"'\""
	'
fi

# --- 4. TCP 443 listening ---
check "check_04_tcp443" "4. TCP 443 listening (caddy)" bash -c 'ss -ltn | grep -q ":443 "'

# --- 5. UDP 3478 listening ---
check "check_05_udp3478" "5. UDP 3478 listening (coturn)" bash -c 'ss -lun | grep -q ":3478 "'

# --- 6. TCP 5349 listening ---
check "check_06_tcp5349" "6. TCP 5349 listening (coturn TURNS)" bash -c 'ss -ltn | grep -q ":5349 "'

# --- 7. xray-client has an outbound ESTABLISHED connection ---
check "check_07_xray_tunnel" "7. xray-client tunnel established" bash -c '
	docker exec oxpulse-partner-xray sh -c "
		(ss -tn state established 2>/dev/null || netstat -tn 2>/dev/null | grep ESTABLISHED) | head -1 | grep -q .
	"
'

# --- 8. Coturn shared-secret matches rendered config ---
check "check_08_coturn_secret" "8. coturn secret matches config" bash -c '
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
if [[ "$SNAPSHOT_MODE" -eq 0 ]]; then echo -n "9. TURNS-443 handshake: "; fi
if [ -z "${TURNS_SUBDOMAIN:-}" ]; then
	snap_emit "check_09_turns443" 0 "SKIP — TURNS_SUBDOMAIN not set in install.env (upgrade from v0.1.x?)\n"
else
	_handshake_out=$(mktemp)
	timeout 10 openssl s_client -connect "${TURNS_SUBDOMAIN}.${DOMAIN}:443" \
		-servername "${TURNS_SUBDOMAIN}.${DOMAIN}" </dev/null >"$_handshake_out" 2>/dev/null || true
	if grep -q "Verify return code: 0 (ok)" "$_handshake_out"; then
		snap_emit "check_09_turns443" 0 "PASS\n"
	else
		snap_emit "check_09_turns443" 1 "FAIL\n"
		FAIL=$((FAIL + 1))
	fi
	rm -f "$_handshake_out"
fi

# --- 10. SPA served on GET / ---
# After removing the @probe cover decoy (2026-04-20), every GET / must
# return the SPA HTML directly — no decoy, no handler branching. Buffer
# the response into a variable because piping straight into `grep -q`
# loses body after the first match via SIGPIPE.
check "check_10_spa" "10. SPA served on GET / (HTML body)" bash -c '
	out=$(docker compose -f "'"$COMPOSE_FILE"'" exec -T caddy wget -qSO- \
		--tries=1 --timeout=5 \
		--header="Host: '"${DOMAIN:-localhost}"'" http://127.0.0.1/ 2>&1)
	echo "$out" | grep -qE "HTTP/.* 200" \
		&& echo "$out" | grep -qiE "<html|<!doctype"
'

# --- 11. SFU UDP media port listening (M2.1) ---
# SFU binds SFU_UDP_PORT on 0.0.0.0 in host netns — ss from the host sees it.
SFU_UDP_PORT="${SFU_UDP_PORT:-7878}"
check "check_11_sfu_udp" "11. UDP ${SFU_UDP_PORT} listening (sfu media)" bash -c '
	ss -lun | grep -qE ":'"${SFU_UDP_PORT}"' "
'

# --- 12. SFU /metrics responds 200 (M1.5 endpoint) ---
# Resolve the SFU metrics bind address from the compose file.
# Post-#288 edges set SFU_METRICS_BIND to the AWG mesh IP (e.g. 10.9.0.7).
# Probing 127.0.0.1 fails on those edges (mesh-only socket, not 0.0.0.0).
# Fallback: 127.0.0.1 preserves behaviour on legacy edges without SFU_METRICS_BIND.
SFU_METRICS_PORT="${SFU_METRICS_PORT:-9317}"
_sfu_metrics_bind=$(grep -E '^\s*SFU_METRICS_BIND:' "$COMPOSE_FILE" \
    | head -1 \
    | sed -E 's/^\s*SFU_METRICS_BIND:\s*//' \
    | tr -d '"' \
    | cut -d/ -f1)
_sfu_metrics_bind="${_sfu_metrics_bind:-127.0.0.1}"
check "check_12_sfu_metrics" "12. SFU /metrics → 200" bash -c '
	code=$(curl -fso /dev/null -w "%{http_code}" --max-time 5 \
		"http://'"${_sfu_metrics_bind}"':'"${SFU_METRICS_PORT}"'/metrics" || true)
	[[ "$code" == "200" ]]
'

if [[ "$SNAPSHOT_MODE" -eq 0 ]]; then echo; fi
# --- 13. Canary: tunnel probe ---
check "check_13_canary_tunnel" "13. canary /canary/tunnel → 2xx" bash -c '
	code=$(curl -fso /dev/null -w "%{http_code}" --max-time 5 \
		"http://127.0.0.1:9080/canary/tunnel" || true)
	[[ "$code" =~ ^2 ]]
'

# --- 14. Canary: upstream probe ---
check "check_14_canary_upstream" "14. canary /canary/upstream → 2xx" bash -c '
	code=$(curl -fso /dev/null -w "%{http_code}" --max-time 5 \
		"http://127.0.0.1:9080/canary/upstream" || true)
	[[ "$code" =~ ^2 ]]
'

# --- 15. Canary: config-hash matches install.env ---
# Warn-only: emergency operator edits survive but become visible in output.
# In snapshot mode, WARN counts as GREEN (warn-only = not a failure indicator).
if [[ "$SNAPSHOT_MODE" -eq 0 ]]; then echo -n "  15. CADDYFILE_SHA drift check:                    "; fi
if [[ -z "${CADDYFILE_SHA:-}" ]]; then
	snap_emit "check_15_caddyfile_sha" 0 "SKIP -- CADDYFILE_SHA not set in install.env (pre-phase1 node?)\n"
else
	# FIX 6: disambiguate "endpoint down" from "hash drift" — both previously
	# emitted the same WARN with empty canary= which operators couldn't distinguish.
	_canary_hash=$(curl -fso- --max-time 5 "http://127.0.0.1:9080/canary/config-hash" 2>/dev/null || true)
	if [[ -z "$_canary_hash" ]]; then
		snap_emit "check_15_caddyfile_sha" 0 "$(printf '\033[33mWARN\033[0m (canary endpoint unreachable -- port 9080 down? pre-Phase-1 node?)\n')"
	elif [[ "$_canary_hash" == "$CADDYFILE_SHA" ]]; then
		snap_emit "check_15_caddyfile_sha" 0 "$(printf '\033[32mOK\033[0m\n')"
	else
		snap_emit "check_15_caddyfile_sha" 0 "$(printf '\033[33mWARN\033[0m (drift: canary=%s install.env=%s -- manual edit?)\n' "$_canary_hash" "$CADDYFILE_SHA")"
	fi
fi

# --- 16. hy2 container running + healthy (graceful on awg-only edges) ---
# In Phase 1.7 partial rollout, edges without hy2 provisioned are awg-only.
# Container absent = info (not fail). Container present but unhealthy = warn.
if [[ "$SNAPSHOT_MODE" -eq 0 ]]; then echo -n "  16. hy2 container healthy:                        "; fi
_hy2_health=$(docker inspect -f '{{.State.Health.Status}}' oxpulse-partner-hysteria2 2>/dev/null || true)
_hy2_running=$(docker ps --filter name=oxpulse-partner-hysteria2 --format '{{.Names}}' 2>/dev/null | grep -c oxpulse-partner-hysteria2 || true)
if [[ "$_hy2_health" == "healthy" ]]; then
	snap_emit "check_16_hy2" 0 "$(printf '\033[32mOK\033[0m\n')"
elif [[ "$_hy2_running" -gt 0 ]]; then
	# Running but not healthy: in snapshot treat as RED (container is failing).
	snap_emit "check_16_hy2" 1 "$(printf '\033[33mWARN\033[0m (running but health status not '"'"'healthy'"'"': %s — may be starting)\n' "${_hy2_health:-unknown}")"
	FAIL=$((FAIL + 1))
else
	# Not deployed: skip (GREEN in snapshot — not a regression indicator).
	snap_emit "check_16_hy2" 0 "INFO (hy2 container not deployed — awg-only mode, Phase 1.7 hy2 not provisioned)\n"
fi

# --- 17. Service token file: present and mode 0600 ---
# Skip-on-legacy: nodes predating Follow-up #2 PR-B won't have the file yet.
# Pass:          file present + mode 0600.
# Pass (legacy): file absent AND OXPULSE_SERVICE_TOKEN env not set.
# Fail:          file present but mode is not 0600.
if [[ "$SNAPSHOT_MODE" -eq 0 ]]; then echo -n "  17. service token file ($CONF_DIR/token):           "; fi
_tok_file="$CONF_DIR/token"
_tok_env="${OXPULSE_SERVICE_TOKEN:-}"
if [[ -e "$_tok_file" ]]; then
	_tok_mode=$(stat -c '%a' "$_tok_file" 2>/dev/null || stat -f '%A' "$_tok_file" 2>/dev/null || echo "unknown")
	if [[ "$_tok_mode" == "600" ]]; then
		snap_emit "check_17_token_mode" 0 "$(printf '\033[32mOK\033[0m\n')"
	else
		snap_emit "check_17_token_mode" 1 "$(printf '\033[31mFAIL\033[0m (mode=%s, expected 600 — fix: chmod 0600 %s)\n' "$_tok_mode" "$_tok_file")"
		FAIL=$((FAIL + 1))
	fi
elif [[ -n "$_tok_env" ]]; then
	snap_emit "check_17_token_mode" 0 "OK (env override — OXPULSE_SERVICE_TOKEN set)\n"
else
	snap_emit "check_17_token_mode" 0 "SKIP (no token file — legacy node or fresh node not yet registered)\n"
fi
unset _tok_file _tok_env _tok_mode

# --- 18. hy2 TCP forwarder listening on :18443 (only if container deployed) ---
if [[ "$_hy2_running" -gt 0 ]]; then
	check "check_18_hy2_tcp" "18. TCP 18443 listening (hy2 forwarder)" bash -c '
		ss -ltnH 2>/dev/null | awk '"'"'{print $4}'"'"' | grep -qE ":18443$"
	'
else
	# Not deployed: emit GREEN in snapshot (not applicable, not a regression).
	if [[ "$SNAPSHOT_MODE" -eq 1 ]]; then
		printf 'check_18_hy2_tcp=GREEN\n'
	fi
fi

# --- 19. service-token authed probe → 2xx ---
# Catches "token rot": file missing, malformed, or revoked server-side.
# Skip-on-legacy: if no token file AND OXPULSE_SERVICE_TOKEN not set, node
# predates service-token provisioning — emit INFO and treat as pass.
if [[ "$SNAPSHOT_MODE" -eq 0 ]]; then echo -n "  19. service-token authed probe → 2xx:             "; fi
_tok_file="$CONF_DIR/token"
_tok_env="${OXPULSE_SERVICE_TOKEN:-}"
if [[ ! -e "$_tok_file" && -z "$_tok_env" ]]; then
	snap_emit "check_19_token_probe" 0 "INFO (legacy node — no service token persisted)\n"
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
		snap_emit "check_19_token_probe" 1 "$(printf '\033[31mFAIL\033[0m (could not read token from %s — missing or empty)\n' "$_tok_file")"
		FAIL=$((FAIL + 1))
	else
		_backend="${OXPULSE_BACKEND_URL:-https://oxpulse.chat}"
		_http_code=$(curl -fsS --max-time 8 \
			-H "Authorization: Bearer $_svc_token" \
			"${_backend%/}/api/partner/hy2-credentials" \
			-o /dev/null -w "%{http_code}" 2>/dev/null || echo "000")
		if [[ "$_http_code" == "200" || "$_http_code" == "503" ]]; then
			snap_emit "check_19_token_probe" 0 "$(printf '\033[32mOK\033[0m (HTTP %s — auth accepted)\n' "$_http_code")"
		else
			snap_emit "check_19_token_probe" 1 "$(printf '\033[31mFAIL\033[0m (HTTP %s — token rejected or endpoint unreachable)\n' "$_http_code")"
			if [[ "$SNAPSHOT_MODE" -eq 0 ]]; then
				echo "    Recovery: docker exec oxpulse-chat partner-cli rotate-service-token --node-id ${NODE_ID:-<NODE_ID>} --force"
				echo "    Then: scp the new value to this edge at /etc/oxpulse-partner-edge/token (mode 0600)"
			fi
			FAIL=$((FAIL + 1))
		fi
		unset _http_code _backend
	fi
	unset _svc_token _tok_lib
fi
unset _tok_file _tok_env

# --- 20. channels-health-report.timer loaded and active (M2.6a) ---
# Skip-on-legacy: unit file absent = pre-M2.6a install; run install.sh to add.
if [[ "$SNAPSHOT_MODE" -eq 0 ]]; then echo -n "  20. channels-health-report.timer loaded:           "; fi
_chr_unit="$SYSTEMD_DIR/oxpulse-channels-health-report.timer"
if [[ ! -f "$_chr_unit" ]]; then
	snap_emit "check_20_chr_timer" 0 "SKIP (unit absent — pre-M2.6a install; re-run install.sh to enable)\n"
else
	_chr_state=$(systemctl show oxpulse-channels-health-report.timer \
		--property=LoadState --value 2>/dev/null || echo "unknown")
	_chr_active=$(systemctl show oxpulse-channels-health-report.timer \
		--property=ActiveState --value 2>/dev/null || echo "unknown")
	if [[ "$_chr_state" == "loaded" && ("$_chr_active" == "active" || "$_chr_active" == "waiting") ]]; then
		snap_emit "check_20_chr_timer" 0 "$(printf '\033[32mOK\033[0m (%s)\n' "$_chr_active")"
	else
		snap_emit "check_20_chr_timer" 1 "$(printf '\033[31mFAIL\033[0m (LoadState=%s ActiveState=%s)\n' "$_chr_state" "$_chr_active")"
		if [[ "$SNAPSHOT_MODE" -eq 0 ]]; then
			echo "    Recovery: systemctl enable --now oxpulse-channels-health-report.timer"
		fi
		FAIL=$((FAIL + 1))
	fi
fi
unset _chr_unit _chr_state _chr_active

# --- 21. Per-channel status (Phase 5.5 resilient install) ---
# Reads channels-status.env written by install.sh / update.sh.
# overall = healthy  when all channels active
# overall = degraded when some channels failed but ≥1 active
# overall = failed   when zero channels active (no bypass path)
# Exit 0 for healthy/degraded; contributes to FAIL for all-failed.
_chs_file="$STATE_DIR/channels-status.env"
if [[ "$SNAPSHOT_MODE" -eq 0 ]]; then echo -n "  21. channel status:                                "; fi
if [[ ! -f "$_chs_file" ]]; then
	snap_emit "check_21_channels" 0 "SKIP (channels-status.env absent — pre-Phase-5.5 install)\n"
else
	_ch_active_count=0
	_ch_failed_count=0
	_ch_total=0
	while IFS='=' read -r _ch_name _ch_status || [[ -n "$_ch_name" ]]; do
		[[ -z "$_ch_name" || "$_ch_name" =~ ^# ]] && continue
		# MEDIUM 3 fix: validate line format — name must be [a-z][a-z0-9_-]* and
		# status must be non-empty.  "xray active" (missing =) would yield
		# _ch_name='xray active' _ch_status='' and fall into skipped silently.
		if [[ ! "$_ch_name" =~ ^[a-z][a-z0-9_-]*$ ]] || [[ -z "$_ch_status" ]]; then
			[[ "$SNAPSHOT_MODE" -eq 0 ]] && printf '\nWARN: channels-status.env: malformed line (name='"'"'%s'"'"' status='"'"'%s'"'"') — skipping\n' "${_ch_name}" "${_ch_status:-<empty>}"
			continue
		fi
		_ch_total=$((_ch_total + 1))
		case "$_ch_status" in
			active)            _ch_active_count=$((_ch_active_count + 1)) ;;
			# failed_at_setup: Phase 5.7 AWG fail-soft — setup failed but install continued.
			# Treated as degraded (counts toward failed) but not a schema-drift unknown.
			failed_at_render|failed_at_start|failed_at_setup) _ch_failed_count=$((_ch_failed_count + 1)) ;;
			skipped)           ;;  # not attempted — does not count toward failure
			# Fix #3: granular skip reasons for naive channel (skipped_no_server when
			# NAIVE_SERVER was empty, skipped_fixture_host when guard rejected a test
			# placeholder like *.example.com / localhost / *.test).  Neither counts
			# toward failure — the naive channel was simply not provisioned.
			skipped_no_server|skipped_fixture_host) ;;  # naive channel intentionally skipped
			# MAJOR 4 fix: unknown/typo status (e.g. 'actived', 'provisioning') counts
			# as failure rather than silently passing.  Schema drift → false-green prevented.
			*) [[ "$SNAPSHOT_MODE" -eq 0 ]] && printf '\nWARN: channels-status.env: unknown status '"'"'%s'"'"' for channel '"'"'%s'"'"' — treating as failed\n' "${_ch_status}" "${_ch_name}"; _ch_failed_count=$((_ch_failed_count + 1)) ;;
		esac
	done < "$_chs_file"

	if [[ $_ch_total -eq 0 ]]; then
		snap_emit "check_21_channels" 0 "SKIP (no channel entries in channels-status.env)\n"
	elif [[ $_ch_active_count -eq 0 && $_ch_failed_count -gt 0 ]]; then
		snap_emit "check_21_channels" 1 "$(printf '\033[31mFAIL\033[0m (overall=failed — zero channels active; failed: %d/%d)\n' "$_ch_failed_count" "$_ch_total")"
		FAIL=$((FAIL + 1))
	elif [[ $_ch_failed_count -gt 0 ]]; then
		snap_emit "check_21_channels" 0 "$(printf '\033[33mWARN\033[0m (overall=degraded — active: %d, failed: %d/%d)\n' "$_ch_active_count" "$_ch_failed_count" "$_ch_total")"
	else
		snap_emit "check_21_channels" 0 "$(printf '\033[32mOK\033[0m (overall=healthy — active: %d/%d)\n' "$_ch_active_count" "$_ch_total")"
	fi
	unset _ch_active_count _ch_failed_count _ch_total _ch_name _ch_status
fi
unset _chs_file

# In snapshot mode: always exit 0 (output is for diffing, not pass/fail signal).
if [[ "$SNAPSHOT_MODE" -eq 1 ]]; then
	exit 0
fi

if [[ $FAIL -eq 0 ]]; then
	echo "All checks passed."
	exit 0
else
	echo "$FAIL check(s) failed."
	exit "$FAIL"
fi
