#!/usr/bin/env bash
# tests/test_self_upgrade_converge_journey.sh — journey-level regression for the
# self-update convergence incident (pillow 0.16.40→0.16.41):
#
# A node may report the target release while still running old containers and
# old host scripts, then fail to retry automatically.
#
# Unlike the previous version of this test, NOTHING below reimplements the
# apply tail: every upgrade scenario drives the REAL upgrade.sh apply path in a
# temp node tree, stubbing only docker, systemctl/systemd-run, curl (fixture
# transport) and the healthcheck — the four seams the task allows.
#
#   J1  happy path: real self-update re-exec + full apply → marker lands LAST
#   J2  lock handoff: re-exec'd child keeps fd 9 → second upgrader refused
#   J3  crash window: kill -9 during pull → marker stays OLD → retry converges
#   J4  required-asset failure: missing required asset dies before any install
#       and before any image mutation
#   J5  marker↔container divergence: real upgrade.sh resumes an interrupted
#       apply instead of exiting "nothing to do"
#   J6  templated units fetched + verified from the TARGET release bundle
#   J7  refresh side (real _maybe_self_upgrade): divergence heal + bounded
#       exponential backoff + ceiling alert + metric
#
# Fixture polarity: OXPULSE_REPO_RAW=fixture://raw, OXPULSE_RELEASES_BASE=
# fixture://rel served by a curl shim (the ONLY stubbed transport).
set -u
cd "$(dirname "$0")/.."
UPGRADE="$PWD/upgrade.sh"
REFRESH="$PWD/oxpulse-partner-edge-refresh.sh"
# Upper bound for the docker stub's crash-window kill: the ancestor walk in
# DOCKER_KILL_UPGRADE must NEVER touch this PID or anything above it. Above the
# test's own shell live the agent harness / CI runner — an fd-9 holder up there
# is not a test victim. Exported so every child (run_upgrade → env →
# upgrade.sh → docker stub) inherits it.
export JOURNEY_TEST_ROOT_PID=$$
TESTS=0; FAILURES=0
pass() { TESTS=$((TESTS+1)); printf 'PASS %s\n' "$1"; }
fail() { TESTS=$((TESTS+1)); FAILURES=$((FAILURES+1)); printf 'FAIL %s\n' "$1"; }

T=$(mktemp -d); trap '[[ "$FAILURES" -eq 0 ]] && rm -rf "$T" || echo "artifacts kept: $T" >&2' EXIT

# ---------------------------------------------------------------------------
# Registry extraction — ground truth comes from upgrade.sh's own arrays, not a
# hand-copied list (a managed file added to the array is automatically part of
# the fixture).
# ---------------------------------------------------------------------------
eval "$(sed -n '/^_HOST_SCRIPT_SBIN_FILES=(/,/^)/p' "$UPGRADE")"
eval "$(sed -n '/^_HOST_SCRIPT_SYSTEMD_FILES=(/,/^)/p' "$UPGRADE")"
eval "$(sed -n '/^_HOST_SCRIPT_SYSTEMD_TEMPLATED_FILES=(/,/^)/p' "$UPGRADE")"
eval "$(awk '/^_host_script_remote_name\(\)/{f=1} f{print} f&&/^}/{exit}' "$UPGRADE")"
eval "$(awk '/^_host_script_install_dir\(\)/{f=1} f{print} f&&/^}/{exit}' "$UPGRADE")"
eval "$(awk '/^_host_script_mode\(\)/{f=1} f{print} f&&/^}/{exit}' "$UPGRADE")"
# Independent oracle for the release.yml staging contract (the consumer-side
# mapping lives inline in sync_host_scripts; this copy asserts it).
_staged_name() {
	case "$1" in
		oxpulse-partner-edge-upgrade)     echo "partner-edge-upgrade.sh" ;;
		oxpulse-partner-edge-hydrate)     echo "hydrate.sh" ;;
		render-channel-lib.sh)            echo "render-channel-lib.sh" ;;
		oxpulse-xray-update.sh)           echo "oxpulse-xray-update.sh" ;;
		oxpulse-geoip-refresh)            echo "oxpulse-geoip-refresh.sh" ;;
		oxpulse-partner-edge-healthcheck) echo "partner-edge-healthcheck.sh" ;;
		*) basename "$(_host_script_remote_name "$1")" ;;
	esac
}

# ---------------------------------------------------------------------------
# Stubbed transport + docker + systemctl (the ONLY seams we fake).
# ---------------------------------------------------------------------------
FIX="$T/fixture"; mkdir -p "$FIX/raw" "$FIX/rel"
STUBS="$T/stubs"; mkdir -p "$STUBS"

cat > "$STUBS/curl" <<'CURLSH'
#!/usr/bin/env bash
for a in "$@"; do [[ "$a" == "--version" ]] && { printf 'curl 8.5.0 fixture\n'; exit 0; }; done
out=""; url=""; prev=""
for a in "$@"; do
	[[ "$prev" == "-o" ]] && out="$a"
	case "$a" in fixture://*) url="$a";; esac
	prev="$a"
done
[[ -z "$url" ]] && exit 22
rel="${url#fixture://}"
src="${FIXTURE_ROOT:?}/$rel"
[[ -f "$src" ]] || exit 22
if [[ -n "$out" ]]; then cp "$src" "$out"; else cat "$src"; fi
exit 0
CURLSH
chmod +x "$STUBS/curl"

cat > "$STUBS/docker" <<'DSH'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "${DOCKER_CALL_LOG:?}"
case "$*" in
	*"ps"*"--filter"*)
		_rt="$(cat "${DOCKER_RUNNING_TAG_FILE:?}" 2>/dev/null || true)"
		[[ -n "$_rt" ]] && printf 'ghcr.io/anatolykoptev/partner-edge-sfu:%s\n' "$_rt"
		# Extra running containers (node-exporter, stale/debug) - the real
		# `docker ps --filter name=` would list them too.
		[[ -r "${DOCKER_PS_EXTRA_FILE:-}" ]] && cat "$DOCKER_PS_EXTRA_FILE"
		exit 0 ;;
	*"config --services"*) printf 'sfu\n'; exit 0 ;;
	*"compose config"*)    cat "${COMPOSE_FILE_PATH:?}"; exit 0 ;;
	*"ps --quiet"*)        printf 'fakectr123\n'; exit 0 ;;
	*"ps"*)                printf 'fakectr123\n'; exit 0 ;;
	*"inspect"*)
		# Pulled/target image → new digest; anything else (running container,
		# old tag) → old digest. Drives the changed-services recreate decision.
		case "$*" in
			*v9.9.9*) printf 'sha256:newdigest%s\n' "00000000000000000000000000000000000000000000000000000000" ;;
			*)        printf 'sha256:olddigest%s\n' "11111111111111111111111111111111111111111111111111111111" ;;
		esac
		exit 0 ;;
	*"pull"*)
		printf 'LOCKHELD=%s\n' "${OXPULSE_UPGRADE_LOCK_HELD:-unset}" >> "${DOCKER_CALL_LOG}"
		[[ -n "${DOCKER_PULL_SLEEP:-0}" && "${DOCKER_PULL_SLEEP}" != "0" ]] && sleep "$DOCKER_PULL_SLEEP"
		if [[ "${DOCKER_KILL_UPGRADE:-0}" == "1" ]]; then
			# Kill -9 the WORKER — the ancestor that actually holds the upgrade
			# flock on fd 9. cmdline matching cannot distinguish the processes:
			# the $(...) subshell, the worker and the logging-wrapper parent all
			# share one cmdline. fd 9 resolves the ambiguity: the wrapper never
			# opens it, so the OUTERMOST fd-9 holder is the worker. Killing an
			# inner subshell would take the handled-rollback path instead of the
			# unhandled crash we are simulating.
			#
			# The walk is BOUNDED at JOURNEY_TEST_ROOT_PID (the test's own
			# shell): it is never considered a candidate and the walk never goes
			# above it — an fd-9 holder up there is the agent harness or a CI
			# runner, not a test victim. Reaching PID 1 without meeting the test
			# root means the stub is not inside the test's subtree: fail loudly
			# and kill nothing.
			if [[ -z "${JOURNEY_TEST_ROOT_PID:-}" ]]; then
				echo "DOCKER_KILL_UPGRADE: JOURNEY_TEST_ROOT_PID unset — refusing to kill" >&2
				exit 1
			fi
			_p=$PPID _victim=""
			while [[ "$_p" =~ ^[0-9]+$ && "$_p" -gt 1 && "$_p" != "$JOURNEY_TEST_ROOT_PID" ]]; do
				[[ -e "/proc/$_p/fd/9" ]] && _victim=$_p
				_p=$(ps -o ppid= -p "$_p" 2>/dev/null | tr -d ' ')
			done
			if [[ "$_p" != "$JOURNEY_TEST_ROOT_PID" ]]; then
				echo "DOCKER_KILL_UPGRADE: ancestor walk reached PID ${_p:-end} without meeting test root $JOURNEY_TEST_ROOT_PID — refusing to kill" >&2
				exit 1
			fi
			[[ -n "$_victim" ]] && kill -KILL "$_victim" 2>/dev/null
		fi
		exit "${DOCKER_PULL_RC:-0}" ;;
	*"up -d"*)
		sed -nE 's|.*partner-edge-sfu:([^ "]+).*|\1|p' "${COMPOSE_FILE_PATH}" | head -n1 > "${DOCKER_RUNNING_TAG_FILE}"
		exit "${DOCKER_UP_RC:-0}" ;;
	*) exit 0 ;;
esac
DSH
chmod +x "$STUBS/docker"

cat > "$STUBS/systemctl" <<'SSH'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "${SYSTEMCTL_CALL_LOG:-/dev/null}"
for a in "$@"; do
	case "$a" in is-enabled) printf 'enabled\n'; exit 0;; esac
done
case "$*" in
	*"ActiveState"*) printf '%s\n' "${SELFUP_STATE:-inactive}"; exit 0 ;;
	*"is-active --quiet"*) exit 0 ;;
	*) exit 0 ;;
esac
SSH
chmod +x "$STUBS/systemctl"

cat > "$STUBS/systemd-run" <<'SRH'
#!/usr/bin/env bash
printf 'systemd-run %s\n' "$*" >> "${SDRUN_CALL_LOG:-/dev/null}"
exit "${SDRUN_RC:-0}"
SRH
chmod +x "$STUBS/systemd-run"

# Deterministic clock for the backoff tests: `date +%s` reads FAKE_EPOCH_FILE
# when set, otherwise delegates to the real date.
cat > "$STUBS/date" <<'DTSH'
#!/usr/bin/env bash
case "$*" in
	*+%s*) [[ -n "${FAKE_EPOCH_FILE:-}" ]] && { cat "$FAKE_EPOCH_FILE"; exit 0; } ;;
esac
exec /bin/date "$@"
DTSH
chmod +x "$STUBS/date"

# ---------------------------------------------------------------------------
# build_node NODE_DIR — a temp "installed" node. $2=marker version (vX.Y.Z),
# $3=upgrader bytes variant ("old"|"new").
# ---------------------------------------------------------------------------
NEW_UPG_SHA_MARK="# release-bytes v9.9.9"
build_node() {
	local N="$1" marker="$2" variant="${3:-old}"
	mkdir -p "$N"/{etc,lib,sbin/lib,bin,libdir,share/oxpulse-partner-edge/config,systemd,snaps}
	cat > "$N/lib/install.env" <<ENV
IMAGE_VERSION=$marker
SIGNALING_SFU_SECRET=testsecret
PARTNER_DOMAIN=edge.example.com
TURNS_SUBDOMAIN=turn.edge.example.com
BACKEND_API=https://api.oxpulse.chat
ENV
	cat > "$N/etc/docker-compose.yml" <<YML
services:
  sfu:
    image: ghcr.io/anatolykoptev/partner-edge-sfu:$marker
    environment:
      SIGNALING_SFU_SECRET: "testsecret"
YML
	# Installed upgrader bytes: "old" = current script + old marker (differs
	# from the fixture release → self-update re-exec fires); "new" = current.
	cp "$UPGRADE" "$N/sbin/oxpulse-partner-edge-upgrade"
	[[ "$variant" == old ]] && printf '\n# old-installed-bytes\n' >> "$N/sbin/oxpulse-partner-edge-upgrade"
	chmod +x "$N/sbin/oxpulse-partner-edge-upgrade"
	# Functional sbin stubs (sourced/executed by the real path).
	cat > "$N/sbin/channel-render-lib.sh" <<'CRL'
refetch_node_config() { return 0; }
re_render_xray() { return 0; }
retire_hysteria2_ch3() { return 0; }
CRL
	cat > "$N/sbin/ghcr-auth-lib.sh" <<'GAL'
ghcr_configure_token() { return 0; }
ghcr_login_from_file() { return 0; }
ghcr_pull_diagnose() { return 0; }
GAL
	for s in oxpulse-partner-edge-selfheal oxpulse-channels-health-report \
	         oxpulse-partner-edge-healthcheck oxpulse-partner-edge-hydrate \
	         oxpulse-partner-edge-refresh oxpulse-partner-edge-sni-rotate \
	         oxpulse-partner-edge-coturn-guard oxpulse-geoip-refresh \
	         oxpulse-partner-edge-split-routing oxpulse-partner-edge-split-disable \
	         oxpulse-partner-edge-ru-subnets-update; do
		printf '#!/usr/bin/env bash\nexit 0\n' > "$N/sbin/$s"; chmod +x "$N/sbin/$s"
	done
	for l in sni-select-lib.sh render-channel-lib.sh oxpulse-token-lib.sh \
	         telegram-alert-lib.sh peer-ip-guard-lib.sh channel-health-lib.sh \
	         cross-probe-lib.sh metric-sink-lib.sh surgical-restart-lib.sh \
	         xprb-refresh-lib.sh; do
		printf '# old lib %s\n' "$l" > "$N/sbin/$l"
	done
	printf '#!/usr/bin/env bash\nexit 0\n' > "$N/sbin/telegram-alert-lib.sh"   # still a lib file; contents unused
	printf 'tg_alert() { printf "ALERT %%s\\n" "$*" >> "${ALERT_LOG:-/dev/null}"; }\n' > "$N/sbin/telegram-alert-lib.sh"
	# tier-1 libs for the sbin run (real repo libs) + stub install-awg.sh
	for l in reconcile.sh compose-lib.sh healthcheck-lib.sh host-scripts-lib.sh \
	         install-firewall.sh telegram-alert-lib.sh; do
		cp "lib/$l" "$N/sbin/lib/$l"
	done
	printf 'ensure_amneziawg() { return 0; }\n' > "$N/sbin/lib/install-awg.sh"
	( cd "$N/sbin/lib" && sha256sum ./* > lib-checksums.txt )
	# tier-2 INSTALL_LIB_DIR for the re-exec'd child (same real libs)
	for l in reconcile.sh compose-lib.sh healthcheck-lib.sh host-scripts-lib.sh \
	         install-firewall.sh telegram-alert-lib.sh; do
		cp "lib/$l" "$N/libdir/$l"
	done
	printf 'ensure_amneziawg() { return 0; }\n' > "$N/libdir/install-awg.sh"
	( cd "$N/libdir" && sha256sum ./* > lib-checksums.txt )
	# bin (xray-update target dir) + misc installed files
	printf '#!/usr/bin/env bash\nexit 0\n' > "$N/bin/oxpulse-xray-update.sh"; chmod +x "$N/bin/oxpulse-xray-update.sh"
	printf '# old defaults\n' > "$N/share/oxpulse-partner-edge/config/defaults.conf"
	printf 'v0.0.1\n' > "$N/share/oxpulse-partner-edge/VERSION"
	# container runtime state: running tag mirrors the marker by default
	printf '%s\n' "${marker#v}" > "$N/running_tag"
	: > "$N/running_tag_marker"; printf 'v%s\n' "${marker#v}" > "$N/running_tag_marker" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# build_release DIR TAG — the "new release" bundle + SHA256SUMS.
# ---------------------------------------------------------------------------
build_release() {
	local D="$1" tag="$2" f an u
	mkdir -p "$D"
	for f in "${_HOST_SCRIPT_SBIN_FILES[@]}"; do
		an=$(_staged_name "$f")
		case "$f" in
			oxpulse-partner-edge-upgrade)
				cp "$UPGRADE" "$D/$an"; printf '\n%s\n' "$NEW_UPG_SHA_MARK" >> "$D/$an" ;;
			channel-render-lib.sh)
				printf 'refetch_node_config() { return 0; }\nre_render_xray() { return 0; }\nretire_hysteria2_ch3() { return 0; }\n' > "$D/$an" ;;
			ghcr-auth-lib.sh)
				printf 'ghcr_configure_token() { return 0; }\nghcr_login_from_file() { return 0; }\nghcr_pull_diagnose() { return 0; }\n' > "$D/$an" ;;
			install-awg.sh)
				printf 'ensure_amneziawg() { return 0; }\n' > "$D/$an" ;;
			telegram-alert-lib.sh)
				printf 'tg_alert() { printf "ALERT %%s\\n" "$*" >> "${ALERT_LOG:-/dev/null}"; }\n' > "$D/$an" ;;
			oxpulse-partner-edge-healthcheck|oxpulse-partner-edge-selfheal|oxpulse-channels-health-report|oxpulse-geoip-refresh|oxpulse-xray-update.sh)
				printf '#!/usr/bin/env bash\nexit 0\n' > "$D/$an" ;;
			*) printf '# release asset %s %s\n' "$f" "$tag" > "$D/$an" ;;
		esac
	done
	for u in "${_HOST_SCRIPT_SYSTEMD_FILES[@]}"; do
		printf '[Unit]\n# release unit %s %s\n' "$u" "$tag" > "$D/$u"
	done
	# templated units: REAL repo templates (carry the {{placeholders}})
	for u in "${_HOST_SCRIPT_SYSTEMD_TEMPLATED_FILES[@]}"; do
		cp "systemd/$u" "$D/$u"
	done
	printf '%s\n' "${tag#v}" > "$D/VERSION"
	printf '# defaults %s\n' "$tag" > "$D/config-defaults.conf"
	( cd "$D" && sha256sum ./* > SHA256SUMS )
}

# ---------------------------------------------------------------------------
# run_upgrade NODE — invoke the REAL upgrade.sh apply path on NODE. Env knobs
# for the fake docker travel through OXPS_* vars.
# ---------------------------------------------------------------------------
run_upgrade() {
	local N="$1"; shift
	env \
		FIXTURE_ROOT="$FIX" \
		PATH="$STUBS:$PATH" \
		OXPULSE_PREFIX_ETC="$N/etc" \
		OXPULSE_PREFIX_LIB="$N/lib" \
		OXPULSE_PREFIX_SBIN="$N/sbin" \
		OXPULSE_PREFIX_BIN="$N/bin" \
		OXPULSE_PREFIX_LIBDIR="$N/libdir" \
		OXPULSE_PREFIX_SHARE="$N/share" \
		OXPULSE_SYSTEMD_DIR="$N/systemd" \
		INSTALL_LIB_DIR="$N/libdir" \
		OXPULSE_HEALTHCHECK="$N/sbin/oxpulse-partner-edge-healthcheck" \
		OXPULSE_CHANNELS_HEALTH_REPORT="$N/sbin/oxpulse-channels-health-report" \
		OXPULSE_SELFHEAL_BIN="$N/sbin/oxpulse-partner-edge-selfheal" \
		OXPULSE_SKIP_ROOT_CHECK=1 \
		OXPULSE_UPGRADE_TAG=v9.9.8 \
		OXPULSE_UPGRADE_LOG="$N/upgrade.log" \
		OXPULSE_UPGRADE_CGROUP_FILE=/dev/null \
		OXPULSE_REPO_RAW="fixture://raw" \
		OXPULSE_RELEASES_BASE="fixture://rel" \
		DOCKER_BIN="$STUBS/docker" \
		SYSTEMCTL_BIN="$STUBS/systemctl" \
		DOCKER_CALL_LOG="$N/docker_calls.log" \
		DOCKER_RUNNING_TAG_FILE="$N/running_tag" \
		DOCKER_STATE_FILE="$N/docker_digest_state" \
		SYSTEMCTL_CALL_LOG="$N/systemctl_calls.log" \
		COMPOSE_FILE_PATH="$N/etc/docker-compose.yml" \
		"$@" bash "$N/sbin/oxpulse-partner-edge-upgrade" v9.9.9
}

echo "=== J0: structural — marker lands AFTER pull/settle/render ==="
# The IMAGE_VERSION write must sit AFTER the render gate in BOTH apply paths.
_marker_line=$(grep -n 's|^IMAGE_VERSION=' "$UPGRADE" | tail -1 | cut -d: -f1)
_render_line=$(grep -n '_render_gate "plain-upgrade-render"' "$UPGRADE" | tail -1 | cut -d: -f1)
_pull_line=$(grep -n 'compose pull' "$UPGRADE" | tail -1 | cut -d: -f1)
[[ "$_marker_line" -gt "$_render_line" && "$_marker_line" -gt "$_pull_line" ]] \
	&& pass "J0a: plain path marker write ($_marker_line) sits after render gate ($_render_line) and pull ($_pull_line)" \
	|| fail "J0a: marker write not after gates ($_marker_line vs render=$_render_line pull=$_pull_line)"
grep -c 'exec 9>&-' "$UPGRADE" | grep -qx '0' \
	&& pass "J0b: no fd-9 close remains in upgrade.sh (lock handoff)" \
	|| fail "J0b: fd 9 is still closed before a re-exec"

echo "=== J1: real apply — self-update re-exec + converge ==="
mkdir -p "$FIX/rel/v9.9.9" "$FIX/rel/v9.9.8"
build_release "$FIX/rel/v9.9.9" v9.9.9
build_release "$FIX/rel/v9.9.8" v9.9.8
N1="$T/n1"; build_node "$N1" v9.9.8 old
OUT1=$(run_upgrade "$N1" 2>&1); RC1=$?
echo "$OUT1" | tail -30 > "$T/j1.log"
_marker=$(sed -n 's/^IMAGE_VERSION=//p' "$N1/lib/install.env")
_ctag=$(sed -nE 's|.*partner-edge-sfu:([^ "]+).*|\1|p' "$N1/etc/docker-compose.yml" | head -n1)
[[ "$RC1" -eq 0 && "$_marker" == v9.9.9 && "$_ctag" == v9.9.9 ]] \
	&& pass "J1a: apply converged (rc=0, marker=$_marker, compose=$_ctag)" \
	|| fail "J1a: apply did not converge (rc=$RC1 marker=$_marker compose=$_ctag)"
if grep -q 'pull' "$N1/docker_calls.log" && grep -q 'up -d' "$N1/docker_calls.log"; then
	pass "J1b: docker pull + recreate ran on the real path"
else
	fail "J1b: pull/recreate missing from docker calls: $(cat "$N1/docker_calls.log" 2>/dev/null | tr '\n' '|')"
fi
grep -q 'self-update: running upgrade.sh differs' <<<"$OUT1" \
	&& grep -q 'inherited already-locked' <<<"$OUT1" \
	&& pass "J1c: real re-exec fired AND the child recognised the fd-9 lock handoff" \
	|| fail "J1c: re-exec or lock-handoff log missing"
grep -q 'oxpulse-partner-cert-watch.service' "$N1/systemctl_calls.log" 2>/dev/null || true
[[ -f "$N1/systemd/oxpulse-partner-cert-watch.service" ]] \
	&& ! grep -qF '{{' "$N1/systemd/oxpulse-partner-cert-watch.service" \
	&& pass "J1d: cert-watch service installed fully rendered from bundle" \
	|| fail "J1d: cert-watch service missing or unrendered"

echo "=== J2: lock handoff — second upgrader refused during re-exec ==="
N2="$T/n2"; build_node "$N2" v9.9.8 old
( DOCKER_PULL_SLEEP=5 run_upgrade "$N2" > "$T/j2.first.log" 2>&1 ) &
P1=$!
sleep 2   # let the parent re-exec and reach the pull sleep
OUT2=$(run_upgrade "$N2" 2>&1); RC2=$?
wait "$P1"; RC1B=$?
grep -q 'another upgrade.sh is running' <<<"$OUT2" \
	&& pass "J2a: second upgrader refused while the re-exec'd child held the lock (rc=$RC2)" \
	|| fail "J2a: second upgrader was NOT refused during the re-exec window (rc=$RC2, out=$(tail -3 <<<"$OUT2"))"
[[ "$RC1B" -eq 0 ]] \
	&& pass "J2b: first upgrader converged after the refused contender exited" \
	|| fail "J2b: first upgrader failed (rc=$RC1B; $(tail -5 "$T/j2.first.log"))"

echo "=== J3: crash window — kill -9 mid-pull leaves marker OLD; retry converges ==="
N3="$T/n3"; build_node "$N3" v9.9.8 old
( DOCKER_KILL_UPGRADE=1 run_upgrade "$N3" > "$T/j3.first.log" 2>&1 ) &
P3=$!
wait "$P3" 2>/dev/null; RC3=$?
# The script's $(...) subshells inherit fd 9; they can outlive the kill by a
# few ms. Real nodes wait minutes between ticks — drain the lock here.
for _i in $(seq 1 50); do
	( exec 9>"$N3/lib/upgrade.lock"; flock -n 9 ) 2>/dev/null && break
	sleep 0.1
done
_marker=$(sed -n 's/^IMAGE_VERSION=//p' "$N3/lib/install.env")
[[ "$RC3" -ne 0 && "$_marker" == v9.9.8 ]] \
	&& pass "J3a: killed mid-pull (rc=$RC3) — marker stayed v9.9.8" \
	|| fail "J3a: crash window leaked the marker (rc=$RC3 marker=$_marker)"
_ctag=$(sed -nE 's|.*partner-edge-sfu:([^ "]+).*|\1|p' "$N3/etc/docker-compose.yml" | head -n1)
[[ "$_ctag" == v9.9.9 ]] \
	&& pass "J3b: compose already rewritten to v9.9.9 when the kill hit (window reproduced)" \
	|| fail "J3b: compose tag=$_ctag (expected v9.9.9 — kill landed before the rewrite?)"
OUT3B=$(run_upgrade "$N3" 2>&1); RC3B=$?
_marker=$(sed -n 's/^IMAGE_VERSION=//p' "$N3/lib/install.env")
[[ "$RC3B" -eq 0 && "$_marker" == v9.9.9 ]] \
	&& pass "J3c: retry after the crash converged fully (marker=v9.9.9)" \
	|| fail "J3c: retry after crash failed (rc=$RC3B marker=$_marker; $(tail -5 <<<"$OUT3B"))"

echo "=== J4: required-asset failure aborts BEFORE any install or image change ==="
N4="$T/n4"; build_node "$N4" v9.9.8 old
build_release "$FIX/rel/v9.9.9" v9.9.9   # rebuild, then remove a REQUIRED asset
rm -f "$FIX/rel/v9.9.9/partner-edge-healthcheck.sh"
OUT4=$(run_upgrade "$N4" 2>&1); RC4=$?
_marker=$(sed -n 's/^IMAGE_VERSION=//p' "$N4/lib/install.env")
_pulls=$(awk '/pull/{n++}END{print n+0}' "$N4/docker_calls.log" 2>/dev/null)
_tglib=$(cat "$N4/sbin/telegram-alert-lib.sh")
[[ "$RC4" -ne 0 && "$_marker" == v9.9.8 && "$_pulls" -eq 0 && "$_tglib" == *"tg_alert"* ]] \
	&& pass "J4a: required-asset failure died before pull (pulls=$_pulls), marker untouched, no sbin install" \
	|| fail "J4a: partial sync proceeded (rc=$RC4 marker=$_marker pulls=$_pulls tglib=$_tglib)"
grep -q 'required target asset' <<<"$OUT4" \
	&& pass "J4b: die names the failed required assets" \
	|| fail "J4b: die message does not name the required asset set"
# restore the asset for later scenarios
build_release "$FIX/rel/v9.9.9" v9.9.9

echo "=== J5: marker/container divergence — real apply resumes instead of no-op ==="
N5="$T/n5"; build_node "$N5" v9.9.9 new   # marker CLAIMS target…
printf '9.9.8\n' > "$N5/running_tag"      # …but containers still run 9.9.8
OUT5=$(run_upgrade "$N5" 2>&1); RC5=$?
grep -q 'resuming the interrupted apply' <<<"$OUT5" \
	&& pass "J5a: divergence detected — apply resumed instead of 'nothing to do'" \
	|| fail "J5a: divergent marker exited early (rc=$RC5; $(tail -4 <<<"$OUT5"))"
[[ "$RC5" -eq 0 ]] \
	&& pass "J5b: resumed apply converged (rc=0)" \
	|| fail "J5b: resumed apply failed (rc=$RC5; $(tail -5 <<<"$OUT5"))"

echo "=== J6: templated units come from the TARGET bundle, not REPO_RAW ==="
# Poison the raw-origin copy: if the code fetched from REPO_RAW the installed
# unit would carry the poison sentinel instead of the bundle template.
mkdir -p "$FIX/raw/systemd"
for u in "${_HOST_SCRIPT_SYSTEMD_TEMPLATED_FILES[@]}"; do
	printf '[Unit]\n# POISONED-RAW-ORIGIN %s\n' "$u" > "$FIX/raw/systemd/$u"
done
N6="$T/n6"; build_node "$N6" v9.9.8 old
OUT6=$(run_upgrade "$N6" 2>&1); RC6=$?
if [[ -f "$N6/systemd/oxpulse-partner-cert-watch.service" ]]; then
	grep -q 'POISONED-RAW-ORIGIN' "$N6/systemd/oxpulse-partner-cert-watch.service" \
		&& fail "J6a: cert-watch unit came from REPO_RAW, not the target bundle" \
		|| pass "J6a: cert-watch unit rendered from the TARGET release bundle"
else
	fail "J6a: cert-watch service not installed (rc=$RC6)"
fi

echo "=== J7: refresh side — divergence heal + bounded backoff + ceiling ==="
R7="$T/r7.sh"
{
	echo 'log()  { printf "==> %s\n" "$*" >&2; }'
	echo 'warn() { printf "!! %s\n"  "$*" >&2; }'
	echo 'emit_metric() { printf "METRIC %s %s %s\n" "$1" "$2" "$3" >> "$METRICS"; }'
	echo 'emit_gauge()  { printf "GAUGE %s %s %s\n" "$1" "$2" "$3" >> "$METRICS"; }'
	awk '/^_self_upgrade_is_ge\(\)/{f=1} f{print} /^}$/ && f{exit}' "$REFRESH"
	awk '/^_self_upgrade_running_tag\(\)/{f=1} f{print} /^}$/ && f{exit}' "$REFRESH"
	awk '/^_write_attempt_marker\(\)/{f=1} f{print} /^}$/ && f{exit}' "$REFRESH"
	awk '/^_self_upgrade_alert\(\)/{f=1} f{print} /^}$/ && f{exit}' "$REFRESH"
	awk '/^_maybe_self_upgrade\(\)/{f=1} f{print} /^}$/ && f{exit}' "$REFRESH"
} > "$R7"
bash -n "$R7" && pass "J7a: extracted refresh functions parse" || fail "J7a: refresh extract syntax"

R7D="$T/r7"; mkdir -p "$R7D/lib" "$R7D/sbin" "$R7D/bin"
printf '1000\n' > "$R7D/epoch"
printf 'tg_alert() { printf "ALERT %%s\\n" "$*" >> "${ALERT_LOG:?}"; }\n' > "$R7D/sbin/telegram-alert-lib.sh"
printf '#!/usr/bin/env bash\nprintf "mv %%s\\n" "$*" >> "${MV_LOG:-/dev/null}"\nexec /bin/mv "$@"\n' > "$R7D/bin/mv"; chmod +x "$R7D/bin/mv"
printf '#!/usr/bin/env bash\nexit 0\n' > "$R7D/bin/oxpulse-partner-edge-upgrade"; chmod +x "$R7D/bin/oxpulse-partner-edge-upgrade"
: > "$R7D/running_tag"

run_refresh() {  # $1=desired; env: R7_TAG_FILE, R7_*
	METRICS="$R7D/metrics"; : > "$METRICS"
	( set -euo pipefail
	  export PATH="$STUBS:$R7D/bin:$PATH" PREFIX_LIB="$R7D/lib" PREFIX_SBIN="$R7D/sbin" \
	         METRICS ALERT_LOG="$R7D/alert.log" FAKE_EPOCH_FILE="$R7D/epoch" \
	         DOCKER_CALL_LOG=/dev/null DOCKER_RUNNING_TAG_FILE="$R7D/running_tag" \
	         DOCKER_STATE_FILE=/dev/null COMPOSE_FILE_PATH=/dev/null \
	         SELFUP_STATE="${SELFUP_STATE:-inactive}" DOCKER_PS_EXTRA_FILE="${R7_PS_EXTRA:-}" \
	         MV_LOG="${MV_LOG:-/dev/null}" \
	         OXPULSE_SELF_UPGRADE_BASE_BACKOFF="${R7_BASE:-3600}" \
	         OXPULSE_SELF_UPGRADE_MAX_BACKOFF="${R7_MAX:-86400}" \
	         OXPULSE_SELF_UPGRADE_MAX_ATTEMPTS="${R7_ATT:-8}"
	  source "$R7"; _maybe_self_upgrade 200 "{\"desired_release\":\"$1\"}" ) 2>"$R7D/stderr.log"
}

# J7b — divergence heal: marker v9.9.9, containers v9.9.8, desired 9.9.9 → retry fires
printf 'IMAGE_VERSION=v9.9.9\n' > "$R7D/lib/install.env"
printf '9.9.8\n' > "$R7D/running_tag"
rm -f "$R7D/lib/self-upgrade.attempted" "$R7D/alert.log" "$T/sdrun_marker"
SDRUN_CALL_LOG="$T/sdrun_marker" run_refresh "9.9.9"
[[ -s "$T/sdrun_marker" ]] \
	&& grep -q 'marker_diverged' "$R7D/metrics" \
	&& pass "J7b: stuck marker (v9.9.9 marker vs v9.9.8 containers) healed — upgrade launched + divergence metric" \
	|| fail "J7b: stuck marker did NOT trigger the retry (sdrun=$(cat "$T/sdrun_marker" 2>/dev/null), metrics=$(cat "$R7D/metrics"))"

# J7c — bounded backoff + ceiling: base=1s, max=4s, ceiling=3, fake clock.
printf 'IMAGE_VERSION=v9.9.8\n' > "$R7D/lib/install.env"
printf '9.9.8\n' > "$R7D/running_tag"
rm -f "$R7D/lib/self-upgrade.attempted" "$R7D/alert.log" "$T/sdrun_marker"
export R7_BASE=1 R7_MAX=4 R7_ATT=3
printf '1000\n' > "$R7D/epoch"
SDRUN_CALL_LOG="$T/sdrun_marker" run_refresh "9.9.9"
n1=$(wc -l < "$T/sdrun_marker" 2>/dev/null || printf '0')
: > "$T/sdrun_marker"
SDRUN_CALL_LOG="$T/sdrun_marker" run_refresh "9.9.9"          # t=1000: 0s into 1s window → deferred
[[ "$n1" -ge 1 && ! -s "$T/sdrun_marker" ]] \
	&& pass "J7c-1: attempt 1 launched; attempt 2 deferred inside the 1s backoff window" \
	|| fail "J7c-1: backoff not applied (n1=$n1, marker=$(cat "$R7D/lib/self-upgrade.attempted"), sdrun=$(cat "$T/sdrun_marker"))"
printf '1001\n' > "$R7D/epoch"
: > "$T/sdrun_marker"
SDRUN_CALL_LOG="$T/sdrun_marker" run_refresh "9.9.9"          # t=1001: window elapsed → attempt 2
n2=$(wc -l < "$T/sdrun_marker" 2>/dev/null || printf '0')
printf '1002\n' > "$R7D/epoch"
: > "$T/sdrun_marker"
SDRUN_CALL_LOG="$T/sdrun_marker" run_refresh "9.9.9"          # t=1002: 1s into the 2s window → deferred
n3d=$(wc -l < "$T/sdrun_marker" 2>/dev/null || printf '0')
printf '1003\n' > "$R7D/epoch"
: > "$T/sdrun_marker"
SDRUN_CALL_LOG="$T/sdrun_marker" run_refresh "9.9.9"          # t=1003: 2s window elapsed → attempt 3
n3=$(wc -l < "$T/sdrun_marker" 2>/dev/null || printf '0')
[[ "$n2" -ge 1 && "$n3d" -eq 0 && "$n3" -ge 1 ]] \
	&& pass "J7c-2: attempt 2 after 1s, attempt 3 deferred 1s then allowed at 2s (exponential)" \
	|| fail "J7c-2: launch pattern wrong (n2=$n2 n3d=$n3d n3=$n3; marker=$(cat "$R7D/lib/self-upgrade.attempted"))"
: > "$T/sdrun_marker"
SDRUN_CALL_LOG="$T/sdrun_marker" run_refresh "9.9.9"          # attempts=3 = ceiling → alert+metric, no launch
n4=$(wc -l < "$T/sdrun_marker" 2>/dev/null || printf '0')
[[ "$n4" -eq 0 && -s "$R7D/alert.log" && "$(cat "$R7D/metrics")" == *"ceiling"* ]] \
	&& pass "J7c-3: ceiling stopped launches; raised Telegram alert + ceiling metric" \
	|| fail "J7c-3: ceiling wrong (n4=$n4, alert=$(cat "$R7D/alert.log" 2>/dev/null), metrics=$(cat "$R7D/metrics"))"
SDRUN_CALL_LOG="$T/sdrun_marker" run_refresh "9.9.9"          # alerted once → silent thereafter
_alerts=$(wc -l < "$R7D/alert.log" 2>/dev/null || printf '0')
[[ "$_alerts" -eq 1 ]] \
	&& pass "J7c-4: ceiling alert fires exactly once" \
	|| fail "J7c-4: ceiling alerted $_alerts times"
unset R7_BASE R7_MAX R7_ATT

echo "=== J8: running-tag probes are scoped to the managed partner-edge images ==="
# node-exporter (v1.8.2) and a stale oxpulse-partner-foo (0.1.0) share the
# name prefix with the edge containers but are NOT managed images. Neither may
# read as a diverging tag when the edge itself runs the desired release.
PSX="$T/ps_extra"
printf 'quay.io/prometheus/node-exporter:v1.8.2\nregistry.example/oxpulse-partner-foo:0.1.0\n' > "$PSX"
printf 'IMAGE_VERSION=v9.9.9\n' > "$R7D/lib/install.env"
printf '9.9.9\n' > "$R7D/running_tag"
rm -f "$R7D/lib/self-upgrade.attempted" "$T/sdrun_marker"
R7_PS_EXTRA="$PSX" SDRUN_CALL_LOG="$T/sdrun_marker" run_refresh "9.9.9"
if [[ ! -s "$T/sdrun_marker" ]] && ! grep -q 'marker_diverged' "$R7D/metrics"; then
	pass "J8a: refresh ignores node-exporter v1.8.2 / non-edge container (edge on desired, no divergence)"
else
	fail "J8a: refresh read a non-edge container as diverged (sdrun=$(cat "$T/sdrun_marker" 2>/dev/null), metrics=$(cat "$R7D/metrics"))"
fi
N8="$T/n8"; build_node "$N8" v9.9.9 new
printf '9.9.9\n' > "$N8/running_tag"
OUT8=$(run_upgrade "$N8" DOCKER_PS_EXTRA_FILE="$PSX" 2>&1); RC8=$?
if [[ "$RC8" -eq 0 ]] && grep -q 'nothing to do' <<<"$OUT8" && ! grep -q 'resuming the interrupted apply' <<<"$OUT8"; then
	pass "J8b: upgrade.sh probe ignores non-edge containers (already on target -> nothing to do)"
else
	fail "J8b: upgrade.sh treated a non-edge container as divergence (rc=$RC8; $(tail -4 <<<"$OUT8"))"
fi

echo "=== J9: in-flight self-upgrade unit consumes no retry budget ==="
printf 'IMAGE_VERSION=v9.9.8\n' > "$R7D/lib/install.env"
printf '9.9.8\n' > "$R7D/running_tag"
printf '100000\n' > "$R7D/epoch"
rm -f "$R7D/lib/self-upgrade.attempted" "$T/sdrun_marker"
SELFUP_STATE=active SDRUN_CALL_LOG="$T/sdrun_marker" run_refresh "9.9.9"
if [[ ! -e "$R7D/lib/self-upgrade.attempted" && ! -s "$T/sdrun_marker" ]]; then
	pass "J9a: active unit, no prior marker -> no marker created, nothing launched"
else
	fail "J9a: in-flight unit touched the attempts marker ($(cat "$R7D/lib/self-upgrade.attempted" 2>/dev/null))"
fi
printf '9.9.9:2:5:0\n' > "$R7D/lib/self-upgrade.attempted"
SELFUP_STATE=active SDRUN_CALL_LOG="$T/sdrun_marker" run_refresh "9.9.9"
if [[ "$(cat "$R7D/lib/self-upgrade.attempted")" == "9.9.9:2:5:0" && ! -s "$T/sdrun_marker" ]]; then
	pass "J9b: active unit, existing marker (attempts=2) -> marker byte-identical"
else
	fail "J9b: in-flight unit consumed budget (marker=$(cat "$R7D/lib/self-upgrade.attempted"))"
fi

echo "=== J10: attempts marker is written atomically (tmp in same dir + mv) ==="
rm -f "$R7D/lib/self-upgrade.attempted" "$T/sdrun_marker" "$T/mv.log"
MV_LOG="$T/mv.log" SDRUN_CALL_LOG="$T/sdrun_marker" run_refresh "9.9.9"
if grep -qE "mv -f $R7D/lib/self-upgrade\.attempted\.tmp\.[0-9]+ $R7D/lib/self-upgrade\.attempted\$" "$T/mv.log" 2>/dev/null \
	&& [[ "$(cut -d: -f1,2 "$R7D/lib/self-upgrade.attempted")" == "9.9.9:1" ]] \
	&& ! ls "$R7D/lib"/self-upgrade.attempted.tmp.* >/dev/null 2>&1; then
	pass "J10a: marker written via same-dir tmp + mv, no tmp left behind"
else
	fail "J10a: marker not written atomically (mv.log=$(cat "$T/mv.log" 2>/dev/null))"
fi

echo "=== J11: lock-handoff credential does not leak to descendants ==="
if grep -q '^LOCKHELD=' "$N1/docker_calls.log" 2>/dev/null \
	&& ! grep '^LOCKHELD=' "$N1/docker_calls.log" | grep -qv '^LOCKHELD=unset$'; then
	pass "J11a: docker (descendant of the re-exec'd upgrader) sees no OXPULSE_UPGRADE_LOCK_HELD"
else
	fail "J11a: descendant inherited the skip-lock credential ($(grep '^LOCKHELD=' "$N1/docker_calls.log" 2>/dev/null | sort -u | tr '\n' ' '))"
fi

echo ""
printf '=== RESULT: %s tests, %s failures ===\n' "$TESTS" "$FAILURES"
[[ "$FAILURES" -eq 0 ]]
