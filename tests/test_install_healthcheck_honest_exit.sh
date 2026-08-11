#!/usr/bin/env bats
# tests/test_install_healthcheck_honest_exit.sh
#
# F2: the installer must not claim success when core health checks are red.
# _healthcheck_poll must return non-zero on timeout (not 0), and
# _healthcheck_wait_turns_cert must return non-zero on cert-timeout.
# healthcheck_run must record the failure in a global so the banner and exit
# code can be honest without set -e killing the script before the summary.

setup() {
	REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	TMPDIR_LOCAL="$(mktemp -d)"
}

teardown() {
	rm -rf "$TMPDIR_LOCAL"
}

@test "_healthcheck_poll returns non-zero when healthcheck stays red" {
	# Build a fake healthcheck script that always fails (simulates red state).
	mkdir -p "$TMPDIR_LOCAL/sbin"
	local fake_hc="$TMPDIR_LOCAL/sbin/oxpulse-partner-edge-healthcheck"
	cat > "$fake_hc" <<'SCRIPT'
#!/usr/bin/env bash
exit 1
SCRIPT
	chmod +x "$fake_hc"

	run bash -c "
		source '$REPO_ROOT/lib/install-healthcheck.sh'
		DRY_RUN=0
		HEALTHCHECK_TIMEOUT=0
		PREFIX_SBIN='$TMPDIR_LOCAL/sbin'
		PREFIX_ETC='$TMPDIR_LOCAL/etc'
		src_dir=''
		REPO_RAW='http://127.0.0.1:1/does-not-exist'
		TURNS_SUBDOMAIN=api-test01
		DOMAIN=example.net
		log()  { echo \"log: \$*\"; }
		warn() { echo \"warn: \$*\"; }
		die()  { echo \"die: \$*\" >&2; exit 1; }

		_healthcheck_install_script() { :; }
		_healthcheck_wait_turns_cert() { :; }

		_healthcheck_poll
		echo \"rc=\$?\"
	"
	[ "$status" -eq 0 ]
	[[ "$output" == *"rc=1"* ]]
}

@test "_healthcheck_wait_turns_cert returns non-zero when cert never appears" {
	# Test the ACTUAL production function with TURNS_CERT_WAIT_TIMEOUT=0 so the
	# deadline expires immediately.  Cert dir does not exist → cert never
	# appears → must time out and return non-zero.
	run bash -c "
		source '$REPO_ROOT/lib/install-healthcheck.sh'
		DRY_RUN=0
		PREFIX_ETC='$TMPDIR_LOCAL/etc'
		TURNS_SUBDOMAIN=api-test01
		DOMAIN=example.net
		TURNS_CERT_WAIT_TIMEOUT=0
		log()  { echo \"log: \$*\"; }
		warn() { echo \"warn: \$*\"; }
		die()  { echo \"die: \$*\" >&2; exit 1; }
		docker() { echo 'docker should not be called'; exit 99; }

		_healthcheck_wait_turns_cert
		echo \"rc=\$?\"
	"
	[ "$status" -eq 0 ]
	[[ "$output" == *"rc=1"* ]]
}

@test "healthcheck_run sets HEALTHCHECK_CORE_FAILED=1 when poll times out" {
	mkdir -p "$TMPDIR_LOCAL/sbin"
	local fake_hc="$TMPDIR_LOCAL/sbin/oxpulse-partner-edge-healthcheck"
	cat > "$fake_hc" <<'SCRIPT'
#!/usr/bin/env bash
exit 1
SCRIPT
	chmod +x "$fake_hc"

	run bash -c "
		source '$REPO_ROOT/lib/install-healthcheck.sh'
		DRY_RUN=0
		HEALTHCHECK_TIMEOUT=0
		PREFIX_SBIN='$TMPDIR_LOCAL/sbin'
		PREFIX_ETC='$TMPDIR_LOCAL/etc'
		src_dir=''
		REPO_RAW='http://127.0.0.1:1/does-not-exist'
		TURNS_SUBDOMAIN=api-test01
		DOMAIN=example.net
		HEALTHCHECK_CORE_FAILED=0
		HEALTHCHECK_TURNS_CERT_FAILED=0
		log()  { echo \"log: \$*\"; }
		warn() { echo \"warn: \$*\"; }
		die()  { echo \"die: \$*\" >&2; exit 1; }

		_healthcheck_install_script() { :; }
		# Cert wait succeeds (cert present) — only the poll fails.
		_healthcheck_wait_turns_cert() { log '  TURNS cert ready'; }

		healthcheck_run
		echo \"CORE_FAILED=\$HEALTHCHECK_CORE_FAILED\"
		echo \"CERT_FAILED=\$HEALTHCHECK_TURNS_CERT_FAILED\"
	"
	[ "$status" -eq 0 ]
	[[ "$output" == *"CORE_FAILED=1"* ]]
	[[ "$output" == *"CERT_FAILED=0"* ]]
}

@test "healthcheck_run sets HEALTHCHECK_CORE_FAILED=0 when poll goes green" {
	mkdir -p "$TMPDIR_LOCAL/sbin"
	local fake_hc="$TMPDIR_LOCAL/sbin/oxpulse-partner-edge-healthcheck"
	cat > "$fake_hc" <<'SCRIPT'
#!/usr/bin/env bash
exit 0
SCRIPT
	chmod +x "$fake_hc"

	run bash -c "
		source '$REPO_ROOT/lib/install-healthcheck.sh'
		DRY_RUN=0
		HEALTHCHECK_TIMEOUT=30
		PREFIX_SBIN='$TMPDIR_LOCAL/sbin'
		PREFIX_ETC='$TMPDIR_LOCAL/etc'
		src_dir='$TMPDIR_LOCAL'
		REPO_RAW='http://127.0.0.1:1/does-not-exist'
		TURNS_SUBDOMAIN=api-test01
		DOMAIN=example.net
		HEALTHCHECK_CORE_FAILED=0
		HEALTHCHECK_TURNS_CERT_FAILED=0
		log()  { echo \"log: \$*\"; }
		warn() { echo \"warn: \$*\"; }
		die()  { echo \"die: \$*\" >&2; exit 1; }

		_healthcheck_install_script() {
			cp '$fake_hc' \"\$PREFIX_SBIN/oxpulse-partner-edge-healthcheck\"
		}
		_healthcheck_wait_turns_cert() { log '  TURNS cert ready'; }

		healthcheck_run
		echo \"CORE_FAILED=\$HEALTHCHECK_CORE_FAILED\"
	"
	[ "$status" -eq 0 ]
	[[ "$output" == *"healthcheck green"* ]]
	[[ "$output" == *"CORE_FAILED=0"* ]]
}

@test "healthcheck_run sets HEALTHCHECK_TURNS_CERT_FAILED=1 when cert wait times out" {
	mkdir -p "$TMPDIR_LOCAL/sbin"
	local fake_hc="$TMPDIR_LOCAL/sbin/oxpulse-partner-edge-healthcheck"
	cat > "$fake_hc" <<'SCRIPT'
#!/usr/bin/env bash
exit 0
SCRIPT
	chmod +x "$fake_hc"

	run bash -c "
		source '$REPO_ROOT/lib/install-healthcheck.sh'
		DRY_RUN=0
		HEALTHCHECK_TIMEOUT=30
		PREFIX_SBIN='$TMPDIR_LOCAL/sbin'
		PREFIX_ETC='$TMPDIR_LOCAL/etc'
		src_dir='$TMPDIR_LOCAL'
		REPO_RAW='http://127.0.0.1:1/does-not-exist'
		TURNS_SUBDOMAIN=api-test01
		DOMAIN=example.net
		HEALTHCHECK_CORE_FAILED=0
		HEALTHCHECK_TURNS_CERT_FAILED=0
		log()  { echo \"log: \$*\"; }
		warn() { echo \"warn: \$*\"; }
		die()  { echo \"die: \$*\" >&2; exit 1; }

		_healthcheck_install_script() {
			cp '$fake_hc' \"\$PREFIX_SBIN/oxpulse-partner-edge-healthcheck\"
		}
		# Cert wait fails — poll would still go green (fake hc returns 0).
		_healthcheck_wait_turns_cert() { warn '  TURNS cert not ready'; return 1; }

		healthcheck_run
		echo \"CORE_FAILED=\$HEALTHCHECK_CORE_FAILED\"
		echo \"CERT_FAILED=\$HEALTHCHECK_TURNS_CERT_FAILED\"
	"
	[ "$status" -eq 0 ]
	[[ "$output" == *"CERT_FAILED=1"* ]]
	[[ "$output" == *"CORE_FAILED=1"* ]]
}
