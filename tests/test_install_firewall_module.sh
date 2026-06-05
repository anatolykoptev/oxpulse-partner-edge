#!/usr/bin/env bash
# tests/test_install_firewall_module.sh — unit tests for lib/install-firewall.sh
#
# Mocks ufw, firewall-cmd, awg so the tests run without root or a firewall tool.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

log()  { printf '[log] %s\n' "$*" >>"$TMP/calls.log"; }
warn() { printf '[warn] %s\n' "$*" >>"$TMP/calls.log"; }
die()  { printf '[die] %s\n' "$*" >>"$TMP/calls.log"; exit 1; }

make_mock() {
	local bin="$1" out="$2"
	cat >"$TMP/mocks/$bin" <<EOF
#!/usr/bin/env bash
echo "$bin \$*" >>"$out"
EOF
	chmod +x "$TMP/mocks/$bin"
}

mkdir -p "$TMP/mocks"
make_mock ufw           "$TMP/calls.log"
make_mock firewall-cmd  "$TMP/calls.log"
make_mock apt-get       "$TMP/calls.log"
cat >"$TMP/mocks/awg" <<'EOF'
#!/usr/bin/env bash
case "$*" in
	"show awg0 listen-port") echo "44321" ;;
	*) echo "awg $*" ;;
esac
EOF
chmod +x "$TMP/mocks/awg"

PATH="$TMP/mocks:$PATH"
. "$REPO_ROOT/lib/install-firewall.sh"

# ── Test 1: ufw branch ───────────────────────────────────────────────────────
: >"$TMP/calls.log"
_firewall_detect_tool() { printf 'ufw'; }

AWG_LISTEN_PORT=44321 firewall_apply
grep -q "ufw default deny incoming"                                              "$TMP/calls.log" || { echo "FAIL test1: deny incoming"; cat "$TMP/calls.log"; exit 1; }
grep -q "ufw default allow outgoing"                                             "$TMP/calls.log" || { echo "FAIL test1: allow outgoing"; exit 1; }
grep -q "ufw allow 22/tcp"                                                       "$TMP/calls.log" || { echo "FAIL test1: ssh"; exit 1; }
grep -q "ufw allow 80/tcp"                                                       "$TMP/calls.log" || { echo "FAIL test1: 80/tcp"; exit 1; }
grep -q "ufw allow 443/tcp"                                                      "$TMP/calls.log" || { echo "FAIL test1: 443/tcp"; exit 1; }
grep -q "ufw allow 443/udp"                                                      "$TMP/calls.log" || { echo "FAIL test1: 443/udp (quic)"; exit 1; }
grep -q "ufw allow 7878/udp"                                                     "$TMP/calls.log" || { echo "FAIL test1: 7878/udp"; exit 1; }
grep -q "ufw allow 49152:65535/udp"                                              "$TMP/calls.log" || { echo "FAIL test1: relay range 49152:65535/udp"; exit 1; }
grep -q "ufw allow 18443/tcp"                                                    "$TMP/calls.log" || { echo "FAIL test1: 18443/tcp"; exit 1; }
grep -q "ufw allow 18443/udp"                                                    "$TMP/calls.log" || { echo "FAIL test1: 18443/udp"; exit 1; }
grep -q "ufw allow 44321/udp"                                                    "$TMP/calls.log" || { echo "FAIL test1: AWG port"; exit 1; }
grep -q "ufw allow from 10.9.0.0/24 to any port 9317 proto tcp"                  "$TMP/calls.log" || { echo "FAIL test1: mesh 9317"; exit 1; }
grep -q "ufw allow from 10.9.0.0/24 to any port 8912 proto tcp"                  "$TMP/calls.log" || { echo "FAIL test1: mesh 8912"; exit 1; }
grep -q "ufw --force enable"                                                     "$TMP/calls.log" || { echo "FAIL test1: enable"; exit 1; }
echo "[ok] test1: ufw whitelist applied with awg=44321"

# ── Test 2: firewalld branch ─────────────────────────────────────────────────
: >"$TMP/calls.log"
_firewall_detect_tool() { printf 'firewalld'; }

AWG_LISTEN_PORT=44322 firewall_apply
grep -q "firewall-cmd --permanent --zone=public --add-service=ssh"               "$TMP/calls.log" || { echo "FAIL test2: ssh"; cat "$TMP/calls.log"; exit 1; }
grep -q "firewall-cmd --permanent --zone=public --add-port=443/tcp"              "$TMP/calls.log" || { echo "FAIL test2: 443/tcp"; exit 1; }
grep -q "firewall-cmd --permanent --zone=public --add-port=443/udp"              "$TMP/calls.log" || { echo "FAIL test2: 443/udp"; exit 1; }
grep -q "firewall-cmd --permanent --zone=public --add-port=49152-65535/udp"      "$TMP/calls.log" || { echo "FAIL test2: relay range 49152-65535/udp"; exit 1; }
grep -q "firewall-cmd --permanent --zone=public --add-port=44322/udp"            "$TMP/calls.log" || { echo "FAIL test2: AWG port"; exit 1; }
grep -q "firewall-cmd --permanent --zone=public --remove-port=9317/tcp"          "$TMP/calls.log" || { echo "FAIL test2: strip 9317"; exit 1; }
grep -q "firewall-cmd --permanent --zone=public --add-rich-rule rule family=ipv4 source address=10.9.0.0/24 port port=9317 protocol=tcp accept" \
                                                                                     "$TMP/calls.log" || { echo "FAIL test2: mesh 9317"; exit 1; }
grep -q "firewall-cmd --reload"                                                  "$TMP/calls.log" || { echo "FAIL test2: reload"; exit 1; }
echo "[ok] test2: firewalld whitelist applied with awg=44322"

# ── Test 3: no firewall tool → warn, no commands executed ────────────────────
: >"$TMP/calls.log"
_firewall_detect_tool() { printf 'none'; }

AWG_LISTEN_PORT=44323 firewall_apply
grep -q "no supported firewall tool" "$TMP/calls.log" || { echo "FAIL test3: warn missing"; cat "$TMP/calls.log"; exit 1; }
# Each tool-mock writes its own argv on a line starting with the tool name.
# Real invocations look like 'ufw allow 22/tcp' or 'firewall-cmd --permanent ...'.
grep -E '^ufw |^firewall-cmd ' "$TMP/calls.log" >/dev/null && { echo "FAIL test3: should NOT have invoked any firewall tool"; cat "$TMP/calls.log"; exit 1; }
echo "[ok] test3: missing-firewall path warns and runs no commands"

# ── Test 4: missing AWG_LISTEN_PORT + no awg0 → skip with warn ───────────────
: >"$TMP/calls.log"
_firewall_detect_tool() { printf 'ufw'; }
cat >"$TMP/mocks/awg" <<'EOF'
#!/usr/bin/env bash
echo "awg $*"
EOF
chmod +x "$TMP/mocks/awg"

unset AWG_LISTEN_PORT
firewall_apply
grep -q "cannot resolve AWG listen port" "$TMP/calls.log" || { echo "FAIL test4: skip warn"; cat "$TMP/calls.log"; exit 1; }
grep -E '^ufw ' "$TMP/calls.log" >/dev/null && { echo "FAIL test4: should NOT have run ufw"; exit 1; }
echo "[ok] test4: missing AWG port → skip without lock-out"

echo "[ok] all firewall-module tests passed"
