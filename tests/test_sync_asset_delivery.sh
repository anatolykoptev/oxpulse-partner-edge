#!/usr/bin/env bats
# tests/test_sync_asset_delivery.sh — bats coverage for the release-asset
# delivery work (AWG-3.1 planPhase P4 / keyDecision D8):
#
#   A. sync_host_scripts' asset step (Step 5d, lib/host-scripts-lib.sh) —
#      _HOST_SCRIPT_ASSET_FILES, fetched via the use_releases_asset URL
#      polarity ($RELEASES_BASE/$tag), verified against the once-per-run
#      SHA256SUMS via _lookup_sha256, atomically installed, _any_changed →
#      the already-listed agent-unit restart. Gated on unit-or-binary
#      present; fail-soft warn+skip; never unverified.
#   B. the bootstrap fallback in lib/install-awg-params-agent.sh — was an
#      unpinned, unverified releases/latest/download fetch; now pinned to
#      the installer's own OXPULSE_RELEASE_TAG + verified against that
#      tag's SHA256SUMS, warn+skip (never die) when unverifiable.
#
# Mocking follows the repo's established pattern (test_awg_params_agent_
# install.sh): curl/systemctl/install/uname stubs on a temp PATH, fixture
# files standing in for the release server. RELEASES_BASE/REPO_RAW use a
# fixture:// scheme the curl stub maps onto $FIXTURE/<host>/<path>; absent
# fixture files exit 22 like `curl -f` on a 404.
#
# The defect this pins: tests/test_restarted_units_are_delivered.sh's
# 4-distinct-hashes fleet fingerprint — every upgrade restarted the agent
# unit and none ever refreshed the binary.

setup() {
	REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	TMP="$(mktemp -d)"
	FAKE_LOG="$TMP/calls.log"
	touch "$FAKE_LOG"
	FIXTURE="$TMP/fixture"
	mkdir -p "$TMP/bin" "$FIXTURE/rel" "$FIXTURE/raw"

	# Node-side dirs (the caller-table PREFIX_*/SYSTEMD_DIR globals).
	FBIN="$TMP/node/bin";      FSBIN="$TMP/node/sbin"
	FSYSTEMD="$TMP/node/systemd"; FETC="$TMP/node/etc"
	FLIBDIR="$TMP/node/libdir";   FSHARE="$TMP/node/share"
	FLIB="$TMP/node/varlib"
	mkdir -p "$FBIN" "$FSBIN" "$FSYSTEMD" "$FETC" "$FLIBDIR" "$FSHARE" "$FLIB"

	# --- curl: map <scheme>://<host>/<path> → $FIXTURE/<host>/<path> ------
	cat > "$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "$FAKE_LOG"
dest=""; url=""
while [[ $# -gt 0 ]]; do
	case "$1" in
		-o)         dest="$2"; shift 2 ;;
		--max-time) shift 2 ;;
		*://*)      url="$1"; shift ;;
		*)          shift ;;
	esac
done
[[ -n "$dest" && -n "$url" ]] || exit 22
f="$FIXTURE/${url#*://}"
if [[ -f "$f" ]]; then cp "$f" "$dest"; exit 0; fi
exit 22
STUB
	chmod +x "$TMP/bin/curl"

	# --- systemctl: log everything; is-active gated on FAKE_SYSTEMCTL_ACTIVE
	cat > "$TMP/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "systemctl $*" >> "$FAKE_LOG"
case "$1" in
	is-active)  [[ "${FAKE_SYSTEMCTL_ACTIVE:-0}" == "1" ]] && exit 0 || exit 3 ;;
	is-enabled) echo "${FAKE_SYSTEMCTL_ENABLED:-enabled}"; exit 0 ;;
	*)          exit 0 ;;
esac
STUB
	chmod +x "$TMP/bin/systemctl"

	# --- install: copy src→dst (same stub shape as test_awg_params_agent_install.sh)
	cat > "$TMP/bin/install" <<'STUB'
#!/usr/bin/env bash
echo "install $*" >> "$FAKE_LOG"
args=("$@")
n=${#args[@]}
src="${args[$((n-2))]}"
dst="${args[$((n-1))]}"
if [[ "$1" == "-d" ]]; then
	mkdir -p "${args[@]:1}"
elif [[ -f "$src" ]]; then
	mkdir -p "$(dirname "$dst")"
	cp "$src" "$dst" 2>/dev/null || touch "$dst"
else
	mkdir -p "$(dirname "$dst")" 2>/dev/null || true
	touch "$dst" 2>/dev/null || true
fi
exit 0
STUB
	chmod +x "$TMP/bin/install"

	# --- uname: FAKE_UNAME drives the arch map
	cat > "$TMP/bin/uname" <<'STUB'
#!/usr/bin/env bash
echo "${FAKE_UNAME:-x86_64}"
STUB
	chmod +x "$TMP/bin/uname"

	# --- sleep: the bootstrap smoke check would otherwise burn 10s
	cat > "$TMP/bin/sleep" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
	chmod +x "$TMP/bin/sleep"

	# --- sha256sum: real tool where present; shasum wrapper on macOS -----
	if ! command -v sha256sum >/dev/null 2>&1; then
		cat > "$TMP/bin/sha256sum" <<'STUB'
#!/usr/bin/env bash
exec shasum -a 256 "$@"
STUB
		chmod +x "$TMP/bin/sha256sum"
	fi

	# Pre-converge sync_host_scripts' incidental writers so _any_changed
	# reflects ONLY the asset step: the channel-health drop-in (Step 6) and
	# xray.env (Step 6.5) would otherwise flip it on every run and mask the
	# same-sha → no-restart assertion.
	mkdir -p "$FSYSTEMD/oxpulse-channels-health-report.service.d"
	printf '[Service]\nEnvironment=OXPULSE_BACKEND_API=https://api.oxpulse.chat\n' \
		> "$FSYSTEMD/oxpulse-channels-health-report.service.d/10-central-url.conf"
	: > "$FETC/xray.env"

	# Runner for sync_host_scripts: supplies the caller-table globals the lib
	# resolves dynamically (normally upgrade.sh's). The managed script/unit
	# lists are deliberately EMPTY so only the asset step can act.
	cat > "$TMP/run_sync.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
log()  { printf 'log: %s\n'  "$*"; }
warn() { printf 'warn: %s\n' "$*"; }
die()  { printf 'die: %s\n'  "$*" >&2; exit 1; }
_HOST_SCRIPT_SBIN_FILES=()
_HOST_SCRIPT_SYSTEMD_FILES=()
_HOST_SCRIPT_SYSTEMD_TEMPLATED_FILES=()
_HOST_SCRIPT_ENABLE_UNITS=()
_HOST_SCRIPT_RESTART_UNITS=(oxpulse-awg-params-agent.service)
_host_script_remote_name()  { printf '%s\n' "$1"; }
_host_script_install_dir()  { printf '%s\n' "$PREFIX_SBIN"; }
_host_script_mode()         { printf '0755\n'; }
STATE_FILE=/dev/null
source "$REPO_ROOT/lib/host-scripts-lib.sh"
sync_host_scripts "$1"
EOF

	# Runner for the install-side lib (install-awg-params-agent.sh).
	cat > "$TMP/run_agent.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
log()  { printf 'log: %s\n'  "$*"; }
warn() { printf 'warn: %s\n' "$*"; }
die()  { printf 'die: %s\n'  "$*" >&2; exit 1; }
source "$REPO_ROOT/lib/install-awg-params-agent.sh"
# Override the install dest AFTER source (module constant → writable path),
# same pattern as tests/test_awg_params_agent_install.sh.
_AWG_PARAMS_AGENT_BIN="$FBIN/oxpulse-awg-params-agent"
"$@"
EOF

	# Fake checkout for the install-side tests: a systemd/ unit but NO
	# bundled binary (forces the network fallback).
	CHECKOUT="$TMP/checkout"
	mkdir -p "$CHECKOUT/systemd"
	printf '[Unit]\nDescription=fake awg-params-agent\n' \
		> "$CHECKOUT/systemd/oxpulse-awg-params-agent.service"
}

teardown() {
	rm -rf "$TMP"
}

# Env shared by every sync_host_scripts invocation. EXPORTed: the PATH stubs
# (curl/systemctl) are child processes and must see FAKE_LOG + FIXTURE.
_sync_env() {
	cat <<ENVEOF
export FAKE_LOG='$FAKE_LOG'
export FIXTURE='$FIXTURE'
export REPO_ROOT='$REPO_ROOT'
export PREFIX_SBIN='$FSBIN'
export PREFIX_BIN='$FBIN'
export PREFIX_LIBDIR='$FLIBDIR'
export PREFIX_SHARE='$FSHARE'
export PREFIX_ETC='$FETC'
export SYSTEMD_DIR='$FSYSTEMD'
export SYSTEMCTL_BIN='$TMP/bin/systemctl'
export REPO_RAW='fixture://raw'
export RELEASES_BASE='fixture://rel'
export DRY_RUN=0
ENVEOF
}

# Env shared by install-awg-params-agent.sh invocations.
_agent_env() {
	cat <<ENVEOF
export FAKE_LOG='$FAKE_LOG'
export FIXTURE='$FIXTURE'
export REPO_ROOT='$REPO_ROOT'
export FBIN='$FBIN'
export DRY_RUN=0
export BAKE_MODE=0
export src_dir='$CHECKOUT'
export REPO_RAW='fixture://raw'
export SYSTEMD_DIR='$FSYSTEMD'
export PREFIX_ETC='$FETC'
export PREFIX_LIB='$FLIB'
export BACKEND_API='https://api.oxpulse.chat'
export NODE_ID='test-node-01'
ENVEOF
}

# Write a release fixture: $1=tag $2=asset basename $3=asset bytes
# $4=wrong-sha (optional; if set, SHA256SUMS carries a bogus hash)
_make_release() {
	local tag="$1" asset="$2" bytes="$3" wrong="${4:-}"
	local dir="$FIXTURE/rel/$tag"
	mkdir -p "$dir"
	printf '%s' "$bytes" > "$dir/$asset"
	local sha
	if [[ -n "$wrong" ]]; then
		sha="0000000000000000000000000000000000000000000000000000000000000000"
	else
		sha=$(sha256sum "$dir/$asset" | awk '{print $1}')
	fi
	printf '%s  %s\n' "$sha" "$asset" >> "$dir/SHA256SUMS"
}

# ===========================================================================
# A. sync_host_scripts asset step
# ===========================================================================

@test "sync: drift → asset fetched, verified, atomically installed, unit restarted" {
	# Unit present (gate) + stale binary on disk + unit active → restart fires.
	printf '[Service]\nExecStart=/usr/local/bin/oxpulse-awg-params-agent\n' \
		> "$FSYSTEMD/oxpulse-awg-params-agent.service"
	printf 'OLD-BINARY' > "$FBIN/oxpulse-awg-params-agent"
	_make_release v9.9.9 oxpulse-awg-params-agent-amd64 'NEW-BINARY-v9.9.9'

	run env FAKE_SYSTEMCTL_ACTIVE=1 PATH="$TMP/bin:$PATH" \
		bash -c "$(_sync_env); bash '$TMP/run_sync.sh' v9.9.9"
	[ "$status" -eq 0 ]
	[[ "$output" == *"installed oxpulse-awg-params-agent"* ]]
	# Verified bytes landed (stale content replaced).
	[ "$(cat "$FBIN/oxpulse-awg-params-agent")" = 'NEW-BINARY-v9.9.9' ]
	# The fetch used the tag-pinned release-asset URL, not latest/download.
	grep -q 'fixture://rel/v9.9.9/oxpulse-awg-params-agent-amd64' "$FAKE_LOG"
	! grep -q 'latest/download' "$FAKE_LOG"
	# Atomic install: no sibling .new.<pid> temp left behind.
	! compgen -G "$FBIN/*.new.*" >/dev/null
	# _any_changed → Step 7 restarted the already-listed unit.
	grep -q 'systemctl restart oxpulse-awg-params-agent.service' "$FAKE_LOG"
}

@test "sync: same sha → up-to-date, no install, no restart" {
	printf '[Service]\nExecStart=/usr/local/bin/oxpulse-awg-params-agent\n' \
		> "$FSYSTEMD/oxpulse-awg-params-agent.service"
	printf 'SAME-BYTES' > "$FBIN/oxpulse-awg-params-agent"
	_make_release v9.9.9 oxpulse-awg-params-agent-amd64 'SAME-BYTES'

	run env FAKE_SYSTEMCTL_ACTIVE=1 PATH="$TMP/bin:$PATH" \
		bash -c "$(_sync_env); bash '$TMP/run_sync.sh' v9.9.9"
	[ "$status" -eq 0 ]
	[[ "$output" == *"up-to-date"* ]]
	! grep -q 'systemctl restart oxpulse-awg-params-agent.service' "$FAKE_LOG"
}

@test "sync: missing unit + missing binary → AWG-less skip (no fetch)" {
	_make_release v9.9.9 oxpulse-awg-params-agent-amd64 'NEW-BINARY'

	run env PATH="$TMP/bin:$PATH" \
		bash -c "$(_sync_env); bash '$TMP/run_sync.sh' v9.9.9"
	[ "$status" -eq 0 ]
	[[ "$output" == *"AWG-less node"* ]]
	# The asset itself was never fetched (SHA256SUMS at Step 1 still is).
	! grep -q 'oxpulse-awg-params-agent-amd64' "$FAKE_LOG"
	[ ! -e "$FBIN/oxpulse-awg-params-agent" ]
	! grep -q 'systemctl restart' "$FAKE_LOG"
}

@test "sync: sha mismatch → warn-skip, installed binary untouched" {
	printf '[Service]\nExecStart=/usr/local/bin/oxpulse-awg-params-agent\n' \
		> "$FSYSTEMD/oxpulse-awg-params-agent.service"
	printf 'SENTINEL' > "$FBIN/oxpulse-awg-params-agent"
	_make_release v9.9.9 oxpulse-awg-params-agent-amd64 'EVIL-BYTES' wrongsha

	run env FAKE_SYSTEMCTL_ACTIVE=1 PATH="$TMP/bin:$PATH" \
		bash -c "$(_sync_env); bash '$TMP/run_sync.sh' v9.9.9"
	[ "$status" -eq 0 ]
	[[ "$output" == *"MISMATCH"* ]]
	[ "$(cat "$FBIN/oxpulse-awg-params-agent")" = 'SENTINEL' ]
	! grep -q 'systemctl restart oxpulse-awg-params-agent.service' "$FAKE_LOG"
}

@test "sync: no SHA256SUMS entry for the asset → never installed" {
	# The sums file exists but does not cover the asset — fail-closed even
	# though verification machinery ran (a release predating the asset, or
	# a manifest one entry short).
	printf '[Service]\nExecStart=/usr/local/bin/oxpulse-awg-params-agent\n' \
		> "$FSYSTEMD/oxpulse-awg-params-agent.service"
	printf 'SENTINEL' > "$FBIN/oxpulse-awg-params-agent"
	mkdir -p "$FIXTURE/rel/v9.9.9"
	printf 'deadbeef  partner-edge-upgrade.sh\n' > "$FIXTURE/rel/v9.9.9/SHA256SUMS"
	printf 'UNVERIFIED-BYTES' > "$FIXTURE/rel/v9.9.9/oxpulse-awg-params-agent-amd64"

	run env FAKE_SYSTEMCTL_ACTIVE=1 PATH="$TMP/bin:$PATH" \
		bash -c "$(_sync_env); bash '$TMP/run_sync.sh' v9.9.9"
	[ "$status" -eq 0 ]
	[[ "$output" == *"no SHA256SUMS entry"* ]]
	[ "$(cat "$FBIN/oxpulse-awg-params-agent")" = 'SENTINEL' ]
	# No sums entry → the asset is never even fetched.
	! grep -q 'oxpulse-awg-params-agent-amd64 -o' "$FAKE_LOG"
	! grep -q 'systemctl restart oxpulse-awg-params-agent.service' "$FAKE_LOG"
}

@test "sync: floating latest tag → warn-skip (root-daemon bytes never unverified)" {
	# tag=latest skips the SHA256SUMS fetch entirely (sha256sums_ok=0);
	# ALLOW_UNVERIFIED=1 — which legitimately un-verifies the SCRIPT class —
	# must NOT un-verify the root-daemon asset.
	printf '[Service]\nExecStart=/usr/local/bin/oxpulse-awg-params-agent\n' \
		> "$FSYSTEMD/oxpulse-awg-params-agent.service"
	printf 'SENTINEL' > "$FBIN/oxpulse-awg-params-agent"

	run env FAKE_SYSTEMCTL_ACTIVE=1 ALLOW_UNVERIFIED=1 PATH="$TMP/bin:$PATH" \
		bash -c "$(_sync_env); bash '$TMP/run_sync.sh' latest"
	[ "$status" -eq 0 ]
	[[ "$output" == *"never installed unverified"* ]]
	[ "$(cat "$FBIN/oxpulse-awg-params-agent")" = 'SENTINEL' ]
}

@test "sync: unsupported arch → warn-skip, binary untouched" {
	printf '[Service]\nExecStart=/usr/local/bin/oxpulse-awg-params-agent\n' \
		> "$FSYSTEMD/oxpulse-awg-params-agent.service"
	printf 'SENTINEL' > "$FBIN/oxpulse-awg-params-agent"
	_make_release v9.9.9 oxpulse-awg-params-agent-amd64 'NEW-BINARY'

	run env FAKE_UNAME=armv7l PATH="$TMP/bin:$PATH" \
		bash -c "$(_sync_env); bash '$TMP/run_sync.sh' v9.9.9"
	[ "$status" -eq 0 ]
	[[ "$output" == *"unsupported arch"* ]]
	[ "$(cat "$FBIN/oxpulse-awg-params-agent")" = 'SENTINEL' ]
	! grep -q 'systemctl restart oxpulse-awg-params-agent.service' "$FAKE_LOG"
}

@test "sync: binary-only node (no unit) still gated in and refreshed" {
	# Gate is unit-OR-binary: a node whose unit file vanished but whose
	# binary remains must still get verified bytes (is-active fails → the
	# restart loop simply skips it).
	printf 'OLD-BINARY' > "$FBIN/oxpulse-awg-params-agent"
	_make_release v9.9.9 oxpulse-awg-params-agent-amd64 'NEW-BINARY-v9.9.9'

	run env PATH="$TMP/bin:$PATH" \
		bash -c "$(_sync_env); bash '$TMP/run_sync.sh' v9.9.9"
	[ "$status" -eq 0 ]
	[ "$(cat "$FBIN/oxpulse-awg-params-agent")" = 'NEW-BINARY-v9.9.9' ]
}

@test "arch map: host-scripts-lib mirrors the install-awg-params-agent authority" {
	# The map exists twice by necessity (the install lib is not resolvable on
	# an upgrade-only box) — pin the two copies identical. A third copy must
	# never exist: upgrade.sh:280-283 is the resolver-drift precedent.
	for m in x86_64 aarch64 armv7l; do
		# if-guard: the fn returns 1 on unsupported arch — a bare $()
		# assignment would trip bats' errexit instead of recording rc.
		if out_a=$(env FAKE_UNAME=$m PATH="$TMP/bin:$PATH" bash -c \
			"source '$REPO_ROOT/lib/install-awg-params-agent.sh'; _awg_params_agent_release_arch"); then
			rc_a=0; else rc_a=$?; fi
		if out_b=$(env FAKE_UNAME=$m PATH="$TMP/bin:$PATH" bash -c \
			"source '$REPO_ROOT/lib/host-scripts-lib.sh'; _host_script_asset_arch"); then
			rc_b=0; else rc_b=$?; fi
		[ "$rc_a" -eq "$rc_b" ]
		[ "$out_a" = "$out_b" ]
	done
}

# ===========================================================================
# B. bootstrap fallback in lib/install-awg-params-agent.sh
# ===========================================================================

@test "bootstrap: pinned+verified fetch installs the installer's own tag" {
	# No bundled binary (src_dir has systemd/ only) → network fallback, which
	# must hit $OXPULSE_RELEASES_BASE/<tag>/, never latest/download.
	_make_release v9.9.9 oxpulse-awg-params-agent-amd64 'PINNED-BINARY'

	run env PATH="$TMP/bin:$PATH" OXPULSE_RELEASE_TAG='v9.9.9' \
		OXPULSE_RELEASES_BASE='fixture://rel' \
		bash -c "$(_agent_env); bash '$TMP/run_agent.sh' _awg_params_agent_install_binary"
	[ "$status" -eq 0 ]
	[ "$(cat "$FBIN/oxpulse-awg-params-agent")" = 'PINNED-BINARY' ]
	grep -q 'fixture://rel/v9.9.9/SHA256SUMS' "$FAKE_LOG"
	grep -q 'fixture://rel/v9.9.9/oxpulse-awg-params-agent-amd64' "$FAKE_LOG"
	! grep -q 'latest/download' "$FAKE_LOG"
}

@test "bootstrap: bad sha → binary NOT installed, warn not die" {
	_make_release v9.9.9 oxpulse-awg-params-agent-amd64 'EVIL-BYTES' wrongsha

	run env PATH="$TMP/bin:$PATH" OXPULSE_RELEASE_TAG='v9.9.9' \
		OXPULSE_RELEASES_BASE='fixture://rel' \
		bash -c "$(_agent_env); bash '$TMP/run_agent.sh' _awg_params_agent_install_binary"
	# Returns 1 (caller gates enablement on it) — not a die under set -e.
	[ "$status" -eq 1 ]
	[[ "$output" == *"MISMATCH"* ]]
	[ ! -e "$FBIN/oxpulse-awg-params-agent" ]
}

@test "bootstrap: mirror base uses the tag-pinned layout" {
	# OXPULSE_MIRROR_BASE contract (upgrade.sh): mirror serves
	# $MIRROR/<tag>/<asset> — the old flat $MIRROR/<asset> fetch is gone.
	_make_release v9.9.9 oxpulse-awg-params-agent-amd64 'PINNED-BINARY'
	mkdir -p "$FIXTURE/mirror"
	cp -a "$FIXTURE/rel/v9.9.9" "$FIXTURE/mirror/v9.9.9"

	run env PATH="$TMP/bin:$PATH" OXPULSE_RELEASE_TAG='v9.9.9' \
		OXPULSE_MIRROR_BASE='fixture://mirror' \
		bash -c "$(_agent_env); bash '$TMP/run_agent.sh' _awg_params_agent_install_binary"
	[ "$status" -eq 0 ]
	[ "$(cat "$FBIN/oxpulse-awg-params-agent")" = 'PINNED-BINARY' ]
	grep -q 'fixture://mirror/v9.9.9/oxpulse-awg-params-agent-amd64' "$FAKE_LOG"
}

@test "bootstrap: absent tag (dev checkout placeholder) → skip not die, unit not enabled" {
	# OXPULSE_RELEASE_TAG unset → the network fallback warns + returns 1;
	# awg_params_agent_run must still install unit+env but NOT enable a unit
	# whose ExecStart is missing.
	run env PATH="$TMP/bin:$PATH" \
		bash -c "$(_agent_env); unset OXPULSE_RELEASE_TAG; bash '$TMP/run_agent.sh' awg_params_agent_run"
	[ "$status" -eq 0 ]
	[[ "$output" == *"no pinned release tag"* ]]
	[[ "$output" == *"NOT enabled"* ]]
	[ -f "$FSYSTEMD/oxpulse-awg-params-agent.service" ]
	[ -f "$FETC/awg-params-agent.env" ]
	! grep -q 'systemctl enable' "$FAKE_LOG"
	[ ! -e "$FBIN/oxpulse-awg-params-agent" ]
}

@test "bootstrap: placeholder tag → same skip shape as unset" {
	run env PATH="$TMP/bin:$PATH" OXPULSE_RELEASE_TAG='@RELEASE_TAG@' \
		bash -c "$(_agent_env); bash '$TMP/run_agent.sh' _awg_params_agent_install_binary"
	[ "$status" -eq 1 ]
	[[ "$output" == *"no pinned release tag"* ]]
	! grep -q 'curl ' "$FAKE_LOG"
	[ ! -e "$FBIN/oxpulse-awg-params-agent" ]
}

@test "bootstrap: binary already present + tag missing → unit still enabled" {
	# Re-run on a node that already has the binary must not regress to
	# disabled just because this installer cannot fetch a verified update.
	printf 'EXISTING-BINARY' > "$FBIN/oxpulse-awg-params-agent"

	run env PATH="$TMP/bin:$PATH" \
		bash -c "$(_agent_env); unset OXPULSE_RELEASE_TAG; bash '$TMP/run_agent.sh' awg_params_agent_run"
	[ "$status" -eq 0 ]
	grep -q 'systemctl enable --now oxpulse-awg-params-agent.service' "$FAKE_LOG"
	[ "$(cat "$FBIN/oxpulse-awg-params-agent")" = 'EXISTING-BINARY' ]
}
