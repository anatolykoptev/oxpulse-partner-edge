#!/usr/bin/env bats
# tests/test_install_healthcheck_module.sh — Phase 4.6

setup() {
	REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	TMPDIR_LOCAL="$(mktemp -d)"
}

teardown() {
	rm -rf "$TMPDIR_LOCAL"
}

@test "healthcheck module sources cleanly" {
	run bash -c "source '$REPO_ROOT/lib/install-healthcheck.sh'; type healthcheck_run"
	[ "$status" -eq 0 ]
	[[ "$output" == *"healthcheck_run is a function"* ]]
}

@test "healthcheck_run dry-run skips cert wait and poll loop" {
	run bash -c "
		source '$REPO_ROOT/lib/install-healthcheck.sh'
		DRY_RUN=1
		HEALTHCHECK_TIMEOUT=300
		PREFIX_SBIN='$TMPDIR_LOCAL/sbin'
		PREFIX_ETC='$TMPDIR_LOCAL/etc'
		src_dir=''
		REPO_RAW='http://127.0.0.1:1/does-not-exist'
		TURNS_SUBDOMAIN=api-test01
		DOMAIN=example.net
		log()  { echo \"log: \$*\"; }
		warn() { echo \"warn: \$*\"; }
		die()  { echo \"die: \$*\" >&2; exit 1; }
		# Poison docker/curl to catch accidental real calls
		docker() { echo 'docker called in dry-run' >&2; exit 99; }
		curl()   { echo 'curl called in dry-run' >&2; exit 99; }
		healthcheck_run
	"
	[ "$status" -eq 0 ]
	[[ "$output" == *"[dry-run] skipping healthcheck"* ]]
	[[ "$output" != *"docker called in dry-run"* ]]
	[[ "$output" != *"curl called in dry-run"* ]]
}

@test "healthcheck_run real-run with mocked healthcheck script returns green" {
	# Build a fake healthcheck script that always succeeds
	mkdir -p "$TMPDIR_LOCAL/sbin"
	local fake_hc="$TMPDIR_LOCAL/fake-healthcheck.sh"
	cat > "$fake_hc" <<'SCRIPT'
#!/usr/bin/env bash
exit 0
SCRIPT
	chmod +x "$fake_hc"

	# Build a fake turns cert so cert-wait loop exits immediately
	local cert_dir="$TMPDIR_LOCAL/turns-cert"
	mkdir -p "$cert_dir"
	touch "$cert_dir/api-test01.example.net.crt"

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
		log()  { echo \"log: \$*\"; }
		warn() { echo \"warn: \$*\"; }
		die()  { echo \"die: \$*\" >&2; exit 1; }

		# Override _healthcheck_install_script to place our fake script
		_healthcheck_install_script() {
			cp '$fake_hc' \"\$PREFIX_SBIN/oxpulse-partner-edge-healthcheck\"
		}

		# Override _healthcheck_wait_turns_cert to skip the real cert poll
		# (simulates cert already present)
		_healthcheck_wait_turns_cert() {
			log '  TURNS cert ready → restarting coturn to enable :5349 TLS listener'
			# no docker compose restart needed in test
		}

		healthcheck_run
	"
	[ "$status" -eq 0 ]
	[[ "$output" == *"healthcheck green"* ]]
}
