#!/bin/bash
# tests/test_coturn_guard.sh — coturn self-relay guard (incident 2026-10-12).
#
# coturn (network_mode: host) relays a TURN client's UDP to any peer it names; the
# credentials are public. Defence is layered and every layer must hold:
#   image    : turnserver runs as a FIXED numeric non-root uid
#   host nft : table inet coturn_self_relay_guard drops coturn->local UDP outside
#              the SFU port and the relay range (keyed on that numeric uid)
#   kernel   : the relay range is reserved from the ephemeral pool
#   config   : coturn.conf renders no allowed-peer-ip; min/max-port = that range
#   firewall : ufw/firewalld open exactly that range
#   delivery : install / plain upgrade / converge / hydrate all load the guard
#   health   : healthcheck reports a missing guard
# A mismatch between any two numbers below is a silent failure in production
# (nothing errors; the guard just stops meaning what it says), hence the pins.
set -uo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$REPO_ROOT" || exit 1

FAILS=0
pass() { echo "OK: $*"; }
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }
need() { # need FILE ERE DESCRIPTION
	grep -qE -- "$2" "$1" && pass "$3" || fail "$3 ($1 lacks /$2/)"
}
nocode() { # nocode FILE ERE DESCRIPTION — absent from every non-comment line
	local code; code=$(grep -vE '^[[:space:]]*#' "$1" || true)
	if [[ -n $code ]] && grep -qE -- "$2" <<<"$code"; then fail "$3 ($1 still matches /$2/)"; else pass "$3"; fi
}

GUARD=oxpulse-partner-edge-coturn-guard.sh
UNIT=systemd/oxpulse-coturn-self-relay-guard.service
TPL=coturn.conf.tpl
DOCKERFILE=images/Dockerfile.coturn

[[ -x $GUARD ]] || fail "$GUARD missing or not executable"
bash -n "$GUARD" || fail "$GUARD has syntax errors"

# --- constants: one value, every place --------------------------------------
g_uid=$(sed -n 's/^readonly COTURN_UID=\([0-9]*\)$/\1/p' "$GUARD")
g_min=$(sed -n 's/^readonly RELAY_MIN=\([0-9]*\)$/\1/p' "$GUARD")
g_max=$(sed -n 's/^readonly RELAY_MAX=\([0-9]*\)$/\1/p' "$GUARD")
[[ -n $g_uid && -n $g_min && -n $g_max ]] && pass "guard constants parse (uid=$g_uid relay=$g_min-$g_max)" \
	|| fail "could not parse COTURN_UID/RELAY_MIN/RELAY_MAX from $GUARD"
[[ ${g_uid:-0} -ge 1000 && ${g_uid:-0} -le 60000 ]] && pass "coturn uid $g_uid is non-root, in the local-allocation band" \
	|| fail "coturn uid '$g_uid' not in 1000..60000"

# image: non-root, same fixed uid, resolvable numerically
d_arg=$(sed -n 's/^ARG COTURN_UID=\([0-9]*\)$/\1/p' "$DOCKERFILE")
[[ $d_arg == "$g_uid" ]] && pass "Dockerfile ARG COTURN_UID == guard COTURN_UID" \
	|| fail "Dockerfile COTURN_UID '$d_arg' != guard '$g_uid' — the nft skuid match would never fire"
last_user=$(grep -E '^USER ' "$DOCKERFILE" | tail -n1)
[[ $last_user == "USER ${g_uid}:${g_uid}" ]] && pass "Dockerfile final USER is ${g_uid}:${g_uid} (numeric, non-root)" \
	|| fail "Dockerfile final USER is '$last_user', want 'USER ${g_uid}:${g_uid}'"
need docker-compose.yml.tpl "^    user: \"${g_uid}:${g_uid}\"$" "compose coturn service runs as ${g_uid}:${g_uid} (== guard uid)"
need "$DOCKERFILE" '^ *&& setcap cap_dac_override\+ep /usr/bin/turnserver' \
	"Dockerfile gives turnserver cap_dac_override (reads root-0600 TLS key / conf / old-owner log volume)"
nocode "$DOCKERFILE" 'cap_net_bind_service' "Dockerfile does not grant cap_net_bind_service (coturn binds 3478/3479/5349 only)"
# the only <1024 listener claim worth checking: no coturn port below 1024
if grep -E '^(listening-port|alt-listening-port|tls-listening-port)=' "$TPL" | awk -F= '$2 < 1024 {bad=1} END{exit !bad}'; then
	fail "coturn.conf.tpl binds a port < 1024 — non-root needs cap_net_bind_service"
else pass "coturn.conf.tpl binds no port < 1024"; fi

# config: relay range
t_min=$(sed -n 's/^min-port=\([0-9]*\)$/\1/p' "$TPL")
t_max=$(sed -n 's/^max-port=\([0-9]*\)$/\1/p' "$TPL")
[[ $t_min == "$g_min" && $t_max == "$g_max" ]] && pass "coturn.conf.tpl min/max-port == guard relay range" \
	|| fail "coturn.conf.tpl min/max-port ($t_min-$t_max) != guard relay range ($g_min-$g_max)"

# firewall: exactly the range, in both the lib and its frozen twin
for fw in lib/firewall-lib.sh lib/install-firewall.sh; do
	r=$(sed -n 's/^_PE_FW_PUB_UDP_RANGES=(\(.*\))$/\1/p' "$fw")
	[[ $r == "${g_min}:${g_max}" ]] && pass "$fw opens exactly ${g_min}:${g_max}/udp" \
		|| fail "$fw _PE_FW_PUB_UDP_RANGES='$r', want ${g_min}:${g_max}"
done

# --- generated nft ruleset + sysctl, via the real script, stubbed binaries -----
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/etc/oxpulse-partner-edge"
cat > "$TMP/bin/nft" <<'EOF'
#!/bin/bash
# stub: record argv; capture the ruleset fed on stdin when it is `-f -`
echo "nft $*" >> "$STUB_LOG"
if [[ "$*" == *"-f -"* ]]; then cat > "$STUB_RULES.$$"; cat "$STUB_RULES.$$" >> "$STUB_RULES"; rm -f "$STUB_RULES.$$"; fi
exit 0
EOF
cat > "$TMP/bin/sysctl" <<'EOF'
#!/bin/bash
echo "sysctl $*" >> "$STUB_LOG"
EOF
chmod +x "$TMP/bin/nft" "$TMP/bin/sysctl"
export STUB_LOG="$TMP/calls.log" STUB_RULES="$TMP/rules.nft"
: > "$STUB_LOG"; : > "$STUB_RULES"
run_guard() { ETC_DIR="$TMP/etc" NFT="$TMP/bin/nft" SYSCTL_BIN="$TMP/bin/sysctl" SS_BIN=/nonexistent "$@"; }

# SFU port comes from the node's compose file when not overridden
cat > "$TMP/etc/oxpulse-partner-edge/docker-compose.yml" <<'EOF'
services:
  sfu:
    environment:
      SFU_UDP_PORT: "9100"
EOF
run_guard "$REPO_ROOT/$GUARD" apply >/dev/null 2>"$TMP/err" || { fail "guard apply failed: $(cat "$TMP/err")"; }
R=$(cat "$STUB_RULES")
grep -q 'nft -c -f -' "$STUB_LOG" && pass "apply validates (nft -c) before loading" || fail "apply never ran nft -c"
grep -q 'nft -f -' "$STUB_LOG" && pass "apply loads the ruleset with one nft -f" || fail "apply never loaded the ruleset"
grep -qE '^table inet coturn_self_relay_guard$' <<<"$R" && grep -q '^delete table inet coturn_self_relay_guard$' <<<"$R" \
	&& pass "ruleset has the table/delete/table atomic-replace preamble" || fail "missing idempotent preamble"
grep -qE "meta skuid ${g_uid} .*fib daddr type local .*udp dport != ${g_min}-${g_max} .*drop" <<<"$R" \
	&& pass "drop rule: numeric skuid ${g_uid}, local daddr, udp dport != ${g_min}-${g_max}" \
	|| fail "no drop rule keyed on numeric skuid ${g_uid} with dport != ${g_min}-${g_max}"
grep -qE 'meta skuid "' <<<"$R" && fail "ruleset matches skuid by NAME — host has no coturn user" || pass "skuid is numeric, not a name"
grep -qE "meta skuid ${g_uid} .*fib daddr type local .*udp dport 9100 .*accept" <<<"$R" \
	&& pass "SFU accept uses the port from compose (9100), for ANY local address" \
	|| fail "no SFU accept for the compose-derived port 9100"
grep -qE '(ip|ip6) daddr' <<<"$R" && fail "ruleset hard-codes an address — the hairpin accept must hold on NAT'd AND public-NIC edges" \
	|| pass "no address match: accept holds when PUBLIC != PRIVATE and when the SFU sits on the NIC's own public IP"
accept_ln=$(grep -n -m1 'udp dport 9100' <<<"$R" || true); accept_ln=${accept_ln%%:*}
drop_ln=$(grep -n -m1 ' drop' <<<"$R" || true); drop_ln=${drop_ln%%:*}
[[ -n $accept_ln && -n $drop_ln && $accept_ln -lt $drop_ln ]] && pass "SFU accept precedes the drop" || fail "SFU accept must come before the drop rule"
grep -qE 'ct direction reply .*accept' <<<"$R" && pass "replies to a TURN client on this host are accepted (healthcheck/cross-probe)" \
	|| fail "no 'ct direction reply accept' — host-side probes of coturn would be blinded"
grep -qE 'hook output priority (mangle|-150)' <<<"$R" && pass "OUTPUT hook after conntrack, before docker nat (dstnat)" \
	|| fail "hook priority must be mangle(-150): conntrack for the reply rule, before dstnat"
grep -q 'type filter hook output' <<<"$R" || fail "not an OUTPUT hook"

# explicit override beats compose
: > "$STUB_RULES"
SFU_UDP_PORT=7000 run_guard "$REPO_ROOT/$GUARD" apply >/dev/null 2>&1
grep -qE 'udp dport 7000 .*accept' "$STUB_RULES" && pass "SFU_UDP_PORT env overrides compose" || fail "SFU_UDP_PORT env ignored"
# default
rm -f "$TMP/etc/oxpulse-partner-edge/docker-compose.yml"; : > "$STUB_RULES"
run_guard "$REPO_ROOT/$GUARD" apply >/dev/null 2>&1
grep -qE 'udp dport 7878 .*accept' "$STUB_RULES" && pass "no compose, no env -> default SFU port 7878" || fail "default SFU port not 7878"
# a garbage port must refuse, not load a rule that accepts everything
: > "$STUB_RULES"
if SFU_UDP_PORT='7878; accept' run_guard "$REPO_ROOT/$GUARD" apply >/dev/null 2>&1; then fail "non-numeric SFU port accepted"; else pass "non-numeric SFU port refused before anything loads"; fi
[[ ! -s "$STUB_RULES" ]] && pass "nothing loaded for a refused port" || fail "ruleset loaded despite bad port"

# sysctl: reservation == relay range, conntrack stream timeout 180
SYS="$TMP/etc/sysctl.d/99-oxpulse-coturn-relay-ports.conf"
[[ -f $SYS ]] && pass "sysctl.d file written" || fail "sysctl.d file not written"
grep -qE "^net.ipv4.ip_local_reserved_ports = ${g_min}-${g_max}$" "$SYS" \
	&& pass "sysctl.d reserves exactly ${g_min}-${g_max} (== coturn min/max-port)" \
	|| fail "sysctl.d reservation != relay range ${g_min}-${g_max}"
grep -qE '^net.netfilter.nf_conntrack_udp_timeout_stream = 180$' "$SYS" && pass "conntrack udp stream timeout 180 (2026-06-05 research)" \
	|| fail "nf_conntrack_udp_timeout_stream = 180 missing"
grep -q "sysctl -q -w net.ipv4.ip_local_reserved_ports=${g_min}-${g_max}" "$STUB_LOG" && pass "apply sets the reservation live" \
	|| fail "apply never ran sysctl -w for the reservation"

# --- config renderers: no allowed-peer-ip anywhere ------------------------------
nocode "$TPL" 'allowed-peer-ip|ALLOWED_PEER_IP_LINE' "coturn.conf.tpl renders no allowed-peer-ip (placeholder or literal)"
for f in install.sh hydrate.sh lib/reconcile.sh; do
	nocode "$f" 'ALLOWED_PEER_IP_LINE|allowed-peer-ip' "$f computes/exports no allowed-peer-ip"
done

# --- delivery: every path that can leave an edge without the guard -------------
need lib/install-systemd.sh 'install -m 0755 "\$src_dir/oxpulse-partner-edge-coturn-guard.sh" "\$PREFIX_SBIN/oxpulse-partner-edge-coturn-guard"' \
	"install.sh path installs the guard script"
need lib/install-systemd.sh 'unit=oxpulse-coturn-self-relay-guard.service' "install.sh path installs the guard unit"
need lib/install-systemd.sh 'systemctl enable --now oxpulse-coturn-self-relay-guard.service' "install.sh enables+starts the guard (full install)"
need lib/install-systemd.sh 'systemctl enable oxpulse-coturn-self-relay-guard.service' "bake mode enables the guard for first boot"
g_enable_ln=$(grep -n -m1 'enable --now oxpulse-coturn-self-relay-guard.service' lib/install-systemd.sh || true); g_enable_ln=${g_enable_ln%%:*}
e_enable_ln=$(grep -n -m1 'enable --now oxpulse-partner-edge.service' lib/install-systemd.sh || true); e_enable_ln=${e_enable_ln%%:*}
[[ -n $g_enable_ln && -n $e_enable_ln && $g_enable_ln -lt $e_enable_ln ]] && pass "guard enabled before the edge unit starts coturn" \
	|| fail "guard must be enabled+started BEFORE oxpulse-partner-edge.service"
need upgrade.sh '^[[:space:]]+oxpulse-partner-edge-coturn-guard$' "plain upgrade delivers the guard script (_HOST_SCRIPT_SBIN_FILES)"
need upgrade.sh 'oxpulse-partner-edge-coturn-guard\) +echo "oxpulse-partner-edge-coturn-guard.sh"' "plain upgrade maps the guard script's release asset name"
need upgrade.sh '^[[:space:]]+oxpulse-coturn-self-relay-guard\.service$' "plain upgrade delivers/enables the guard unit"
need upgrade.sh '^_HOST_SCRIPT_APPLY_UNITS=\(' "plain upgrade declares an APPLY set (start/reload, not just enable)"
apply_set=$(awk '/^_HOST_SCRIPT_APPLY_UNITS=\(/,/^\)/' upgrade.sh)
[[ $apply_set == *oxpulse-coturn-self-relay-guard.service* ]] \
	&& pass "APPLY set contains the guard" || fail "_HOST_SCRIPT_APPLY_UNITS lacks the guard"
need lib/host-scripts-lib.sh 'for _au in "\$\{_HOST_SCRIPT_APPLY_UNITS\[@\]\}"' "sync_host_scripts walks the APPLY set"
need lib/host-scripts-lib.sh 'reload-or-restart "\$_au"' "sync_host_scripts reload-or-restarts each APPLY unit"
need .github/workflows/release.yml 'cp systemd/oxpulse-coturn-self-relay-guard.service' "release stages the guard unit"
[[ $(grep -c 'oxpulse-partner-edge-coturn-guard.sh' .github/workflows/release.yml) -ge 2 ]] && pass "release checksums list the guard script (both lists)" \
	|| fail "release.yml checksum lists must include oxpulse-partner-edge-coturn-guard.sh twice"
need hydrate.sh 'reload-or-restart oxpulse-coturn-self-relay-guard.service' "hydrate (clone first boot) loads the guard"
h_g=$(grep -n -m1 'reload-or-restart oxpulse-coturn-self-relay-guard.service' hydrate.sh || true); h_g=${h_g%%:*}
h_c=$(grep -n -m1 'docker compose -f "\$PREFIX_ETC/docker-compose.yml" up -d' hydrate.sh || true); h_c=${h_c%%:*}
[[ -n $h_g && -n $h_c && $h_g -lt $h_c ]] && pass "hydrate loads the guard BEFORE docker compose up" || fail "hydrate must load the guard before compose up"
need uninstall.sh 'oxpulse-coturn-self-relay-guard.service' "uninstall stops the guard unit"

# unit: ordered before docker, no hard coupling to coturn
need "$UNIT" '^Before=.*docker\.service' "guard unit ordered Before=docker.service (dockerd restarts containers at boot)"
nocode "$UNIT" '^(Requires|BindsTo|PartOf)=' "guard unit has no Requires/BindsTo/PartOf (breaks coturn restart/rollback)"
need "$UNIT" '^ExecReload=.*coturn-guard apply$' "guard unit reloads by re-applying"
need systemd/oxpulse-partner-edge.service '^Wants=.*oxpulse-coturn-self-relay-guard\.service' "edge unit pulls the guard in"

# --- converge: reconcile_firewall_surface re-asserts the guard after firewall_apply
CT="$TMP/converge"; mkdir -p "$CT/bin"
cat > "$CT/bin/systemctl" <<'EOF'
#!/bin/bash
echo "systemctl $*" >> "$CONVERGE_LOG"
EOF
chmod +x "$CT/bin/systemctl"
export CONVERGE_LOG="$CT/calls.log"
for fw_rc in 0 1; do
	: > "$CONVERGE_LOG"
	(
		export PATH="$CT/bin:$PATH" DRY_RUN=0
		log() { :; }; warn() { :; }; die() { echo "die: $*" >&2; exit 9; }
		# shellcheck disable=SC1091
		. "$REPO_ROOT/lib/reconcile.sh"
		echo 'firewall_apply() { return '"$fw_rc"'; }' > "$CT/fw.sh"
		export FIREWALL_LIB="$CT/fw.sh"
		_reconcile_firewall_emit_gauge() { :; }
		_reconcile_firewall_escalate() { :; }
		reconcile_firewall_surface
	) >/dev/null 2>&1
	grep -qx 'systemctl reload-or-restart oxpulse-coturn-self-relay-guard.service' "$CONVERGE_LOG" \
		&& pass "converge re-applies the guard (firewall_apply rc=$fw_rc)" \
		|| fail "converge did not re-apply the guard when firewall_apply rc=$fw_rc (calls: $(tr '\n' ';' < "$CONVERGE_LOG"))"
done

# --- docker exec into coturn must run as root: conf is 0600, exec'd uid is non-root
bare_exec=$(grep -rnE 'docker exec( -[a-z]+)* oxpulse-partner-coturn' healthcheck.sh lib/channel-health-lib.sh lib/cross-probe-lib.sh || true)
bare_exec=$(grep -vE 'docker exec -u 0 oxpulse-partner-coturn' <<<"$bare_exec" || true)
bare_exec=$(grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' <<<"$bare_exec" || true)
if [[ -n $bare_exec ]]; then
	fail "a host-side 'docker exec oxpulse-partner-coturn' runs as the non-root default user and cannot read the 0600 coturn.conf"
else pass "every host-side docker exec into coturn uses -u 0"; fi

# --- health: a missing guard is visible -----------------------------------------
need healthcheck.sh 'check "check_22_coturn_self_relay_guard" .* "\$_COTURN_GUARD_BIN" status' "healthcheck reports a missing guard (check_22)"

# --- real nft syntax check when the host has nft (CI runner / operator box) -----
if command -v nft >/dev/null 2>&1; then
	"$REPO_ROOT/$GUARD" render > "$TMP/real.nft" 2>/dev/null
	if nft -c -f "$TMP/real.nft" 2>"$TMP/nft.err"; then pass "nft -c accepts the generated ruleset"
	elif grep -qiE 'operation not permitted|permission denied' "$TMP/nft.err"; then echo "SKIP: nft -c needs privileges here"
	else fail "nft rejects the generated ruleset: $(cat "$TMP/nft.err")"; fi
else echo "SKIP: nft not installed — syntax checked by the live acceptance probe"; fi

echo
if [[ $FAILS -eq 0 ]]; then echo "All coturn guard tests passed."; exit 0; fi
echo "$FAILS coturn guard check(s) FAILED."; exit 1
