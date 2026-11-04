#!/usr/bin/env bash
# oxpulse-relay-upgrade — central-driven self-upgrade of a relay-only node.
#
# A relay-only node runs coturn and nothing else (see docs/relay-only-node.md).
# This is the relay-only counterpart of the edge self-upgrade: it asks central
# which release the node should run, downloads that release's relay assets
# (static coturn 4.18 + scripts + template + units), verifies every one against
# the release's SHA256SUMS, swaps them in, restarts coturn behind a health gate
# and rolls back on any failure.
#
#   oxpulse-relay-upgrade --check                  timer entry: ask central, start --apply detached
#   oxpulse-relay-upgrade --to X.Y.Z               operator: upgrade to X.Y.Z (detached, same guards)
#   oxpulse-relay-upgrade --apply X.Y.Z            the upgrade itself (foreground; what --check/--to start)
#   oxpulse-relay-upgrade --install-upgrader --version X.Y.Z
#                                                  one-time bootstrap of a LIVE relay node: installs the
#                                                  upgrader, its libs, the timer and a VERSION baseline.
#                                                  Does not touch coturn and never restarts it.
#   oxpulse-relay-upgrade --init-baseline          ensure releases/0.0.0 + the `current` symlink exist
#   oxpulse-relay-upgrade --status
#
# Invariants (relay-only profile): NO Docker; NEVER calls /api/partner/register or
# the node-config endpoint; writes no registration material; re-runs the
# registration-material gate before acting. The only central call is the
# unauthenticated POST /api/partner/heartbeat {node_id}, which returns
# desired_release (it carries no Reality material: node-config is a different
# endpoint).
#
# Safety: desired must be a bare MAJOR.MINOR.PATCH and strictly greater than the
# installed version (a downgrade or an equal version is a no-op); every asset must
# be listed in SHA256SUMS AND match it (a missing entry is a failure, not a skip);
# a pre-swap snapshot of every replaced file lets a failed health gate restore
# the previous binary, unit, template and scripts; a version that failed is not
# retried until the operator removes $LIB_ROOT/failed-version or central moves on.
#
# THIS RESTARTS coturn (live allocations drop; calls reconnect). The timer fires
# in a quiet window; the swap itself runs as its own transient unit so a
# TimeoutStartSec on the timer's service can never kill it mid-swap.
#
# Exit: 0 ok / no-op, 2 usage, 10 verification or pre-swap failure (nothing
# changed), 11 health gate failed and the previous version was restored,
# 12 health gate failed AND the rollback failed (coturn is down: page a human).
set -euo pipefail

PREFIX_ETC="${PREFIX_ETC:-/etc/oxpulse-partner-edge}"
LIB_ROOT="${RELAY_LIB_DIR:-/usr/local/lib/oxpulse-relay}"
SBIN="${PREFIX_SBIN:-/usr/local/sbin}"
UNIT_DIR="${UNIT_DIR:-/etc/systemd/system}"
SHARE_DIR="${PREFIX_SHARE:-/usr/local/share}/oxpulse-partner-edge"
VERSION_FILE="${SHARE_DIR}/VERSION"
OPEC_DST="${OPEC_DST:-/usr/bin/opec}"
RELEASES_BASE="${RELAY_RELEASES_BASE:-https://github.com/anatolykoptev/oxpulse-partner-edge/releases/download}"
BACKEND="${OXPULSE_BACKEND_API:-https://api.oxpulse.chat}"
BACKEND="${BACKEND%/}"
CURL="${RELAY_CURL:-curl}"
SYSTEMCTL="${SYSTEMCTL:-systemctl}"
SYSTEMD_RUN="${SYSTEMD_RUN:-systemd-run}"
COTURN_UNIT="oxpulse-relay-coturn.service"
SELF_UNIT="oxpulse-relay-self-upgrade"
BASELINE_VER="0.0.0"
GATE_TRIES="${RELAY_GATE_TRIES:-15}"
GATE_INTERVAL="${RELAY_GATE_INTERVAL:-2}"
SYSTEM_BIN_DIR="${RELAY_SYSTEM_BIN_DIR:-/usr/bin}"
SEMVER_RE='^[0-9]+\.[0-9]+\.[0-9]+$'

log()  { printf '[relay-upgrade] %s\n' "$*" >&2; }
warn() { printf '[relay-upgrade] WARN: %s\n' "$*" >&2; }
die()  { printf '[relay-upgrade] ERR:  %s\n' "$*" >&2; exit "${DIE_RC:-10}"; }
# crit — loud: stderr (journal) plus a syslog line at crit priority.
crit() {
	printf '[relay-upgrade] CRIT: %s\n' "$*" >&2
	command -v logger >/dev/null 2>&1 && logger -t oxpulse-relay-upgrade -p user.crit -- "$*" || true
}

is_semver() { [[ "$1" =~ $SEMVER_RE ]]; }
# ver_gt A B — A strictly greater than B (both bare semver).
ver_gt() { [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" == "$1" ]]; }

installed_version() {
	local v=""
	[[ -r "$VERSION_FILE" ]] && v=$(awk '{print $1; exit}' "$VERSION_FILE" 2>/dev/null || true)
	printf '%s' "$v"
}

arch_token() {
	case "${RELAY_ARCH_OVERRIDE:-$(uname -m)}" in
		x86_64|amd64) printf 'amd64' ;;
		aarch64|arm64) printf 'arm64' ;;
		*) return 1 ;;
	esac
}

# dest_for KIND NAME VER — where a manifest entry installs. The manifest never
# supplies a path: the kind picks a fixed directory and NAME is a bare filename.
dest_for() {
	case "$1" in
		sbin) printf '%s/%s' "$SBIN" "$2" ;;
		lib)  printf '%s/%s' "$LIB_ROOT" "$2" ;;
		etc)  printf '%s/%s' "$PREFIX_ETC" "$2" ;;
		unit) printf '%s/%s' "$UNIT_DIR" "$2" ;;
		bin)  printf '%s/releases/%s/%s' "$LIB_ROOT" "$3" "$2" ;;
		*) return 1 ;;
	esac
}
mode_for() { case "$1" in sbin|bin) printf '0755' ;; *) printf '0644' ;; esac; }

# install_atomic SRC DST MODE — sibling temp + rename(2).
install_atomic() {
	local src="$1" dst="$2" mode="$3" tmp
	# Create a missing directory only: `install -d -m` would also chmod an existing
	# one (it loosens /etc/oxpulse-partner-edge from 0750 to 0755).
	[[ -d "$(dirname "$dst")" ]] || install -d -m 0755 "$(dirname "$dst")" || return 1
	tmp="${dst}.new.$$"
	install -m "$mode" "$src" "$tmp" || return 1
	mv -f "$tmp" "$dst" || return 1
}

# ---- registration-material gate / node identity -----------------------------
load_relay_lib() { # <dir containing relay-lib.sh>
	# shellcheck source=relay/relay-lib.sh
	. "$1/relay-lib.sh"
}
assert_relay_node() {
	relay_assert_no_registration_material
	[[ -s "${PREFIX_ETC}/node-id" && -r "${PREFIX_ETC}/relay.env" ]] \
		|| die "not a relay-only node: ${PREFIX_ETC}/node-id or relay.env missing"
	NODE_ID=$(tr -d '[:space:]' < "${PREFIX_ETC}/node-id")
	[[ "$NODE_ID" =~ ^[A-Za-z0-9._-]{1,128}$ ]] || die "bad node-id"
}

# ---- fetch + verify ---------------------------------------------------------
fetch() { # <url> <dest>
	"$CURL" -fsSL --proto '=https' --tlsv1.2 --max-time 180 -o "$2" "$1"
}
SUMS_FILE=""
sums_lookup() { awk -v n="$1" '$2 == n || $2 == "*" n || $2 == "./" n { print $1; exit }' "$SUMS_FILE"; }
# verify_asset FILE ASSET — FAIL CLOSED: an asset absent from SHA256SUMS is an
# error, never "nothing to compare against".
verify_asset() {
	local file="$1" asset="$2" want have
	want=$(sums_lookup "$asset")
	[[ "$want" =~ ^[0-9a-f]{64}$ ]] || die "${asset}: not listed in the release SHA256SUMS; refusing an unverified file"
	have=$(sha256sum "$file" | awk '{print $1}')
	[[ "$have" == "$want" ]] || die "${asset}: SHA256 MISMATCH (expected ${want}, got ${have}); nothing installed"
}

MANIFEST_ROWS=()   # "group|kind|asset|name"
# stage_release VER GROUPS STAGE_DIR — download and verify SHA256SUMS, the
# manifest and every asset of the requested groups into STAGE_DIR.
# GROUPS: "upgrader" or "all".
stage_release() {
	local ver="$1" groups="$2" stage="$3" base arch line group kind asset name f
	base="${RELEASES_BASE}/v${ver}"
	arch=$(arch_token) || die "unsupported architecture $(uname -m)"
	fetch "${base}/SHA256SUMS" "${stage}/SHA256SUMS" || die "could not fetch ${base}/SHA256SUMS (release v${ver} missing or network down)"
	SUMS_FILE="${stage}/SHA256SUMS"
	fetch "${base}/relay-manifest.txt" "${stage}/relay-manifest.txt" || die "could not fetch relay-manifest.txt for v${ver}"
	verify_asset "${stage}/relay-manifest.txt" relay-manifest.txt
	MANIFEST_ROWS=()
	while IFS= read -r line; do
		line="${line%%#*}"
		[[ -n "${line//[[:space:]]/}" ]] || continue
		read -r group kind asset name <<<"$line"
		[[ "$group" == upgrader || "$group" == release ]] || die "manifest: bad group '${group}'"
		case "$kind" in sbin|lib|etc|unit|bin) ;; *) die "manifest: bad kind '${kind}'" ;; esac
		asset="${asset//@ARCH@/$arch}"
		[[ "$asset" =~ ^[A-Za-z0-9._-]+$ && "$name" =~ ^[A-Za-z0-9._-]+$ ]] || die "manifest: unsafe file name in '${line}'"
		[[ "$groups" == all || "$group" == "$groups" ]] || continue
		MANIFEST_ROWS+=("${group}|${kind}|${asset}|${name}")
	done < "${stage}/relay-manifest.txt"
	((${#MANIFEST_ROWS[@]})) || die "manifest for v${ver} lists nothing for group '${groups}'"
	for line in "${MANIFEST_ROWS[@]}"; do
		IFS='|' read -r group kind asset name <<<"$line"
		f="${stage}/${asset}"
		fetch "${base}/${asset}" "$f" || die "could not fetch ${base}/${asset}"
		verify_asset "$f" "$asset"
		[[ "$kind" != sbin && "$kind" != bin ]] || chmod 0755 "$f"
	done
	log "v${ver}: ${#MANIFEST_ROWS[@]} assets verified against SHA256SUMS"
}

# ensure_opec VER STAGE — the template must render with the installed opec. If it
# cannot (older than the relay subcommands), install the release's opec, which
# is checksummed in the same SHA256SUMS.
opec_supports() {
	"$1" check-node-secret --help >/dev/null 2>&1 && "$1" render coturn --help 2>&1 | grep -q -- '--secret-file'
}
ensure_opec() { # <ver> <stage>
	if [[ -x "$OPEC_DST" ]] && opec_supports "$OPEC_DST"; then return 0; fi
	local arch asset f
	arch=$(arch_token) || die "unsupported architecture"
	asset="opec-${arch}"
	f="$2/${asset}"
	fetch "${RELEASES_BASE}/v$1/${asset}" "$f" || die "opec: could not fetch ${asset}"
	verify_asset "$f" "$asset"
	opec_supports "$f" || die "opec: release v$1 ${asset} lacks the relay subcommands"
	install_atomic "$f" "$OPEC_DST" 0755
	log "opec replaced from release v$1 (checksum verified)"
}

# ---- snapshot / activate / rollback ------------------------------------------
SNAP_DIR="" # set per run
snapshot_live() { # <ver> — copy every file the activation will replace
	local new="${LIB_ROOT}/snapshots/.new" row group kind asset name dst
	rm -rf "${new:?}"
	install -d -m 0700 "$new"
	: > "${new}/ABSENT"
	for row in "${MANIFEST_ROWS[@]}"; do
		IFS='|' read -r group kind asset name <<<"$row"
		[[ "$kind" != bin ]] || continue
		dst=$(dest_for "$kind" "$name" "$1")
		if [[ -e "$dst" ]]; then
			install -d -m 0700 "${new}/${kind}"
			cp -p "$dst" "${new}/${kind}/${name}"
		else
			printf '%s %s\n' "$kind" "$name" >> "${new}/ABSENT"
		fi
	done
	if [[ -L "${LIB_ROOT}/current" ]]; then readlink "${LIB_ROOT}/current" > "${new}/current.target"; else : > "${new}/current.none"; fi
	cp -p "$VERSION_FILE" "${new}/VERSION" 2>/dev/null || true
	rm -rf "${LIB_ROOT}/snapshots/last"
	mv "$new" "${LIB_ROOT}/snapshots/last"
	SNAP_DIR="${LIB_ROOT}/snapshots/last"
}

set_current() { # <target dir relative to LIB_ROOT>
	local tmp="${LIB_ROOT}/.current.new.$$"
	ln -sfn "$1" "$tmp" || return 1
	mv -T "$tmp" "${LIB_ROOT}/current" || return 1
}

# activate VER — install every manifest file, then flip `current`. Libs first and
# the upgrader last, so a half-done activation never leaves a script that needs a
# lib that is not there. Runs inside an `||` list, where `set -e` is off, so every
# step returns explicitly.
activate() {
	local ver="$1" kind row group k a name dst
	for kind in lib etc unit sbin; do
		for row in "${MANIFEST_ROWS[@]}"; do
			IFS='|' read -r group k a name <<<"$row"
			[[ "$k" == "$kind" ]] || continue
			dst=$(dest_for "$kind" "$name" "$ver") || return 1
			install_atomic "${STAGE}/${a}" "$dst" "$(mode_for "$kind")" || return 1
		done
	done
	set_current "releases/${ver}" || return 1
	"$SYSTEMCTL" daemon-reload || return 1
}

restore_snapshot() {
	local kind name f
	[[ -d "${SNAP_DIR}" ]] || { crit "no snapshot to roll back to"; return 1; }
	for kind in lib etc unit sbin; do
		[[ -d "${SNAP_DIR}/${kind}" ]] || continue
		for f in "${SNAP_DIR}/${kind}"/*; do
			[[ -e "$f" ]] || continue
			name=$(basename "$f")
			install_atomic "$f" "$(dest_for "$kind" "$name" x)" "$(mode_for "$kind")" || return 1
		done
	done
	while read -r kind name; do
		[[ -n "${kind:-}" ]] || continue
		rm -f -- "$(dest_for "$kind" "$name" x)" || return 1
	done < "${SNAP_DIR}/ABSENT"
	if [[ -f "${SNAP_DIR}/current.target" ]]; then
		set_current "$(cat "${SNAP_DIR}/current.target")" || return 1
	else
		rm -f "${LIB_ROOT}/current" || return 1
	fi
	"$SYSTEMCTL" daemon-reload || return 1
}

# ---- restart + health gate ----------------------------------------------------
restart_coturn() {
	"$SYSTEMCTL" reset-failed "$COTURN_UNIT" 2>/dev/null || true
	"$SYSTEMCTL" restart "$COTURN_UNIT"
}

# health_gate — coturn active, TCP-control Allocate, TURNS TLS and a bound UDP
# listener, the same probes the heartbeat uses (relay-probe-lib.sh). Retries: coturn
# needs a moment after a restart.
health_gate() {
	local i
	# shellcheck source=/dev/null
	. "${PREFIX_ETC}/relay.env"
	: "${EXTERNAL_IP:?relay.env missing EXTERNAL_IP}" "${RELAY_HOSTNAME:?relay.env missing RELAY_HOSTNAME}"
	_PREFIX_ETC="$PREFIX_ETC"
	export EXTERNAL_IP RELAY_HOSTNAME
	if [[ -z "${TURN_UCLIENT:-}" ]]; then
		if [[ -x "${LIB_ROOT}/current/turnutils_uclient" ]]; then TURN_UCLIENT="${LIB_ROOT}/current/turnutils_uclient"; else TURN_UCLIENT=turnutils_uclient; fi
	fi
	export TURN_UCLIENT
	for ((i = 1; i <= GATE_TRIES; i++)); do
		if "$SYSTEMCTL" is-active --quiet "$COTURN_UNIT" && relay_probe_allocate && relay_probe_tls && relay_probe_udp_listener; then
			log "health gate passed (attempt ${i})"
			return 0
		fi
		sleep "$GATE_INTERVAL"
	done
	crit "health gate failed after ${GATE_TRIES} attempts (last reason: ${RELAY_PROBE_REASON:-unit-inactive})"
	return 1
}

# ---- baseline -------------------------------------------------------------------
# releases/0.0.0 stands for "whatever the distro package installed": its binaries
# are symlinks to /usr/bin, so `current` is always valid and the coturn unit can
# always point at ${LIB_ROOT}/current/turnserver.
init_baseline() {
	local d="${LIB_ROOT}/releases/${BASELINE_VER}" b
	install -d -m 0755 "${LIB_ROOT}/releases" "${LIB_ROOT}/snapshots"
	install -d -m 0755 "$d"
	for b in turnserver turnutils_uclient; do
		[[ -e "${d}/${b}" || -L "${d}/${b}" ]] || ln -s "${SYSTEM_BIN_DIR}/${b}" "${d}/${b}"
	done
	[[ -L "${LIB_ROOT}/current" ]] || set_current "releases/${BASELINE_VER}"
	if [[ ! -s "$VERSION_FILE" ]]; then
		install -d -m 0755 "$SHARE_DIR"
		printf '%s\n' "$BASELINE_VER" > "${VERSION_FILE}.new.$$"
		mv -f "${VERSION_FILE}.new.$$" "$VERSION_FILE"
		log "VERSION baseline ${BASELINE_VER} written (pre-autoupdate relay)"
	fi
}

write_version() {
	install -d -m 0755 "$SHARE_DIR"
	printf '%s\n' "$1" > "${VERSION_FILE}.new.$$"
	mv -f "${VERSION_FILE}.new.$$" "$VERSION_FILE"
}

prune_releases() { # keep the two newest staged releases (the baseline dir stays)
	local d name keep
	keep=$(for d in "${LIB_ROOT}/releases"/*; do
		name=$(basename "$d")
		[[ -d "$d" && "$name" =~ $SEMVER_RE && "$name" != "$BASELINE_VER" ]] && printf '%s\n' "$name"
	done | sort -V | tail -n2)
	for d in "${LIB_ROOT}/releases"/*; do
		name=$(basename "$d")
		[[ -d "$d" && "$name" =~ $SEMVER_RE && "$name" != "$BASELINE_VER" ]] || continue
		grep -qxF "$name" <<<"$keep" || rm -rf -- "${LIB_ROOT:?}/releases/${name:?}"
	done
}

# ---- apply ------------------------------------------------------------------------
STAGE=""
cleanup_stage() { [[ -z "$STAGE" ]] || rm -rf -- "$STAGE"; }

apply_upgrade() { # <ver>
	local ver="$1" inst failed lockf
	is_semver "$ver" || { DIE_RC=2 die "version '${ver}' is not a bare MAJOR.MINOR.PATCH"; }
	[[ "${ALLOW_NONROOT:-0}" = 1 || "$(id -u)" -eq 0 ]] || { DIE_RC=2 die "run as root"; }
	load_relay_lib "$LIB_ROOT"
	assert_relay_node
	# shellcheck source=relay/relay-probe-lib.sh
	. "${LIB_ROOT}/relay-probe-lib.sh"
	install -d -m 0755 "$LIB_ROOT"
	lockf="${LIB_ROOT}/.lock"
	exec 9>"$lockf"
	flock -n 9 || { log "another relay upgrade is running; nothing to do"; return 0; }

	inst=$(installed_version)
	is_semver "$inst" || die "installed version '${inst:-unset}' is not a concrete semver; bootstrap with --install-upgrader first"
	if [[ "$ver" == "$inst" ]]; then log "already at v${inst}; nothing to do"; return 0; fi
	if ! ver_gt "$ver" "$inst"; then log "refusing downgrade: desired=${ver} installed=${inst}"; return 0; fi
	failed=$(cat "${LIB_ROOT}/failed-version" 2>/dev/null || true)
	if [[ "$failed" == "$ver" ]]; then
		log "v${ver} failed its health gate earlier; not retrying (rm ${LIB_ROOT}/failed-version to retry)"
		return 0
	fi
	log "upgrading ${inst} -> ${ver}"

	init_baseline
	install -d -m 0755 "${LIB_ROOT}/releases"
	STAGE="${LIB_ROOT}/.stage.$$"
	rm -rf -- "$STAGE"; install -d -m 0700 "$STAGE"
	trap cleanup_stage EXIT
	stage_release "$ver" all "$STAGE"
	# Pre-swap checks: the shipped binary must execute on THIS host.
	local bin_ts
	bin_ts="${STAGE}/relay-turnserver-$(arch_token)"
	"$bin_ts" --version >/dev/null 2>&1 || die "v${ver}: the shipped turnserver does not run on this host; nothing changed"
	ensure_opec "$ver" "$STAGE"

	# Lay the release dir out (binaries live there), then snapshot and swap.
	local rel_dir="${LIB_ROOT}/releases/${ver}" row group kind asset name
	rm -rf -- "${rel_dir:?}"; install -d -m 0755 "$rel_dir"
	for row in "${MANIFEST_ROWS[@]}"; do
		IFS='|' read -r group kind asset name <<<"$row"
		[[ "$kind" == bin ]] || continue
		install_atomic "${STAGE}/${asset}" "${rel_dir}/${name}" 0755
	done
	snapshot_live "$ver"
	local swapped=0
	if activate "$ver"; then
		restart_coturn || warn "systemctl restart reported failure; the health gate decides"
		health_gate && swapped=1
	else
		crit "v${ver}: activation failed part-way"
	fi
	if [[ "$swapped" == 1 ]]; then
		write_version "$ver"
		rm -f "${LIB_ROOT}/failed-version"
		prune_releases
		log "upgrade to v${ver} complete"
		return 0
	fi

	crit "v${ver} did not come up healthy; rolling back to ${inst}"
	printf '%s\n' "$ver" > "${LIB_ROOT}/failed-version"
	restore_snapshot || { crit "rollback could not restore files; coturn state is UNKNOWN"; return 12; }
	restart_coturn || warn "restart after rollback reported failure"
	if health_gate; then
		crit "rolled back to ${inst}: coturn is healthy on the previous version; v${ver} will not be retried"
		return 11
	fi
	crit "ROLLBACK FAILED: coturn is unhealthy on the previous version too. Manual intervention required"
	return 12
}

# ---- check (timer) -------------------------------------------------------------------
fetch_desired() { # prints desired_release or nothing
	local resp code body
	resp=$("$CURL" -sS -X POST -H 'Content-Type: application/json' --proto '=https' --tlsv1.2 --max-time 10 \
		-d "{\"node_id\":\"${NODE_ID}\"}" "${BACKEND}/api/partner/heartbeat" -w '\n%{http_code}' 2>/dev/null || printf '\n000')
	code=$(printf '%s' "$resp" | tail -n1)
	body=$(printf '%s' "$resp" | sed '$d')
	if [[ "$code" != 200 ]]; then warn "central heartbeat answered http=${code}; will retry next tick"; return 0; fi
	printf '%s' "$body" | jq -r '.desired_release // empty' 2>/dev/null || true
}

# launch_detached VER — its own transient unit, never inside the timer's service.
launch_detached() {
	local ver="$1" st self
	st=$("$SYSTEMCTL" show -p ActiveState --value "${SELF_UNIT}.service" 2>/dev/null || true)
	case "$st" in
		active|activating|deactivating|reloading) log "${SELF_UNIT}.service already ${st}; not starting another"; return 0 ;;
	esac
	self="${SBIN}/oxpulse-relay-upgrade"
	[[ -x "$self" ]] || self="$(readlink -f "${BASH_SOURCE[0]}")"
	if "$SYSTEMD_RUN" --quiet --no-block --collect --unit="$SELF_UNIT" \
		--description="OxPulse relay-only upgrade to v${ver}" \
		--property=Type=oneshot --property=TimeoutStartSec=1200 \
		timeout 1000 "$self" --apply "$ver" >/dev/null 2>&1; then
		log "v${ver} started detached as ${SELF_UNIT}.service (journalctl -u ${SELF_UNIT})"
	else
		warn "could not start ${SELF_UNIT}.service for v${ver} (retry next tick)"
	fi
}

# desired_decision VER — echoes "go" or a reason; used by --check and --to.
check_and_launch() { # <desired>
	local desired="$1" inst failed
	[[ -n "$desired" ]] || return 0
	is_semver "$desired" || { warn "ignoring desired_release '${desired}': not a concrete release semver"; return 0; }
	inst=$(installed_version)
	is_semver "$inst" || { warn "installed version '${inst:-unset}' is not a concrete semver; bootstrap with --install-upgrader"; return 0; }
	[[ "$desired" != "$inst" ]] || return 0
	ver_gt "$desired" "$inst" || { log "refusing downgrade: desired=${desired} installed=${inst}"; return 0; }
	failed=$(cat "${LIB_ROOT}/failed-version" 2>/dev/null || true)
	[[ "$failed" != "$desired" ]] || { log "v${desired} failed earlier; not retrying"; return 0; }
	launch_detached "$desired"
}

do_check() {
	[[ "${ALLOW_NONROOT:-0}" = 1 || "$(id -u)" -eq 0 ]] || { DIE_RC=2 die "run as root"; }
	load_relay_lib "$LIB_ROOT"
	assert_relay_node
	check_and_launch "$(fetch_desired)"
}

# ---- bootstrap of a live node ----------------------------------------------------------------
do_install_upgrader() { # <ver>
	local ver="$1" row group kind k asset name dst
	is_semver "$ver" || { DIE_RC=2 die "--version must be a bare MAJOR.MINOR.PATCH"; }
	[[ "${ALLOW_NONROOT:-0}" = 1 || "$(id -u)" -eq 0 ]] || { DIE_RC=2 die "run as root"; }
	STAGE=$(mktemp -d)
	trap cleanup_stage EXIT
	stage_release "$ver" upgrader "$STAGE"
	# The gate runs from the VERIFIED relay-lib.sh of the release, before anything is installed.
	[[ -f "${STAGE}/relay-lib.sh" ]] && load_relay_lib "$STAGE"
	declare -F relay_assert_no_registration_material >/dev/null || die "the upgrader group must ship relay-lib.sh"
	assert_relay_node
	for kind in lib unit sbin; do
		for row in "${MANIFEST_ROWS[@]}"; do
			IFS='|' read -r group k asset name <<<"$row"
			[[ "$k" == "$kind" ]] || continue
			dst=$(dest_for "$kind" "$name" "$ver")
			install_atomic "${STAGE}/${asset}" "$dst" "$(mode_for "$kind")"
			log "installed ${dst}"
		done
	done
	init_baseline
	"$SYSTEMCTL" daemon-reload
	"$SYSTEMCTL" enable --now oxpulse-relay-upgrade.timer >/dev/null 2>&1 || warn "could not enable oxpulse-relay-upgrade.timer"
	log "upgrader installed from v${ver}. coturn was NOT touched or restarted."
	log "installed version: $(installed_version). Upgrade when ready: oxpulse-relay-upgrade --to ${ver}"
}

do_status() {
	printf 'installed: %s\n' "$(installed_version)"
	printf 'current -> %s\n' "$(readlink "${LIB_ROOT}/current" 2>/dev/null || echo none)"
	printf 'failed-version: %s\n' "$(cat "${LIB_ROOT}/failed-version" 2>/dev/null || echo none)"
	printf 'snapshot: %s\n' "$([[ -d "${LIB_ROOT}/snapshots/last" ]] && echo present || echo none)"
}

main() {
	local mode="${1:-}"
	case "$mode" in
		--check) do_check ;;
		--apply) [[ $# -eq 2 ]] || { DIE_RC=2 die "usage: --apply X.Y.Z"; }; apply_upgrade "$2" ;;
		--to)
			[[ $# -eq 2 ]] || { DIE_RC=2 die "usage: --to X.Y.Z"; }
			is_semver "$2" || { DIE_RC=2 die "version must be a bare MAJOR.MINOR.PATCH"; }
			load_relay_lib "$LIB_ROOT"
			assert_relay_node
			check_and_launch "$2" ;;
		--install-upgrader)
			[[ "${2:-}" == --version && -n "${3:-}" ]] || { DIE_RC=2 die "usage: --install-upgrader --version X.Y.Z"; }
			do_install_upgrader "$3" ;;
		--init-baseline) init_baseline ;;
		--status) do_status ;;
		*) DIE_RC=2 die "usage: $0 --check | --to X.Y.Z | --apply X.Y.Z | --install-upgrader --version X.Y.Z | --init-baseline | --status" ;;
	esac
}
main "$@"
exit
