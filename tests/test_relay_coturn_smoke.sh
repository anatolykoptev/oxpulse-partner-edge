#!/usr/bin/env bash
# tests/test_relay_coturn_smoke.sh — run the REAL static turnserver with the REAL
# relay template and prove what the unit tests cannot:
#   1. it starts on the rendered template with no "Bad configuration" (every key is
#      valid for the shipped coturn; 4.18 rejects the removed no-dtls / no-tlsv1*),
#   2. a TURN Allocate over turnutils_uclient succeeds,
#   3. permission to 127.0.0.1 and to ::ffff:127.0.0.1 is REFUSED because of the
#      template's denied-peer-ip lines (a control server with those lines removed
#      accepts the same request, so the refusal is not coturn's built-in loopback
#      check, which is switched off for the pair via allow-loopback-peers),
#   4. TURNS serves TLS 1.2 on the template's cipher list, DTLS and the CLI are off.
#
#   RELAY_COTURN_BIN_DIR=<dir with turnserver turnutils_uclient> [OPEC=<opec>] \
#       [RELAY_SMOKE_REQUIRE_IPV6=1] bash tests/test_relay_coturn_smoke.sh
# Without RELAY_COTURN_BIN_DIR it SKIPs (exit 0): the binaries come from the
# static build (relay/coturn-static/Dockerfile), run by CI and the release workflow.
# With OPEC set the template is rendered by the real `opec render coturn`, the
# renderer the unit's ExecStartPre uses; otherwise by a plain substitution.
#
# Mutations that must turn this RED (stated as the edit):
#   * relay/coturn-relay.conf.tpl: re-add `no-dtls` -> "starts with no Bad configuration".
#   * relay/coturn-relay.conf.tpl: delete `denied-peer-ip=127.0.0.0-127.255.255.255`
#     -> "CreatePermission to 127.0.0.1 is refused".
# (The `::ffff:0.0.0.0-::ffff:255.255.255.255` line is NOT a mutation target: coturn
# 4.13+ canonicalises an IPv4-mapped peer to IPv4 before the range check, so
# ::ffff:127.0.0.1 is refused by the 127.0.0.0/8 line and the mapped line is redundant
# on 4.18. It stays for 4.6.x, where it is load-bearing.)
set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TPL="${RELAY_TEMPLATE:-$REPO_ROOT/relay/coturn-relay.conf.tpl}"
BIN="${RELAY_COTURN_BIN_DIR:-}"
[[ -n "$BIN" ]] || { echo "SKIP: RELAY_COTURN_BIN_DIR not set (static build not available)"; exit 0; }
for b in turnserver turnutils_uclient; do [[ -x "$BIN/$b" ]] || { echo "FAIL: $BIN/$b missing"; exit 1; }; done
for c in openssl python3 ss; do command -v "$c" >/dev/null || { echo "SKIP: $c not available"; exit 0; }; done

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

T="$(mktemp -d)"
cleanup() { local f; for f in "$T"/*.pid; do [[ -f "$f" ]] && kill "$(cat "$f")" 2>/dev/null; done; sleep 1; rm -rf "$T"; }
trap cleanup EXIT

BASE="${RELAY_SMOKE_PORT:-$((24000 + RANDOM % 2000 * 2))}"   # A: BASE/BASE+1, control: BASE+10/BASE+11
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$T/key.pem" -out "$T/cert.pem" \
	-days 2 -subj /CN=relay.example.org -addext subjectAltName=DNS:relay.example.org 2>/dev/null
head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n' > "$T/secret"; printf '\n' >> "$T/secret"; chmod 600 "$T/secret"

# --- render the template ------------------------------------------------------
if [[ -n "${OPEC:-}" ]]; then
	RELAY_HOSTNAME=relay.example.org EXTERNAL_IP=127.0.0.1 "$OPEC" render coturn --tpl "$TPL" --out "$T/rendered.conf" --secret-file "$T/secret" \
		&& pass "template renders with opec" || { fail "template renders with opec"; exit 1; }
else
	python3 - "$TPL" "$T/secret" "$T/rendered.conf" <<'PY'
import sys
tpl, sec, out = sys.argv[1:4]
s = open(tpl).read().replace("{{EXTERNAL_IP}}", "127.0.0.1").replace("{{RELAY_HOSTNAME}}", "relay.example.org")
lines = "".join("static-auth-secret=%s\n" % l.strip() for l in open(sec) if l.strip())
open(out, "w").write(s.replace("{{STATIC_AUTH_SECRET_LINES}}", lines.rstrip("\n")))
PY
	echo "NOTE: rendered by substitution (no OPEC given)"
fi

# --- test config: only the host plumbing changes, never the policy ---------------
mkconf() { # name port with_denied
	local n="$1" p="$2" d="$3" f="$T/$1.conf"
	sed -e "s/^listening-port=.*/listening-port=$p/" -e "s/^tls-listening-port=.*/tls-listening-port=$((p+1))/" \
		-e "s#^cert=.*#cert=$T/cert.pem#" -e "s#^pkey=.*#pkey=$T/key.pem#" \
		-e '/^syslog$/d' -e '/^no-stdout-log$/d' -e '/^simple-log$/d' "$T/rendered.conf" > "$f"
	[[ "$d" == 1 ]] || sed -i '/^denied-peer-ip=/d' "$f"
	# allow-loopback-peers switches OFF coturn's built-in loopback refusal for BOTH servers,
	# so what remains between them is exactly the template's denied-peer-ip lines.
	printf 'log-file=%s/%s.log\npidfile=%s/%s.pid\nlistening-ip=127.0.0.1\nrelay-ip=127.0.0.1\nallow-loopback-peers\n' "$T" "$n" "$T" "$n" >> "$f"
	if ip -6 addr show lo 2>/dev/null | grep '::1' >/dev/null; then printf 'listening-ip=::1\nrelay-ip=::1\n' >> "$f"; V6=1; fi
}
V6=0
mkconf A "$BASE" 1
mkconf C "$((BASE+10))" 0
for n in A C; do ( "$BIN/turnserver" -c "$T/$n.conf" >"$T/$n.stdout" 2>&1 & ); done
up=0
for _ in $(seq 1 80); do
	if ss -lnt | grep "127.0.0.1:${BASE} " >/dev/null && ss -lnt | grep "127.0.0.1:$((BASE+10)) " >/dev/null; then up=1; break; fi
	sleep 0.5
done
if [[ "$up" == 1 ]] && ! grep -qiE 'bad configuration|unrecognized option|unknown option' "$T"/A.stdout "$T"/A*.log 2>/dev/null; then
	pass "starts with no Bad configuration and listens on the template ports"
else
	fail "starts with no Bad configuration and listens on the template ports: $(sed -n 1,5p "$T/A.stdout"; grep -hiE 'bad config|error' "$T"/A*.log 2>/dev/null | sed -n 1,5p)"
	echo "relay coturn smoke: PASS=$PASS FAIL=$FAIL"; exit 1
fi
ss -lnt | grep ':5766 ' >/dev/null && fail "no CLI listener (5766)" || pass "no CLI listener (5766)"
grep -q 'DTLS listeners are not started' "$T"/A*.log && pass "DTLS stays off (4.18 needs --dtls)" || fail "DTLS stays off"

# --- allocate + permission checks -----------------------------------------------------
user="$(( $(date +%s) + 600 )):smoke"
pass_="$(K="$(head -n1 "$T/secret")" python3 -c 'import hmac,hashlib,os,sys,base64; print(base64.b64encode(hmac.new(os.environb[b"K"], sys.argv[1].encode(), hashlib.sha1).digest()).decode())' "$user")"
uc() { # port host peer [extra flags]  -> output in $OUT, rc in $RC
	local port="$1" host="$2" peer="$3"; shift 3
	OUT="$(timeout 60 "$BIN/turnutils_uclient" -v -u "$user" -w "$pass_" -p "$port" -n 3 -c "$@" -e "$peer" "$host" 2>&1)"; RC=$?
}
refused() { [[ "$RC" -ne 0 && "$OUT" == *"clnet_allocate: rtv=0"* && "$OUT" == *"channel bind: error 403"* ]]; }
accepted() { [[ "$RC" -eq 0 && "$OUT" == *"clnet_allocate: rtv=0"* && "$OUT" != *"error 403"* ]]; }

uc "$BASE" 127.0.0.1 127.0.0.1
[[ "$OUT" == *"clnet_allocate: rtv=0"* ]] && pass "Allocate over turnutils_uclient succeeds" || fail "Allocate over turnutils_uclient succeeds: $(tail -3 <<<"$OUT")"
refused && pass "CreatePermission to 127.0.0.1 is refused (denied-peer-ip)" || fail "CreatePermission to 127.0.0.1 is refused: rc=$RC $(tail -2 <<<"$OUT")"
uc "$((BASE+10))" 127.0.0.1 127.0.0.1
accepted && pass "control: the same request is accepted once denied-peer-ip is removed (refusal is the template's)" || fail "control accepts 127.0.0.1: rc=$RC $(tail -2 <<<"$OUT")"

if [[ "$V6" == 1 ]]; then
	uc "$BASE" ::1 ::ffff:127.0.0.1 -x
	refused && pass "CreatePermission to ::ffff:127.0.0.1 is refused (IPv4-mapped deny)" || fail "CreatePermission to ::ffff:127.0.0.1 is refused: rc=$RC $(tail -2 <<<"$OUT")"
	uc "$((BASE+10))" ::1 ::ffff:127.0.0.1 -x
	accepted && pass "control: ::ffff:127.0.0.1 is accepted once denied-peer-ip is removed" || fail "control accepts ::ffff:127.0.0.1: rc=$RC $(tail -2 <<<"$OUT")"
	uc "$BASE" ::1 64:ff9b::7f00:1 -x
	refused && pass "CreatePermission to NAT64 64:ff9b::7f00:1 is refused" || fail "NAT64 refused: rc=$RC $(tail -2 <<<"$OUT")"
	uc "$((BASE+10))" ::1 64:ff9b::7f00:1 -x
	accepted && pass "control: NAT64 is accepted once denied-peer-ip is removed" || fail "control accepts NAT64: rc=$RC $(tail -2 <<<"$OUT")"
elif [[ "${RELAY_SMOKE_REQUIRE_IPV6:-0}" == 1 ]]; then
	fail "IPv6 loopback unavailable but RELAY_SMOKE_REQUIRE_IPV6=1"
else
	echo "NOTE: no IPv6 loopback here; the ::ffff: and NAT64 checks are skipped"
fi

# --- TURNS: TLS 1.2 on the template's cipher list ---------------------------------------
if printf '' | timeout 15 openssl s_client -connect "127.0.0.1:$((BASE+1))" -servername relay.example.org -tls1_2 >"$T/tls.out" 2>&1 && grep -q 'Cipher is\|Cipher    :' "$T/tls.out"; then
	pass "TURNS completes a TLS 1.2 handshake on the template's cipher list"
else
	fail "TURNS TLS 1.2 handshake: $(tail -3 "$T/tls.out")"
fi

# --- legacy coturn (4.6.x): the prestart's legacy render keeps DTLS off ----------------------
# On coturn < 4.18 the ABSENCE of no-dtls switches a DTLS listener on (udp on the TLS
# port). oxpulse-relay-prestart renders the legacy lines for such a binary; here the
# same relay-lib.sh functions render for a real coturn 4.6.1 container and a control
# (4.18 form, no legacy lines) shows the UDP bind the lines are there to prevent.
if [[ "${RELAY_SMOKE_LEGACY:-0}" == 1 ]]; then
	if ! command -v docker >/dev/null; then fail "legacy: docker not available"; else
	LB=$((BASE+100)); LI="${RELAY_LEGACY_IMAGE:-coturn/coturn:4.6.1}"
	chmod 755 "$T"; chmod 644 "$T/cert.pem" "$T/key.pem"   # the container runs as nobody
	legacy_conf() { # name port with_legacy
		local f="$T/$1.conf"
		sed -e "s/^listening-port=.*/listening-port=$2/" -e "s/^tls-listening-port=.*/tls-listening-port=$(($2+5))/" \
			-e "s#^cert=.*#cert=$T/cert.pem#" -e "s#^pkey=.*#pkey=$T/key.pem#" \
			-e '/^syslog$/d' -e '/^no-stdout-log$/d' -e '/^simple-log$/d' "$T/rendered.conf" > "$f"
		# TLS port is port+5: port+1 is coturn's default alt-listening-port and 4.6.x refuses to bind both.
		printf 'log-file=stdout\nlistening-ip=127.0.0.1\nrelay-ip=127.0.0.1\n' >> "$f"
		if [[ "$3" == 1 ]]; then ( . "$REPO_ROOT/relay/relay-lib.sh"; relay_append_legacy_directives "$f" ); fi
		chmod 644 "$f"
	}
	legacy_conf L "$LB" 1; legacy_conf LC "$((LB+10))" 0
	for n in L LC; do
		docker run -d --rm --name "relay-smoke-$n-$BASE" --network host -v "$T:$T:ro" --entrypoint turnserver "$LI" -c "$T/$n.conf" >/dev/null 2>&1 || true
	done
	trap 'docker rm -f "relay-smoke-L-$BASE" "relay-smoke-LC-$BASE" >/dev/null 2>&1; cleanup' EXIT
	for _ in $(seq 1 120); do
		if ss -lnt | grep "127.0.0.1:$((LB+5)) " >/dev/null && ss -lnt | grep "127.0.0.1:$((LB+15)) " >/dev/null; then break; fi
		sleep 0.5
	done
	if ss -lnt | grep "127.0.0.1:$((LB+5)) " >/dev/null; then
		ss -lnu | grep ":$((LB+5)) " >/dev/null && fail "legacy 4.6.1 with the legacy render binds no UDP on the TLS port" || pass "legacy 4.6.1 with the legacy render binds no UDP on the TLS port"
		ss -lnu | grep ":$((LB+15)) " >/dev/null && pass "control: 4.6.1 WITHOUT the legacy lines does bind UDP on the TLS port (what they prevent)" || fail "control: 4.6.1 without the legacy lines binds UDP on the TLS port"
	else
		fail "legacy 4.6.1 container did not come up: $(docker logs "relay-smoke-L-$BASE" 2>&1 | tail -3) | listening: $(ss -lntu | grep -E ":$((LB))|:$((LB+5))" | tr -s ' ' | tr '\n' ';')"
	fi
	fi
fi

echo ""
echo "relay coturn smoke: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
