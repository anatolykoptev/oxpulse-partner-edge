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
#   * relay/install-relay.sh relay_main: delete `relay_assert_no_registration_material`
#     -> "forbidden material: refuses before any change"; delete
#     `relay_firewall_apply` -> "relay_main order"; delete `relay_install_guard`
#     -> "relay_main order".
#   * relay/oxpulse-relay-health-report.sh: delete the `-t` of the uclient call
#     -> "uclient argv".
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
for v in SIGNALING_SFU_SECRET TURN_PARTNER_LEGACY TURN_CENTRAL_SECRET ROOM_HMAC_KEY REALITY_PRIVATE_KEY REALITY_SHORT_ID OXPULSE_SERVICE_TOKEN; do
	refuses "fails closed: env $v" assert_clean "$T/clean" "$v=x"
done
for f in node-config.json token .env reality.priv awg-private.key sfu-signing-key xray.env ghcr.token docker-compose.yml Caddyfile cross-probe-token; do
	d="$T/f-$f"; mkdir -p "$d"; : > "$d/$f"
	refuses "fails closed: file $f present" assert_clean "$d"
done
d="$T/text"; mkdir -p "$d"; echo '{"signaling_sfu_secret":"x"}' > "$d/anything.json"
refuses "fails closed: signaling_sfu_secret inside a config file" assert_clean "$d"
d="$T/text3"; mkdir -p "$d"; echo 'REALITY_UUID=x' > "$d/x.env"
refuses "fails closed: REALITY_ text inside a config file" assert_clean "$d"
d="$T/libdir"; mkdir -p "$d/etc" "$d/lib"
refuses "fails closed: /var/lib/oxpulse-partner-edge state dir present" assert_clean "$d/etc" "PREFIX_LIB=$d/lib"
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
want="tcp 80
tcp 443
tcp 3478
udp 3478
udp 49152:65535"
if [[ "$rules" == "$want" ]]; then pass "relay firewall rule set"; else fail "relay firewall rule set"; fi
# ufw path: stub ufw (records calls; canned `status`), sshd (-T) and IPV6=yes file.
mkdir -p "$T/bin"; cat > "$T/bin/ufw" <<STUB
#!/bin/bash
echo "\$*" >> "$T/ufw.log"
[[ "\${1:-}" == status ]] && cat "$T/ufw.status"
exit 0
STUB
printf '#!/bin/bash\necho "port 2222"\n' > "$T/bin/sshd"
chmod +x "$T/bin/ufw" "$T/bin/sshd"
printf 'IPV6=yes\n' > "$T/ufw.default"
run_ufw() { # <status-file-content>
	: > "$T/ufw.log"; printf '%s' "$1" > "$T/ufw.status"
	PATH="$T/bin:$PATH" UFW_DEFAULT="$T/ufw.default" bash -c '
		log(){ :; }; die(){ echo "$*" >&2; exit 1; }
		. "$1"; . "$2"; _firewall_detect_tool(){ echo ufw; }; relay_firewall_apply' _ "$REPO_ROOT/lib/firewall-lib.sh" "$R/relay-lib.sh"
}
run_ufw ""
grep -q '^allow 49152:65535/udp' "$T/ufw.log" && pass "ufw: relay range allowed" || fail "ufw: relay range allowed"
grep -q '^default deny incoming' "$T/ufw.log" && pass "ufw: default deny incoming" || fail "ufw: default deny incoming"
grep -q '^allow 2222/tcp' "$T/ufw.log" && ! grep -q '^allow 22/tcp' "$T/ufw.log" && pass "ufw: ssh port comes from sshd -T" || fail "ufw: ssh port comes from sshd -T"
grep -q '^allow 80/tcp' "$T/ufw.log" && grep -q '^allow 443/tcp' "$T/ufw.log" && grep -q '^allow 3478/tcp' "$T/ufw.log" && grep -q '^allow 3478/udp' "$T/ufw.log" \
	&& pass "ufw: acme/turns/turn allowed" || fail "ufw: acme/turns/turn allowed"
grep -q '^allow 443/udp' "$T/ufw.log" && fail "ufw: no dead udp 443 rule" || pass "ufw: no dead udp 443 rule"
grep -q 'reset' "$T/ufw.log" && fail "ufw: existing rules are not reset" || pass "ufw: existing rules are not reset"
if grep -qE '7878|18443|5349|8920|9317|8912|from 10\.9' "$T/ufw.log"; then fail "ufw: no SFU/AWG/mesh/hy2 rules"; else pass "ufw: no SFU/AWG/mesh/hy2 rules"; fi
run_ufw "2222/tcp                   ALLOW       198.51.100.0/24
"
grep -q '^allow 2222' "$T/ufw.log" && fail "ufw: a pre-existing source-restricted ssh rule is not widened" || pass "ufw: a pre-existing source-restricted ssh rule is not widened"
printf 'IPV6=no\n' > "$T/ufw.default"
refuses "ufw: IPV6=no is refused" run_ufw ""
printf 'IPV6=yes\n' > "$T/ufw.default"

# --- reserved-range cleanliness ---
printf '#!/bin/bash\necho "UNCONN 0 0 0.0.0.0:50123 0.0.0.0:* users:((\\"chronyd\\",pid=1,fd=5))"\n' > "$T/bin/ss-dirty"
printf '#!/bin/bash\necho "UNCONN 0 0 0.0.0.0:50123 0.0.0.0:* users:((\\"turnserver\\",pid=1,fd=5))"\n' > "$T/bin/ss-clean"
chmod +x "$T/bin/ss-dirty" "$T/bin/ss-clean"
range_check() { PATH="$T/bin:$PATH" SS="$1" bash -c 'log(){ :; }; die(){ echo "$*" >&2; exit 1; }; systemctl(){ :; }; . "$1"; relay_assert_relay_range_clean' _ "$R/relay-lib.sh"; }
refuses "range check: a non-turnserver UDP socket in 49152-65535 fails" range_check "$T/bin/ss-dirty"
check "range check: turnserver-owned sockets are fine" range_check "$T/bin/ss-clean"
# a TCP listener (sshd on 50022) must not abort the install: only -ulnp may report
cat > "$T/bin/ss-tcp" <<'STUB'
#!/bin/bash
case "$*" in *-tlnp*) echo 'LISTEN 0 128 0.0.0.0:50022 0.0.0.0:* users:(("sshd",pid=1,fd=3))' ;; esac
STUB
chmod +x "$T/bin/ss-tcp"
check "range check: a TCP listener (sshd:50022) does not abort" range_check "$T/bin/ss-tcp"

# --- range agreement: template, guard, sysctl, firewall ---
min="$(sed -nE 's/^min-port=([0-9]+)$/\1/p' "$R/coturn-relay.conf.tpl")"
max="$(sed -nE 's/^max-port=([0-9]+)$/\1/p' "$R/coturn-relay.conf.tpl")"
grep -q "udp dport != ${min}-${max} counter drop" "$R/coturn-self-relay-guard.nft" && pass "guard range == coturn range" || fail "guard range == coturn range"
grep -q "^net.ipv4.ip_local_reserved_ports = ${min}-${max}\$" "$R/99-coturn-relay-ports.conf" && pass "sysctl reservation == coturn range" || fail "sysctl reservation == coturn range"
[[ "$rules" == *"udp ${min}:${max}"* ]] && pass "firewall range == coturn range" || fail "firewall range == coturn range"
grep -q 'meta skuid "turnserver" fib daddr type local meta l4proto udp' "$R/coturn-self-relay-guard.nft" && pass "guard keyed on turnserver, local daddr, udp" || fail "guard keyed on turnserver, local daddr, udp"
grep -q '^Before=oxpulse-relay-coturn.service' "$R/coturn-self-relay-guard.service" && ! grep -qE '^(Requires|BindsTo)=.*coturn' "$R/coturn-self-relay-guard.service" \
	&& pass "guard unit ordered Before coturn, no hard coupling from the guard" || fail "guard unit ordered Before coturn, no hard coupling from the guard"

# --- template: directives coturn 4.6.1 rejects must not come back ---
if grep -qE '^(allocation-default-timeout|no-loopback-peers)' "$R/coturn-relay.conf.tpl"; then fail "template: no directives rejected by coturn 4.6.1"; else pass "template: no directives rejected by coturn 4.6.1"; fi
for d in 'denied-peer-ip=::' 'denied-peer-ip=64:ff9b::-64:ff9b::ffff:ffff' 'denied-peer-ip=2002::-2002:ffff:ffff:ffff:ffff:ffff:ffff:ffff' 'max-bps=625000'; do
	grep -qx "$d" "$R/coturn-relay.conf.tpl" && pass "template has $d" || fail "template has $d"
done

# --- coturn unit ---
U="$R/oxpulse-relay-coturn.service"
for c in node-secret relay.env relay-certs/fullchain.pem relay-certs/privkey.pem; do
	grep -q "^ConditionPathExists=/etc/oxpulse-partner-edge/$c\$" "$U" && pass "unit condition: $c" || fail "unit condition: $c"
done
for d in '^ExecStartPre=+/usr/local/sbin/oxpulse-relay-prestart$' '^Requires=coturn-self-relay-guard.service$' '^After=.*coturn-self-relay-guard.service' \
	'^StartLimitBurst=' '^StartLimitIntervalSec=' '^CapabilityBoundingSet=CAP_NET_BIND_SERVICE$' '^NoNewPrivileges=yes$' '^ProtectSystem=strict$' \
	'^ProtectHome=yes$' '^PrivateTmp=yes$' '^RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK$' '^ProtectKernelTunables=yes$' \
	'^ProtectKernelModules=yes$' '^SystemCallFilter=@system-service$'; do
	grep -q -- "$d" "$U" && pass "unit has $d" || fail "unit has $d"
done
P="$R/oxpulse-relay-prestart.sh"
grep -q 'list table inet coturn_self_relay_guard' "$P" && grep -q 'relay_assert_no_registration_material' "$P" \
	&& grep -q 'check-node-secret' "$P" && grep -q 'render coturn' "$P" && grep -q -- '--secret-file' "$P" \
	&& pass "prestart: gate + guard + secret check + render" || fail "prestart: gate + guard + secret check + render"
grep -q 'relay_assert_no_registration_material' "$R/oxpulse-relay-apply.sh" && pass "apply re-runs the gate" || fail "apply re-runs the gate"
grep -q 'drops live\|dropped' "$R/oxpulse-relay-apply.sh" && grep -qi 'restart' "$REPO_ROOT/docs/relay-only-node.md" && pass "restart impact documented" || fail "restart impact documented"
grep -q 'not yet limited' "$REPO_ROOT/docs/relay-only-node.md" && grep -q 'not yet limited' "$R/install-relay.sh" && pass "docs state the service token's real reach" || fail "docs state the service token's real reach"

# --- fingerprints never print the secret ---
printf '%s\n%s\n' "$S1" "$S2" > "$T/sec"
fp="$(bash -c '. "$1"; relay_secret_fingerprints "$2"' _ "$R/relay-lib.sh" "$T/sec")"
if [[ "$fp" == *"$S1"* || "$fp" == *"$S2"* ]]; then fail "fingerprints do not leak the secret"; else pass "fingerprints do not leak the secret"; fi
[[ "$(wc -l <<<"$fp")" -eq 2 && "$fp" =~ ^secret\ line\ 1:\ sha256\ [0-9a-f]{8} ]] && pass "fingerprints: one sha256 prefix per line" || fail "fingerprints: one sha256 prefix per line"

# --- heartbeat (needs bash>=5 for EPOCHREALTIME, jq, python3: CI has them) ---
if [[ "${BASH_VERSINFO[0]}" -ge 5 ]] && command -v jq >/dev/null && command -v python3 >/dev/null; then
	E="$T/etc"; mkdir -p "$E"
	echo relay-node-1 > "$E/node-id"
	printf 'RELAY_HOSTNAME=relay.example.org\nEXTERNAL_IP=203.0.113.10\n' > "$E/relay.env"
	printf '%s\n' "$S1" > "$E/node-secret"; chmod 600 "$E/node-secret"
	printf 'stkn_testtoken123\n' > "$E/service-token"; chmod 600 "$E/service-token"
	# Stubs that record argv, so the probes are asserted by what they run.
	cat > "$T/bin/uclient" <<STUB
#!/bin/bash
echo "\$*" > "$T/uclient.argv"
[[ -n "\${UCLIENT_FAIL:-}" ]] && { echo "Allocation Quota Reached 486" >&2; exit 255; }
echo allocated
STUB
	cat > "$T/bin/openssl" <<STUB
#!/bin/bash
echo "\$*" > "$T/openssl.argv"
[[ -n "\${OPENSSL_FAIL:-}" ]] && { echo "verify error:num=10:certificate has expired" >&2; exit 1; }
echo ok
STUB
	chmod +x "$T/bin/uclient" "$T/bin/openssl"
	hb() { env PREFIX_ETC="$E" RELAY_LIB_DIR="$REPO_ROOT/lib" RELAY_TOKEN_OWNER_UID="$(id -u)" TURN_UCLIENT="$T/bin/uclient" OPENSSL_BIN="$T/bin/openssl" "$@" bash "$R/oxpulse-relay-health-report.sh" --dry-run 2>&1; }
	payloads() { sed -n '/^{/,/^}/p' <<<"$1" | jq -c .; }   # one compact object per channel
	out="$(hb)"
	[[ "$(payloads "$out" | jq -r '.channel_name' | paste -sd, -)" == "coturn,coturn-tls" ]] && pass "heartbeat reports coturn and coturn-tls" || fail "heartbeat reports coturn and coturn-tls: $out"
	[[ "$(payloads "$out" | jq -r 'select(.channel_name=="coturn") | .node_id + ":" + (.channel_handshake_ok|tostring)')" == "relay-node-1:true" ]] \
		&& pass "heartbeat payload (coturn ok)" || fail "heartbeat payload (coturn ok)"
	[[ "$(payloads "$out" | jq -r 'select(.channel_name=="coturn-tls") | (.channel_handshake_ok|tostring) + ":" + .channel_probe_mode')" == "true:tls-verify" ]] \
		&& pass "heartbeat payload (coturn-tls ok)" || fail "heartbeat payload (coturn-tls ok)"
	[[ "$out" != *"$S1"* ]] && pass "heartbeat output never contains the secret" || fail "heartbeat output never contains the secret"
	argv="$(cat "$T/uclient.argv")"
	[[ "$argv" =~ ^-t\ -u\ [0-9]+:healthprobe\ -w\ [A-Za-z0-9+/=]+\ -y\ -n\ 1\ -p\ 3478\ 203\.0\.113\.10$ ]] \
		&& pass "uclient argv: -t -y -p 3478 <EXTERNAL_IP>, <ts>:healthprobe user" || fail "uclient argv: -t -y -p 3478 <EXTERNAL_IP>, <ts>:healthprobe user: $argv"
	[[ "$argv" != *"$S1"* ]] && pass "uclient argv does not contain the base secret" || fail "uclient argv does not contain the base secret"
	oargv="$(cat "$T/openssl.argv")"
	[[ "$oargv" == "s_client -connect 203.0.113.10:443 -servername relay.example.org -verify_hostname relay.example.org -verify_return_error" ]] \
		&& pass "openssl argv: SNI + hostname verification + fatal chain errors on 443" || fail "openssl argv: $oargv"
	out="$(hb UCLIENT_FAIL=1)"
	payloads "$out" | jq -e -s 'map(select(.channel_name=="coturn"))[0] | .channel_handshake_ok == false and .channel_probe_reason == "auth-486"' >/dev/null 2>&1 \
		&& pass "heartbeat payload (failed allocate carries reason)" || fail "heartbeat payload (failed allocate carries reason): $out"
	out="$(hb OPENSSL_FAIL=1)"
	payloads "$out" | jq -e -s 'map(select(.channel_name=="coturn-tls"))[0] | .channel_handshake_ok == false and .channel_probe_reason == "cert-verify"' >/dev/null 2>&1 \
		&& pass "heartbeat payload (failed TLS verify carries reason)" || fail "heartbeat payload (failed TLS verify carries reason): $out"
	chmod 644 "$E/service-token"
	if out="$(hb)"; then rc=0; else rc=$?; fi
	[[ "$rc" -ne 0 && "$out" == *"no service token"* ]] && pass "service-token with loose mode is refused" || fail "service-token with loose mode is refused"
	chmod 600 "$E/service-token"; printf 'not-a-token\n' > "$E/service-token"
	if out="$(hb)"; then rc=0; else rc=$?; fi
	[[ "$rc" -ne 0 && "$out" == *"no service token"* ]] && pass "service-token with a bad shape is refused" || fail "service-token with a bad shape is refused"
	printf 'stkn_testtoken123\n' > "$E/service-token"; chmod 600 "$E/service-token"
	if out="$(hb RELAY_TOKEN_OWNER_UID=99999)"; then rc=0; else rc=$?; fi
	[[ "$rc" -ne 0 && "$out" == *"no service token"* ]] && pass "service-token owned by someone else is refused" || fail "service-token owned by someone else is refused"
else
	echo "NOTE: heartbeat tests need bash>=5, jq, python3 — run on Linux CI"
fi

# --- relay_main end to end against stubs: order + refusal before any change ---
M="$T/e2e"; mkdir -p "$M/bin" "$M/root"
LOG="$M/calls.log"
mkstub() { printf '#!/bin/bash\necho "%s $*" >> "%s"\n%s\n' "$1" "$LOG" "${2:-exit 0}" > "$M/bin/$1"; chmod +x "$M/bin/$1"; }
for c in apt-get systemctl nft sysctl chown ufw; do mkstub "$c"; done
mkstub certbot 'mkdir -p "$LE_DIR/live/relay.example.org"; : > "$LE_DIR/live/relay.example.org/fullchain.pem"; : > "$LE_DIR/live/relay.example.org/privkey.pem"'
mkstub id 'echo 0'
mkstub getent 'echo "203.0.113.10 STREAM relay.example.org"'
mkstub sshd 'echo "port 22"'
mkstub ss 'exit 0'
# install(1) wrapper: drop -o/-g (no turnserver group here), delegate to the real one.
cat > "$M/bin/install" <<'STUB'
#!/bin/bash
args=(); while [[ $# -gt 0 ]]; do case "$1" in -o|-g) shift 2 ;; *) args+=("$1"); shift ;; esac; done
exec "$(PATH=/usr/bin:/bin command -v install)" "${args[@]}"
STUB
chmod +x "$M/bin/install"
printf '#!/bin/bash\necho "opec $*" >> "%s"\n[[ "${2:-}" == "--help" || "${3:-}" == "--help" ]] && echo "--secret-file"\nexit 0\n' "$LOG" > "$M/root/opec"; chmod +x "$M/root/opec"
printf 'ID=ubuntu\nID_LIKE=debian\n' > "$M/os-release"
printf 'IPV6=yes\n' > "$M/ufw.default"
printf '0\n' > "$M/reserved"
newenv() { ETC="$(mktemp -d "$T/etc.XXXXXX")"; LEDIR="$(mktemp -d "$T/le.XXXXXX")"; }
run_main() { # env assignments...
	: > "$LOG"
	env "$@" PATH="$M/bin:$PATH" PREFIX_ETC="$ETC" PREFIX_LIB="$T/no-such-lib" RELAY_LIB_DIR="$M/libdst" PREFIX_SBIN="$M/sbin" UNIT_DIR="$M/units" \
		OPEC_DST="$M/root/opec" SYSCTL_DIR="$M/sysctl" LE_DIR="$LEDIR" RESERVED_PORTS_FILE="$M/reserved" OS_RELEASE_PATH="$M/os-release" UFW_DEFAULT="$M/ufw.default" \
		bash -c '
			. "$1"
			_firewall_detect_tool() { echo ufw; }
			relay_main --hostname relay.example.org --public-ip 203.0.113.10 --node-id relay-node-1' _ "$R/install-relay.sh" >"$M/out" 2>&1
}
first_line() { grep -n -m1 -- "$1" "$LOG" | cut -d: -f1; }
newenv
run_main SIGNALING_SFU_SECRET=hunter2hunter2 && rc=0 || rc=$?
if [[ "$rc" -ne 0 && "$(grep -vc "^id " "$LOG")" -eq 0 && ! -e "$ETC/relay.env" && "$(<"$M/out")" != *hunter2* ]]; then pass "forbidden material: refuses before any change"; else fail "forbidden material: refuses before any change (rc=$rc, log: $(cat "$LOG"))"; fi
newenv; echo '{"node_id":"x"}' > "$ETC/node-config.json"
run_main && rc=0 || rc=$?
if [[ "$rc" -ne 0 && "$(grep -vc "^id " "$LOG")" -eq 0 ]]; then pass "forbidden file: refuses before any change"; else fail "forbidden file: refuses before any change"; fi
newenv
run_main && rc=0 || rc=$?
m=$(first_line 'systemctl mask coturn.service'); a=$(first_line 'apt-get install'); f=$(first_line 'ufw default deny incoming')
g=$(first_line 'sysctl -q -p'); gs=$(first_line 'systemctl reload-or-restart coturn-self-relay-guard')
if [[ "$rc" -eq 0 && -n "$m" && -n "$a" && -n "$f" && -n "$g" && -n "$gs" && "$m" -lt "$a" && "$a" -lt "$f" && "$f" -lt "$g" && "$g" -lt "$gs" ]]; then
	pass "relay_main order: mask -> packages -> firewall -> sysctl -> guard"
else fail "relay_main order: mask($m) apt($a) ufw($f) sysctl($g) guard($gs) rc=$rc: $(tail -5 "$M/out") LOG: $(tr "\n" "|" < "$LOG")"; fi
[[ -f "$ETC/relay.env" && -f "$ETC/node-id" ]] && pass "relay_main writes relay.env and node-id" || fail "relay_main writes relay.env and node-id"
grep -q 'api/partner' "$LOG" && fail "relay_main makes no backend call" || pass "relay_main makes no backend call"


# --- relay_main with a dirty UDP range aborts (call site gated) ---
newenv
run_main SS="$T/bin/ss-dirty" && rc=0 || rc=$?
if [[ "$rc" -ne 0 && "$(<"$M/out")" == *"relay range"* ]]; then pass "relay_main aborts when a non-turnserver socket sits in the relay range"; else fail "relay_main aborts when a non-turnserver socket sits in the relay range (rc=$rc)"; fi

# --- prestart: behavioural (stubbed NFT/OPEC), ALLOW_NONROOT=1 ---
PS="$T/ps"; mkdir -p "$PS"
PSLOG="$PS/calls.log"
printf '#!/bin/bash\necho "nft $*" >> "%s"\n[[ -n "${NFT_FAIL:-}" ]] && exit 1\nexit 0\n' "$PSLOG" > "$PS/nft"
cat > "$PS/opec" <<STUB
#!/bin/bash
echo "opec \$*" >> "$PSLOG"
if [[ "\$1" == check-node-secret ]]; then [[ -n "\${OPEC_CHECK_FAIL:-}" ]] && exit 1; exit 0; fi
if [[ "\$1" == render ]]; then while [[ \$# -gt 0 ]]; do [[ "\$1" == --out ]] && : > "\$2"; shift; done; fi
exit 0
STUB
chmod +x "$PS/nft" "$PS/opec"
run_prestart() { # extra env...; uses a fresh prefix in $PSETC
	: > "$PSLOG"
	env "$@" ALLOW_NONROOT=1 PREFIX_ETC="$PSETC" PREFIX_LIB="$T/no-such-lib" RELAY_LIB_DIR="$R" NFT="$PS/nft" OPEC="$PS/opec" \
		RELAY_HOSTNAME=relay.example.org EXTERNAL_IP=203.0.113.10 bash "$R/oxpulse-relay-prestart.sh" >"$PS/out" 2>&1
}
PSETC="$(mktemp -d "$T/ps-etc.XXXXXX")"
run_prestart && rc=0 || rc=$?
if [[ "$rc" -eq 0 ]] && grep -q '^opec render coturn ' "$PSLOG" && grep -q -- '--secret-file' "$PSLOG" && [[ -f "$PSETC/coturn.conf" ]]; then pass "prestart: all gates pass -> render runs"; else fail "prestart: all gates pass -> render runs (rc=$rc): $(cat "$PS/out")"; fi
PSETC="$(mktemp -d "$T/ps-etc.XXXXXX")"
run_prestart NFT_FAIL=1 && rc=0 || rc=$?
if [[ "$rc" -ne 0 ]] && ! grep -q '^opec render' "$PSLOG" && [[ ! -e "$PSETC/coturn.conf" ]]; then pass "prestart: missing guard table -> fails, no render"; else fail "prestart: missing guard table -> fails, no render (rc=$rc)"; fi
PSETC="$(mktemp -d "$T/ps-etc.XXXXXX")"; echo '{}' > "$PSETC/node-config.json"
run_prestart && rc=0 || rc=$?
if [[ "$rc" -ne 0 ]] && ! grep -q '^opec render' "$PSLOG" && [[ ! -e "$PSETC/coturn.conf" ]]; then pass "prestart: forbidden file -> fails, no render"; else fail "prestart: forbidden file -> fails, no render (rc=$rc)"; fi
PSETC="$(mktemp -d "$T/ps-etc.XXXXXX")"
run_prestart OPEC_CHECK_FAIL=1 && rc=0 || rc=$?
if [[ "$rc" -ne 0 ]] && grep -q '^opec check-node-secret' "$PSLOG" && ! grep -q '^opec render' "$PSLOG" && [[ ! -e "$PSETC/coturn.conf" ]]; then pass "prestart: invalid node-secret -> fails, no render"; else fail "prestart: invalid node-secret -> fails, no render (rc=$rc)"; fi

# --- apply: reset-failed precedes restart; gate and secret check precede both ---
AP="$T/ap"; mkdir -p "$AP"; APLOG="$AP/calls.log"
for c in systemctl sleep; do printf '#!/bin/bash\necho "%s $*" >> "%s"\nexit 0\n' "$c" "$APLOG" > "$AP/$c"; chmod +x "$AP/$c"; done
printf '#!/bin/bash\necho "opec $*" >> "%s"\nexit 0\n' "$APLOG" > "$AP/opec"; chmod +x "$AP/opec"
printf '%s\n' "$S1" > "$AP/node-secret"; chmod 600 "$AP/node-secret"
: > "$APLOG"
PATH="$AP:$PATH" ALLOW_NONROOT=1 PREFIX_ETC="$AP" PREFIX_LIB="$T/no-such-lib" RELAY_LIB_DIR="$R" OPEC="$AP/opec" bash "$R/oxpulse-relay-apply.sh" >"$AP/out" 2>&1 && rc=0 || rc=$?
rf=$(grep -n -m1 'reset-failed oxpulse-relay-coturn' "$APLOG" | cut -d: -f1); rs=$(grep -n -m1 'systemctl restart oxpulse-relay-coturn' "$APLOG" | cut -d: -f1)
ck=$(grep -n -m1 '^opec check-node-secret' "$APLOG" | cut -d: -f1)
if [[ "$rc" -eq 0 && -n "$rf" && -n "$rs" && -n "$ck" && "$ck" -lt "$rf" && "$rf" -lt "$rs" ]]; then pass "apply: check-node-secret -> reset-failed -> restart"; else fail "apply order (rc=$rc ck=$ck rf=$rf rs=$rs): $(cat "$AP/out")"; fi
[[ "$(<"$AP/out")" != *"$S1"* ]] && pass "apply never prints the secret" || fail "apply never prints the secret"

# --- reverse guard: the full-edge scripts refuse on a relay node ---
mkdir -p "$T/rev"; : > "$T/rev/relay.env"
for sc in install.sh upgrade.sh; do
	if out="$(OXPULSE_PREFIX_ETC="$T/rev" bash "$REPO_ROOT/$sc" 2>&1)"; then rc=0; else rc=$?; fi
	[[ "$rc" -eq 1 && "$out" == *"relay-only node"* ]] && pass "reverse guard: $sc refuses on a relay node" || fail "reverse guard: $sc refuses on a relay node (rc=$rc): $(head -c 300 <<<"$out")"
done

echo ""
echo "relay profile: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
