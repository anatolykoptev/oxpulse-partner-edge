#!/usr/bin/env bash
# tests/test_relay_upgrade.sh — relay-only self-upgrade (relay/oxpulse-relay-upgrade.sh)
# against a fake release server, a stub systemctl/curl/uclient/openssl/ss and a
# throw-away filesystem tree. Needs python3 (probe credential), sha256sum, flock.
#
# Mutations that must turn this RED (stated as the edit, FILE:LINE of the call site;
# RELAY_UPGRADE_SCRIPT lets a mutant be checked without touching the repo file):
#   * relay/oxpulse-relay-upgrade.sh verify_asset(): make the first line `return 0`
#     (skip SHA256 verification) -> "checksum mismatch aborts before any swap",
#     "asset missing from SHA256SUMS fails closed".
#   * relay/oxpulse-relay-upgrade.sh apply_upgrade(): delete the
#     `restore_snapshot || { ...; return 12; }` line (skip rollback on a failed
#     health gate) -> "health gate failure rolls back", "rollback restores ...".
#   * relay/oxpulse-relay-upgrade.sh on_exit(): delete the `case "$rc" in 10|11|12)` line
#     (never persist the failure) -> "persists last-rc".
#   * relay/oxpulse-relay-upgrade.sh apply_upgrade(): delete the `ver_gt` guard
#     line (`if ! ver_gt "$ver" "$inst"; then ...`) -> "a downgrade is refused".
set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
R="$REPO_ROOT/relay"
UP="${RELAY_UPGRADE_SCRIPT:-$R/oxpulse-relay-upgrade.sh}"
PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
ok()   { local n="$1"; shift; if "$@"; then pass "$n"; else fail "$n"; fi; }

for need in python3 sha256sum flock; do
	command -v "$need" >/dev/null || { echo "SKIP: $need not available"; exit 0; }
done

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
CURL_LOG="$T/curl.log"; SYSLOG="$T/systemctl.log"

# ---- stubs -----------------------------------------------------------------
cat > "$T/bin/curl" <<'STUB'
#!/bin/bash
# fake release server: file:// fixtures, heartbeat answered from $HB_* variables.
out="" url="" post=0
while [[ $# -gt 0 ]]; do
	case "$1" in
		-o) out="$2"; shift 2 ;;
		-d) post=1; shift 2 ;;
		-w|-H|--proto|--tlsv1.2|--max-time|-X) [[ "$1" == --tlsv1.2 ]] && shift || shift 2 ;;
		-*) shift ;;
		*) url="$1"; shift ;;
	esac
done
echo "$url" >> "$CURL_LOG"
case "$url" in
	*/api/partner/heartbeat)
		if [[ -n "${HB_DESIRED:-}" ]]; then printf '{"node_id":"n","keys_version":"x","desired_release":"%s"}\n%s' "$HB_DESIRED" "${HB_CODE:-200}"
		else printf '{"node_id":"n","keys_version":"x"}\n%s' "${HB_CODE:-200}"; fi
		exit 0 ;;
	"$RELAY_RELEASES_BASE"/*)
		f="$FIXTURES/${url#"$RELAY_RELEASES_BASE"/}"
		[[ -f "$f" ]] || exit 22
		cp "$f" "$out"; exit 0 ;;
esac
exit 22
STUB
cat > "$T/bin/systemctl" <<'STUB'
#!/bin/bash
echo "systemctl $*" >> "$SYSLOG"
case "$1" in
	is-active) [[ -e "$T_COTURN_DOWN" ]] && exit 3; exit 0 ;;
	show) exit 0 ;;
esac
exit 0
STUB
cat > "$T/bin/systemd-run" <<'STUB'
#!/bin/bash
echo "systemd-run $*" >> "$SYSLOG"
while [[ $# -gt 0 && "$1" != */oxpulse-relay-upgrade ]]; do shift; done
exec "$@"
STUB
printf '#!/bin/bash\nexit 0\n' > "$T/bin/openssl"
printf '#!/bin/bash\necho "UNCONN 0 0 0.0.0.0:3478 0.0.0.0:* users:((\\"turnserver\\",pid=1,fd=3))"\n' > "$T/bin/ss"
printf '#!/bin/bash\nexit 0\n' > "$T/bin/logger"
# system turnutils_uclient (the "previous version" probe): passes unless told otherwise.
printf '#!/bin/bash\n[[ -e "$T_SYS_UCLIENT_FAIL" ]] && exit 1\nexit 0\n' > "$T/bin/turnutils_uclient"
chmod +x "$T/bin"/*

export CURL_LOG SYSLOG
export T_COTURN_DOWN="$T/coturn-down" T_SYS_UCLIENT_FAIL="$T/sys-uclient-fail"
export FIXTURES="$T/rel" RELAY_RELEASES_BASE="https://example.test/releases/download"

# ---- fake release builder -----------------------------------------------------
# mkrelease VER — built from the REAL manifest and the real relay files. Knobs (env):
#   BAD_UCLIENT=1  the release's turnutils_uclient fails (health gate must fail)
#   CORRUPT=name   change the bytes of asset NAME after SHA256SUMS was written
#   OMIT=name      leave NAME out of SHA256SUMS
#   WITH_OPEC=1    ship an opec-amd64 asset
mkrelease() {
	local ver="$1" d="$FIXTURES/v$1" line asset src
	rm -rf "$d"; mkdir -p "$d"
	cp "$R/relay-manifest.txt" "$d/relay-manifest.txt"
	while read -r line; do
		line="${line%%#*}"; [[ -n "${line// /}" ]] || continue
		read -r _ _ asset _ <<<"$line"
		asset="${asset//@ARCH@/amd64}"
		case "$asset" in
			relay-turnserver-*) printf '#!/bin/sh\necho "Version: Coturn-4.18.0"\n' > "$d/$asset" ;;
			relay-turnutils_uclient-*) if [[ -n "${BAD_UCLIENT:-}" ]]; then printf '#!/bin/sh\nexit 1\n'; else printf '#!/bin/sh\nexit 0\n'; fi > "$d/$asset" ;;
			*) src="$R/$asset"; [[ -f "$src" ]] || src="$REPO_ROOT/lib/$asset"
			   cp "$src" "$d/$asset"; printf '\n# fixture release v%s\n' "$ver" >> "$d/$asset" ;;
		esac
	done < "$R/relay-manifest.txt"
	[[ -z "${WITH_OPEC:-}" ]] || cp "$T/bin/opec-ok" "$d/opec-amd64"
	( cd "$d" && sha256sum * > SHA256SUMS.all
	  if [[ -n "${OMIT:-}" ]]; then grep -v " ${OMIT}\$" SHA256SUMS.all > SHA256SUMS; else cp SHA256SUMS.all SHA256SUMS; fi
	  rm SHA256SUMS.all )
	[[ -z "${CORRUPT:-}" ]] || printf 'tampered\n' >> "$d/$CORRUPT"
}

# ---- fake node ------------------------------------------------------------------------
node() { # build a relay node at version 1.0.0 with "old" files
	rm -rf "$T/n"; N="$T/n"
	mkdir -p "$N"/{etc,lib,sbin,units,share}; chmod 0750 "$N/etc"
	echo relay-node-1 > "$N/etc/node-id"
	printf 'RELAY_HOSTNAME=relay.example.org\nEXTERNAL_IP=203.0.113.10\n' > "$N/etc/relay.env"
	printf 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n' > "$N/etc/node-secret"; chmod 600 "$N/etc/node-secret"
	echo "OLD-TEMPLATE" > "$N/etc/coturn-relay.conf.tpl"
	echo "OLD-APPLY" > "$N/sbin/oxpulse-relay-apply"
	printf '[Service]\nExecStart=/usr/bin/turnserver -c x\n' > "$N/units/oxpulse-relay-coturn.service"
	cp "$R/relay-lib.sh" "$R/relay-probe-lib.sh" "$REPO_ROOT/lib/channel-health-lib.sh" "$N/lib/"
	cp "$UP" "$N/sbin/oxpulse-relay-upgrade"; chmod +x "$N/sbin/oxpulse-relay-upgrade"
	mkdir -p "$N/share/oxpulse-partner-edge"; echo "1.0.0  # installed" > "$N/share/oxpulse-partner-edge/VERSION"
	: > "$CURL_LOG"; : > "$SYSLOG"; rm -f "$T_COTURN_DOWN" "$T_SYS_UCLIENT_FAIL"
	UPARGS=--init-baseline up >/dev/null
	: > "$SYSLOG"
}
up() { # run the upgrader under the fake node's seams
	env PATH="$T/bin:$PATH" ALLOW_NONROOT=1 PREFIX_ETC="$N/etc" PREFIX_LIB="$T/no-such-lib" RELAY_LIB_DIR="$N/lib" PREFIX_SBIN="$N/sbin" \
		UNIT_DIR="$N/units" PREFIX_SHARE="$N/share" OPEC_DST="$N/opec" RELAY_CURL="$T/bin/curl" SYSTEMCTL="$T/bin/systemctl" \
		SYSTEMD_RUN="$T/bin/systemd-run" OPENSSL_BIN="$T/bin/openssl" SS_BIN="$T/bin/ss" RELAY_ARCH_OVERRIDE=amd64 RELAY_SYSTEM_BIN_DIR="$T/bin" \
		RELAY_GATE_TRIES=2 RELAY_GATE_INTERVAL=0 "$@" bash "$UP" $UPARGS 2>&1
}
# fake opec that supports the relay subcommands (so the upgrader does not fetch one)
printf '#!/bin/bash\n[[ "$*" == *--help* ]] && echo "--secret-file"\nexit 0\n' > "$T/bin/opec-ok"; chmod +x "$T/bin/opec-ok"
setup_opec() { cp "$T/bin/opec-ok" "$N/opec"; }
installed() { awk '{print $1; exit}' "$N/share/oxpulse-partner-edge/VERSION"; }
restarts()  { grep -c 'systemctl restart oxpulse-relay-coturn' "$SYSLOG" || true; }
snap_state() { # hash of everything a failed upgrade must leave untouched
	( cd "$N" && cat etc/coturn-relay.conf.tpl sbin/oxpulse-relay-apply units/oxpulse-relay-coturn.service share/oxpulse-partner-edge/VERSION; readlink lib/current ) | sha256sum
}

# ============ 1. no-op: desired == installed, and check does not even launch ============
node; setup_opec; mkrelease 1.0.0
before="$(snap_state)"
UPARGS="--apply 1.0.0" up >/dev/null; rc=$?
[[ "$rc" -eq 0 && "$(restarts)" -eq 0 && "$(snap_state)" == "$before" && ! -s "$CURL_LOG" ]] && pass "no-op when desired == installed (no fetch, no restart)" || fail "no-op when desired == installed (rc=$rc)"
: > "$SYSLOG"
HB_DESIRED=1.0.0 UPARGS="--check" up >/dev/null
! grep -q 'systemd-run' "$SYSLOG" && pass "check: desired == installed launches nothing" || fail "check: desired == installed launches nothing"

# ============ 2. a downgrade is refused (apply, to, check) ===============================
node; setup_opec; mkrelease 0.9.0; before="$(snap_state)"; : > "$CURL_LOG"
UPARGS="--apply 0.9.0" up >/dev/null; rc=$?
[[ "$rc" -eq 0 && "$(restarts)" -eq 0 && "$(snap_state)" == "$before" && ! -s "$CURL_LOG" ]] && pass "a downgrade is refused (apply: nothing fetched, nothing changed)" || fail "a downgrade is refused (apply, rc=$rc)"
HB_DESIRED=0.9.0 UPARGS="--check" up >/dev/null
! grep -q 'systemd-run' "$SYSLOG" && pass "a downgrade is refused (check launches nothing)" || fail "a downgrade is refused (check)"
UPARGS="--to 0.9.0" up >/dev/null
! grep -q 'systemd-run' "$SYSLOG" && pass "a downgrade is refused (--to launches nothing)" || fail "a downgrade is refused (--to)"
for bad in 1.2 1.2.3-rc1 v1.2.3 latest ''; do
	HB_DESIRED="$bad" UPARGS="--check" up >/dev/null
done
! grep -q 'systemd-run' "$SYSLOG" && pass "check ignores a non-semver desired_release" || fail "check ignores a non-semver desired_release"
HB_DESIRED=1.2.3 HB_CODE=500 UPARGS="--check" up >/dev/null
! grep -q 'systemd-run' "$SYSLOG" && pass "check: a failing central answer launches nothing" || fail "check: a failing central answer launches nothing"

# ============ 3. happy path: check -> detached apply -> installed =============================
node; setup_opec; mkrelease 1.2.3; : > "$CURL_LOG"; echo 11 > "$N/lib/last-rc"; echo 1.1.0 > "$N/lib/failed-version"
HB_DESIRED=1.2.3 UPARGS="--check" up >"$T/happy.out"; rc=$?
[[ "$rc" -eq 0 ]] && pass "happy path exits 0" || fail "happy path exits 0 (rc=$rc: $(tail -3 "$T/happy.out"))"
grep -q 'systemd-run.*--unit=oxpulse-relay-self-upgrade.*--apply 1.2.3' "$SYSLOG" && pass "upgrade runs detached as its own transient unit" || fail "upgrade runs detached as its own transient unit"
[[ ! -e "$N/lib/last-rc" && ! -e "$N/lib/failed-version" ]] && pass "success leaves no failure state" || fail "success leaves no failure state"
[[ "$(installed)" == "1.2.3" ]] && pass "VERSION written only on success" || fail "VERSION written (got $(installed))"
[[ "$(readlink "$N/lib/current")" == "releases/1.2.3" && -x "$N/lib/releases/1.2.3/turnserver" && -x "$N/lib/releases/1.2.3/turnutils_uclient" ]] && pass "binaries staged under releases/<ver>, current switched" || fail "binaries staged, current switched ($(readlink "$N/lib/current"))"
grep -q 'ExecStart=/usr/local/lib/oxpulse-relay/current/turnserver' "$N/units/oxpulse-relay-coturn.service" && pass "unit ExecStart points at current/turnserver" || fail "unit ExecStart points at current/turnserver"
! grep -qE '^(no-dtls|no-tlsv1)' "$N/etc/coturn-relay.conf.tpl" && grep -q 'fixture release v1.2.3' "$N/etc/coturn-relay.conf.tpl" && pass "new template installed (4.18 form)" || fail "new template installed"
grep -q 'fixture release v1.2.3' "$N/sbin/oxpulse-relay-apply" && pass "scripts replaced" || fail "scripts replaced"
[[ -d "$N/lib/snapshots/last" && "$(cat "$N/lib/snapshots/last/etc/coturn-relay.conf.tpl")" == "OLD-TEMPLATE" ]] && pass "pre-swap snapshot holds the previous files" || fail "pre-swap snapshot"
reset="$(grep -n 'systemctl daemon-reload' "$SYSLOG" | tail -1 | cut -d: -f1)"; rs="$(grep -n 'systemctl restart oxpulse-relay-coturn' "$SYSLOG" | sed -n '1p' | cut -d: -f1)"
[[ -n "$reset" && -n "$rs" && "$reset" -lt "$rs" && "$(restarts)" -eq 1 ]] && pass "daemon-reload precedes the single coturn restart" || fail "daemon-reload precedes the single restart ($reset/$rs)"
# never calls register / node-config: only heartbeat + release URLs
stray="$(grep -vE '/api/partner/heartbeat$|^https://example\.test/releases/download/v1\.2\.3/' "$CURL_LOG" || true)"
[[ -z "$stray" ]] && pass "only heartbeat + release assets are fetched" || fail "only heartbeat + release assets are fetched: $stray"
! grep -qE 'register|node-config' "$CURL_LOG" && pass "never calls register / node-config" || fail "never calls register / node-config"
[[ ! -e "$N/etc/node-config.json" && ! -e "$N/etc/token" ]] && pass "no registration material written" || fail "no registration material written"
[[ "$(stat -c %a "$N/etc")" == "750" ]] && pass "/etc dir mode stays 0750 across an upgrade" || fail "/etc dir mode stays 0750 across an upgrade ($(stat -c %a "$N/etc"))"
# second run: converged, nothing to do
: > "$SYSLOG"; UPARGS="--apply 1.2.3" up >/dev/null; [[ "$(restarts)" -eq 0 ]] && pass "idempotent: converged node is a no-op" || fail "idempotent: converged node is a no-op"

# ============ 4. checksum mismatch aborts BEFORE any swap ==========================================
node; setup_opec; CORRUPT=oxpulse-relay-apply.sh mkrelease 1.2.3; before="$(snap_state)"
UPARGS="--apply 1.2.3" up >"$T/m.out"; rc=$?
[[ "$rc" -eq 10 && "$(restarts)" -eq 0 && "$(snap_state)" == "$before" && "$(grep -c 'MISMATCH' "$T/m.out")" -ge 1 ]] \
	&& pass "checksum mismatch aborts before any swap (rc 10, nothing changed, no restart)" || fail "checksum mismatch aborts before any swap (rc=$rc: $(tail -2 "$T/m.out"))"
[[ "$(cat "$N/lib/last-rc" 2>/dev/null)" == "10" ]] && pass "a verify failure persists last-rc 10" || fail "a verify failure persists last-rc 10"
[[ ! -e "$N/lib/releases/1.2.3" && ! -e "$N/lib/snapshots/last" ]] && pass "mismatch: no release dir, no snapshot taken" || fail "mismatch: no release dir, no snapshot"
CORRUPT=relay-turnserver-amd64 mkrelease 1.2.3
UPARGS="--apply 1.2.3" up >/dev/null; rc=$?
[[ "$rc" -eq 10 && "$(restarts)" -eq 0 && "$(snap_state)" == "$before" ]] && pass "a tampered binary is refused" || fail "a tampered binary is refused (rc=$rc)"

# ============ 5. an asset missing from SHA256SUMS fails closed ==========================================
node; setup_opec; OMIT=relay-turnserver-amd64 mkrelease 1.2.3; before="$(snap_state)"
UPARGS="--apply 1.2.3" up >"$T/o.out"; rc=$?
[[ "$rc" -eq 10 && "$(restarts)" -eq 0 && "$(snap_state)" == "$before" ]] && pass "asset missing from SHA256SUMS fails closed" || fail "asset missing from SHA256SUMS fails closed (rc=$rc)"
node; setup_opec; OMIT=relay-manifest.txt mkrelease 1.2.3
UPARGS="--apply 1.2.3" up >/dev/null; rc=$?
[[ "$rc" -eq 10 && "$(restarts)" -eq 0 ]] && pass "an unverifiable manifest is refused" || fail "an unverifiable manifest is refused (rc=$rc)"
node; setup_opec; rm -rf "$FIXTURES/v1.2.3"
UPARGS="--apply 1.2.3" up >/dev/null; rc=$?
[[ "$rc" -eq 10 && "$(restarts)" -eq 0 ]] && pass "a missing release is refused" || fail "a missing release is refused (rc=$rc)"

# ============ 6. health gate failure rolls back and leaves the old binary running =======================
node; setup_opec; BAD_UCLIENT=1 mkrelease 1.2.3; before="$(snap_state)"
UPARGS="--apply 1.2.3" up >"$T/r.out"; rc=$?
[[ "$rc" -eq 11 ]] && pass "health gate failure rolls back (rc 11)" || fail "health gate failure rolls back (rc=$rc: $(tail -4 "$T/r.out"))"
[[ "$(restarts)" -eq 2 ]] && pass "rollback restarts coturn again (2 restarts)" || fail "rollback restarts coturn again ($(restarts) restarts)"
[[ "$(snap_state)" == "$before" ]] && pass "rollback restores template, scripts, unit, current and VERSION" || fail "rollback restores previous state"
grep -q 'ExecStart=/usr/bin/turnserver' "$N/units/oxpulse-relay-coturn.service" && [[ "$(readlink "$N/lib/current")" == "releases/0.0.0" ]] && pass "rollback: old unit ExecStart and the previous binary are back" || fail "rollback: old unit and binary"
[[ "$(cat "$N/lib/last-rc" 2>/dev/null)" == "11" ]] && pass "a rolled-back upgrade persists last-rc 11" || fail "a rolled-back upgrade persists last-rc 11 ($(cat "$N/lib/last-rc" 2>/dev/null))"
[[ "$(cat "$N/lib/failed-version" 2>/dev/null)" == "1.2.3" ]] && grep -q 'CRIT' "$T/r.out" && pass "failure is logged loudly and the version is parked" || fail "failure is logged loudly and parked"
[[ "$(stat -c %a "$N/etc")" == "750" ]] && pass "/etc dir mode stays 0750 across a rollback" || fail "/etc dir mode stays 0750 across a rollback ($(stat -c %a "$N/etc"))"
: > "$SYSLOG"; : > "$CURL_LOG"; UPARGS="--apply 1.2.3" up >/dev/null; rc=$?
[[ "$rc" -eq 0 && "$(restarts)" -eq 0 && ! -s "$CURL_LOG" ]] && pass "a parked failed version is not retried" || fail "a parked failed version is not retried (rc=$rc)"
: > "$SYSLOG"; HB_DESIRED=1.2.3 UPARGS="--check" up >/dev/null
! grep -q 'systemd-run' "$SYSLOG" && pass "check does not relaunch a parked failed version" || fail "check relaunches a parked failed version"

# ============ 7. rollback that cannot recover is reported as such ===========================================
node; setup_opec; BAD_UCLIENT=1 mkrelease 1.2.3; : > "$T_SYS_UCLIENT_FAIL"
UPARGS="--apply 1.2.3" up >"$T/rr.out"; rc=$?
[[ "$(cat "$N/lib/last-rc" 2>/dev/null)" == "12" ]] && pass "a failed rollback persists last-rc 12" || fail "a failed rollback persists last-rc 12"
[[ "$rc" -eq 12 ]] && grep -q 'ROLLBACK FAILED' "$T/rr.out" && pass "rollback that stays unhealthy exits 12 and says so" || fail "rollback that stays unhealthy exits 12 (rc=$rc)"
rm -f "$T_SYS_UCLIENT_FAIL"
node; setup_opec; mkrelease 1.2.3; : > "$T_COTURN_DOWN"; before="$(snap_state)"
UPARGS="--apply 1.2.3" up >/dev/null; rc=$?
[[ "$rc" -eq 12 ]] && pass "coturn inactive after the restart fails the gate (and the rollback too: rc 12)" || fail "inactive coturn fails the gate (rc=$rc)"
rm -f "$T_COTURN_DOWN"

# ============ 8. the registration-material gate runs before anything =========================================
node; setup_opec; mkrelease 1.2.3; : > "$CURL_LOG"; before="$(snap_state)"
UPARGS="--apply 1.2.3" up SIGNALING_SFU_SECRET=hunter2hunter2 >"$T/g.out"; rc=$?
[[ "$rc" -ne 0 && ! -s "$CURL_LOG" && "$(restarts)" -eq 0 && "$(snap_state)" == "$before" && "$(<"$T/g.out")" != *hunter2* ]] && pass "gate: registration material in env refuses before any fetch or change" || fail "gate: env material (rc=$rc)"
node; setup_opec; mkrelease 1.2.3; : > "$CURL_LOG"; echo '{}' > "$N/etc/node-config.json"
UPARGS="--apply 1.2.3" up >/dev/null; rc=$?
[[ "$rc" -ne 0 && ! -s "$CURL_LOG" && "$(restarts)" -eq 0 ]] && pass "gate: node-config.json on the host refuses the upgrade" || fail "gate: node-config.json (rc=$rc)"
node; setup_opec; mkrelease 1.2.3; : > "$CURL_LOG"; rm "$N/etc/node-id"
UPARGS="--check" up HB_DESIRED=1.2.3 >/dev/null; rc=$?
[[ "$rc" -ne 0 && ! -s "$CURL_LOG" ]] && pass "check refuses a host that is not a provisioned relay node" || fail "check refuses a non-relay host (rc=$rc)"
node; echo "1.0.0" > "$N/share/oxpulse-partner-edge/VERSION"; rm "$N/share/oxpulse-partner-edge/VERSION"; mkrelease 1.2.3; : > "$CURL_LOG"
UPARGS="--apply 1.2.3" up >/dev/null; rc=$?
[[ "$rc" -eq 10 && ! -s "$CURL_LOG" ]] && pass "unknown installed version: refuses until bootstrapped" || fail "unknown installed version (rc=$rc)"
grep -v '^[[:space:]]*#' "$UP" | grep -E 'api/partner/(register|node-config)|node-config' >/dev/null && fail "upgrader never references register / node-config" || pass "upgrader never references register / node-config"
grep -v '^[[:space:]]*#' "$UP" | grep -E '(^|[^a-z-])docker( |$)' >/dev/null && fail "upgrader never uses docker" || pass "upgrader never uses docker"

# ============ 9. bootstrap of a live node: upgrader group only, coturn untouched ===========================
node; mkrelease 1.2.3; rm -rf "$N/lib/releases" "$N/lib/current" "$N/lib/snapshots" "$N/share/oxpulse-partner-edge/VERSION"
rm -f "$N/lib/relay-probe-lib.sh" "$N/sbin/oxpulse-relay-upgrade"; : > "$SYSLOG"; : > "$CURL_LOG"; before_unit="$(cat "$N/units/oxpulse-relay-coturn.service")"
UPARGS="--install-upgrader --version 1.2.3" up >"$T/b.out"; rc=$?
[[ "$rc" -eq 0 ]] && pass "bootstrap exits 0" || fail "bootstrap exits 0 (rc=$rc: $(tail -3 "$T/b.out"))"
[[ -x "$N/sbin/oxpulse-relay-upgrade" && -f "$N/lib/relay-probe-lib.sh" && -f "$N/units/oxpulse-relay-upgrade.timer" && -f "$N/units/oxpulse-relay-upgrade.service" ]] && pass "bootstrap installs upgrader, probe lib, service and timer" || fail "bootstrap installs the upgrader group"
[[ "$(installed)" == "0.0.0" ]] && pass "bootstrap writes the VERSION baseline 0.0.0" || fail "bootstrap VERSION baseline ($(installed))"
[[ "$(restarts)" -eq 0 ]] && ! grep -qE 'systemctl (restart|stop|start) oxpulse-relay-coturn' "$SYSLOG" && pass "bootstrap never restarts coturn" || fail "bootstrap never restarts coturn"
grep -q 'systemctl enable --now oxpulse-relay-upgrade.timer' "$SYSLOG" && pass "bootstrap enables the timer" || fail "bootstrap enables the timer"
[[ "$(cat "$N/units/oxpulse-relay-coturn.service")" == "$before_unit" && "$(cat "$N/etc/coturn-relay.conf.tpl")" == "OLD-TEMPLATE" && "$(cat "$N/sbin/oxpulse-relay-apply")" == "OLD-APPLY" ]] && pass "bootstrap leaves the coturn unit, template and scripts alone" || fail "bootstrap leaves coturn files alone"
[[ -L "$N/lib/current" ]] && pass "bootstrap creates the baseline release + current" || fail "bootstrap creates baseline"
# the bootstrapped node can then upgrade for real
setup_opec; UPARGS="--apply 1.2.3" up >/dev/null; rc=$?
[[ "$rc" -eq 0 && "$(installed)" == "1.2.3" ]] && pass "a bootstrapped node upgrades end to end" || fail "bootstrapped node upgrades (rc=$rc)"
# bootstrap refuses on a host holding registration material
node; mkrelease 1.2.3; rm -rf "$N/lib/current"; : > "$N/etc/node-config.json"; : > "$CURL_LOG"
UPARGS="--install-upgrader --version 1.2.3" up >/dev/null; rc=$?
[[ "$rc" -ne 0 && ! -e "$N/units/oxpulse-relay-upgrade.timer" ]] && pass "bootstrap refuses a host with registration material, installing nothing" || fail "bootstrap gate (rc=$rc)"

# ============ 10. opec replacement is part of the swap and is rolled back ====================================
node; printf '#!/bin/bash\necho OLDOPEC\nexit 1\n' > "$N/opec"; chmod +x "$N/opec"; old_opec="$(sha256sum "$N/opec" | cut -d' ' -f1)"
WITH_OPEC=1 BAD_UCLIENT=1 mkrelease 1.2.3
UPARGS="--apply 1.2.3" up >/dev/null; rc=$?
[[ "$rc" -eq 11 && "$(sha256sum "$N/opec" | cut -d' ' -f1)" == "$old_opec" ]] && pass "a rollback restores the previous opec" || fail "a rollback restores the previous opec (rc=$rc)"
node; printf '#!/bin/bash\necho OLDOPEC\nexit 1\n' > "$N/opec"; chmod +x "$N/opec"; WITH_OPEC=1 mkrelease 1.2.3
before_opec="$(sha256sum "$N/opec" | cut -d' ' -f1)"
UPARGS="--apply 1.2.3" up >/dev/null; rc=$?
[[ "$rc" -eq 0 && "$(sha256sum "$N/opec" | cut -d' ' -f1)" != "$before_opec" ]] && pass "an unsupported opec is replaced with the swap on success" || fail "opec replaced on success (rc=$rc)"
node; printf '#!/bin/bash\necho OLDOPEC\nexit 1\n' > "$N/opec"; chmod +x "$N/opec"; CORRUPT=opec-amd64 WITH_OPEC=1 mkrelease 1.2.3; before_opec="$(sha256sum "$N/opec" | cut -d' ' -f1)"
UPARGS="--apply 1.2.3" up >/dev/null; rc=$?
[[ "$rc" -eq 10 && "$(sha256sum "$N/opec" | cut -d' ' -f1)" == "$before_opec" ]] && pass "a tampered opec is refused before anything changes" || fail "tampered opec refused (rc=$rc)"

echo ""
echo "relay upgrade: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
