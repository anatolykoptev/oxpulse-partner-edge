#!/usr/bin/env bash
# tests/test_secret_file_modes.sh — secret-bearing files under PREFIX_ETC are
# never group/world readable, and a one-shot repair tightens nodes that were
# provisioned with the old modes.
#
# Silent-failure surface: a wrong mode produces no error anywhere; the file just
# stays readable by every local user.  Each case below turns RED under a named
# one-line mutation (see "Falsification").
#
#   M1  atomic_swap default mode            (coturn/xray callers + default)
#   M2  coturn caller   atomic_swap ... 0600
#   M3  xray_client caller atomic_swap ... 0600
#   M4  channel-render-lib _backup_secret_file: install -m 0600 -> cp -a
#   M5  channel-render-lib re_render_xray must back up through the helper
#   R1  repair: dir 0750, secrets 0600, naive 0640 root:65532, public files untouched,
#       never loosens, idempotent
#   R2  sync_host_scripts calls harden_prefix_etc_perms (plain-upgrade path)
#   R3  reconcile_all dispatches the prefix_etc_perms surface + manifest registers it
#
# Falsification (each must turn the named case RED):
#   lib/reconcile.sh   coturn  atomic_swap ... 0600 -> 0644     => M2
#   lib/reconcile.sh   xray    atomic_swap ... 0600 -> 0644     => M3
#   lib/reconcile.sh   atomic_swap default ${3:-0600} -> 0644   => M1
#   channel-render-lib.sh _backup_secret_file install -m 0600 -> cp -a => M4
#   lib/host-scripts-lib.sh remove the harden_prefix_etc_perms call in sync_host_scripts => R2
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
RECONCILE="$REPO_ROOT/lib/reconcile.sh"
HSL="$REPO_ROOT/lib/host-scripts-lib.sh"
CRL="$REPO_ROOT/channel-render-lib.sh"
PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
mode() { stat -c %a "$1"; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# ---------------------------------------------------------------------------
# M1-M3: drive the real surfaces with stub opec/docker.
# ---------------------------------------------------------------------------
out=$(
	set +e
	cd "$T"
	log() { :; }; warn() { :; }; die() { echo "DIE: $*" >&2; exit 1; }
	# shellcheck source=/dev/null
	. "$RECONCILE"
	ETC="$T/etc"; mkdir -p "$ETC" "$T/state"
	export PREFIX_ETC="$ETC" STATE_DIR="$T/state" DOCKER_BIN=true
	# The render env needs node-config.json / STATE; irrelevant to the mode — stub.
	_setup_coturn_render_env() { return 0; }
	_setup_xray_client_render_env() {
		export REALITY_PUBLIC_KEY=k REALITY_UUID=u REALITY_SHORT_ID=s REALITY_ENCRYPTION=e BACKEND_HOST=h BACKEND_PORT=1
	}
	_reconcile_emit_prom_gauge() { :; }
	# opec stub: write a deterministic candidate to --out.
	opec() {
		local out=""
		while (( $# )); do [[ "$1" == "--out" ]] && out="$2"; shift; done
		[[ -n "$out" ]] && printf 'static-auth-secret=s3cret\n' > "$out"
	}
	tpl="$T/x.tpl"; : > "$tpl"
	# A previously-installed world-readable file whose content differs -> forces a swap.
	printf 'old\n' > "$ETC/coturn.conf";      chmod 0644 "$ETC/coturn.conf"
	printf 'old\n' > "$ETC/xray-client.json"; chmod 0644 "$ETC/xray-client.json"
	reconcile_coturn_surface "$ETC" "$tpl" >/dev/null 2>&1
	reconcile_xray_client_surface "$ETC" "$tpl" >/dev/null 2>&1
	echo "COTURN_MODE=$(stat -c %a "$ETC/coturn.conf")"
	echo "XRAY_MODE=$(stat -c %a "$ETC/xray-client.json")"
	echo "COTURN_BODY=$(cat "$ETC/coturn.conf")"
	echo "XRAY_BODY=$(cat "$ETC/xray-client.json")"
	# M1: default-mode swap.
	: > "$T/cand"; printf 'x\n' > "$T/cand"
	atomic_swap "$ETC/default-mode.bin" "$T/cand"
	echo "DEFAULT_MODE=$(stat -c %a "$ETC/default-mode.bin")"
	# Caddyfile-style explicit 0644 still honoured.
	printf 'x\n' > "$T/cand2"; atomic_swap "$ETC/Caddyfile" "$T/cand2" 0644
	echo "EXPLICIT_MODE=$(stat -c %a "$ETC/Caddyfile")"
) 2>&1 || true
get() { printf '%s\n' "$out" | sed -n "/^$1=/{s/^$1=//;p;q;}"; }
[[ "$(get COTURN_BODY)" == "static-auth-secret=s3cret" ]] || fail "setup: coturn surface did not swap (harness broken): $out"
[[ "$(get XRAY_BODY)" == "static-auth-secret=s3cret" ]] || fail "setup: xray surface did not swap (harness broken)"
[[ "$(get COTURN_MODE)" == "600" ]] && pass "M2: coturn.conf swapped to 0600 (was 0644)" || fail "M2: coturn.conf mode is $(get COTURN_MODE), want 600"
[[ "$(get XRAY_MODE)" == "600" ]] && pass "M3: xray-client.json swapped to 0600 (was 0644)" || fail "M3: xray-client.json mode is $(get XRAY_MODE), want 600"
[[ "$(get DEFAULT_MODE)" == "600" ]] && pass "M1: atomic_swap default mode is 0600" || fail "M1: atomic_swap default mode is $(get DEFAULT_MODE), want 600"
[[ "$(get EXPLICIT_MODE)" == "644" ]] && pass "M1b: explicit 0644 (Caddyfile caller) still honoured" || fail "M1b: explicit mode not honoured"

# ---------------------------------------------------------------------------
# M4/M5: backups.
# ---------------------------------------------------------------------------
out=$(
	set +e
	log() { :; }; warn() { :; }; die() { echo "DIE: $*" >&2; exit 1; }
	export PREFIX_ETC="$T/etc2"; mkdir -p "$PREFIX_ETC"
	# shellcheck source=/dev/null
	. "$CRL" >/dev/null 2>&1
	f="$PREFIX_ETC/xray-client.json"
	printf '{}\n' > "$f"; chmod 0644 "$f"          # the legacy world-readable live file
	# 8 pre-existing epoch backups (oldest first) + one non-epoch backup that must survive.
	for i in 1 2 3 4 5 6 7 8; do printf 'b%s\n' "$i" > "$f.bak.170000000$i"; done
	printf 'keep\n' > "$f.bak.pre-migration"
	_backup_secret_file "$f"
	newest=$(printf '%s\n' "$f".bak.[0-9]* | sort -r | sed -n 1p)
	echo "NEW_MODE=$(stat -c %a "$newest")"
	echo "NEPOCH=$(printf '%s\n' "$f".bak.[0-9]* | wc -l)"
	echo "OLDEST_GONE=$([[ ! -e "$f.bak.1700000001" ]] && echo yes || echo no)"
	echo "NEWER_KEPT=$([[ -e "$f.bak.1700000008" ]] && echo yes || echo no)"
	echo "NONEPOCH_KEPT=$([[ -e "$f.bak.pre-migration" ]] && echo yes || echo no)"
) 2>&1 || true
[[ "$(get NEW_MODE)" == "600" ]] && pass "M4: backup of a 0644 file is 0600" || fail "M4: backup mode is $(get NEW_MODE), want 600 ($out)"
[[ "$(get NEPOCH)" == "5" ]] && pass "M4b: epoch backups pruned to the newest 5" || fail "M4b: $(get NEPOCH) epoch backups remain, want 5"
[[ "$(get OLDEST_GONE)" == "yes" && "$(get NEWER_KEPT)" == "yes" ]] && pass "M4c: pruning drops the oldest, keeps the newest" || fail "M4c: wrong backups pruned"
[[ "$(get NONEPOCH_KEPT)" == "yes" ]] && pass "M4d: non-epoch backup is never pruned" || fail "M4d: non-epoch backup deleted"
# M5: both writers go through the helper (no cp -a of a secret file left).
if grep -nE 'cp -a "\$(XRAY_CFG|NODE_CFG)"' "$CRL" >/dev/null; then
	fail "M5: channel-render-lib.sh still copies a secret config with cp -a"
elif [[ "$(grep -c '_backup_secret_file "\$\(XRAY_CFG\|NODE_CFG\)"' "$CRL")" -eq 2 ]]; then
	pass "M5: xray-client.json and node-config.json backups both use _backup_secret_file"
else
	fail "M5: expected 2 _backup_secret_file call sites in channel-render-lib.sh"
fi

# ---------------------------------------------------------------------------
# R1: the repair.
# ---------------------------------------------------------------------------
out=$(
	set +e
	log() { :; }; warn() { echo "WARN: $*"; }; die() { exit 1; }
	chown() { echo "chown $*" >> "$T/chown.log"; }   # not root in CI
	export DRY_RUN=0
	# shellcheck source=/dev/null
	. "$HSL"
	D="$T/etc3"; mkdir -p "$D"; chmod 0755 "$D"
	for f in reality.uuid xray-client.json xray-client.json.bak.1700000001 coturn.conf coturn.conf.pre-v0.16.20 \
		node-config.json node-config.json.bak.1700000002 hysteria2-client.yaml hysteria2-client.yaml.bak.1 \
		something.bad-render naive-client.json.bak.5; do
		printf 'secret\n' > "$D/$f"; chmod 0644 "$D/$f"
	done
	for f in reality.pub awg-public.key Caddyfile .env xray.env docker-compose.yml; do printf 'pub\n' > "$D/$f"; chmod 0644 "$D/$f"; done
	printf 'ro\n' > "$D/node-config.json.bak.9"; chmod 0400 "$D/node-config.json.bak.9"   # matched AND tighter than 0600: must NOT be loosened
	printf 'n\n' > "$D/naive-client.json"; chmod 0644 "$D/naive-client.json"
	ln -s "$D/Caddyfile" "$D/coturn.conf.link"                        # symlink: must be skipped
	harden_prefix_etc_perms "$D"
	for f in reality.uuid xray-client.json xray-client.json.bak.1700000001 coturn.conf coturn.conf.pre-v0.16.20 \
		node-config.json node-config.json.bak.1700000002 hysteria2-client.yaml hysteria2-client.yaml.bak.1 \
		something.bad-render naive-client.json.bak.5 node-config.json.bak.9 naive-client.json \
		reality.pub awg-public.key Caddyfile .env xray.env docker-compose.yml; do
		echo "M[$f]=$(stat -c %a "$D/$f")"
	done
	echo "DIR=$(stat -c %a "$D")"
	echo "CHOWN=$(cat "$T/chown.log" 2>/dev/null | tr '\n' ';')"
	snap1=$(cd "$D" && stat -c '%n %a' * .env | sort | md5sum)
	harden_prefix_etc_perms "$D"
	snap2=$(cd "$D" && stat -c '%n %a' * .env | sort | md5sum)
	echo "IDEMPOTENT=$([[ "$snap1" == "$snap2" ]] && echo yes || echo no)"
	harden_prefix_etc_perms "$T/does-not-exist"; echo "MISSING_DIR_RC=$?"
) 2>&1 || true
m() { printf '%s\n' "$out" | sed -n "/^M\[$1\]=/{s/^M\[$1\]=//;p;q;}"; }
bad=""
for f in reality.uuid xray-client.json xray-client.json.bak.1700000001 coturn.conf coturn.conf.pre-v0.16.20 \
	node-config.json node-config.json.bak.1700000002 hysteria2-client.yaml hysteria2-client.yaml.bak.1 \
	something.bad-render naive-client.json.bak.5 node-config.json.bak.9; do
	want=600; [[ "$f" == node-config.json.bak.9 ]] && want=400
	[[ "$(m "$f")" == "$want" ]] || bad="$bad $f=$(m "$f")"
done
[[ -z "$bad" ]] && pass "R1a: every secret-bearing file/backup is 0600 (a 0400 backup is not loosened)" || fail "R1a: wrong modes:$bad"
[[ "$(get DIR)" == "750" ]] && pass "R1b: PREFIX_ETC dir tightened 0755 -> 0750" || fail "R1b: dir mode $(get DIR), want 750"
bad=""
for f in reality.pub awg-public.key Caddyfile .env xray.env docker-compose.yml; do [[ "$(m "$f")" == "644" ]] || bad="$bad $f=$(m "$f")"; done
[[ -z "$bad" ]] && pass "R1c: public 0644 files untouched" || fail "R1c: public files changed:$bad"
[[ "$(m naive-client.json)" == "640" && "$(get CHOWN)" == *"root:65532"*"naive-client.json"* ]] \
	&& pass "R1d: naive-client.json -> 0640 + chown root:65532" || fail "R1d: naive mode=$(m naive-client.json) chown=$(get CHOWN)"
[[ "$(get IDEMPOTENT)" == "yes" ]] && pass "R1e: second run changes nothing" || fail "R1e: not idempotent"
[[ "$(get MISSING_DIR_RC)" == "0" ]] && pass "R1f: missing dir is a no-op (rc 0)" || fail "R1f: missing dir rc=$(get MISSING_DIR_RC)"

# ---------------------------------------------------------------------------
# R2/R3: the repair is wired on the plain-upgrade path AND the templates path.
# ---------------------------------------------------------------------------
sync_body=$(awk '/^sync_host_scripts\(\)/,/^}/' "$HSL")
if printf '%s\n' "$sync_body" | grep -E '^[[:space:]]*harden_prefix_etc_perms ' >/dev/null; then
	pass "R2: sync_host_scripts (every upgrade path) calls harden_prefix_etc_perms"
else
	fail "R2: sync_host_scripts does not call harden_prefix_etc_perms — the plain self-upgrade path would not repair nodes"
fi
all_body=$(awk '/^reconcile_all\(\)/,/^}/' "$RECONCILE")
if printf '%s\n' "$all_body" | grep -E 'prefix_etc_perms\)' >/dev/null \
	&& printf '%s\n' "$all_body" | grep -E 'reconcile_prefix_etc_perms_surface ' >/dev/null \
	&& awk '/^  - id: prefix_etc_perms$/{f=1;next} f&&/^  - id:/{exit} f&&/kind: sync_verified/{ok=1} END{exit !ok}' "$REPO_ROOT/manifest.yaml"; then
	pass "R3: manifest registers prefix_etc_perms (sync_verified) and reconcile_all dispatches it"
else
	fail "R3: prefix_etc_perms surface not registered/dispatched"
fi
# R3b: the surface wrapper reaches the lib's implementation.
d3="$T/etc4"; mkdir -p "$d3"; printf 's\n' > "$d3/reality.uuid"; chmod 0644 "$d3/reality.uuid"
(
	log() { :; }; warn() { :; }; die() { exit 1; }
	# shellcheck source=/dev/null
	. "$RECONCILE"
	HOST_SCRIPTS_LIB="$HSL" reconcile_prefix_etc_perms_surface "$d3"
) >/dev/null 2>&1 || true
[[ "$(mode "$d3/reality.uuid")" == "600" ]] && pass "R3b: reconcile_prefix_etc_perms_surface tightens reality.uuid" || fail "R3b: surface wrapper did not repair"

echo ""
echo "secret-file-modes: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
