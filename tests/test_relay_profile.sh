#!/usr/bin/env bash
# tests/test_relay_profile.sh — relay-only node profile (relay/): fail-closed on
# registration material, relay firewall rule set, guard/range agreement, secrets
# never printed, heartbeat payload shape.
#
# Mutations that must turn this RED (stated as the edit):
#   * relay/relay-lib.sh: delete SIGNALING_SFU_SECRET from RELAY_FORBIDDEN_ENV
#     -> "fails closed: env SIGNALING_SFU_SECRET".
#   * relay/relay-lib.sh: delete the `udp 49152:65535` line in relay_firewall_rules
#     -> "relay firewall rule set".
#   * relay/oxpulse-relay-health-report.sh: change channel_name "coturn" to "ch4"
#     -> "heartbeat payload".
set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
R="$REPO_ROOT/relay"
PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }
refuses() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then fail "$name"; else pass "$name"; fi; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
S1="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
S2="BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"

# Runs relay_assert_no_registration_material in a subshell against an etc dir.
assert_clean() { # <etc-dir> [VAR=VALUE ...]
	local etc="$1"; shift
	( env "$@" PREFIX_ETC="$etc" bash -c '
		log(){ :; }; warn(){ :; }; die(){ echo "$*" >&2; exit 1; }
		. "$1"; relay_assert_no_registration_material' _ "$R/relay-lib.sh" )
}

mkdir -p "$T/clean"
check "clean host passes the registration-material gate" assert_clean "$T/clean"
for v in SIGNALING_SFU_SECRET TURN_PARTNER_LEGACY TURN_CENTRAL_SECRET ROOM_HMAC_KEY REALITY_PRIVATE_KEY OXPULSE_SERVICE_TOKEN; do
	refuses "fails closed: env $v" assert_clean "$T/clean" "$v=x"
done
for f in node-config.json token .env reality.priv awg-private.key sfu-signing-key; do
	d="$T/f-$f"; mkdir -p "$d"; : > "$d/$f"
	refuses "fails closed: file $f present" assert_clean "$d"
done
d="$T/text"; mkdir -p "$d"; echo '{"signaling_sfu_secret":"x"}' > "$d/anything.json"
refuses "fails closed: signaling_sfu_secret inside a config file" assert_clean "$d"
d="$T/text2"; mkdir -p "$d"; echo 'TURN_PARTNER_LEGACY=x' > "$d/x.conf"
refuses "fails closed: TURN_PARTNER_LEGACY inside a config file" assert_clean "$d"
out="$(assert_clean "$T/clean" SIGNALING_SFU_SECRET=hunter2hunter2 2>&1 || true)"
if [[ "$out" == *hunter2* ]]; then fail "refusal never prints the value"; else pass "refusal never prints the value"; fi

# --- installer surface ---
refuses "install-relay.sh rejects --token" bash "$R/install-relay.sh" --hostname a.b --public-ip 1.2.3.4 --node-id n --token x
refuses "install-relay.sh rejects --partner-id" bash "$R/install-relay.sh" --partner-id x
if grep -nEi 'api/partner/register|partner/node-config|node-config\.json"|docker|caddy|xray|hysteria|naive|amnezia|refresh\.timer' "$R"/install-relay.sh "$R"/oxpulse-relay-*.service "$R"/oxpulse-relay-*.timer "$R"/oxpulse-relay-apply.sh "$R"/oxpulse-relay-health-report.sh | grep -vE '^\S+:[0-9]+:\s*#' >/dev/null; then
	fail "no register/node-config/docker/caddy/xray/hy2/naive/awg/refresh reference in executable relay lines"
else pass "no register/node-config/docker/caddy/xray/hy2/naive/awg/refresh reference in executable relay lines"; fi

# --- firewall ---
rules="$(bash -c '. "$1"; relay_firewall_rules' _ "$R/relay-lib.sh")"
want="tcp 22
tcp 80
tcp 443
udp 443
tcp 3478
udp 3478
udp 49152:65535"
if [[ "$rules" == "$want" ]]; then pass "relay firewall rule set"; else fail "relay firewall rule set"; fi
# ufw path: stub ufw, record every call.
mkdir -p "$T/bin"; cat > "$T/bin/ufw" <<STUB
#!/bin/bash
echo "\$*" >> "$T/ufw.log"
STUB
chmod +x "$T/bin/ufw"; : > "$T/ufw.log"
PATH="$T/bin:$PATH" bash -c '
	log(){ :; }; die(){ echo "$*" >&2; exit 1; }
	. "$1"; . "$2"; _firewall_detect_tool(){ echo ufw; }; relay_firewall_apply' _ "$REPO_ROOT/lib/firewall-lib.sh" "$R/relay-lib.sh"
grep -q '^allow 49152:65535/udp' "$T/ufw.log" && pass "ufw: relay range allowed" || fail "ufw: relay range allowed"
grep -q '^default deny incoming' "$T/ufw.log" && pass "ufw: default deny incoming" || fail "ufw: default deny incoming"
grep -q '^allow 22/tcp' "$T/ufw.log" && grep -q '^allow 80/tcp' "$T/ufw.log" && grep -q '^allow 443/udp' "$T/ufw.log" && grep -q '^allow 3478/tcp' "$T/ufw.log" \
	&& pass "ufw: ssh/acme/turns/turn allowed" || fail "ufw: ssh/acme/turns/turn allowed"
if grep -qE '7878|18443|5349|8920|9317|8912|from 10\.9' "$T/ufw.log"; then fail "ufw: no SFU/AWG/mesh/hy2 rules"; else pass "ufw: no SFU/AWG/mesh/hy2 rules"; fi

# --- range agreement: template, guard, sysctl, firewall ---
min="$(sed -nE 's/^min-port=([0-9]+)$/\1/p' "$R/coturn-relay.conf.tpl")"
max="$(sed -nE 's/^max-port=([0-9]+)$/\1/p' "$R/coturn-relay.conf.tpl")"
grep -q "udp dport != ${min}-${max} counter drop" "$R/coturn-self-relay-guard.nft" && pass "guard range == coturn range" || fail "guard range == coturn range"
grep -q "^net.ipv4.ip_local_reserved_ports = ${min}-${max}\$" "$R/99-coturn-relay-ports.conf" && pass "sysctl reservation == coturn range" || fail "sysctl reservation == coturn range"
[[ "$rules" == *"udp ${min}:${max}"* ]] && pass "firewall range == coturn range" || fail "firewall range == coturn range"
grep -q 'meta skuid "turnserver" fib daddr type local meta l4proto udp' "$R/coturn-self-relay-guard.nft" && pass "guard keyed on turnserver, local daddr, udp" || fail "guard keyed on turnserver, local daddr, udp"
grep -q '^Before=oxpulse-relay-coturn.service' "$R/coturn-self-relay-guard.service" && ! grep -qE '^(Requires|BindsTo)=.*coturn' "$R/coturn-self-relay-guard.service" \
	&& pass "guard unit ordered Before coturn, no hard coupling" || fail "guard unit ordered Before coturn, no hard coupling"

# --- coturn unit refuses to start without secret + cert + config ---
for c in node-secret coturn.conf relay-certs/fullchain.pem; do
	grep -q "^ConditionPathExists=/etc/oxpulse-partner-edge/$c\$" "$R/oxpulse-relay-coturn.service" && pass "unit condition: $c" || fail "unit condition: $c"
done
grep -q '^ExecStartPre=+/usr/bin/opec check-node-secret ' "$R/oxpulse-relay-coturn.service" && pass "unit validates the secret as root before start" || fail "unit validates the secret as root before start"

# --- fingerprints never print the secret ---
printf '%s\n%s\n' "$S1" "$S2" > "$T/sec"
fp="$(bash -c '. "$1"; relay_secret_fingerprints "$2"' _ "$R/relay-lib.sh" "$T/sec")"
if [[ "$fp" == *"$S1"* || "$fp" == *"$S2"* ]]; then fail "fingerprints do not leak the secret"; else pass "fingerprints do not leak the secret"; fi
[[ "$(wc -l <<<"$fp")" -eq 2 && "$fp" =~ ^secret\ line\ 1:\ sha256\ [0-9a-f]{8} ]] && pass "fingerprints: one sha256 prefix per line" || fail "fingerprints: one sha256 prefix per line"

# --- heartbeat payload (needs bash>=5 for EPOCHREALTIME, jq, python3: CI has them) ---
if [[ "${BASH_VERSINFO[0]}" -ge 5 ]] && command -v jq >/dev/null && command -v python3 >/dev/null; then
	E="$T/etc"; mkdir -p "$E"
	echo relay-node-1 > "$E/node-id"
	printf 'RELAY_HOSTNAME=relay.example.org\nEXTERNAL_IP=203.0.113.10\n' > "$E/relay.env"
	printf '%s\n' "$S1" > "$E/node-secret"; chmod 600 "$E/node-secret"
	printf 'stkn_testtoken\n' > "$E/service-token"; chmod 600 "$E/service-token"
	printf '#!/bin/bash\necho "allocated" \nexit 0\n' > "$T/bin/uclient-ok"
	printf '#!/bin/bash\necho "Allocation Quota Reached 486" >&2\nexit 255\n' > "$T/bin/uclient-bad"
	chmod +x "$T/bin/uclient-ok" "$T/bin/uclient-bad"
	hb() { PREFIX_ETC="$E" RELAY_LIB_DIR="$REPO_ROOT/lib" TURN_UCLIENT="$1" bash "$R/oxpulse-relay-health-report.sh" --dry-run 2>&1; }
	out="$(hb "$T/bin/uclient-ok")"
	[[ "$(jq -r '.channel_name' <<<"$out" 2>/dev/null)" == coturn && "$(jq -r '.node_id' <<<"$out" 2>/dev/null)" == relay-node-1 \
	   && "$(jq -r '.channel_handshake_ok' <<<"$out" 2>/dev/null)" == true && "$(jq -r '.channel_probed_at' <<<"$out" 2>/dev/null)" != null ]] \
		&& pass "heartbeat payload (ok)" || fail "heartbeat payload (ok): $out"
	[[ "$out" != *"$S1"* ]] && pass "heartbeat output never contains the secret" || fail "heartbeat output never contains the secret"
	out="$(hb "$T/bin/uclient-bad")"
	jq -e '.channel_handshake_ok == false and .channel_probe_reason == "auth-486"' >/dev/null 2>&1 <<<"$(sed -n '/^{/,$p' <<<"$out")" \
		&& pass "heartbeat payload (failed probe carries reason)" || fail "heartbeat payload (failed probe carries reason): $out"
	chmod 644 "$E/service-token"
	if out="$(hb "$T/bin/uclient-ok")"; then rc=0; else rc=$?; fi
	[[ "$rc" -ne 0 && "$out" == *"no service token"* ]] && pass "service-token with loose mode is refused" || fail "service-token with loose mode is refused"
else
	echo "NOTE: heartbeat tests need bash>=5, jq, python3 — run on Linux CI"
fi

echo ""
echo "relay profile: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
