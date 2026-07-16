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

# docker mock: `docker network inspect <net> --format '{{.Id}}...{{.Subnet}}'`
# returns "<network-id> <subnet>". Tests the dynamic derivation for the SFU
# client WS (:8920) local-bridge allow rule (subnet 172.18.0.0/16, bridge iface
# br-<id[:12]> = br-abcdef012345). Default: network present.
cat >"$TMP/mocks/docker" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "network" ] && [ "$2" = "inspect" ]; then
	printf 'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789 172.18.0.0/16\n'
	exit 0
fi
echo "docker $*"
EOF
chmod +x "$TMP/mocks/docker"

# iptables mock: _firewall_purge_rogue_rejects calls `iptables -L INPUT
# --line-numbers -n` to find rogue REJECT/DROP rules before the UFW chain.
# In CI (no root, no CAP_NET_ADMIN) the real iptables fails with permission
# denied — and under `set -euo pipefail` the grep-in-pipeline aborts the
# test. Mock returns an empty INPUT chain (no rogue rules → purge is a no-op).
cat >"$TMP/mocks/iptables" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
	"-L INPUT") echo "Chain INPUT (policy ACCEPT)" ;;
	*) echo "iptables $*" ;;
esac
EOF
chmod +x "$TMP/mocks/iptables"

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
# SFU client WS (:8920): allowed ONLY from the dynamically-derived docker edge
# bridge — bound to BOTH the bridge INTERFACE (br-<id[:12]>) and the source
# subnet (correct-by-construction; cannot match public-NIC traffic), never as a
# public port.
grep -q "ufw allow in on br-abcdef012345 from 172.18.0.0/16 to any port 8920 proto tcp" "$TMP/calls.log" || { echo "FAIL test1: sfu-ws 8920 must be interface+subnet scoped (in on br-<id>)"; cat "$TMP/calls.log"; exit 1; }
grep -qE "ufw allow 8920/(tcp|udp)"                                              "$TMP/calls.log" && { echo "FAIL test1: 8920 must NOT be a public allow"; cat "$TMP/calls.log"; exit 1; }
grep -qE "ufw allow from [0-9.]+/[0-9]+ to any port 8920"                        "$TMP/calls.log" && { echo "FAIL test1: 8920 must be interface-scoped, not source-only, on the docker-derived path"; cat "$TMP/calls.log"; exit 1; }
grep -q "ufw --force enable"                                                     "$TMP/calls.log" || { echo "FAIL test1: enable"; exit 1; }
echo "[ok] test1: ufw whitelist applied with awg=44321 (8920 interface+subnet scoped)"

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
grep -q "firewall-cmd --permanent --zone=public --remove-port=8920/tcp"          "$TMP/calls.log" || { echo "FAIL test2: strip public 8920"; exit 1; }
grep -q "firewall-cmd --permanent --zone=public --add-rich-rule rule family=ipv4 source address=172.18.0.0/16 port port=8920 protocol=tcp accept" \
                                                                                     "$TMP/calls.log" || { echo "FAIL test2: sfu-ws local-bridge 8920 rich rule"; cat "$TMP/calls.log"; exit 1; }
grep -q "firewall-cmd --permanent --zone=public --add-port=8920/tcp"             "$TMP/calls.log" && { echo "FAIL test2: 8920 must NOT be a public add-port"; cat "$TMP/calls.log"; exit 1; }
grep -q "firewall-cmd --reload"                                                  "$TMP/calls.log" || { echo "FAIL test2: reload"; exit 1; }
echo "[ok] test2: firewalld whitelist applied with awg=44322 (8920 local-bridge only)"

# ── Test 3: no firewall tool → warn + FAIL-LOUD (distinct rc=2), no commands ──
# t14 fail-loud contract (lib/install-firewall.sh none|*) branch): this path
# applies NOTHING, so it MUST report a distinct non-zero (2), not success.
# The old `return 0` here silently no-op'd — reconcile_firewall_surface's
# `firewall_apply || warn` never fired and the converge cycle logged green with
# _RECONCILE_FIREWALL_APPLIED=1 while the SFU mesh-only ports (:9317,:8912) and
# the public whitelist stayed unenforced on any distro without ufw/firewalld.
# The escalation on that rc is reconcile.sh's job, covered by
# tests/test_reconcile_firewall_unsupported.sh; here we pin install-firewall.sh's
# own exit-code contract. NOTE: the bare call must capture rc — under this
# file's `set -e`, an unguarded `firewall_apply` on this branch aborts the
# whole test (which is exactly the pre-fix false-negative this assertion fixes).
: >"$TMP/calls.log"
_firewall_detect_tool() { printf 'none'; }

_rc=0
AWG_LISTEN_PORT=44323 firewall_apply || _rc=$?
[ "$_rc" -eq 2 ] || { echo "FAIL test3: no-tool path must return distinct non-zero 2 (t14 fail-loud), got rc=$_rc"; cat "$TMP/calls.log"; exit 1; }
grep -q "no supported firewall tool" "$TMP/calls.log" || { echo "FAIL test3: warn missing"; cat "$TMP/calls.log"; exit 1; }
# Each tool-mock writes its own argv on a line starting with the tool name.
# Real invocations look like 'ufw allow 22/tcp' or 'firewall-cmd --permanent ...'.
grep -E '^ufw |^firewall-cmd ' "$TMP/calls.log" >/dev/null && { echo "FAIL test3: should NOT have invoked any firewall tool"; cat "$TMP/calls.log"; exit 1; }
echo "[ok] test3: missing-firewall path returns rc=2, warns, runs no commands"

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

# ── Test 5: edge network not up yet (first install, pre-`docker compose up`) ──
# The edge bridge is created by the FIRST `docker compose up`, which install.sh
# runs AFTER firewall_apply. So on a fresh install `docker network inspect`
# fails: the 8920 rule must be silently skipped WITHOUT failing firewall_apply
# (the public + mesh rules must still apply, and the exit code must be success).
# reconcile_firewall_surface re-runs firewall_apply every converge and adds the
# 8920 rule once the network exists — this proves the graceful-degrade half.
: >"$TMP/calls.log"
_firewall_detect_tool() { printf 'ufw'; }
cat >"$TMP/mocks/docker" <<'EOF'
#!/usr/bin/env bash
# Network not created yet: inspect fails, no output.
[ "$1" = "network" ] && [ "$2" = "inspect" ] && exit 1
echo "docker $*"
EOF
chmod +x "$TMP/mocks/docker"

_rc=0
AWG_LISTEN_PORT=44324 firewall_apply || _rc=$?
[ "$_rc" -eq 0 ]                                                                 || { echo "FAIL test5: firewall_apply must succeed even with edge net absent, got rc=$_rc"; cat "$TMP/calls.log"; exit 1; }
grep -q "ufw allow from 10.9.0.0/24 to any port 9317 proto tcp"                  "$TMP/calls.log" || { echo "FAIL test5: mesh rules must still apply"; exit 1; }
grep -q "ufw --force enable"                                                     "$TMP/calls.log" || { echo "FAIL test5: enable must still run"; exit 1; }
grep -q "to any port 8920 proto tcp"                                             "$TMP/calls.log" && { echo "FAIL test5: no 8920 rule expected when edge net absent"; cat "$TMP/calls.log"; exit 1; }
# MAJOR-2: docker present but resolver empty → a WARN breadcrumb must be logged so
# a converged node with a vanished 8920 rule is diagnosable (not a silent gap).
grep -q "SFU WS local-path rule (:8920) NOT applied"                             "$TMP/calls.log" || { echo "FAIL test5: missing warn breadcrumb for skipped 8920 rule"; cat "$TMP/calls.log"; exit 1; }
echo "[ok] test5: edge net absent → 8920 rule skipped + WARN logged, firewall still applied"

# ── Test 6: PE_FW_EDGE_SUBNETS override seam — multi-subnet + RFC1918 gate ────
# The override seam (deterministic subnets, or a node with >1 edge subnet) emits
# one source-only rule per VALID PRIVATE CIDR (iface unknown on this path) and
# MUST drop junk AND any non-RFC1918 CIDR — an operator fat-fingering 0.0.0.0/0
# can never open :8920 to the world (MINOR-2 security gate).
: >"$TMP/calls.log"
_firewall_detect_tool() { printf 'ufw'; }
PE_FW_EDGE_SUBNETS="172.19.0.0/16 10.10.0.0/24 0.0.0.0/0 8.8.8.0/24 not-a-cidr" \
	AWG_LISTEN_PORT=44325 firewall_apply
grep -q "ufw allow from 172.19.0.0/16 to any port 8920 proto tcp"               "$TMP/calls.log" || { echo "FAIL test6: private subnet 1"; cat "$TMP/calls.log"; exit 1; }
grep -q "ufw allow from 10.10.0.0/24 to any port 8920 proto tcp"                "$TMP/calls.log" || { echo "FAIL test6: private subnet 2"; exit 1; }
grep -q "0.0.0.0/0"                                                             "$TMP/calls.log" && { echo "FAIL test6: 0.0.0.0/0 must be REJECTED by the RFC1918 gate"; cat "$TMP/calls.log"; exit 1; }
grep -q "8.8.8.0/24"                                                            "$TMP/calls.log" && { echo "FAIL test6: public CIDR must be REJECTED by the RFC1918 gate"; cat "$TMP/calls.log"; exit 1; }
grep -q "not-a-cidr"                                                             "$TMP/calls.log" && { echo "FAIL test6: junk token must be filtered out"; cat "$TMP/calls.log"; exit 1; }
echo "[ok] test6: PE_FW_EDGE_SUBNETS override → one rule per valid PRIVATE CIDR, public/junk rejected"

echo "[ok] all firewall-module tests passed"
