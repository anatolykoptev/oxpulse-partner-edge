#!/usr/bin/env bats
# tests/test_install_profile_russia.sh — CL-4: --profile=russia wiring tests
#
# Covers:
#   1. args_parse accepts --profile=russia (= form)
#   2. args_parse accepts --profile russia (space form)
#   3. args_parse --profile foo dies with an error
#   4. args_parse with no --profile sets PROFILE empty
#   5. install.sh calls split_routing_run ONLY when PROFILE=russia
#   6. install.sh does NOT call split_routing_run when no --profile
#   7. install.sh sources install-split-routing.sh in the lib-source block
#   8. install-args.sh usage text mentions --profile
#
# TDD ref: CL-4 deliverable (feat/split-routing-install-wiring)
# Plan ref: ~/deploy/krolik-server/plans/oxpulse-partner-edge/2026-05-09-russia-profile-installer.md

setup() {
	REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

# Helper: source install-args.sh with minimal stubs and run args_parse; dump PROFILE.
_run_args_parse_profile() {
	bash -c "
		set -euo pipefail
		die()  { echo \"die: \$*\" >&2; exit 1; }
		warn() { true; }
		log()  { true; }
		PREFIX_ETC='/etc/oxpulse-partner-edge'
		PREFIX_LIB='/var/lib/oxpulse-partner-edge'
		BACKEND_API='https://api.oxpulse.chat'
		OXPULSE_PARTNER_TOKEN=''
		OXPULSE_IMAGE_VERSION=''
		TURNS_SUBDOMAIN=''
		SFU_UDP_PORT=''
		SFU_METRICS_PORT=''
		SFU_EDGE_ID=''
		REGION=''
		HEALTHCHECK_TIMEOUT=''
		BRANDING_CONFIG=''
		OXPULSE_GHCR_TOKEN=''
		PROFILE=''
		OXPULSE_NONINTERACTIVE=1

		source '${REPO_ROOT}/lib/install-args.sh'
		args_parse \$@
		echo \"PROFILE=\$PROFILE\"
	" -- "$@"
}

# ─── 1. --profile=russia (= form) sets PROFILE ───────────────────────────────

@test "args_parse --profile=russia sets PROFILE=russia" {
	run _run_args_parse_profile --dry-run --partner-id=test --domain=test.net --token=abc --profile=russia
	[ "$status" -eq 0 ]
	[[ "$output" == *"PROFILE=russia"* ]]
}

# ─── 2. --profile russia (space form) sets PROFILE ───────────────────────────

@test "args_parse --profile russia (space form) sets PROFILE=russia" {
	run _run_args_parse_profile --dry-run --partner-id=test --domain=test.net --token=abc --profile russia
	[ "$status" -eq 0 ]
	[[ "$output" == *"PROFILE=russia"* ]]
}

# ─── 3. Unknown profile dies ─────────────────────────────────────────────────

@test "args_parse --profile foo dies with error" {
	run _run_args_parse_profile --dry-run --partner-id=test --domain=test.net --token=abc --profile=foo
	[ "$status" -ne 0 ]
	[[ "$output" == *"profile"* ]]
}

# ─── 4. No --profile leaves PROFILE empty ────────────────────────────────────

@test "args_parse with no --profile leaves PROFILE empty" {
	run _run_args_parse_profile --dry-run --partner-id=test --domain=test.net --token=abc
	[ "$status" -eq 0 ]
	[[ "$output" == *"PROFILE="* ]]
	# Must not be PROFILE=russia
	run grep -q "PROFILE=russia" <<< "$output"
	[ "$status" -ne 0 ]
}

# ─── 5. install.sh calls split_routing_run when PROFILE=russia ───────────────
# Strategy: extract the gating block from install.sh via grep, stub split_routing_run,
# set PROFILE=russia, evaluate, verify the stub was called.
# grep -A4 pulls exactly: if [[ ... ]]; then  /  log  /  split_routing_run  /  fi

@test "install.sh calls split_routing_run when PROFILE=russia" {
	run bash -c "
		set -euo pipefail
		CALLED=0
		log() { true; }
		split_routing_run() { CALLED=1; echo 'split_routing_run called'; }
		PROFILE=russia

		# Extract the russia profile gating block from install.sh
		_gate=\$(grep -A4 'PROFILE:-}' '${REPO_ROOT}/install.sh')
		eval \"\$_gate\"
		[ \"\$CALLED\" -eq 1 ]
	"
	[ "$status" -eq 0 ]
	[[ "$output" == *"split_routing_run called"* ]]
}

# ─── 6. install.sh does NOT call split_routing_run when PROFILE is empty ─────

@test "install.sh does NOT call split_routing_run when PROFILE is empty" {
	run bash -c "
		set -euo pipefail
		CALLED=0
		log() { true; }
		split_routing_run() { CALLED=1; echo 'split_routing_run called'; }
		PROFILE=

		_gate=\$(grep -A4 'PROFILE:-}' '${REPO_ROOT}/install.sh')
		eval \"\$_gate\"
		[ \"\$CALLED\" -eq 0 ]
	"
	[ "$status" -eq 0 ]
	[[ "$output" != *"split_routing_run called"* ]]
}

# ─── 7. install.sh sources install-split-routing.sh via _install_lib_source ──

@test "install.sh has _install_lib_source install-split-routing.sh" {
	run grep -q '_install_lib_source install-split-routing.sh' "${REPO_ROOT}/install.sh"
	[ "$status" -eq 0 ]
}

# ─── 8. install-args.sh usage text mentions --profile ────────────────────────

@test "_args_usage includes --profile in usage text" {
	run bash -c "
		die()  { echo \"die: \$*\" >&2; exit 1; }
		warn() { true; }
		log()  { true; }
		PREFIX_ETC='/etc/oxpulse-partner-edge'
		PREFIX_LIB='/var/lib/oxpulse-partner-edge'
		BACKEND_API='https://api.oxpulse.chat'
		source '${REPO_ROOT}/lib/install-args.sh'
		_args_usage 2>&1 || true
	"
	[[ "$output" == *"--profile"* ]]
}
