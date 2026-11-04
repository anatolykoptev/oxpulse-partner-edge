#!/bin/bash
# tests/test_retire_ch3.sh — CH3 (hysteria2) is retired; the edge tears it down
# on its own decision (channel-render-lib.sh: retire_hysteria2_ch3).
#
# What is silent if it breaks:
#   1. a node keeps a crash-looping hysteria2 container (rvpn: 30,440 restarts)
#   2. the `ch3` profile survives in .env, so the next `compose up` brings the
#      container back
#   3. the teardown touches a neighbouring container or the .env COMPOSE_FILE
#      line (rvpn's docker-compose.override.yml)
#   4. the yaml is deleted while the container survives: docker restarts it and
#      creates a DIRECTORY where the bind-mount source used to be
#   5. a second run, or a run on a node that never had CH3 (pillow), changes
#      something
#
# `docker` is a PATH shim over a fixture file; no daemon is needed.
set -uo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LIB="$REPO_ROOT/channel-render-lib.sh"
[[ -f "$LIB" ]] || { echo "FAIL: $LIB not found"; exit 1; }

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# Fake node. $TMP/containers is the "daemon": one container name per line.
# $TMP/calls records every mutating docker call as "<cwd>|<args>".
setup() {
	TMP="$(mktemp -d)"
	ETC="$TMP/etc"; VAR="$TMP/var"; SBIN="$TMP/sbin"; BIN="$TMP/bin"
	mkdir -p "$ETC" "$VAR" "$SBIN" "$BIN"
	: > "$TMP/calls"
	cat > "$BIN/docker" <<'DOCKER'
#!/bin/bash
C="$FAKE_DOCKER_STATE"
case "$1" in
  ps) cat "$C/containers" ;;
  rm)
    echo "$PWD|$*" >> "$C/calls"
    [[ -n "${FAKE_RM_FAILS:-}" ]] && exit 1
    grep -vx "${@: -1}" "$C/containers" > "$C/containers.t"; mv -f "$C/containers.t" "$C/containers" ;;
  compose)
    echo "$PWD|$*" >> "$C/calls"
    # Only `--profile ch3 rm -sf hysteria2-client` is ever expected.
    if [[ "$*" == *"rm -sf hysteria2-client"* && -z "${FAKE_COMPOSE_RM_FAILS:-}" ]]; then
      grep -vx oxpulse-partner-hysteria2 "$C/containers" > "$C/containers.t"; mv -f "$C/containers.t" "$C/containers"
    else
      exit 1
    fi ;;
  *) echo "$PWD|$*" >> "$C/calls" ;;
esac
exit 0
DOCKER
	chmod +x "$BIN/docker"
	export FAKE_DOCKER_STATE="$TMP" PATH="$BIN:$PATH"
	export PREFIX_ETC="$ETC" PREFIX_LIB="$VAR" PREFIX_SBIN="$SBIN" DOCKER_BIN=docker
	unset FAKE_RM_FAILS FAKE_COMPOSE_RM_FAILS
}
teardown() { rm -rf "$TMP"; }

# A node with CH3 as rvpn had it: container, yaml + backup, sha, ch3 in the
# profiles next to COMPOSE_FILE, status active, the two helper scripts.
fixture_ch3_node() {
	printf '%s\n' oxpulse-partner-xray oxpulse-partner-hysteria2 oxpulse-partner-caddy oxpulse-partner-sfu > "$TMP/containers"
	echo "server: x"  > "$ETC/hysteria2-client.yaml"
	echo "server: old" > "$ETC/hysteria2-client.yaml.bak.1700000000"
	echo "deadbeef" > "$VAR/hysteria2-config.sha"
	printf 'COMPOSE_FILE=docker-compose.yml:docker-compose.override.yml\nCOMPOSE_PROFILES=ch3,ch5\n' > "$ETC/.env"
	printf '# Generated\nxray=active\nhysteria2=active\nnaive=active\nawg=active\n' > "$VAR/channels-status.env"
	: > "$SBIN/oxpulse-partner-edge-enable-hy2"; : > "$SBIN/hydrate-hy2.sh"
}
# A node that never had CH3 (pillow): other containers, metrics profile, skipped.
fixture_clean_node() {
	printf '%s\n' oxpulse-partner-xray oxpulse-partner-caddy > "$TMP/containers"
	printf 'COMPOSE_FILE=docker-compose.yml\nCOMPOSE_PROFILES=metrics\n' > "$ETC/.env"
	printf '# Generated\nxray=active\nhysteria2=skipped\nnaive=active\nawg=active\n' > "$VAR/channels-status.env"
}
# Everything the teardown could change, in one comparable blob.
snapshot() { ( cd "$TMP" && find etc var sbin containers -type f -print0 | sort -z | xargs -0 md5sum; ) ; }
mutations() { wc -l < "$TMP/calls" | tr -d ' '; }

run_lib() {   # [lib-path]
	# shellcheck source=/dev/null  # LIB or a mutant copy of it
	( set -e; . "${1:-$LIB}" ; retire_hysteria2_ch3 ) > "$TMP/out" 2>&1
}

echo ""
echo "=== retire_hysteria2_ch3 (channel-render-lib.sh) ==="

# 1 — full teardown on an rvpn-shaped node
setup; fixture_ch3_node; run_lib; rc=$?
[[ $rc -eq 0 ]] && pass "teardown exits 0" || fail "teardown exit $rc: $(cat "$TMP/out")"
! grep -qx oxpulse-partner-hysteria2 "$TMP/containers" && pass "hysteria2 container removed" || fail "hysteria2 container still present"
[[ "$(sort "$TMP/containers" | tr '\n' ' ')" == "oxpulse-partner-caddy oxpulse-partner-sfu oxpulse-partner-xray " ]] \
	&& pass "other containers untouched" || fail "other containers changed: $(tr '\n' ' ' < "$TMP/containers")"
[[ ! -e "$ETC/hysteria2-client.yaml" && ! -e "$ETC/hysteria2-client.yaml.bak.1700000000" && ! -e "$VAR/hysteria2-config.sha" ]] \
	&& pass "yaml, its backup and the sha removed" || fail "CH3 config left behind: $(ls "$ETC" "$VAR" | tr '\n' ' ')"
[[ ! -e "$SBIN/oxpulse-partner-edge-enable-hy2" && ! -e "$SBIN/hydrate-hy2.sh" ]] \
	&& pass "CH3-only host scripts removed" || fail "enable-hy2 / hydrate-hy2.sh left in sbin"
grep -qx 'COMPOSE_PROFILES=ch5' "$ETC/.env" && ! grep -q 'ch3' "$ETC/.env" \
	&& pass "ch3 dropped from COMPOSE_PROFILES, ch5 kept" || fail ".env profiles wrong: $(cat "$ETC/.env")"
grep -qx 'COMPOSE_FILE=docker-compose.yml:docker-compose.override.yml' "$ETC/.env" \
	&& pass ".env COMPOSE_FILE (the override file) preserved" || fail "COMPOSE_FILE line lost: $(cat "$ETC/.env")"
grep -qx 'hysteria2=retired' "$VAR/channels-status.env" \
	&& [[ "$(grep -c '^hysteria2=' "$VAR/channels-status.env")" == 1 ]] \
	&& pass "channels-status.env: hysteria2=retired (once)" || fail "channels-status wrong: $(cat "$VAR/channels-status.env")"
[[ "$(grep -v '^hysteria2=' "$VAR/channels-status.env" | tr '\n' ';')" == "# Generated;xray=active;naive=active;awg=active;" ]] \
	&& pass "other channel statuses untouched" || fail "other statuses changed: $(cat "$VAR/channels-status.env")"
[[ "$(grep -c . "$TMP/out")" == 1 ]] && grep -q 'CH3 (hysteria2) retired' "$TMP/out" \
	&& pass "exactly one log line" || fail "log output: $(cat "$TMP/out")"
# Compose is driven from the node's project dir (so .env's COMPOSE_FILE applies)
# and only ever names the hysteria2 service.
grep -q "^$ETC|compose --profile ch3 rm -sf hysteria2-client\$" "$TMP/calls" \
	&& pass "compose rm runs in the project dir with --profile ch3, service hysteria2-client only" \
	|| fail "compose invocation wrong: $(cat "$TMP/calls")"
! grep -E 'restart|down|stop|up |xray|caddy|sfu' "$TMP/calls" >/dev/null \
	&& pass "no docker call touches another service" || fail "other docker call: $(cat "$TMP/calls")"

# 2 — a second run is a no-op
before="$(snapshot)"; : > "$TMP/calls"
run_lib; rc=$?
[[ $rc -eq 0 && "$(snapshot)" == "$before" && "$(mutations)" == 0 && ! -s "$TMP/out" ]] \
	&& pass "second run: nothing changed, no docker mutation, no output" \
	|| fail "second run not a no-op (rc=$rc calls=$(mutations) out=$(cat "$TMP/out"))"
teardown

# 3 — node that never had CH3
setup; fixture_clean_node; before="$(snapshot)"
run_lib; rc=$?
[[ $rc -eq 0 && "$(snapshot)" == "$before" && "$(mutations)" == 0 && ! -s "$TMP/out" ]] \
	&& pass "node without CH3: no-op (files byte-identical, no docker mutation, silent)" \
	|| fail "touched a node without CH3 (rc=$rc calls=$(mutations) out=$(cat "$TMP/out"))"
teardown

# 4 — .env holding only the ch3 profile: the line goes, nothing else is invented
setup; fixture_ch3_node; printf 'COMPOSE_PROFILES=ch3\n' > "$ETC/.env"; run_lib
[[ ! -s "$ETC/.env" ]] && pass ".env with only ch3: profile line removed" || fail ".env still has: $(cat "$ETC/.env")"
teardown

# 5 — the profile alone (container + yaml already gone, e.g. a half-finished earlier run)
setup; fixture_clean_node; printf 'COMPOSE_FILE=a.yml\nCOMPOSE_PROFILES=metrics,ch3\n' > "$ETC/.env"; run_lib
grep -qx 'COMPOSE_PROFILES=metrics' "$ETC/.env" && grep -qx 'COMPOSE_FILE=a.yml' "$ETC/.env" \
	&& pass "stale ch3 profile alone is dropped, other profiles and COMPOSE_FILE kept" || fail ".env: $(cat "$ETC/.env")"
teardown

# 6 — compose cannot remove it (the live compose no longer defines the service):
#     fall back to docker rm -f by exact name
setup; fixture_ch3_node; export FAKE_COMPOSE_RM_FAILS=1; run_lib
! grep -qx oxpulse-partner-hysteria2 "$TMP/containers" && grep -q '|rm -f oxpulse-partner-hysteria2$' "$TMP/calls" \
	&& pass "compose rm failing falls back to docker rm -f oxpulse-partner-hysteria2" \
	|| fail "no fallback (containers: $(tr '\n' ' ' < "$TMP/containers") calls: $(cat "$TMP/calls"))"
teardown

# 7 — the container cannot be removed at all: the yaml MUST stay (docker would
#     recreate the missing bind-mount source as a directory), exit stays 0
setup; fixture_ch3_node; export FAKE_COMPOSE_RM_FAILS=1 FAKE_RM_FAILS=1; run_lib; rc=$?
[[ $rc -eq 0 && -f "$ETC/hysteria2-client.yaml" && -f "$VAR/hysteria2-config.sha" ]] \
	&& pass "container stuck: config kept (no bind-mount directory trap), exit 0" \
	|| fail "config deleted while container survives (rc=$rc): $(ls "$ETC")"
grep -q 'ch3' "$ETC/.env" && grep -qx 'hysteria2=active' "$VAR/channels-status.env" \
	&& pass "container stuck: nothing else changed, next cycle retries" || fail "partial state written: $(cat "$ETC/.env")"
teardown

# --- mutation: skip the profile removal ---------------------------------------
# Same fixture, the lib with step 3 disabled. Test 1's profile assertions must
# fail — proving they, not the fixture, carry the check.
setup; fixture_ch3_node
MUT="$TMP/mutant-channel-render-lib.sh"
sed 's/^    if (( have_profile )); then$/    if false; then/' "$LIB" > "$MUT"
if cmp -s "$LIB" "$MUT"; then
	fail "mutation did not apply (pattern drifted) — fix the sed in this test"
else
	run_lib "$MUT"
	if grep -q 'ch3' "$ETC/.env"; then
		pass "MUTANT (profile removal skipped) is caught: ch3 survives in .env"
	else
		fail "mutant not caught: ch3 vanished from .env anyway"
	fi
fi
teardown

# --- wiring ------------------------------------------------------------------
# A teardown nobody calls is decoration. Call sites, in the order that matters.
UPG="$REPO_ROOT/upgrade.sh"; REF="$REPO_ROOT/oxpulse-partner-edge-refresh.sh"
ln_of() { grep -n -m1 -- "$2" "$1" | cut -d: -f1; }

# upgrade.sh, both apply paths: after sync_host_scripts, BEFORE the pre-change
# baseline. Collect every call site and every baseline site and pair them up.
mapfile -t calls < <(grep -n '^[[:space:]]*_retire_ch3_best_effort$' "$UPG" | cut -d: -f1)
mapfile -t bases < <(grep -n 'health_snapshot "\$HEALTHCHECK" "\$_\(wt_\)\?baseline_snap\(shot\)\?"' "$UPG" | cut -d: -f1)
if [[ ${#calls[@]} -eq 2 && ${#bases[@]} -eq 2 && ${calls[0]} -lt ${bases[0]} && ${calls[1]} -lt ${bases[1]} ]]; then
	pass "upgrade.sh: teardown runs before the baseline snapshot in both apply paths"
else
	fail "upgrade.sh wiring: calls=(${calls[*]:-}) baselines=(${bases[*]:-})"
fi
t_ln=$(ln_of "$UPG" 'retire_hysteria2_ch3$'); [[ -n "$t_ln" ]] \
	&& pass "upgrade.sh --templates-only calls retire_hysteria2_ch3" || fail "upgrade.sh --templates-only does not call the teardown"

r_ln=$(ln_of "$REF" 'retire_hysteria2_ch3 )'); d_ln=$(ln_of "$REF" '^_rederive_channels_status$')
[[ -n "$r_ln" && -n "$d_ln" && $r_ln -lt $d_ln ]] \
	&& pass "refresh.sh: teardown runs every cycle, before the channels_version block" || fail "refresh.sh wiring (teardown=$r_ln rederive=$d_ln)"

# The upgrade helper end to end: sources the freshly synced lib in a subshell
# and runs the teardown; a missing lib never fails the upgrade.
setup; fixture_ch3_node
cp "$LIB" "$SBIN/channel-render-lib.sh"
helper="$(awk '/^_retire_ch3_best_effort\(\) \{/,/^}/' "$UPG")"
( warn() { echo "WARN $*"; }; log() { echo "$*"; }; eval "$helper"; _retire_ch3_best_effort ) > "$TMP/out" 2>&1; rc=$?
[[ $rc -eq 0 ]] && ! grep -qx oxpulse-partner-hysteria2 "$TMP/containers" && [[ ! -e "$ETC/hysteria2-client.yaml" ]] \
	&& pass "_retire_ch3_best_effort: sources the synced lib and tears CH3 down" || fail "helper did not tear down (rc=$rc): $(cat "$TMP/out")"
rm -f "$SBIN/channel-render-lib.sh"
( warn() { echo "WARN $*"; }; log() { echo "$*"; }; eval "$helper"; _retire_ch3_best_effort ) > "$TMP/out" 2>&1; rc=$?
[[ $rc -eq 0 ]] && grep -q 'WARN' "$TMP/out" && pass "_retire_ch3_best_effort: missing lib warns and returns 0" || fail "missing lib: rc=$rc $(cat "$TMP/out")"
teardown

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
