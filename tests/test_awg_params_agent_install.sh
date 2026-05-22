#!/usr/bin/env bats
# tests/test_awg_params_agent_install.sh — bats coverage for lib/install-awg-params-agent.sh
#
# Verifies:
#   1. awg_params_agent_run dry-run — skips all side-effecting calls
#   2. Binary copied to /usr/local/bin/oxpulse-awg-params-agent
#   3. Systemd unit file installed to SYSTEMD_DIR
#   4. Env file rendered with all required vars
#   5. State directory created
#   6. BAKE_MODE: enable-only, not enable --now

setup() {
	REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	TMP="$(mktemp -d)"
	FAKE_LOG="$TMP/calls.log"
	touch "$FAKE_LOG"

	# Fake binary dir for install/chmod/systemctl/curl stubs
	mkdir -p "$TMP/bin"

	cat > "$TMP/bin/install" << 'STUB'
#!/usr/bin/env bash
echo "install $*" >> "$FAKE_LOG"
# copy src→dst so downstream reads succeed
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

	cat > "$TMP/bin/systemctl" << 'STUB'
#!/usr/bin/env bash
echo "systemctl $*" >> "$FAKE_LOG"
exit 0
STUB
	chmod +x "$TMP/bin/systemctl"

	cat > "$TMP/bin/curl" << 'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "$FAKE_LOG"
# extract -o <dest> and touch it
while [[ $# -gt 0 ]]; do
    if [[ "$1" == "-o" ]]; then touch "$2" 2>/dev/null || true; shift 2; else shift; fi
done
exit 0
STUB
	chmod +x "$TMP/bin/curl"

	cat > "$TMP/bin/uname" << 'STUB'
#!/usr/bin/env bash
echo "x86_64"
STUB
	chmod +x "$TMP/bin/uname"

	# Set up fake checkout
	CHECKOUT="$TMP/checkout"
	mkdir -p "$CHECKOUT/systemd"
	printf '[Unit]\nDescription=fake awg-params-agent\n' \
		> "$CHECKOUT/systemd/oxpulse-awg-params-agent.service"
	# Put a fake binary alongside the lib (bundled binary path)
	echo "fake-binary" > "$CHECKOUT/oxpulse-awg-params-agent-amd64"
	chmod +x "$CHECKOUT/oxpulse-awg-params-agent-amd64"

	# Destination dirs
	DEST_SYSTEMD="$TMP/systemd"
	DEST_BIN="$TMP/usr-local-bin"
	DEST_ETC="$TMP/etc"
	DEST_LIB="$TMP/lib"
	mkdir -p "$DEST_SYSTEMD" "$DEST_BIN" "$DEST_ETC" "$DEST_LIB"
}

teardown() {
	rm -rf "$TMP"
}

# Minimal env shared by tests
_common_env() {
	cat <<ENVEOF
DRY_RUN=0
BAKE_MODE=0
src_dir='$CHECKOUT'
REPO_RAW='http://127.0.0.1:1/does-not-exist'
SYSTEMD_DIR='$DEST_SYSTEMD'
PREFIX_ETC='$DEST_ETC'
PREFIX_LIB='$DEST_LIB'
BACKEND_API='https://api.oxpulse.chat'
NODE_ID='test-node-01'
log()  { echo "log: \$*"; }
warn() { echo "warn: \$*"; }
die()  { echo "die: \$*" >&2; exit 1; }
ENVEOF
}

@test "module sources cleanly" {
	run bash -c "source '$REPO_ROOT/lib/install-awg-params-agent.sh'; type awg_params_agent_run"
	[ "$status" -eq 0 ]
	[[ "$output" == *"awg_params_agent_run is a function"* ]]
}

@test "dry-run skips all side-effecting calls" {
	run bash -c "
		$(_common_env)
		DRY_RUN=1
		source '$REPO_ROOT/lib/install-awg-params-agent.sh'
		install()   { echo 'install called in dry-run' >&2; exit 99; }
		curl()      { echo 'curl called in dry-run' >&2; exit 99; }
		systemctl() { echo 'systemctl called in dry-run' >&2; exit 99; }
		awg_params_agent_run
	"
	[ "$status" -eq 0 ]
	[[ "$output" == *"[dry-run] skipping awg-params-agent install"* ]]
	[[ "$output" != *"install called in dry-run"* ]]
	[[ "$output" != *"systemctl called in dry-run"* ]]
}

@test "binary copied to destination on full install" {
	run env FAKE_LOG="$FAKE_LOG" PATH="$TMP/bin:$PATH" bash -c "
		$(_common_env)
		source '$REPO_ROOT/lib/install-awg-params-agent.sh'
		# Override dest AFTER source so module constant is replaced with writable path
		_AWG_PARAMS_AGENT_BIN='$DEST_BIN/oxpulse-awg-params-agent'
		_awg_params_agent_install_binary
	"
	[ "$status" -eq 0 ]
	# install must have been called
	grep -q '^install ' "$FAKE_LOG"
}

@test "systemd unit file installed from src_dir" {
	run env FAKE_LOG="$FAKE_LOG" PATH="$TMP/bin:$PATH" bash -c "
		$(_common_env)
		source '$REPO_ROOT/lib/install-awg-params-agent.sh'
		_awg_params_agent_install_unit
	"
	[ "$status" -eq 0 ]
	[ -f "$DEST_SYSTEMD/oxpulse-awg-params-agent.service" ]
}

@test "env file rendered with required vars" {
	run bash -c "
		$(_common_env)
		source '$REPO_ROOT/lib/install-awg-params-agent.sh'
		_awg_params_agent_render_env
	"
	[ "$status" -eq 0 ]
	[ -f "$DEST_ETC/awg-params-agent.env" ]
	grep -q 'OXPULSE_CENTRAL_URL=https://api.oxpulse.chat' "$DEST_ETC/awg-params-agent.env"
	grep -q 'OXPULSE_NODE_ID=test-node-01'                 "$DEST_ETC/awg-params-agent.env"
	grep -q 'OXPULSE_SERVICE_TOKEN_PATH='                  "$DEST_ETC/awg-params-agent.env"
	grep -q 'OXPULSE_AWG_CONF_PATH='                       "$DEST_ETC/awg-params-agent.env"
	grep -q 'OXPULSE_AWG_IFACE=awg0'                       "$DEST_ETC/awg-params-agent.env"
	grep -q 'OXPULSE_STATE_PATH='                          "$DEST_ETC/awg-params-agent.env"
	grep -q 'OXPULSE_POLL_INTERVAL=30s'                    "$DEST_ETC/awg-params-agent.env"
}

@test "state directory created (idempotent)" {
	local extra_lib="$TMP/extra-lib"
	run env PATH="$TMP/bin:$PATH" bash -c "
		$(_common_env)
		PREFIX_LIB='$extra_lib'
		source '$REPO_ROOT/lib/install-awg-params-agent.sh'
		_awg_params_agent_state_dir
		_awg_params_agent_state_dir  # second call must not fail
	"
	[ "$status" -eq 0 ]
	[ -d "$extra_lib" ]
}

@test "bake mode: enable without --now" {
	run env FAKE_LOG="$FAKE_LOG" PATH="$TMP/bin:$PATH" bash -c "
		$(_common_env)
		BAKE_MODE=1
		source '$REPO_ROOT/lib/install-awg-params-agent.sh'
		_awg_params_agent_enable
	"
	[ "$status" -eq 0 ]
	grep -q 'systemctl daemon-reload' "$FAKE_LOG"
	grep -q 'systemctl enable oxpulse-awg-params-agent.service' "$FAKE_LOG"
	# must NOT have enable --now
	! grep -q 'systemctl enable --now' "$FAKE_LOG"
}

@test "full install mode: enable --now" {
	run env FAKE_LOG="$FAKE_LOG" PATH="$TMP/bin:$PATH" bash -c "
		$(_common_env)
		BAKE_MODE=0
		source '$REPO_ROOT/lib/install-awg-params-agent.sh'
		_awg_params_agent_enable
	"
	[ "$status" -eq 0 ]
	grep -q 'systemctl enable --now oxpulse-awg-params-agent.service' "$FAKE_LOG"
}

@test "awg_params_agent_run full install orchestrates all steps" {
	run env FAKE_LOG="$FAKE_LOG" PATH="$TMP/bin:$PATH" bash -c "
		$(_common_env)
		_AWG_PARAMS_AGENT_BIN='$DEST_BIN/oxpulse-awg-params-agent'
		source '$REPO_ROOT/lib/install-awg-params-agent.sh'
		# smoke check uses sleep + systemctl; stub systemctl returns 0 = active
		sleep() { :; }
		awg_params_agent_run
	"
	[ "$status" -eq 0 ]
	# unit file present
	[ -f "$DEST_SYSTEMD/oxpulse-awg-params-agent.service" ]
	# env file present with node ID
	[ -f "$DEST_ETC/awg-params-agent.env" ]
	grep -q 'OXPULSE_NODE_ID=test-node-01' "$DEST_ETC/awg-params-agent.env"
	# state dir present
	[ -d "$DEST_LIB" ]
	# systemctl enable --now called
	grep -q 'systemctl enable --now oxpulse-awg-params-agent.service' "$FAKE_LOG"
}

@test "BAKE_MODE=1 with unset NODE_ID: awg_params_agent_run must not crash" {
	# Regression guard for BLOCKER 1: awg_params_agent_run was called outside
	# the BAKE_MODE=0 gate; _awg_params_agent_render_env expanded unset NODE_ID
	# under set -euo pipefail, crashing the installer.
	# After fix (Option A): awg_params_agent_run is inside BAKE_MODE=0 block,
	# so this test exercises the function directly with DRY_RUN=1 to verify
	# it doesn't touch NODE_ID on the dry path.
	run bash -c "
		DRY_RUN=1
		BAKE_MODE=1
		src_dir=''
		REPO_RAW='http://127.0.0.1:1/does-not-exist'
		SYSTEMD_DIR='/tmp'
		PREFIX_ETC='/tmp'
		PREFIX_LIB='/tmp'
		BACKEND_API='https://api.oxpulse.chat'
		log()  { echo \"log: \$*\"; }
		warn() { echo \"warn: \$*\"; }
		die()  { echo \"die: \$*\" >&2; exit 1; }
		set -euo pipefail
		unset NODE_ID
		source \"$REPO_ROOT/lib/install-awg-params-agent.sh\"
		awg_params_agent_run
	"
	[ "$status" -eq 0 ]
	[[ "$output" == *"[dry-run] skipping"* ]]
}

@test "bundled-binary detection uses INSTALL_SH_DIR not BASH_SOURCE[1]" {
	# Regression guard for MAJOR 1: BASH_SOURCE[1] inside a sourced lib
	# resolves to the lib file, not install.sh. INSTALL_SH_DIR is now exported
	# by install.sh and used as the canonical lookup path.
	local fake_install_dir
	fake_install_dir="$(mktemp -d)"
	# Simulate tarball flat layout: binary alongside install.sh
	touch "${fake_install_dir}/oxpulse-awg-params-agent-amd64"
	chmod +x "${fake_install_dir}/oxpulse-awg-params-agent-amd64"

	run env FAKE_LOG="$FAKE_LOG" PATH="$TMP/bin:$PATH" bash -c "
		DRY_RUN=0
		BAKE_MODE=0
		src_dir=''
		INSTALL_SH_DIR='${fake_install_dir}'
		REPO_RAW='http://127.0.0.1:1/does-not-exist'
		SYSTEMD_DIR='$DEST_SYSTEMD'
		PREFIX_ETC='$DEST_ETC'
		PREFIX_LIB='$DEST_LIB'
		BACKEND_API='https://api.oxpulse.chat'
		NODE_ID='test-node-01'
		log()  { echo \"log: \$*\"; }
		warn() { echo \"warn: \$*\" >&2; }
		die()  { echo \"die: \$*\" >&2; exit 1; }
		_AWG_PARAMS_AGENT_BIN='$DEST_BIN/oxpulse-awg-params-agent'
		source \"$REPO_ROOT/lib/install-awg-params-agent.sh\"
		_awg_params_agent_install_binary
	"
	[ "$status" -eq 0 ]
	# Must have used the bundled path (install called), NOT curl
	grep -q '^install ' "$FAKE_LOG"
	! grep -q '^curl ' "$FAKE_LOG"

	rm -rf "$fake_install_dir"
}
