#!/usr/bin/env bats
# tests/test_install_healthcheck_slowstart_hint.sh
# Asserts that the healthcheck timeout warn includes a slow-start hint for operators.

setup() {
	REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	TMPDIR_LOCAL="$(mktemp -d)"
}

teardown() {
	rm -rf "$TMPDIR_LOCAL"
}

@test "healthcheck timeout warn includes SFU slow-start hint" {
	# Build a fake healthcheck script that always fails (simulates red state)
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

		# Skip install and cert-wait — test only the poll timeout path
		_healthcheck_install_script() { :; }
		_healthcheck_wait_turns_cert() { :; }

		_healthcheck_poll
	"
	[ "$status" -eq 0 ]
	# Must mention slow-start of SFU containers
	[[ "$output" == *"30-60s"* ]] || [[ "$output" == *"slow"* ]]
	# Must suggest re-checking with the healthcheck binary
	[[ "$output" == *"oxpulse-partner-edge-healthcheck"* ]]
	# Must hint at a longer timeout
	[[ "$output" == *"--healthcheck-timeout"* ]]
}
