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

# =============================================================================
# Round-1 review fixes
# =============================================================================
fmode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
finode() { ls -i "$1" | awk '{print $1}'; }

# --- (1) plain-upgrade conf migration -------------------------------------------
# A plain `oxpulse-partner-edge-upgrade` never reaches reconcile_all, so the live
# coturn.conf (max-port=65535, allowed-peer-ip, 1..2 static-auth-secret lines) is
# only fixed by the guard's own apply. Fixture mirrors a pre-fix NAT'd edge.
mkconf() {
	cat > "$1" <<'EOF'
listening-port=3478
static-auth-secret=NEWSECRET+with=equals==
static-auth-secret=OLDSECRET/rotation=
#min-port=1111
allowed-peer-ip=10.0.1.44
min-port=49152
max-port=65535
external-ip=203.0.113.5/10.0.1.44
allowed-peer-ip=10.0.1.45
log-file=/var/log/turnserver/turn.log
EOF
	chmod 0600 "$1"
}
MIG="$TMP/mig"; mkdir -p "$MIG"; mkconf "$MIG/coturn.conf"; cp "$MIG/coturn.conf" "$MIG/orig"
sec_before=$(grep -a '^static-auth-secret=' "$MIG/orig")
mig_out=$(COTURN_CONF="$MIG/coturn.conf" "$REPO_ROOT/$GUARD" migrate-conf 2>&1)
[[ $(grep -c '^min-port=49152$' "$MIG/coturn.conf") == 1 && $(grep -c "^max-port=${g_max}$" "$MIG/coturn.conf") == 1 ]] \
	&& pass "migration: min-port/max-port == guard range (${g_min}-${g_max}), once each" \
	|| fail "migration: range not fixed: $(grep -a 'port=' "$MIG/coturn.conf" | tr '\n' ' ')"
[[ $(grep -c 'allowed-peer-ip' "$MIG/coturn.conf" || true) == 0 ]] && pass "migration: every allowed-peer-ip line removed" || fail "migration: allowed-peer-ip survived"
[[ $(grep -a '^static-auth-secret=' "$MIG/coturn.conf") == "$sec_before" ]] && pass "migration: both static-auth-secret lines byte-identical" || fail "migration changed a static-auth-secret line"
[[ $(grep -avE '^(min-port|max-port|allowed-peer-ip)=' "$MIG/orig") == $(grep -avE '^(min-port|max-port|allowed-peer-ip)=' "$MIG/coturn.conf") ]] \
	&& pass "migration: every other line (incl. commented #min-port) byte-identical" || fail "migration touched an unrelated line"
[[ $(fmode "$MIG/coturn.conf") == 600 ]] && pass "migration: mode 0600 preserved" || fail "migration lost mode 0600 (now $(fmode "$MIG/coturn.conf"))"
[[ "$mig_out" != *NEWSECRET* && "$mig_out" != *OLDSECRET* ]] && pass "migration never prints a secret" || fail "migration output leaked a secret"
ino1=$(finode "$MIG/coturn.conf"); sum1=$(cksum < "$MIG/coturn.conf")
mig_out2=$(COTURN_CONF="$MIG/coturn.conf" "$REPO_ROOT/$GUARD" migrate-conf 2>&1)
[[ $(finode "$MIG/coturn.conf") == "$ino1" && $(cksum < "$MIG/coturn.conf") == "$sum1" && -z "$mig_out2" ]] \
	&& pass "migration: second run is a no-op (no rename, no change, silent)" || fail "migration not idempotent: $mig_out2"
[[ -z $(find "$MIG" -name 'coturn.conf.*' -print) ]] && pass "migration leaves no temp files" || fail "temp file left behind: $(ls "$MIG")"
# absent directives are appended (coturn's default would be 49152-65535)
printf 'listening-port=3478\nstatic-auth-secret=S\n' > "$MIG/bare.conf"
COTURN_CONF="$MIG/bare.conf" "$REPO_ROOT/$GUARD" migrate-conf >/dev/null 2>&1
[[ $(grep -c "^max-port=${g_max}$" "$MIG/bare.conf") == 1 && $(grep -c "^min-port=${g_min}$" "$MIG/bare.conf") == 1 ]] \
	&& pass "migration: missing min/max-port are appended" || fail "bare conf not given an explicit range"

# apply: conf migrated BEFORE the table loads; coturn restarted only on change
mkconf "$MIG/coturn.conf"
cat > "$TMP/bin/docker" <<'EOF'
#!/bin/bash
echo "docker $*" >> "$STUB_LOG"
[[ "$1" == ps ]] && echo abc123
exit 0
EOF
chmod +x "$TMP/bin/docker"
cat > "$TMP/bin/nft" <<'EOF'
#!/bin/bash
echo "nft $*" >> "$STUB_LOG"
if [[ "$*" == *"-f -"* ]]; then
	cat > "$STUB_RULES.$$"; cat "$STUB_RULES.$$" >> "$STUB_RULES"; rm -f "$STUB_RULES.$$"
	# record what the conf looked like AT LOAD TIME (not -c): order oracle
	[[ "$*" != *"-c "* ]] && awk -F= '$1=="max-port"{print $2}' "${COTURN_CONF:-/dev/null}" >> "$TMP_ORDER"
fi
exit 0
EOF
chmod +x "$TMP/bin/nft"
export TMP_ORDER="$TMP/order.log"; : > "$TMP_ORDER"; : > "$STUB_LOG"
COTURN_CONF="$MIG/coturn.conf" DOCKER_BIN="$TMP/bin/docker" run_guard "$REPO_ROOT/$GUARD" apply >/dev/null 2>&1
[[ $(cat "$TMP_ORDER") == "$g_max" ]] && pass "apply: conf already migrated when the table loads (no window of live relays outside the range)" \
	|| fail "apply loaded the table while max-port was '$(cat "$TMP_ORDER")'"
grep -q 'docker restart oxpulse-partner-coturn' "$STUB_LOG" && pass "apply: coturn restarted after a conf change" || fail "no coturn restart after migrating the conf"
: > "$STUB_LOG"
COTURN_CONF="$MIG/coturn.conf" DOCKER_BIN="$TMP/bin/docker" run_guard "$REPO_ROOT/$GUARD" apply >/dev/null 2>&1
grep -q 'docker restart' "$STUB_LOG" && fail "second apply restarted coturn (conf unchanged)" || pass "apply: unchanged conf -> coturn NOT restarted"

# --- (7) sysctl: merge, never clobber ----------------------------------------------
mp() { "$REPO_ROOT/$GUARD" merge-ports "$1"; }
[[ $(mp "") == "${g_min}-${g_max}" ]] && pass "merge: empty reservation -> our range" || fail "merge('') = $(mp "")"
[[ $(mp "80,443") == "80,443,${g_min}-${g_max}" ]] && pass "merge: foreign reservations are kept" || fail "merge(80,443) = $(mp "80,443")"
[[ $(mp "${g_min}-${g_max}") == "${g_min}-${g_max}" ]] && pass "merge: already reserved -> unchanged" || fail "merge(self) = $(mp "${g_min}-${g_max}")"
[[ $(mp "100-200,49000-50500") == "100-200,49000-50500" ]] && pass "merge: a wider foreign range absorbs ours" || fail "merge(wide) = $(mp "100-200,49000-50500")"
[[ $(mp "50000,${g_min}") == "${g_min}-50000" ]] && pass "merge: adjacent/overlapping singles coalesce" || fail "merge(single) = $(mp "50000,${g_min}")"
printf '80,443\n' > "$TMP/reserved"
: > "$STUB_LOG"
RESERVED_PORTS_FILE="$TMP/reserved" COTURN_CONF=/nonexistent run_guard "$REPO_ROOT/$GUARD" apply >/dev/null 2>&1
grep -q "sysctl -q -w net.ipv4.ip_local_reserved_ports=80,443,${g_min}-${g_max}" "$STUB_LOG" \
	&& pass "apply writes the UNION live (foreign 80,443 survives)" || fail "apply clobbered the live reservation: $(grep reserved "$STUB_LOG")"
grep -qE '^net.ipv4.ip_local_reserved_ports = 49152-49999$' "$SYS" && pass "persistent sysctl.d file carries only our range" || fail "sysctl.d file carries more than our range"

# --- (9) fresh install: guard loaded before the FIRST coturn container start -------
i_g=$(grep -n -m1 '^systemd_guard_early$' install.sh || true); i_g=${i_g%%:*}
i_c2=$(grep -n -m1 '(cd "\$PREFIX_ETC" && .*docker compose up -d)' install.sh || true); i_c2=${i_c2%%:*}
[[ -n $i_g && -n $i_c2 && $i_g -lt $i_c2 ]] && pass "install.sh loads the guard (systemd_guard_early) before the first docker compose up" \
	|| fail "install.sh must call systemd_guard_early before Step 6's docker compose up (guard line=${i_g:-none}, compose line=${i_c2:-none})"
need lib/install-systemd.sh '^systemd_guard_early\(\) \{' "systemd_guard_early is defined"
need lib/install-systemd.sh 'systemctl enable --now oxpulse-coturn-self-relay-guard.service \\$' "systemd_guard_early enables+starts the guard and dies if it cannot"

# --- (2) truthful status ------------------------------------------------------------
mkstatus() { # mkstatus NAME -> sets SD with a healthy fixture
	SD="$TMP/st_$1"; rm -rf "$SD"; mkdir -p "$SD/proc/4242" "$SD/bin"
	printf '%s\n' "type filter hook output priority mangle; policy accept;" \
		"meta skuid ${g_uid} fib daddr type local meta l4proto udp udp dport != ${g_min}-${g_max} counter packets 0 bytes 0 drop" > "$SD/chain"
	printf 'Name:\tturnserver\nUid:\t%s\t%s\t%s\t%s\n' "$g_uid" "$g_uid" "$g_uid" "$g_uid" > "$SD/proc/4242/status"
	printf '%s\n' "${g_min}-${g_max}" > "$SD/reserved"
	printf 'min-port=%s\nmax-port=%s\nstatic-auth-secret=x\n' "$g_min" "$g_max" > "$SD/coturn.conf"
	printf '#!/bin/bash\n[[ "$*" == *"list chain"* ]] && cat "%s/chain"\nexit 0\n' "$SD" > "$SD/bin/nft"
	printf '#!/bin/bash\necho 4242\n' > "$SD/bin/pgrep"
	printf '#!/bin/bash\nexit 0\n' > "$SD/bin/ss"
	chmod +x "$SD/bin/nft" "$SD/bin/pgrep" "$SD/bin/ss"
}
status_rc() { # status_rc -> rc of `guard status` against $SD
	NFT="$SD/bin/nft" PGREP_BIN="$SD/bin/pgrep" SS_BIN="$SD/bin/ss" PROC_DIR="$SD/proc" \
		RESERVED_PORTS_FILE="$SD/reserved" COTURN_CONF="$SD/coturn.conf" "$REPO_ROOT/$GUARD" status >"$SD/out" 2>&1
}
mkstatus ok;  status_rc && pass "status: healthy fixture -> in force (rc 0)" || fail "status failed on a healthy fixture: $(cat "$SD/out")"
mkstatus uid; printf 'Uid:\t0\t0\t0\t0\n' > "$SD/proc/4242/status"
status_rc && fail "status passed while turnserver runs as ROOT (the table matches nothing)" || pass "status FAILS when the running turnserver is not uid ${g_uid}"
mkstatus uid2; printf 'Uid:\t%s\t0\t0\t0\n' "$g_uid" > "$SD/proc/4242/status"
status_rc && fail "status passed with effective uid 0" || pass "status FAILS on a mixed real/effective uid"
mkstatus noproc; printf '#!/bin/bash\nexit 1\n' > "$SD/bin/pgrep"
status_rc && pass "status: no turnserver running -> nothing to be wrong about (rc 0)" || fail "status failed with no turnserver process: $(cat "$SD/out")"
mkstatus rng; printf 'min-port=%s\nmax-port=65535\n' "$g_min" > "$SD/coturn.conf"
status_rc && fail "status passed with coturn.conf max-port=65535" || pass "status FAILS when the deployed conf's max-port differs from the guard range"
mkstatus rng2; printf 'min-port=%s\n' "$g_min" > "$SD/coturn.conf"
status_rc && fail "status passed with no max-port (coturn default 65535)" || pass "status FAILS when the deployed conf has no max-port (coturn default is 49152-65535)"
mkstatus rng3; printf 'min-port=1024\nmax-port=%s\n' "$g_max" > "$SD/coturn.conf"
status_rc && fail "status passed with min-port=1024" || pass "status FAILS when the deployed conf's min-port differs"
mkstatus stray; printf '%s\n' 'UNCONN 0 0 0.0.0.0:49500 0.0.0.0:* users:(("hysteria",pid=7,fd=3))' > "$SD/ssout"
printf '#!/bin/bash\n[[ "$*" == *-uanp* ]] && cat "%s/ssout"\nexit 0\n' "$SD" > "$SD/bin/ss"
status_rc && fail "status passed with a foreign UDP socket inside the relay range" || pass "status FAILS when a non-turnserver socket sits inside ${g_min}-${g_max}"
mkstatus own; printf '%s\n' 'UNCONN 0 0 0.0.0.0:49500 0.0.0.0:* users:(("turnserver",pid=7,fd=3))' > "$SD/ssout"
printf '#!/bin/bash\n[[ "$*" == *-uanp* ]] && cat "%s/ssout"\nexit 0\n' "$SD" > "$SD/bin/ss"
status_rc && pass "status: turnserver's own relay sockets are fine" || fail "status flagged coturn's own relay socket: $(cat "$SD/out")"
mkstatus norule; printf 'type filter hook output priority mangle; policy accept;\n' > "$SD/chain"
status_rc && fail "status passed without the drop rule" || pass "status FAILS when the rule set lacks the drop rule"
mkstatus noresv; printf '80,443\n' > "$SD/reserved"
status_rc && fail "status passed with the range unreserved" || pass "status FAILS when the relay range is not reserved"
mkstatus widerr; printf '49000-50500\n' > "$SD/reserved"
status_rc && pass "status: a wider reservation that covers the range is in force" || fail "status rejected a covering reservation: $(cat "$SD/out")"

# --- (3) firewalld/ufw legacy 49152-65535 range -------------------------------------
fwtest() { # fwtest FILE -> runs _firewall_apply_firewalld with a recording firewall-cmd
	local f="$1" fb="$TMP/fwbin_$$"; mkdir -p "$fb"; : > "$fb/calls"
	printf '#!/bin/bash\necho "$*" >> "%s/calls"\nexit 0\n' "$fb" > "$fb/firewall-cmd"; chmod +x "$fb/firewall-cmd"
	( export PATH="$fb:$PATH" PE_FW_EDGE_SUBNETS="172.18.0.0/16"; log() { :; }; warn() { :; }
	  # shellcheck disable=SC1090
	  . "$REPO_ROOT/$f"; _firewall_apply_firewalld 51820 ) >/dev/null 2>&1
	cat "$fb/calls"
}
for fwf in lib/firewall-lib.sh lib/install-firewall.sh; do
	calls=$(fwtest "$fwf")
	rm_ln=$(grep -n -m1 -e '--permanent --zone=public --remove-port=49152-65535/udp' <<<"$calls" || true); rm_ln=${rm_ln%%:*}
	add_ln=$(grep -n -m1 -e "--permanent --zone=public --add-port=${g_min}-${g_max}/udp" <<<"$calls" || true); add_ln=${add_ln%%:*}
	[[ -n $rm_ln && -n $add_ln ]] && pass "$fwf (firewalld) removes the legacy 49152-65535/udp and adds ${g_min}-${g_max}/udp" \
		|| fail "$fwf firewalld calls lack remove(legacy)=${rm_ln:-none} / add(new)=${add_ln:-none}"
done

# guard-side cleanup (plain upgrade never runs firewall_apply): firewalld + ufw stubs
FW="$TMP/fwg"; mkdir -p "$FW"
printf '#!/bin/bash\necho "firewall-cmd $*" >> "%s/calls"\n[[ "$*" == *--state* ]] && exit 0\n[[ "$*" == *--query-port=49152-65535/udp* ]] && exit "${LEGACY_RC:-0}"\nexit 0\n' "$FW" > "$FW/firewall-cmd"
printf '#!/bin/bash\necho "ufw $*" >> "%s/calls"\n[[ "$1" == status ]] && echo "49152:65535/udp ALLOW Anywhere"\nexit 0\n' "$FW" > "$FW/ufw"
chmod +x "$FW/firewall-cmd" "$FW/ufw"; : > "$FW/calls"
FIREWALL_CMD="$FW/firewall-cmd" UFW_BIN="$FW/ufw" COTURN_CONF=/nonexistent run_guard "$REPO_ROOT/$GUARD" apply >/dev/null 2>&1
fc=$(cat "$FW/calls")
a1=$(grep -n -m1 -e "firewall-cmd --permanent --zone=public --add-port=${g_min}-${g_max}/udp" <<<"$fc" || true); a1=${a1%%:*}
r1=$(grep -n -m1 -e 'firewall-cmd --permanent --zone=public --remove-port=49152-65535/udp' <<<"$fc" || true); r1=${r1%%:*}
[[ -n $a1 && -n $r1 && $a1 -lt $r1 ]] && pass "apply (plain-upgrade path): firewalld legacy range removed AFTER the narrow range is added" || fail "firewalld cleanup missing/misordered: $fc"
ua=$(grep -n -m1 -e "ufw allow ${g_min}:${g_max}/udp" <<<"$fc" || true); ua=${ua%%:*}
ud=$(grep -n -m1 -e 'ufw --force delete allow 49152:65535/udp' <<<"$fc" || true); ud=${ud%%:*}
[[ -n $ua && -n $ud && $ua -lt $ud ]] && pass "apply: ufw legacy range removed AFTER the narrow range is allowed" || fail "ufw cleanup missing/misordered: $fc"
: > "$FW/calls"; LEGACY_RC=1 FIREWALL_CMD="$FW/firewall-cmd" UFW_BIN=/nonexistent COTURN_CONF=/nonexistent run_guard "$REPO_ROOT/$GUARD" apply >/dev/null 2>&1
grep -q -e '--remove-port\|--add-port' "$FW/calls" && fail "clean firewalld node was touched" || pass "apply: clean node (no legacy rule) -> firewalld untouched"

# --- (4) no exec channel into coturn: probes use a fresh locked-down container ------
PR="$TMP/probe"; mkdir -p "$PR/bin" "$PR/etc"
cat > "$PR/bin/docker" <<'EOF'
#!/bin/bash
echo "$*" >> "$PROBE_LOG"
[[ "$1" == inspect ]] && { echo "ghcr.io/anatolykoptev/partner-edge-coturn:v9.9.9"; exit 0; }
exit 0
EOF
printf '#!/bin/bash\nshift\nexec "$@"\n' > "$PR/bin/timeout"
chmod +x "$PR/bin/docker" "$PR/bin/timeout"
printf 'external-ip=203.0.113.9/10.0.0.9\nstatic-auth-secret=first=sec/ret+\nstatic-auth-secret=second\n' > "$PR/etc/coturn.conf"
export PROBE_LOG="$PR/log"; : > "$PROBE_LOG"
probe_out=$(
	export PATH="$PR/bin:$PATH"
	log() { :; }; warn() { :; }
	_NODE_CONFIG="$PR/etc/node-config.json"
	# shellcheck disable=SC1091
	. "$REPO_ROOT/lib/channel-health-lib.sh"
	_coturn_probe_run 7 turnutils_uclient -u user -w pw -y -n 1 -p 3478 203.0.113.9
	echo "SECRET=$(_coturn_conf_value static-auth-secret)"
	echo "EXT=$(_coturn_conf_value external-ip)"
)
want="run --rm --init --pull never --network host --read-only --cap-drop ALL --user 65534:65534 --entrypoint timeout ghcr.io/anatolykoptev/partner-edge-coturn:v9.9.9 7 turnutils_uclient -u user -w pw -y -n 1 -p 3478 203.0.113.9"
[[ $(grep -a '^run ' "$PROBE_LOG") == "$want" ]] && pass "probe helper: docker run --rm --init, host net, read-only, cap-drop ALL, uid 65534, in-container timeout, configured image" \
	|| fail "probe argv wrong: $(cat "$PROBE_LOG")"
[[ -z $(grep -aE '^exec |[[:space:]]exec[[:space:]]' "$PROBE_LOG" || true) ]] && pass "probe helper never issues docker exec" || fail "docker exec issued: $(cat "$PROBE_LOG")"
[[ $probe_out == *"SECRET=first=sec/ret+"* && $probe_out != *second* ]] && pass "secret = FIRST static-auth-secret line of the host conf ('=' preserved)" || fail "secret read wrong: $probe_out"
[[ $probe_out == *"EXT=203.0.113.9/10.0.0.9"* ]] && pass "external-ip read from the host conf" || fail "external-ip read wrong: $probe_out"
# the probes themselves must not carry a docker-exec any more (behaviourally: a stub
# that fails every `exec` still lets the helper's callers work; the structural check
# above in this file pins the call sites)
need lib/cross-probe-lib.sh '_coturn_probe_run "\$stun_timeout"' "cross-probe uses the shared helper"
need lib/channel-health-lib.sh '_coturn_probe_run 10 turnutils_uclient' "ch4 Allocate probe uses the shared helper"
need lib/channel-health-lib.sh '_coturn_probe_run 10 turnutils_stunclient' "ch4 STUN fallback uses the shared helper"

# --- (5) sync_host_scripts really APPLIES the guard ---------------------------------
sync_with_systemctl_log() { # sync_with_systemctl_log DRY_RUN -> prints the systemctl calls
	local T="$TMP/sync$1"; rm -rf "$T"; mkdir -p "$T/bin" "$T/sd" "$T/sbin" "$T/share" "$T/etc" "$T/lib" "$T/bin2"
	: > "$T/sd/oxpulse-coturn-self-relay-guard.service"
	printf '#!/bin/bash\necho "$*" >> "%s/systemctl.log"\nexit 0\n' "$T" > "$T/bin/systemctl"
	printf '#!/bin/bash\nexit 22\n' > "$T/bin/curl"
	chmod +x "$T/bin/systemctl" "$T/bin/curl"
	(
		export PATH="$T/bin:$PATH"
		log() { :; }; warn() { :; }; die() { echo "die: $*" >&2; exit 9; }
		SYSTEMD_DIR="$T/sd"; SYSTEMCTL_BIN="$T/bin/systemctl"; STATE_FILE="$T/etc/state"
		PREFIX_SBIN="$T/sbin"; PREFIX_SHARE="$T/share"; PREFIX_BIN="$T/bin2"; PREFIX_ETC="$T/etc"; PREFIX_LIBDIR="$T/lib"
		REPO_RAW=https://fixture.invalid; RELEASES_BASE=https://fixture.invalid/r; DRY_RUN=$1; ALLOW_UNVERIFIED=1
		PREV_HOST_SCRIPTS_DIR="$T/prev"
		_HOST_SCRIPT_SBIN_FILES=(); _HOST_SCRIPT_SYSTEMD_FILES=(); _HOST_SCRIPT_SYSTEMD_TEMPLATED_FILES=()
		_HOST_SCRIPT_ENABLE_UNITS=(); _HOST_SCRIPT_RESTART_UNITS=()
		# the REAL apply set from upgrade.sh
		eval "$(awk '/^_HOST_SCRIPT_APPLY_UNITS=\(/,/^\)/' "$REPO_ROOT/upgrade.sh")"
		# shellcheck disable=SC1091
		. "$REPO_ROOT/lib/host-scripts-lib.sh"
		sync_host_scripts latest
	) >/dev/null 2>&1
	cat "$T/systemctl.log" 2>/dev/null || true
}
sc=$(sync_with_systemctl_log 0)
[[ $sc == *"reload-or-restart oxpulse-coturn-self-relay-guard.service"* ]] \
	&& pass "sync_host_scripts (real, stub SYSTEMCTL_BIN) invokes reload-or-restart on the guard unit" \
	|| fail "sync_host_scripts never reload-or-restarted the guard (systemctl calls: $(tr '\n' ';' <<<"$sc"))"
sc=$(sync_with_systemctl_log 1)
[[ $sc != *"reload-or-restart"* ]] && pass "sync_host_scripts --dry-run applies nothing" || fail "dry-run reload-or-restarted the guard"

# --- real nft syntax check when the host has nft (CI runner / operator box) -----
# `nft -c` still opens a netlink socket, so it needs CAP_NET_ADMIN: run it directly
# with the capability, else via passwordless sudo (GitHub runners have it). Only a
# pure capability error with no sudo available is a SKIP; anything else is a FAIL.
if command -v nft >/dev/null 2>&1; then
	"$REPO_ROOT/$GUARD" render > "$TMP/real.nft" 2>/dev/null
	nft_cmd=(nft)
	if [[ $(id -u) -ne 0 ]] && command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then nft_cmd=(sudo -n nft); fi
	if "${nft_cmd[@]}" -c -f "$TMP/real.nft" >"$TMP/nft.err" 2>&1; then pass "nft -c accepts the generated ruleset"
	elif [[ ${nft_cmd[0]} == nft ]] && grep -qiE 'operation not permitted|permission denied|cache initialization' "$TMP/nft.err"; then
		echo "SKIP: nft -c needs CAP_NET_ADMIN and no root/sudo here"
	else fail "nft rejects the generated ruleset: $(cat "$TMP/nft.err")"; fi
else echo "SKIP: nft not installed — syntax checked by the live acceptance probe"; fi

echo
if [[ $FAILS -eq 0 ]]; then echo "All coturn guard tests passed."; exit 0; fi
echo "$FAILS coturn guard check(s) FAILED."; exit 1
