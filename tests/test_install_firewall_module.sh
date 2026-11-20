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
# ufw mock: logs every call AND keeps a tiny ruleset so `ufw show added` (the
# independent read-back the SSH-coverage hard stop uses) reflects what was really
# added. UFW_DROP_RULE="1987/tcp" simulates an `allow` that silently did not land.
cat >"$TMP/mocks/ufw" <<EOF
#!/usr/bin/env bash
echo "ufw \$*" >>"$TMP/calls.log"
case "\$1" in
	reset) : >"$TMP/ufw.rules" ;;
	allow) if [[ "\${UFW_FAIL_RULE:-}" == "\$2" ]]; then echo "ufw \$*" >>"$TMP/ufw.rules"; exit 1; fi   # fails AFTER recording: only the rc check can catch it
	       [[ "\${UFW_DROP_RULE:-}" == "\$2" ]] || echo "ufw \$*" >>"$TMP/ufw.rules" ;;
	# ufw translates its status: under any locale but C the word is not "active".
	status) if [[ -n "\${UFW_STATUS_ACTIVE:-}" ]]; then [[ "\${LC_ALL:-}" == C ]] && echo "Status: active" || echo "Statut : actif"; else echo "Status: inactive"; fi ;;
	show) [[ "\$2" == added ]] && { echo "Added user rules (see 'ufw status' for running firewall):"; cat "$TMP/ufw.rules" 2>/dev/null || true; } ;;
esac
exit 0
EOF
chmod +x "$TMP/mocks/ufw"
# Hermetic ssh detection: sshd -T / ss read from per-test files (default: port 22).
printf 'port 22\n' >"$TMP/sshd_T"; : >"$TMP/ss_out"
cat >"$TMP/mocks/sshd" <<EOF
#!/usr/bin/env bash
[[ -s "$TMP/sshd_fail" ]] && exit 1
cat "$TMP/sshd_T"
EOF
cat >"$TMP/mocks/ss" <<EOF
#!/usr/bin/env bash
[[ -s "$TMP/ss_fail" ]] && exit 1
cat "$TMP/ss_out"
EOF
# systemctl mock: socket unit active iff $TMP/sock_<unit>.active is non-empty;
# `show -p Listen <unit>` prints $TMP/sock_<unit>.listen.
cat >"$TMP/mocks/systemctl" <<EOF
#!/usr/bin/env bash
unit="\${@: -1}"
case "\$1" in
	is-active) [[ -s "$TMP/sock_\$unit.active" ]] ;;
	show) cat "$TMP/sock_\$unit.listen" 2>/dev/null || true ;;
esac
EOF
chmod +x "$TMP/mocks/systemctl"
# dpkg-query mock: package named in $TMP/pkg_installed (if any) reports installed.
cat >"$TMP/mocks/dpkg-query" <<EOF
#!/usr/bin/env bash
pkg="\${@: -1}"
[[ -s "$TMP/pkg_installed" ]] && grep -qx "\$pkg" "$TMP/pkg_installed" && printf 'install ok installed'
exit 0
EOF
chmod +x "$TMP/mocks/sshd" "$TMP/mocks/ss" "$TMP/mocks/dpkg-query"
export PE_FW_RULES_V4="$TMP/rules.v4" PE_FW_RULES_V6="$TMP/rules.v6"   # never read the real host's rules
unset SSH_CONNECTION
FWS="$TMP/fws"; mkdir -p "$FWS"
make_fwcmd_mock() {
cat >"$TMP/mocks/firewall-cmd" <<EOF
#!/usr/bin/env bash
scope=run; for a in "\$@"; do [[ "\$a" == --permanent ]] && scope=perm; done
echo "firewall-cmd \$*" >>"$TMP/calls.log"
f="$FWS/\$scope"; touch "\$f"
for a in "\$@"; do case "\$a" in
  --add-port=*)    p=\${a#*=}; grep -qxF "\$p" "\$f" || echo "\$p" >> "\$f" ;;
  --add-service=*) echo "\${a#*=}" >> "\$f.svc" ;;
  --list-ports)    cat "\$f" ;;
  --list-services) cat "\$f.svc" 2>/dev/null ;;
  --remove-port=*) p=\${a#*=}; grep -vxF "\$p" "\$f" > "\$f.n" || true; mv "\$f.n" "\$f" ;;
esac; done
exit 0
EOF
chmod +x "$TMP/mocks/firewall-cmd"
}
make_fwcmd_mock
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
grep -q "ufw allow 49152:49999/udp"                                              "$TMP/calls.log" || { echo "FAIL test1: relay range 49152:49999/udp"; exit 1; }
# 18443 was the hysteria2 (CH3) forwarder, retired: it must no longer be opened.
grep -q "18443" "$TMP/calls.log" && { echo "FAIL test1: 18443 must not be allowed (CH3 retired)"; cat "$TMP/calls.log"; exit 1; }
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
grep -q "firewall-cmd --permanent --zone=public --add-port=49152-49999/udp"      "$TMP/calls.log" || { echo "FAIL test2: relay range 49152-49999/udp"; exit 1; }
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

# ── Test 2b: firewalld node that still has the retired :18443 ───────────────
# Older releases opened 18443 tcp+udp; add-port never removes, so the converge
# must. Stateful stub: --permanent and runtime state in separate files.
printf '%s\n' 18443/tcp 18443/udp 9999/tcp 443/tcp > "$FWS/perm"
cp "$FWS/perm" "$FWS/run"
make_fwcmd_mock
: >"$TMP/calls.log"
AWG_LISTEN_PORT=44322 firewall_apply >"$TMP/fw.out" 2>&1
for sc in perm run; do
	if [ "$sc" = perm ]; then
		grep -q '18443' "$FWS/perm" && { echo "FAIL test2b: 18443 still in permanent config"; cat "$FWS/perm"; exit 1; }
	fi
done
grep -q '18443' "$FWS/run" && { echo "FAIL test2b: 18443 still in runtime config"; cat "$FWS/run"; exit 1; }
grep -qxF 9999/tcp "$FWS/perm" && grep -qxF 9999/tcp "$FWS/run" || { echo "FAIL test2b: unrelated port 9999/tcp was touched"; exit 1; }
for want in 443/tcp 3478/tcp 5349/udp 7878/udp; do
	grep -qxF "$want" "$FWS/perm" || { echo "FAIL test2b: expected $want in permanent config"; cat "$FWS/perm"; exit 1; }
done
# idempotent + silent: a second converge on the now-clean node prints nothing.
AWG_LISTEN_PORT=44322 firewall_apply >"$TMP/fw.out" 2>&1
grep -q '18443' "$TMP/fw.out" && { echo "FAIL test2b: second run mentions 18443"; exit 1; }
echo "[ok] test2b: firewalld converge removes retired 18443 (permanent+runtime), leaves other ports"
# restore the call-logging mock for later tests
FWS="$TMP/fws"; for _f in perm run perm.svc run.svc; do : >"$FWS/$_f"; done; make_fwcmd_mock

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

# ── Test 7: firewalld rich rules for UDP MUST NOT use source-only scoping ────
# Regression guard for #436: the firewalld path for SFU client WS (:8920)
# uses source-subnet-scoped rich rules (cannot match ingress interface).
# This is safe for TCP (no return path for spoofer) but NOT for UDP.
# Structural test: no firewalld rich rule in firewall-lib.sh should use
# protocol=udp with source-only scoping (no interface/zone restriction).
if grep -q "protocol=udp" "$REPO_ROOT/lib/firewall-lib.sh" 2>/dev/null; then
	echo "FAIL test7: firewall-lib.sh has UDP rich rule (source-only scoping is spoofable for UDP)"
	exit 1
fi
echo "[ok] test7: no UDP rich rules in firewall-lib.sh (source-only scoping is spoofable for UDP)"

# ── SSH port detection / takeover guard / stable bridge (2026-11-20 incident) ──
# A host whose sshd listens only on 1987 was locked out at reboot because the
# installer hardcoded `ufw allow 22/tcp`; its operator iptables rules were
# discarded by the ufw takeover; and the :8920 rule pinned a bridge name that
# changes whenever the docker network is recreated.
t_reset() {
	: >"$TMP/calls.log"; : >"$TMP/ufw.rules"; : >"$TMP/ss_out"
	: >"$TMP/sshd_fail"; : >"$TMP/ss_fail"; : >"$TMP/pkg_installed"; : >"$TMP/rules.v4"; : >"$TMP/rules.v6"
	local _u; for _u in ssh.socket sshd.socket; do : >"$TMP/sock_$_u.active"; : >"$TMP/sock_$_u.listen"; done
	printf 'port 22\n' >"$TMP/sshd_T"
	unset PE_SSH_PORTS PE_FIREWALL_TAKEOVER UFW_DROP_RULE UFW_FAIL_RULE UFW_STATUS_ACTIVE DOCKER_BRIDGE_OPT SSH_CONNECTION
	_firewall_detect_tool() { printf 'ufw'; }
	t_dock
}
# docker mock: DOCKER_BRIDGE_OPT = value of the bridge.name option ("" = legacy
# network); $TMP/net_row = "<id> <subnet>"; no row → network absent.
t_dock() {
	cat >"$TMP/mocks/docker" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "network" ] && [ "\$2" = "inspect" ]; then
	[ -s "$TMP/net_row" ] || exit 1
	case "\$*" in
		*'index .Options'*) echo "\${DOCKER_BRIDGE_OPT:-}" ;;
		*) cat "$TMP/net_row" ;;
	esac
	exit 0
fi
EOF
	chmod +x "$TMP/mocks/docker"
}
: >"$TMP/net_row"
t_apply() { _rc=0; AWG_LISTEN_PORT=44330 firewall_apply >/dev/null 2>&1 || _rc=$?; }

# Test 8: sshd on 1987 only → 1987/tcp allowed, 22 NOT opened
t_reset; printf 'port 1987\n' >"$TMP/sshd_T"; t_apply
[ "$_rc" -eq 0 ]                                 || { echo "FAIL test8: rc=$_rc"; cat "$TMP/calls.log"; exit 1; }
grep -q "^ufw allow 1987/tcp" "$TMP/calls.log"   || { echo "FAIL test8: sshd on 1987 must yield 'ufw allow 1987/tcp'"; cat "$TMP/calls.log"; exit 1; }
grep -q "^ufw allow 22/tcp"   "$TMP/calls.log"   && { echo "FAIL test8: 22/tcp must not be opened when sshd is not on 22"; exit 1; }
grep -q "^ufw --force enable" "$TMP/calls.log"   || { echo "FAIL test8: enable"; exit 1; }
echo "[ok] test8: sshd on 1987 only → ufw allow 1987/tcp (not 22)"

# Test 9: sshd on 22 → 22
t_reset; t_apply
grep -q "^ufw allow 22/tcp" "$TMP/calls.log" || { echo "FAIL test9: sshd on 22 must yield 22/tcp"; exit 1; }
echo "[ok] test9: sshd on 22 → ufw allow 22/tcp"

# Test 10: detection failure → 22 + loud warning (still applies)
t_reset; : >"$TMP/sshd_T"; echo 1 >"$TMP/sshd_fail"; echo 1 >"$TMP/ss_fail"; t_apply
grep -q "^ufw allow 22/tcp" "$TMP/calls.log" || { echo "FAIL test10: fallback 22"; cat "$TMP/calls.log"; exit 1; }
grep -q "could not determine the sshd listen port" "$TMP/calls.log" || { echo "FAIL test10: missing loud warning"; cat "$TMP/calls.log"; exit 1; }
echo "[ok] test10: undetectable sshd port → 22/tcp + warning"

# Test 11: union of sshd -T, ss (socket-activated listener) and PE_SSH_PORTS override
t_reset
printf 'LISTEN 0 128 0.0.0.0:2222 0.0.0.0:* users:(("sshd",pid=1,fd=3))\nLISTEN 0 128 [::]:2222 [::]:* users:(("sshd",pid=1,fd=4))\nLISTEN 0 4096 0.0.0.0:8080 0.0.0.0:* users:(("nginx",pid=2,fd=5))\n' >"$TMP/ss_out"
PE_SSH_PORTS="2200,2201" t_apply
for want in 22 2222 2200 2201; do
	grep -q "^ufw allow ${want}/tcp" "$TMP/calls.log" || { echo "FAIL test11: ${want}/tcp missing from union"; cat "$TMP/calls.log"; exit 1; }
done
grep -q "^ufw allow 8080/tcp" "$TMP/calls.log" && { echo "FAIL test11: non-sshd listener must not be opened"; exit 1; }
echo "[ok] test11: ssh ports = sshd -T ∪ ss(sshd) ∪ PE_SSH_PORTS"

# Test 12: HARD STOP — a detected sshd port the ruleset does not allow must never reach `ufw enable`
t_reset; printf 'port 1987\n' >"$TMP/sshd_T"; UFW_DROP_RULE="1987/tcp" t_apply
[ "$_rc" -ne 0 ] || { echo "FAIL test12: uncovered sshd port must fail"; exit 1; }
grep -q "^ufw --force enable" "$TMP/calls.log" && { echo "FAIL test12: ufw enabled over an uncovered sshd port"; cat "$TMP/calls.log"; exit 1; }
grep -q "REFUSING to enable ufw" "$TMP/calls.log" || { echo "FAIL test12: no clear message"; cat "$TMP/calls.log"; exit 1; }
echo "[ok] test12: uncovered sshd port → hard stop before ufw --force enable (rc=$_rc)"

# Test 13: firewalld branch follows the detected port (no blanket ssh service)
t_reset; printf 'port 1987\n' >"$TMP/sshd_T"; _firewall_detect_tool() { printf 'firewalld'; }
for _f in perm run perm.svc run.svc; do : >"$FWS/$_f"; done; make_fwcmd_mock; t_apply
[ "$_rc" -eq 0 ] || { echo "FAIL test13: rc=$_rc"; cat "$TMP/calls.log"; exit 1; }
grep -q "add-port=1987/tcp" "$TMP/calls.log" || { echo "FAIL test13: 1987/tcp"; cat "$TMP/calls.log"; exit 1; }
grep -q "add-service=ssh"   "$TMP/calls.log" && { echo "FAIL test13: ssh service (22) must not be opened when sshd is on 1987"; exit 1; }
# hard stop: a firewall-cmd whose add-port never lands → refuse before --reload
cat >"$TMP/mocks/firewall-cmd" <<EOF
#!/usr/bin/env bash
echo "firewall-cmd \$*" >>"$TMP/calls.log"
exit 0
EOF
: >"$TMP/calls.log"; t_apply
[ "$_rc" -ne 0 ] || { echo "FAIL test13: uncovered ssh port must fail"; exit 1; }
grep -q "firewall-cmd --reload" "$TMP/calls.log" && { echo "FAIL test13: reloaded over an uncovered ssh port"; cat "$TMP/calls.log"; exit 1; }
make_fwcmd_mock
echo "[ok] test13: firewalld allows detected port, hard-stops before --reload when uncovered"

# Test 14: takeover guard — rules.v4 with INPUT ACCEPT, ufw not active → refuse without opt-in
cat >"$TMP/rules.v4.sample" <<'EOF'
*filter
:INPUT ACCEPT [0:0]
-A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
-A INPUT -i lo -j ACCEPT
-A INPUT -p tcp -m tcp --dport 1987 -j ACCEPT
-A INPUT -p tcp -m tcp --dport 443 -j ACCEPT
-A INPUT -s 10.9.0.0/24 -p tcp -m tcp --dport 9100 -j ACCEPT
-A INPUT -p tcp -m tcp --dport 8888 -j ACCEPT
COMMIT
EOF
t_reset; printf 'port 1987\n' >"$TMP/sshd_T"; cp "$TMP/rules.v4.sample" "$TMP/rules.v4"; t_apply
[ "$_rc" -eq 4 ] || { echo "FAIL test14: takeover without opt-in must return 4, got $_rc"; cat "$TMP/calls.log"; exit 1; }
grep -qE "^ufw (reset|--force|default|allow)|^apt-get" "$TMP/calls.log" && { echo "FAIL test14: nothing may be touched before the guard passes"; cat "$TMP/calls.log"; exit 1; }
grep -q -- "--dport 9100" "$TMP/calls.log" || { echo "FAIL test14: uncovered mesh-only 9100 rule not listed"; cat "$TMP/calls.log"; exit 1; }
grep -q -- "--dport 8888" "$TMP/calls.log" || { echo "FAIL test14: uncovered 8888 rule not listed"; cat "$TMP/calls.log"; exit 1; }
grep -qE "warn\] +-A INPUT .*(--dport (443|1987)|RELATED,ESTABLISHED|-i lo)" "$TMP/calls.log" && { echo "FAIL test14: covered rules must not be listed as lost"; cat "$TMP/calls.log"; exit 1; }
PE_FIREWALL_TAKEOVER=1 t_apply
{ [ "$_rc" -eq 0 ] && grep -q "^ufw --force enable" "$TMP/calls.log"; } || { echo "FAIL test14: opt-in must proceed"; cat "$TMP/calls.log"; exit 1; }
echo "[ok] test14: rules.v4 takeover refused (rc=4) w/o opt-in, uncovered rules listed; proceeds with PE_FIREWALL_TAKEOVER=1"

# Test 15: iptables-persistent installed → refuse BEFORE apt-get (it would remove the package)
t_reset; _firewall_detect_tool() { printf 'ufw-install'; }; echo iptables-persistent >"$TMP/pkg_installed"; t_apply
[ "$_rc" -eq 4 ] || { echo "FAIL test15: rc=$_rc"; cat "$TMP/calls.log"; exit 1; }
grep -q "^apt-get" "$TMP/calls.log" && { echo "FAIL test15: apt-get ran before the guard (would remove iptables-persistent)"; exit 1; }
PE_FIREWALL_TAKEOVER=1 t_apply
grep -q "^apt-get install" "$TMP/calls.log" || { echo "FAIL test15: opt-in must proceed to install ufw"; cat "$TMP/calls.log"; exit 1; }
echo "[ok] test15: iptables-persistent installed → refused before apt-get; opt-in installs"

# Test 16: ufw already active (takeover already done) + stale rules.v4 → converge must NOT refuse
t_reset; cp "$TMP/rules.v4.sample" "$TMP/rules.v4"; UFW_STATUS_ACTIVE=1 t_apply
[ "$_rc" -eq 0 ] || { echo "FAIL test16: every-converge re-apply refused on an already-ufw host (rc=$_rc)"; cat "$TMP/calls.log"; exit 1; }
echo "[ok] test16: active ufw + leftover rules.v4 → converge proceeds"

# Test 17: stable edge bridge — the resolver emits the FIXED name for a network created
# with it, the same name after the network is recreated (new id + subnet); a legacy
# network (option unset) keeps its real br-<id>.
t_reset
printf '1111111111112222222222223333333333334444444444445555555555556666 172.18.0.0/16\n' >"$TMP/net_row"
out1=$(DOCKER_BRIDGE_OPT=pe-edge0 _firewall_resolve_edge_bridges)
printf 'ffffffffffff2222222222223333333333334444444444445555555555556666 172.21.0.0/16\n' >"$TMP/net_row"
out2=$(DOCKER_BRIDGE_OPT=pe-edge0 _firewall_resolve_edge_bridges)
{ [ "$out1" = "pe-edge0 172.18.0.0/16" ] && [ "$out2" = "pe-edge0 172.21.0.0/16" ]; } || { echo "FAIL test17: resolver must return the fixed bridge name across recreation: '$out1' / '$out2'"; exit 1; }
out3=$(_firewall_resolve_edge_bridges)
[ "$out3" = "br-ffffffffffff 172.21.0.0/16" ] || { echo "FAIL test17: legacy network must keep br-<id>: '$out3'"; exit 1; }
# the fixed name must be exactly what compose creates (same literal, <=15 chars)
tpl_name=$(sed -n 's/^ *com\.docker\.network\.bridge\.name: *//p' "$REPO_ROOT/docker-compose.yml.tpl")
{ [ "$tpl_name" = "$_PE_FW_EDGE_BRIDGE" ] && [ "${#tpl_name}" -le 15 ]; } || { echo "FAIL test17: compose bridge name '$tpl_name' != firewall '$_PE_FW_EDGE_BRIDGE' (or >15 chars)"; exit 1; }
DOCKER_BRIDGE_OPT=pe-edge0 t_apply
grep -q "^ufw allow in on pe-edge0 to any port 8920 proto tcp" "$TMP/calls.log" || { echo "FAIL test17: rule must pin 'in on pe-edge0' (interface-only: the docker-assigned subnet can change on recreate)"; cat "$TMP/calls.log"; exit 1; }
grep -qE "^ufw allow in on pe-edge0 from " "$TMP/calls.log" && { echo "FAIL test17: stable-bridge rule must not carry a source subnet"; exit 1; }
grep -q "in on br-" "$TMP/calls.log" && { echo "FAIL test17: no br-<id> pin once the stable name is in use"; exit 1; }
echo "[ok] test17: edge bridge resolves to fixed pe-edge0 across network recreation; legacy keeps br-<id>"

# ── Review round 1 ─────────────────────────────────────────────────────────────
# Test 18: socket-activated sshd. Before the first connection `ss -p` shows the
# listener owned by "systemd" (not sshd) and `sshd -T` reports sshd_config Port,
# not the socket's ListenStream — so the socket unit is the only truth.
t_sock() { # t_sock UNIT LISTEN-VALUE...  (marks UNIT active, writes `Listen=<v> (Stream)` lines)
	local u="$1"; shift; echo active >"$TMP/sock_$u.active"; : >"$TMP/sock_$u.listen"
	local v; for v in "$@"; do printf 'Listen=%s (Stream)\n' "$v" >>"$TMP/sock_$u.listen"; done
}
for fmt in "[::]:1987" "0.0.0.0:1987" "1987"; do
	t_reset; printf 'port 22\n' >"$TMP/sshd_T"
	printf 'LISTEN 0 4096 *:1987 *:* users:(("systemd",pid=1,fd=45))\n' >"$TMP/ss_out"
	t_sock ssh.socket "$fmt"; t_apply
	grep -q "^ufw allow 1987/tcp" "$TMP/calls.log" || { echo "FAIL test18: systemd-owned ssh.socket ListenStream '$fmt' (sshd -T says 22) must allow 1987/tcp"; cat "$TMP/calls.log"; exit 1; }
done
# reverse: socket on 22, sshd_config Port 2222 → both stay reachable
t_reset; printf 'port 2222\n' >"$TMP/sshd_T"; t_sock ssh.socket "[::]:22"; t_apply
{ grep -q "^ufw allow 22/tcp" "$TMP/calls.log" && grep -q "^ufw allow 2222/tcp" "$TMP/calls.log"; } || { echo "FAIL test18: socket on 22 + config 2222 must allow both"; cat "$TMP/calls.log"; exit 1; }
# an INACTIVE socket unit contributes nothing
t_reset; printf 'port 22\n' >"$TMP/sshd_T"; : >"$TMP/sock_ssh.socket.active"; printf 'Listen=[::]:1987 (Stream)\n' >"$TMP/sock_ssh.socket.listen"; t_apply
grep -q "^ufw allow 1987/tcp" "$TMP/calls.log" && { echo "FAIL test18: inactive ssh.socket must not be consulted"; exit 1; }
# the live session's own destination port ($SSH_CONNECTION = "cip cport sip sport")
t_reset; printf 'port 22\n' >"$TMP/sshd_T"; SSH_CONNECTION="198.51.100.7 51234 203.0.113.9 2201" t_apply
grep -q "^ufw allow 2201/tcp" "$TMP/calls.log" || { echo "FAIL test18: SSH_CONNECTION local port 2201 must be allowed"; cat "$TMP/calls.log"; exit 1; }
echo "[ok] test18: ssh ports include active ssh.socket ListenStream (any format) and the live session port"

# Test 19: a failing required `ufw allow` must never reach `ufw --force enable`
# (fn || return suspends errexit, so only explicit propagation + read-back stop it).
# 19a: allow exits non-zero (rule even recorded) → only the rc check can catch it
t_reset; UFW_FAIL_RULE="443/tcp" t_apply
[ "$_rc" -ne 0 ] || { echo "FAIL test19a: failing 'ufw allow 443/tcp' must fail firewall_apply"; exit 1; }
grep -q "^ufw --force enable" "$TMP/calls.log" && { echo "FAIL test19a: ufw enabled after a failed 'ufw allow 443/tcp'"; cat "$TMP/calls.log"; exit 1; }
# 19b: allow "succeeds" but the rule never lands (awg port, mesh-less read-back) → read-back catches it
for drop in "44330/udp" "443/tcp" "49152:49999/udp"; do
	t_reset; UFW_DROP_RULE="$drop" t_apply
	[ "$_rc" -ne 0 ] || { echo "FAIL test19b: missing required rule $drop must fail"; exit 1; }
	grep -q "^ufw --force enable" "$TMP/calls.log" && { echo "FAIL test19b: ufw enabled with required rule $drop absent"; cat "$TMP/calls.log"; exit 1; }
	grep -q "required rules missing" "$TMP/calls.log" || { echo "FAIL test19b: no clear message for $drop"; cat "$TMP/calls.log"; exit 1; }
done
# 19c: firewalld twin — a failing add-port must stop before --reload
t_reset; _firewall_detect_tool() { printf 'firewalld'; }
cat >"$TMP/mocks/firewall-cmd" <<EOF
#!/usr/bin/env bash
echo "firewall-cmd \$*" >>"$TMP/calls.log"
case "\$*" in *--list-ports*) echo "1987/tcp 80/tcp 443/tcp 3478/tcp 5349/tcp 443/udp 3478/udp 5349/udp 7878/udp 49152-49999/udp 44330/udp" ;; *--list-services*) echo ssh ;; esac
case "\$*" in *--add-port=443/tcp*) exit 1 ;; esac
exit 0
EOF
printf 'port 22\n' >"$TMP/sshd_T"; t_apply
[ "$_rc" -ne 0 ] || { echo "FAIL test19c: failing firewall-cmd add-port must fail"; exit 1; }
grep -q "firewall-cmd --reload" "$TMP/calls.log" && { echo "FAIL test19c: reloaded after a failed add-port"; cat "$TMP/calls.log"; exit 1; }
make_fwcmd_mock
echo "[ok] test19: failed/missing required rule (rc and read-back, ufw and firewalld) → no enable/reload"

# Test 20: invalid/empty port lists are rejected BEFORE `ufw --force reset`
for bad in "abc" "70000" "22 0" "22;ls"; do
	t_reset; _rc=0; _firewall_apply_ufw 44330 "$bad" >/dev/null 2>&1 || _rc=$?
	[ "$_rc" -ne 0 ] || { echo "FAIL test20: ssh ports '$bad' must be rejected"; exit 1; }
	grep -q "^ufw" "$TMP/calls.log" && { echo "FAIL test20: ufw touched before port validation for '$bad'"; cat "$TMP/calls.log"; exit 1; }
done
t_reset; _rc=0; _firewall_apply_ufw "x1" "22" >/dev/null 2>&1 || _rc=$?
{ [ "$_rc" -ne 0 ] && ! grep -q "^ufw" "$TMP/calls.log"; } || { echo "FAIL test20: invalid awg port must be rejected before reset"; exit 1; }
echo "[ok] test20: invalid ssh/awg port list → refused before ufw --force reset"

# Test 21: takeover coverage — source/interface-restricted public-port rules are NOT
# reproduced by ufw (it would open them to the world); rules.v6 is read too.
t_reset; cat >"$TMP/rules.v4" <<'EOF'
-A INPUT -s 203.0.113.0/24 -p tcp -m tcp --dport 443 -j ACCEPT
-A INPUT -i eth1 -p tcp -m tcp --dport 80 -j ACCEPT
-A INPUT -p tcp -m tcp --dport 3478 -j ACCEPT
EOF
cat >"$TMP/rules.v6" <<'EOF'
-A INPUT -p tcp -m tcp --dport 9999 -j ACCEPT
-A INPUT -p ipv6-icmp -j ACCEPT
EOF
t_apply
[ "$_rc" -eq 4 ] || { echo "FAIL test21: rc=$_rc"; cat "$TMP/calls.log"; exit 1; }
grep -q "warn\] *-A INPUT -s 203.0.113.0/24 .*--dport 443" "$TMP/calls.log" || { echo "FAIL test21: source-restricted 443 rule must be listed as NOT covered"; cat "$TMP/calls.log"; exit 1; }
grep -q "warn\] *-A INPUT -i eth1 .*--dport 80" "$TMP/calls.log" || { echo "FAIL test21: interface-restricted 80 rule must be listed as NOT covered"; cat "$TMP/calls.log"; exit 1; }
grep -q "warn\] *-A INPUT -p tcp -m tcp --dport 9999" "$TMP/calls.log" || { echo "FAIL test21: rules.v6 rule must be read and listed"; cat "$TMP/calls.log"; exit 1; }
grep -qE "warn\] *-A INPUT -p tcp -m tcp --dport 3478|ipv6-icmp" "$TMP/calls.log" && { echo "FAIL test21: unrestricted 3478 / ipv6-icmp are covered, must not be listed"; cat "$TMP/calls.log"; exit 1; }
# rules.v6 alone (empty v4) also triggers the guard
t_reset; printf -- '-A INPUT -p tcp -m tcp --dport 9999 -j ACCEPT\n' >"$TMP/rules.v6"; t_apply
[ "$_rc" -eq 4 ] || { echo "FAIL test21: rules.v6-only host must trigger the takeover guard (rc=$_rc)"; exit 1; }
echo "[ok] test21: -s/-i restricted public-port rules reported as uncovered; rules.v6 read"

# Test 22: an active ufw must be recognised under a translated status (LC_ALL=C forced,
# no head/grep -q pipe) — otherwise the every-converge re-apply refuses forever.
t_reset; printf -- '-A INPUT -p tcp -m tcp --dport 8888 -j ACCEPT\n' >"$TMP/rules.v4"; UFW_STATUS_ACTIVE=1 LANG=fr_FR.UTF-8 t_apply
[ "$_rc" -eq 0 ] || { echo "FAIL test22: active ufw under a localized status must not trigger the takeover guard (rc=$_rc)"; cat "$TMP/calls.log"; exit 1; }
echo "[ok] test22: active ufw detected with LC_ALL=C"

# Test 23: install.sh turns the refusal rcs into an explicit die naming the knob
# (not an unexplained errexit), and persists the overrides into install.env (which
# install.sh rewrites from scratch) so the converge sees them.
inst="$REPO_ROOT/install.sh"
grep -q 'firewall_apply || _fw_rc=\$?' "$inst" || { echo "FAIL test23: install.sh must capture firewall_apply's rc"; exit 1; }
fw_blk=$(awk '/_fw_rc=0/,/esac/' "$inst")
grep -q 'PE_SSH_PORTS' <<<"$fw_blk" || { echo "FAIL test23: rc 3 die must name PE_SSH_PORTS"; exit 1; }
grep -q 'PE_FIREWALL_TAKEOVER' <<<"$fw_blk" || { echo "FAIL test23: rc 4 die must name PE_FIREWALL_TAKEOVER"; exit 1; }
grep -q "PE_SSH_PORTS=%s.*install.env" "$inst" && grep -q "PE_FIREWALL_TAKEOVER=1.*install.env" "$inst" || { echo "FAIL test23: overrides must be persisted to install.env"; exit 1; }
echo "[ok] test23: install.sh dies explicitly on rc 3/4 and persists PE_SSH_PORTS / PE_FIREWALL_TAKEOVER"

echo "[ok] all firewall-module tests passed"
