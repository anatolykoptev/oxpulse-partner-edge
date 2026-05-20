#!/usr/bin/env bats
# tests/test_install_serve_countries.sh — Federation Phase 1 follow-up
#
# Verifies that lib/install-args.sh correctly parses --serve-countries
# and that install.sh jq pipeline converts CSV to a well-formed JSON array.

setup() {
	REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

_parse_sc() {
	local root="$REPO_ROOT"
	bash -s "$root" "$@" <<'SH'
		set -euo pipefail
		REPO_ROOT="$1"; shift
		die()  { echo "die: $*" >&2; exit 1; }
		warn() { true; }
		log()  { true; }
		PREFIX_ETC="/etc/oxpulse-partner-edge"
		PREFIX_LIB="/var/lib/oxpulse-partner-edge"
		BACKEND_API="https://api.oxpulse.chat"
		OXPULSE_PARTNER_TOKEN=""
		OXPULSE_IMAGE_VERSION=""
		TURNS_SUBDOMAIN=""
		SFU_UDP_PORT=""
		SFU_METRICS_PORT=""
		SFU_EDGE_ID=""
		REGION=""
		HEALTHCHECK_TIMEOUT=""
		BRANDING_CONFIG=""
		OXPULSE_GHCR_TOKEN=""
		SERVE_COUNTRIES=""
		OXPULSE_NONINTERACTIVE=1
		source "$REPO_ROOT/lib/install-args.sh"
		args_parse "$@"
		echo "SERVE_COUNTRIES=$SERVE_COUNTRIES"
SH
}

_jq_pipeline() {
	printf '%s' "$1" | jq -R '[split(",")[] | gsub("^\\s+|\\s+$";"")]' | jq -c .
}

@test "--serve-countries=RU,BY stored in SERVE_COUNTRIES" {
	run _parse_sc --dry-run --partner-id=tp --domain=tp.example.com --token=ptkn_t --serve-countries=RU,BY
	[ "$status" -eq 0 ]
	[[ "$output" == *"SERVE_COUNTRIES=RU,BY"* ]]
}

@test "--serve-countries=RU stored in SERVE_COUNTRIES" {
	run _parse_sc --dry-run --partner-id=tp --domain=tp.example.com --token=ptkn_t --serve-countries=RU
	[ "$status" -eq 0 ]
	[[ "$output" == *"SERVE_COUNTRIES=RU"* ]]
}

@test "SERVE_COUNTRIES empty by default" {
	run _parse_sc --dry-run --partner-id=tp --domain=tp.example.com --token=ptkn_t
	[ "$status" -eq 0 ]
	echo "$output" | grep -qE "SERVE_COUNTRIES=$"
}

@test "jq pipeline: RU,BY produces correct JSON" {
	run _jq_pipeline "RU,BY"
	[ "$status" -eq 0 ]
	[ "$output" = '["RU","BY"]' ]
}

@test "jq pipeline: single RU produces correct JSON" {
	run _jq_pipeline "RU"
	[ "$status" -eq 0 ]
	[ "$output" = '["RU"]' ]
}

@test "jq pipeline trims whitespace in RU, BY" {
	run _jq_pipeline "RU, BY"
	[ "$status" -eq 0 ]
	[ "$output" = '["RU","BY"]' ]
}

@test "jq pipeline trims leading and trailing whitespace" {
	run _jq_pipeline " RU , BY "
	[ "$status" -eq 0 ]
	[ "$output" = '["RU","BY"]' ]
}
