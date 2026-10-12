#!/bin/bash
# tests/test_coturn_guard.sh — coturn self-relay guard (incident 2026-10-12).
#
# coturn (network_mode: host) relays a TURN client's UDP to any peer it names; the
# credentials are public. Defence is layered and every layer must hold:
#   image    : turnserver runs as a FIXED numeric non-root uid
#   host nft : table inet coturn_self_relay_guard drops coturn->local UDP outside
#              the SFU port and the relay range (keyed on that numeric uid)
#   kernel   : the relay range is reserved from the ephemeral pool
#   config   : coturn.conf allows ONLY this host's own relay address; min/max-port = that range
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
# `ip -o addr show` seam: this fake host owns pillow-like addresses; anything else
# (e.g. 10.9.9.9) is NOT local. The guard's locality checks run against it.
cat > "$TMP/bin/ip" <<'EOF'
#!/bin/bash
[[ "$*" == *"addr show"* ]] || exit 0
printf '%s\n' \
 '1: lo    inet 127.0.0.1/8 scope host lo' \
 '2: ens3    inet 10.0.1.44/24 brd 10.0.1.255 scope global ens3' \
 '2: ens3    inet 10.0.1.160/24 brd 10.0.1.255 scope global secondary ens3' \
 '2: ens3    inet6 fe80::1/64 scope link'
EOF
chmod +x "$TMP/bin/ip"
export IP_BIN="$TMP/bin/ip"
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
# coturn.conf.tpl: the placeholder, once, and no literal allowed-peer-ip= (a literal
# would be rendered on every edge, public-NIC ones included).
[[ $(grep -c '^{{ALLOWED_PEER_IP_LINE}}$' "$TPL") == 1 ]] && pass "coturn.conf.tpl has the {{ALLOWED_PEER_IP_LINE}} placeholder exactly once" || fail "coturn.conf.tpl must carry exactly one {{ALLOWED_PEER_IP_LINE}}"
nocode "$TPL" '^allowed-peer-ip=' "coturn.conf.tpl has no literal allowed-peer-ip="
for f in install.sh hydrate.sh lib/reconcile.sh; do
	# the line is derived from THIS host's PRIVATE_IP only, never from anything else
	need "$f" 'ALLOWED_PEER_IP_LINE="allowed-peer-ip=\$\{PRIVATE_IP' "$f renders allowed-peer-ip from PRIVATE_IP (own address) only"
	need "$f" 'ALLOWED_PEER_IP_LINE=""|ALLOWED_PEER_IP_LINE=$' "$f renders it empty when there is no private address"
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
allowed-peer-ip=10.0.1.160
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
[[ $(grep -c '^allowed-peer-ip=' "$MIG/coturn.conf" || true) == 1 && $(grep -c '^allowed-peer-ip=10.0.1.44$' "$MIG/coturn.conf" || true) == 1 ]] \
	&& pass "migration: exactly ONE allowed-peer-ip survives - this host's own (10.0.1.44); the secondary local address 10.0.1.160 (not a relay address, not needed) is gone" \
	|| fail "migration: allowed-peer-ip lines are $(grep -a '^allowed-peer-ip=' "$MIG/coturn.conf" | tr '\n' ' ')"
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

# own-address rule (the v0.16.29 regression: deleting the own allowed-peer-ip broke
# same-edge relaying with 403 Forbidden IP on a NAT edge)
own_cases() { # own_cases NAME CONTENT-HEREDOC-ON-STDIN -> migrates, sets $OC to the file
	OC="$MIG/own_$1.conf"; cat > "$OC"; chmod "${2:-600}" "$OC"
	COTURN_CONF="$OC" "$REPO_ROOT/$GUARD" migrate-conf >/dev/null 2>&1
}
aip() { grep -a '^allowed-peer-ip=' "$OC" | tr '\n' ' '; }
own_cases relayip 644 <<'EOF'
listening-port=3478
static-auth-secret=S1
relay-ip=10.0.1.44
external-ip=203.0.113.5
allowed-peer-ip=10.0.1.44
allowed-peer-ip=10.0.1.160
min-port=49152
max-port=65535
EOF
[[ $(aip) == "allowed-peer-ip=10.0.1.44 " ]] && pass "relay-ip + own and a secondary-IP allowed-peer-ip -> exactly the own one is kept" || fail "relay-ip case kept: $(aip)"
[[ $(grep -a -n 'allowed-peer-ip=10.0.1.44' "$OC" | cut -d: -f1) -gt $(grep -a -n '^relay-ip=' "$OC" | cut -d: -f1) ]] && pass "existing own line stays where it was (after relay-ip)" || fail "own line moved"
[[ $(fmode "$OC") == 600 ]] && pass "migration forces mode 0600 (was 0644 with static-auth-secret inside)" || fail "mode is $(fmode "$OC"), want 600"
own_cases emit 600 <<'EOF'
static-auth-secret=S1
relay-ip=10.0.1.44
allowed-peer-ip=10.0.1.160
max-port=49999
min-port=49152
EOF
[[ $(aip) == "allowed-peer-ip=10.0.1.44 " ]] && pass "own allowed-peer-ip is EMITTED when missing (secondary-IP one dropped)" || fail "emit case: $(aip)"
[[ $(grep -a -A1 '^relay-ip=' "$OC" | tail -n1) == "allowed-peer-ip=10.0.1.44" ]] && pass "emitted right after relay-ip=" || fail "emitted line not after relay-ip"
own_cases natext 600 <<'EOF'
static-auth-secret=S1
external-ip=203.0.113.5/10.0.1.44
min-port=49152
max-port=49999
EOF
[[ $(aip) == "allowed-peer-ip=10.0.1.44 " ]] && pass "no relay-ip: own address = private half of external-ip, emitted" || fail "external-ip/private case: $(aip)"
own_cases pubnic 600 <<'EOF'
static-auth-secret=S1
external-ip=203.0.113.5
allowed-peer-ip=10.0.1.44
min-port=49152
max-port=65535
EOF
[[ -z $(aip) ]] && pass "public-NIC edge (no relay-ip, no private half): NO allowed-peer-ip" || fail "public-NIC kept: $(aip)"
cp "$OC" "$OC.1"; COTURN_CONF="$OC" "$REPO_ROOT/$GUARD" migrate-conf >/dev/null 2>&1
cmp -s "$OC" "$OC.1" && pass "own-address migration is idempotent" || fail "second migration changed the conf"
# --- locality: the own address must be configured on THIS host --------------------
own_cases stale 600 <<'EOF'
static-auth-secret=S1
relay-ip=10.9.9.9
allowed-peer-ip=10.9.9.9
min-port=49152
max-port=49999
EOF
[[ -z $(aip) ]] && pass "migrate: a NON-local relay address (10.9.9.9) -> its allowed-peer-ip is dropped (fail closed)" || fail "migrate kept an allowance to a non-local address: $(aip)"
mig_warn=$(COTURN_CONF="$MIG/own_stale.conf" "$REPO_ROOT/$GUARD" migrate-conf 2>&1; printf 'static-auth-secret=S1\nrelay-ip=10.9.9.9\nallowed-peer-ip=10.9.9.9\nmin-port=49152\nmax-port=49999\n' > "$MIG/own_stale2.conf"; COTURN_CONF="$MIG/own_stale2.conf" "$REPO_ROOT/$GUARD" migrate-conf 2>&1)
[[ $mig_warn == *"NOT a local address"* ]] && pass "migrate logs loudly that the relay address is not local" || fail "no loud log for a non-local relay address: $mig_warn"
own_cases stale_ext 600 <<'EOF'
static-auth-secret=S1
external-ip=203.0.113.5/10.9.9.9
min-port=49152
max-port=49999
EOF
[[ -z $(aip) ]] && pass "migrate: a non-local private half of external-ip -> no line emitted" || fail "emitted for a non-local external-ip half: $(aip)"
own_cases local_ok 600 <<'EOF'
static-auth-secret=S1
relay-ip=10.0.1.44
min-port=49152
max-port=49999
EOF
[[ $(aip) == "allowed-peer-ip=10.0.1.44 " ]] && pass "migrate: a LOCAL relay address keeps/emits its allowed-peer-ip" || fail "local own address not honoured: $(aip)"
# --- renderer (reconcile) resolves the line against the LIVE addresses --------------
render_line() { # render_line PUBLIC PRIVATE -> prints ALLOWED_PEER_IP_LINE
	(
		log() { :; }; warn() { echo "WARN $*" >&2; }; die() { echo "die: $*" >&2; exit 9; }
		export IP_BIN PARTNER_DOMAIN=example.com TURNS_SUBDOMAIN=turns TURN_SECRET=s PUBLIC_IP="$1" PRIVATE_IP="$2" STATE_FILE=/nonexistent
		# shellcheck disable=SC1091
		. "$REPO_ROOT/lib/reconcile.sh"
		_setup_coturn_render_env "$TMP/nonexistent-etc" >/dev/null 2>&1
		printf '%s' "${ALLOWED_PEER_IP_LINE-UNSET}"
	)
}
[[ $(render_line 203.0.113.5 10.0.1.44) == "allowed-peer-ip=10.0.1.44" ]] && pass "reconcile renderer: NAT'd + local PRIVATE_IP -> allowed-peer-ip=<own>" || fail "renderer line: $(render_line 203.0.113.5 10.0.1.44)"
[[ -z $(render_line 203.0.113.5 10.9.9.9) ]] && pass "reconcile renderer: STALE (non-local) PRIVATE_IP -> no allowed-peer-ip" || fail "renderer allowed a non-local PRIVATE_IP: $(render_line 203.0.113.5 10.9.9.9)"
[[ -z $(render_line 203.0.113.5 203.0.113.5) ]] && pass "reconcile renderer: PRIVATE_IP == PUBLIC_IP -> none" || fail "renderer emitted for PRIVATE==PUBLIC"
[[ -z $(render_line 203.0.113.5 "") ]] && pass "reconcile renderer: no PRIVATE_IP -> none" || fail "renderer emitted without a private IP"

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

# mode fix alone does not restart coturn
printf 'static-auth-secret=S1\nrelay-ip=10.0.1.44\nallowed-peer-ip=10.0.1.44\nmin-port=49152\nmax-port=49999\n' > "$MIG/modeonly.conf"; chmod 0644 "$MIG/modeonly.conf"
: > "$STUB_LOG"
COTURN_CONF="$MIG/modeonly.conf" DOCKER_BIN="$TMP/bin/docker" run_guard "$REPO_ROOT/$GUARD" apply >/dev/null 2>&1
[[ $(fmode "$MIG/modeonly.conf") == 600 ]] && pass "apply fixes a 0644 conf in place" || fail "mode-only conf still $(fmode "$MIG/modeonly.conf")"
grep -q 'docker restart' "$STUB_LOG" && fail "coturn restarted for a mode-only change" || pass "mode-only fix does not restart coturn"


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
mkstatus aip1; printf 'min-port=%s\nmax-port=%s\nrelay-ip=10.0.1.44\nexternal-ip=203.0.113.5\n' "$g_min" "$g_max" > "$SD/coturn.conf"
status_rc && fail "status passed with relay-ip set but NO allowed-peer-ip (same-edge relaying is broken: 403 Forbidden IP)" || pass "status FAILS when relay-ip is set but the matching allowed-peer-ip is missing"
mkstatus aip2; printf 'min-port=%s\nmax-port=%s\nrelay-ip=10.0.1.44\nallowed-peer-ip=10.0.1.44\n' "$g_min" "$g_max" > "$SD/coturn.conf"
status_rc && pass "status: relay-ip + exactly its own allowed-peer-ip is in force" || fail "status rejected the correct NAT conf: $(cat "$SD/out")"
mkstatus aip3; printf 'min-port=%s\nmax-port=%s\nexternal-ip=203.0.113.5/10.0.1.44\nallowed-peer-ip=10.0.1.44\nallowed-peer-ip=10.0.1.160\n' "$g_min" "$g_max" > "$SD/coturn.conf"
status_rc && fail "status passed with an extra allowed-peer-ip" || pass "status FAILS on any allowed-peer-ip other than this host's own"
mkstatus aip4; printf 'min-port=%s\nmax-port=%s\nexternal-ip=203.0.113.5\nallowed-peer-ip=10.0.1.44\n' "$g_min" "$g_max" > "$SD/coturn.conf"
status_rc && fail "status passed with allowed-peer-ip on a public-NIC edge" || pass "status FAILS when a public-NIC edge carries an allowed-peer-ip"
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

mkstatus loc1; printf 'min-port=%s\nmax-port=%s\nrelay-ip=10.9.9.9\nallowed-peer-ip=10.9.9.9\n' "$g_min" "$g_max" > "$SD/coturn.conf"
status_rc && fail "status passed with a NON-local relay address whose allowed-peer-ip matches the conf (conf compared with itself)" || pass "status FAILS when the relay address is not configured on a local interface"
mkstatus loc2; printf 'min-port=%s\nmax-port=%s\nexternal-ip=203.0.113.5/10.9.9.9\nallowed-peer-ip=10.9.9.9\n' "$g_min" "$g_max" > "$SD/coturn.conf"
status_rc && fail "status passed with a non-local private half of external-ip" || pass "status FAILS when the private half of external-ip is not local"
mkstatus loc3; printf 'min-port=%s\nmax-port=%s\nrelay-ip=10.0.1.44\nexternal-ip=132.145.192.254\nallowed-peer-ip=10.0.1.44\n' "$g_min" "$g_max" > "$SD/coturn.conf"
status_rc && pass "status: pillow's real shape (relay-ip local + own allowed-peer-ip) is in force" || fail "status rejected pillow's conf: $(cat "$SD/out")"

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

# guard-side firewall convergence (plain upgrade never runs firewall_apply).
# The stub models REAL firewalld 1.3 semantics, verified in rockylinux:9 on 2026-10-12
# (firewall-offline-cmd): add-port of a range COVERED by an existing entry is a no-op
# (WARNING ALREADY_ENABLED), remove-port removes only an EXACT entry, --list-ports
# prints the entries. State = $FWS/perm and $FWS/run (one entry per line).
# FW_ADD_NOOP=<LO-HI>: add-port of that range silently does nothing (a failed add).
FW="$TMP/fwg"; mkdir -p "$FW"
install -m 0755 "$REPO_ROOT/tests/fixtures/stateful-firewall-cmd.sh" "$FW/firewall-cmd"
cat > "$FW/ufw" <<'UFWEOF'
#!/bin/bash
echo "ufw $*" >> "$FWS/calls"; touch "$FWS/ufw.state"
case "$1" in
	status) echo "Status: ${UFW_STATUS:-active}"; cat "$FWS/ufw.state" ;;
	allow) echo "$2 ALLOW Anywhere" >> "$FWS/ufw.state" ;;
	--force) grep -vF "${4} " "$FWS/ufw.state" > "$FWS/ufw.n" || true; mv "$FWS/ufw.n" "$FWS/ufw.state" ;;
esac
exit 0
UFWEOF
chmod +x "$FW/firewall-cmd" "$FW/ufw"
export FWS="$FW"
fwreset() { rm -f "$FW/perm" "$FW/run" "$FW/ufw.state" "$FW/calls"; touch "$FW/calls"; }
fwset() { printf '%s\n' "$@" > "$FW/perm"; printf '%s\n' "$@" > "$FW/run"; } # same entries both scopes
fwstate() { echo "perm=[$(tr '\n' ' ' < "$FW/perm")] run=[$(tr '\n' ' ' < "$FW/run")]"; }
fwgrd() { FIREWALL_CMD="$FW/firewall-cmd" UFW_BIN="${UFW:-/nonexistent}" COTURN_CONF="${CONF:-/nonexistent}" run_guard "$REPO_ROOT/$GUARD" "$@" >/dev/null 2>"$FW/err"; }

# F1: THE rvpn incident. Legacy range present, narrow range covered by it -> after apply the
# zone must hold exactly the narrow range in BOTH scopes (it used to hold nothing).
fwreset; fwset 49152-65535/udp 3478/udp
fwgrd apply
want="perm=[3478/udp ${g_min}-${g_max}/udp ] run=[3478/udp ${g_min}-${g_max}/udp ]"
[[ $(fwstate) == "$want" ]] && pass "apply: legacy 49152-65535 retired and ${g_min}-${g_max}/udp in force (permanent + runtime)" \
	|| fail "apply left the wrong zone state (the rvpn no-relay-range bug): $(fwstate)"

# F2: the narrow add silently fails -> the legacy range must be RESTORED, never left with no range.
fwreset; fwset 49152-65535/udp
FW_ADD_NOOP="${g_min}-${g_max}" fwgrd apply
[[ $(fwstate) == "perm=[49152-65535/udp ] run=[49152-65535/udp ]" ]] && pass "apply: narrow add failed -> legacy range restored (wide beats closed)" \
	|| fail "apply failed to restore the legacy range after a failed narrow add: $(fwstate)"
grep -q 'RESTORED' "$FW/err" && pass "apply: the restore is loud (warn)" || fail "apply restored the legacy range silently"

# F3: clean node (no legacy entry, narrow range present) -> no add/remove calls at all.
fwreset; fwset "${g_min}-${g_max}/udp"
fwgrd apply
grep -qE -e '--(add|remove)-port' "$FW/calls" && fail "clean firewalld node was mutated: $(cat "$FW/calls")" || pass "apply: clean node -> firewalld untouched (idempotent)"

# F4: post-rollback shape: migrated conf (49152-49999), firewall lost its range -> firewall-sync restores it.
printf 'min-port=%s\nmax-port=%s\n' "$g_min" "$g_max" > "$TMP/fwconf"
fwreset; fwset 3478/udp
CONF="$TMP/fwconf" fwgrd firewall-sync
[[ $(fwstate) == "perm=[3478/udp ${g_min}-${g_max}/udp ] run=[3478/udp ${g_min}-${g_max}/udp ]" ]] && pass "firewall-sync: zone range follows coturn.conf min/max after a rollback" \
	|| fail "firewall-sync did not restore the conf range: $(fwstate)"

# F5: runtime-only loss (permanent kept it) is repaired too.
fwreset; fwset "${g_min}-${g_max}/udp"; : > "$FW/run"
CONF="$TMP/fwconf" fwgrd firewall-sync
fw_run=$(tr '\n' ' ' < "$FW/run"); [[ $fw_run == "${g_min}-${g_max}/udp " ]] && pass "firewall-sync: runtime scope repaired independently of permanent" || fail "runtime scope not repaired: $fw_run"

# F6: UNMIGRATED conf (no directives = coturn default 49152-65535): the legacy range is what coturn
# binds, so sync must KEEP/ensure it, not retire it under a still-old conf.
printf 'realm=x\n' > "$TMP/fwconf_old"
fwreset; fwset 49152-65535/udp
CONF="$TMP/fwconf_old" fwgrd firewall-sync
[[ $(fwstate) == "perm=[49152-65535/udp ] run=[49152-65535/udp ]" ]] && pass "firewall-sync: unmigrated conf keeps the legacy range (firewall == conf)" || fail "sync retired the range an unmigrated conf still uses: $(fwstate)"

# F7: ufw: narrow rule added, legacy deleted only once the narrow one is listed; and kept if not.
fwreset; printf '49152:65535/udp ALLOW Anywhere\n' > "$FW/ufw.state"
UFW_BIN="$FW/ufw" FIREWALL_CMD=/nonexistent COTURN_CONF=/nonexistent run_guard "$REPO_ROOT/$GUARD" apply >/dev/null 2>&1
st=$(cat "$FW/ufw.state"); { grep -q "${g_min}:${g_max}/udp" <<<"$st" && ! grep -q '49152:65535' <<<"$st"; } \
	&& pass "apply: ufw legacy range replaced by ${g_min}:${g_max}/udp" || fail "ufw state wrong: $st"
printf '#!/bin/bash\necho "ufw $*" >> "%s/calls"\n[[ "$1" == status ]] && { echo "Status: active"; echo "49152:65535/udp ALLOW Anywhere"; }\nexit 0\n' "$FW" > "$FW/ufw_noop"; chmod +x "$FW/ufw_noop"; : > "$FW/calls"
UFW_BIN="$FW/ufw_noop" FIREWALL_CMD=/nonexistent COTURN_CONF=/nonexistent run_guard "$REPO_ROOT/$GUARD" apply >/dev/null 2>&1
grep -q 'delete allow' "$FW/calls" && fail "ufw legacy rule deleted although the narrow rule never appeared" || pass "apply: ufw legacy rule kept when the narrow rule is not in force"

# F8: ufw installed but INACTIVE (pillow): nothing to manage - rc 0, no rule writes, no false alarm.
fwreset; printf '49152:65535/udp ALLOW Anywhere\n' > "$FW/ufw.state"
UFW_STATUS=inactive UFW_BIN="$FW/ufw" FIREWALL_CMD=/nonexistent COTURN_CONF="$TMP/fwconf" run_guard "$REPO_ROOT/$GUARD" firewall-sync >/dev/null 2>"$FW/err8"; rc8=$?
{ [[ $rc8 -eq 0 ]] && ! grep -qE 'ufw (allow|--force)' "$FW/calls" && ! grep -q 'blocked' "$FW/err8"; } \
	&& pass "firewall-sync: inactive ufw -> rc 0, no rule writes, no 'blocked' warning" \
	|| fail "inactive ufw mishandled (rc=$rc8): $(cat "$FW/calls" "$FW/err8")"
fwreset; : > "$FW/ufw.state"
UFW_STATUS=inactive UFW_BIN="$FW/ufw" FIREWALL_CMD=/nonexistent COTURN_CONF=/nonexistent run_guard "$REPO_ROOT/$GUARD" apply >/dev/null 2>&1 \
	&& pass "apply: inactive ufw + no firewalld -> apply succeeds" || fail "apply failed on inactive ufw"

# F9: per-scope verification. Permanent add works, RUNTIME add silently no-ops -> not "done":
# legacy must come back in both scopes, loudly. (Dropping the runtime check reports success
# with the runtime zone empty.)
fwreset; fwset 49152-65535/udp
FW_ADD_NOOP="${g_min}-${g_max}" FW_ADD_NOOP_SCOPE=run CONF="$TMP/fwconf" fwgrd firewall-sync || true
{ grep -qx '49152-65535/udp' "$FW/perm" && grep -qx '49152-65535/udp' "$FW/run"; } && pass "firewall-sync: runtime add no-op -> legacy restored in both scopes" \
	|| fail "runtime-scope failure not caught: $(fwstate)"
grep -q 'RESTORED' "$FW/err" && pass "firewall-sync: runtime-scope failure is reported" || fail "runtime-scope failure silent"

# F10: a firewall-sync failure never fails apply or unloads the nft table.
: > "$STUB_RULES"; fwreset; : > "$FW/perm"; : > "$FW/run"
FW_ADD_NOOP="${g_min}-${g_max}" FIREWALL_CMD="$FW/firewall-cmd" UFW_BIN=/nonexistent COTURN_CONF=/nonexistent run_guard "$REPO_ROOT/$GUARD" apply >/dev/null 2>&1; rc10=$?
{ [[ $rc10 -eq 0 ]] && grep -q 'table inet coturn_self_relay_guard {' "$STUB_RULES"; } \
	&& pass "apply: firewall range cannot be applied -> apply still rc 0 with the nft table loaded" \
	|| fail "firewall failure took the guard down (rc=$rc10)"

# F11: status (check_22) sees the incident state: relay range missing from the ACTIVE firewall.
mkstatus fw1; fwreset; fwset 3478/udp
FIREWALL_CMD="$FW/firewall-cmd" status_rc && fail "status passed with no relay range in firewalld" || pass "status FAILS when the active firewalld lacks the relay range"
grep -q 'not allowed' "$SD/out" && pass "status names the missing firewalld range" || fail "status message unclear: $(cat "$SD/out")"
mkstatus fw2; fwreset; fwset 3478/udp "${g_min}-${g_max}/udp"; : > "$FW/run"
FIREWALL_CMD="$FW/firewall-cmd" status_rc && fail "status passed with the runtime scope empty" || pass "status FAILS when only the runtime scope lacks the range"
mkstatus fw3; fwreset; fwset "${g_min}-${g_max}/udp"
FIREWALL_CMD="$FW/firewall-cmd" status_rc && pass "status: relay range in force in both firewalld scopes" || fail "status rejected a correct firewalld: $(cat "$SD/out")"
mkstatus fw4; fwreset
UFW_STATUS=inactive UFW_BIN="$FW/ufw" FIREWALL_CMD=/nonexistent status_rc && pass "status: inactive ufw + no firewalld -> skipped (pillow)" || fail "status failed on inactive ufw: $(cat "$SD/out")"
mkstatus fw5; fwreset; : > "$FW/ufw.state"
UFW_BIN="$FW/ufw" FIREWALL_CMD=/nonexistent status_rc && fail "status passed with active ufw lacking the range" || pass "status FAILS when active ufw lacks the relay range"

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
