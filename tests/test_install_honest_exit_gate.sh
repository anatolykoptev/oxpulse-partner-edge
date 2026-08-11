#!/usr/bin/env bats
# tests/test_install_honest_exit_gate.sh
#
# F2: exercise the REAL exit-gate blocks extracted from install.sh — both the
# top-up path (existing-install guard) and the fresh-install gate.  The
# lib-level building blocks are covered by test_install_healthcheck_honest_exit.sh;
# this file proves the gates themselves exist in install.sh and honour
# ALLOW_DEGRADED on both exit paths.
#
# The extraction uses the same awk pattern as test_awg_params_agent_install.sh
# (WS4 guard tests) — track `; then`/`fi` depth to capture exactly the block.

setup() {
	REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	TMP="$(mktemp -d)"
}

teardown() {
	rm -rf "$TMP"
}

# Extract the existing-install guard block (outer if…fi) from install.sh.
# Same awk pattern as test_awg_params_agent_install.sh WS4 tests.
_extract_topup_guard() {
	awk '
		/if \[\[ -f "\$PREFIX_LIB\/install\.env" && -z "\$MANUAL_CONFIG" \]\]; then/ { cap=1 }
		cap {
			print
			if ($0 ~ /; then[[:space:]]*$/) depth++
			if ($0 ~ /^[[:space:]]*fi[[:space:]]*$/) { depth--; if (depth==0) exit }
		}
	' "$REPO_ROOT/install.sh" > "$TMP/guard.sh"
}

# Extract the fresh-install honest-exit gate (the `if [[ HEALTHCHECK_CORE_FAILED
# … && ALLOW_DEGRADED … ]]; then exit 1; fi` block) from install.sh.
_extract_fresh_gate() {
	awk '
		/^# F2: honest exit code/ { cap=1 }
		cap {
			print
			if ($0 ~ /^[[:space:]]*fi[[:space:]]*$/) exit
		}
	' "$REPO_ROOT/install.sh" > "$TMP/gate.sh"
}

# Shared env for the top-up guard tests.  $1 = healthcheck exit code,
# $2 = ALLOW_DEGRADED value.  Writes a fake healthcheck and install.env.
_topup_setup() {
	local hc_rc="$1"
	local allow_degraded="$2"

	# install.env with a prior NODE_ID so the guard enters the top-up branch.
	mkdir -p "$TMP/lib"
	cat > "$TMP/lib/install.env" <<EOF
NODE_ID=stale-node-42
BACKEND_API=https://api.oxpulse.chat
EOF

	# Fake healthcheck binary.
	mkdir -p "$TMP/sbin"
	cat > "$TMP/sbin/oxpulse-partner-edge-healthcheck" <<SCRIPT
#!/usr/bin/env bash
exit $hc_rc
SCRIPT
	chmod +x "$TMP/sbin/oxpulse-partner-edge-healthcheck"

	# Stub awg_params_agent_run so we don't need the full install machinery.
	cat > "$TMP/awg-stub.sh" <<'STUB'
awg_params_agent_run() { :; }
STUB
}

# ---------------------------------------------------------------------------
# Top-up path (F1): existing-install guard
# ---------------------------------------------------------------------------

@test "top-up path: failing healthcheck + ALLOW_DEGRADED=0 → exit 1" {
	_topup_setup 1 0
	_extract_topup_guard
	[ -s "$TMP/guard.sh" ]
	# Couple test to real code: the guard must call the healthcheck.
	grep -q 'oxpulse-partner-edge-healthcheck' "$TMP/guard.sh"

	run bash -c "
		set -euo pipefail
		DRY_RUN=0
		BAKE_MODE=0
		MANUAL_CONFIG=''
		PREFIX_LIB='$TMP/lib'
		PREFIX_SBIN='$TMP/sbin'
		PREFIX_ETC='$TMP/etc'
		ALLOW_DEGRADED=0
		log()  { :; }
		warn() { :; }
		die()  { echo \"die: \$*\" >&2; exit 1; }
		source '$TMP/awg-stub.sh'
		source '$TMP/guard.sh'
		echo 'GUARD_DID_NOT_EXIT'
	"
	[ "$status" -eq 1 ]
	[[ "$output" != *"GUARD_DID_NOT_EXIT"* ]]
}

@test "top-up path: failing healthcheck + ALLOW_DEGRADED=1 → exit 0" {
	_topup_setup 1 1
	_extract_topup_guard
	[ -s "$TMP/guard.sh" ]

	run bash -c "
		set -euo pipefail
		DRY_RUN=0
		BAKE_MODE=0
		MANUAL_CONFIG=''
		PREFIX_LIB='$TMP/lib'
		PREFIX_SBIN='$TMP/sbin'
		PREFIX_ETC='$TMP/etc'
		ALLOW_DEGRADED=1
		log()  { :; }
		warn() { :; }
		die()  { echo \"die: \$*\" >&2; exit 1; }
		source '$TMP/awg-stub.sh'
		source '$TMP/guard.sh'
		echo 'GUARD_DID_NOT_EXIT'
	"
	[ "$status" -eq 0 ]
	[[ "$output" != *"GUARD_DID_NOT_EXIT"* ]]
}

@test "top-up path: passing healthcheck + ALLOW_DEGRADED=0 → exit 0" {
	_topup_setup 0 0
	_extract_topup_guard
	[ -s "$TMP/guard.sh" ]

	run bash -c "
		set -euo pipefail
		DRY_RUN=0
		BAKE_MODE=0
		MANUAL_CONFIG=''
		PREFIX_LIB='$TMP/lib'
		PREFIX_SBIN='$TMP/sbin'
		PREFIX_ETC='$TMP/etc'
		ALLOW_DEGRADED=0
		log()  { :; }
		warn() { :; }
		die()  { echo \"die: \$*\" >&2; exit 1; }
		source '$TMP/awg-stub.sh'
		source '$TMP/guard.sh'
		echo 'GUARD_DID_NOT_EXIT'
	"
	[ "$status" -eq 0 ]
	[[ "$output" != *"GUARD_DID_NOT_EXIT"* ]]
}

# ---------------------------------------------------------------------------
# Fresh-install gate (install.sh:1804-1806)
# ---------------------------------------------------------------------------

@test "fresh-install gate: HEALTHCHECK_CORE_FAILED=1 + ALLOW_DEGRADED=0 → exit 1" {
	_extract_fresh_gate
	[ -s "$TMP/gate.sh" ]
	# Couple test to real code: the gate must check both variables.
	grep -q 'HEALTHCHECK_CORE_FAILED' "$TMP/gate.sh"
	grep -q 'ALLOW_DEGRADED' "$TMP/gate.sh"

	run bash -c "
		set -euo pipefail
		HEALTHCHECK_CORE_FAILED=1
		ALLOW_DEGRADED=0
		source '$TMP/gate.sh'
		echo 'GATE_DID_NOT_EXIT'
	"
	[ "$status" -eq 1 ]
	[[ "$output" != *"GATE_DID_NOT_EXIT"* ]]
}

@test "fresh-install gate: HEALTHCHECK_CORE_FAILED=1 + ALLOW_DEGRADED=1 → exit 0" {
	_extract_fresh_gate
	[ -s "$TMP/gate.sh" ]

	run bash -c "
		set -euo pipefail
		HEALTHCHECK_CORE_FAILED=1
		ALLOW_DEGRADED=1
		source '$TMP/gate.sh'
		echo 'GATE_DID_NOT_EXIT'
	"
	[ "$status" -eq 0 ]
	[[ "$output" == *"GATE_DID_NOT_EXIT"* ]]
}

@test "fresh-install gate: HEALTHCHECK_CORE_FAILED=0 + ALLOW_DEGRADED=0 → exit 0" {
	_extract_fresh_gate
	[ -s "$TMP/gate.sh" ]

	run bash -c "
		set -euo pipefail
		HEALTHCHECK_CORE_FAILED=0
		ALLOW_DEGRADED=0
		source '$TMP/gate.sh'
		echo 'GATE_DID_NOT_EXIT'
	"
	[ "$status" -eq 0 ]
	[[ "$output" == *"GATE_DID_NOT_EXIT"* ]]
}
