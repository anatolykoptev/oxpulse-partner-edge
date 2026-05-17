#!/usr/bin/env bats
# tests/test_install_args_module.sh — Phase 4.9
# Tests for lib/install-args.sh module: args_parse public API.

setup() {
	REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

# Helper: source the module with minimal stubs in a subshell and run args_parse,
# then print the resulting variable values so the test can inspect them.
_run_args_parse() {
	# $@ = args to pass to args_parse
	bash -c "
		set -euo pipefail
		# Minimal stubs required before sourcing the module
		die()  { echo \"die: \$*\" >&2; exit 1; }
		warn() { true; }
		log()  { true; }
		# Constants the module references
		PREFIX_ETC='\${PREFIX_ETC:-/etc/oxpulse-partner-edge}'
		PREFIX_LIB='\${PREFIX_LIB:-/var/lib/oxpulse-partner-edge}'
		BACKEND_API='\${BACKEND_API:-https://api.oxpulse.chat}'
		# Env vars module reads at assign time
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
		OXPULSE_NONINTERACTIVE=1

		source '${REPO_ROOT}/lib/install-args.sh'
		args_parse \$@
		# Dump interesting vars so bats can grep
		echo \"DRY_RUN=\$DRY_RUN\"
		echo \"CHECK_MODE=\$CHECK_MODE\"
		echo \"BAKE_MODE=\$BAKE_MODE\"
		echo \"FORCE_KEYGEN=\$FORCE_KEYGEN\"
		echo \"PARTNER_ID=\$PARTNER_ID\"
		echo \"DOMAIN=\$DOMAIN\"
		echo \"TOKEN=\$TOKEN\"
		echo \"TOKEN_FILE=\$TOKEN_FILE\"
		echo \"TUNNEL=\$TUNNEL\"
		echo \"REGION=\$REGION\"
		echo \"IMAGE_VERSION=\$IMAGE_VERSION\"
	" -- "$@"
}

@test "lib/install-args.sh sources cleanly and exports args_parse as a function" {
	run bash -c "
		die()  { echo \"die: \$*\" >&2; exit 1; }
		warn() { true; }
		log()  { true; }
		OXPULSE_PARTNER_TOKEN='' OXPULSE_IMAGE_VERSION='' TURNS_SUBDOMAIN='' \
		SFU_UDP_PORT='' SFU_METRICS_PORT='' SFU_EDGE_ID='' REGION='' \
		HEALTHCHECK_TIMEOUT='' BRANDING_CONFIG='' OXPULSE_GHCR_TOKEN=''
		PREFIX_ETC=/etc/oxpulse-partner-edge
		PREFIX_LIB=/var/lib/oxpulse-partner-edge
		BACKEND_API=https://api.oxpulse.chat
		source '${REPO_ROOT}/lib/install-args.sh'
		type args_parse
	"
	[ "$status" -eq 0 ]
	[[ "$output" == *"args_parse is a function"* ]]
}

@test "args_parse --dry-run --partner-id --domain --token sets expected globals" {
	run _run_args_parse --dry-run --partner-id=zvonilka --domain=zvonilka.net --token=abc
	[ "$status" -eq 0 ]
	[[ "$output" == *"DRY_RUN=1"* ]]
	[[ "$output" == *"PARTNER_ID=zvonilka"* ]]
	[[ "$output" == *"DOMAIN=zvonilka.net"* ]]
	[[ "$output" == *"TOKEN=abc"* ]]
}

@test "args_parse --check sets CHECK_MODE=1" {
	# --check mode ultimately exits with a drift exit code (1 or 2) because
	# there is no real installed Caddyfile in the test environment.
	# We verify CHECK_MODE=1 is set by inspecting the parsed globals BEFORE the
	# drift-check block runs. We do this by parsing args without the full
	# --check side-effects: source the module and invoke just the while-loop
	# portion via a patched version that prints CHECK_MODE then exits.
	run bash -c "
		set -euo pipefail
		die()  { echo \"die: \$*\" >&2; exit 1; }
		warn() { true; }
		log()  { true; }
		PREFIX_ETC=/tmp
		PREFIX_LIB=/tmp
		BACKEND_API='https://api.oxpulse.chat'
		REPO_RAW='https://raw.githubusercontent.com/anatolykoptev/oxpulse-partner-edge/main'
		OXPULSE_PARTNER_TOKEN='' OXPULSE_IMAGE_VERSION='' TURNS_SUBDOMAIN='' \
		SFU_UDP_PORT='' SFU_METRICS_PORT='' SFU_EDGE_ID='' REGION='' \
		HEALTHCHECK_TIMEOUT='' BRANDING_CONFIG='' OXPULSE_GHCR_TOKEN=''
		OXPULSE_NONINTERACTIVE=1

		source '${REPO_ROOT}/lib/install-args.sh'

		# Fake install.env so --check mode can source it
		_fake_dir=\$(mktemp -d)
		echo 'PARTNER_DOMAIN=zvonilka.net' > \"\$_fake_dir/install.env\"
		PREFIX_LIB=\"\$_fake_dir\"

		# Override exit so the drift check block doesn't terminate the subshell —
		# we only want to confirm CHECK_MODE is set correctly.
		exit() { echo \"CHECK_MODE=\$CHECK_MODE\"; builtin exit \"\${1:-0}\"; }
		args_parse --check || true
	"
	# Status may be non-zero (drift) — only check that CHECK_MODE was printed as 1
	[[ "$output" == *"CHECK_MODE=1"* ]]
}

@test "args_parse --token-file reads token from file" {
	run bash -c "
		set -euo pipefail
		die()  { echo \"die: \$*\" >&2; exit 1; }
		warn() { true; }
		log()  { true; }
		PREFIX_ETC=/etc/oxpulse-partner-edge
		PREFIX_LIB=/var/lib/oxpulse-partner-edge
		BACKEND_API=https://api.oxpulse.chat
		OXPULSE_PARTNER_TOKEN='' OXPULSE_IMAGE_VERSION='' TURNS_SUBDOMAIN='' \
		SFU_UDP_PORT='' SFU_METRICS_PORT='' SFU_EDGE_ID='' REGION='' \
		HEALTHCHECK_TIMEOUT='' BRANDING_CONFIG='' OXPULSE_GHCR_TOKEN=''
		OXPULSE_NONINTERACTIVE=1

		_tfile=\$(mktemp)
		echo 'ptkn_file_token_xyz' > \"\$_tfile\"
		source '${REPO_ROOT}/lib/install-args.sh'
		# --dry-run bypasses the root-required check so we can run as non-root
		args_parse --dry-run --partner-id=test --domain=test.net --token-file=\"\$_tfile\"
		rm -f \"\$_tfile\"
		echo \"TOKEN=\$TOKEN\"
	"
	[ "$status" -eq 0 ]
	[[ "$output" == *"TOKEN=ptkn_file_token_xyz"* ]]
}
