#!/usr/bin/env bats

setup() {
	REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	TMPMOD="$(mktemp -d)"
}

teardown() {
	rm -rf "$TMPMOD"
}

@test "runtime module sources cleanly" {
	run bash -c "source '$REPO_ROOT/lib/install-runtime.sh'; type runtime_run"
	[ "$status" -eq 0 ]
	[[ "$output" == *"runtime_run is a function"* ]]
}

@test "runtime_run dry-run skips mmdb download and docker compose" {
	run bash -c "
		source '$REPO_ROOT/lib/install-runtime.sh'
		DRY_RUN=1
		PREFIX_ETC=/tmp/p
		PREFIX_SBIN=/tmp/sbin
		PREFIX_LIB=/tmp/lib
		log()  { echo \"log: \$*\"; }
		warn() { echo \"warn: \$*\"; }
		die()  { echo \"die: \$*\" >&2; exit 1; }
		runtime_run
	"
	[ "$status" -eq 0 ]
	[[ "$output" == *"[dry-run] skipping DB-IP mmdb download"* ]]
	[[ "$output" == *"[dry-run] would: docker compose up -d"* ]]
}

@test "runtime_run writes install.env with required fields (non-dry)" {
	run bash -c "
		TMP='$TMPMOD'
		source '$REPO_ROOT/lib/install-runtime.sh'
		DRY_RUN=0
		# Stub mmdb refresh + docker so the test only exercises install.env write.
		export PATH=\"\$TMP/bin:/usr/bin:/bin\"
		mkdir -p \"\$TMP/bin\" \"\$TMP/sbin\" \"\$TMP/lib\" \"\$TMP/etc\"
		cat >\"\$TMP/bin/curl\" <<'EOF'
#!/usr/bin/env bash
# Fake curl — succeeds without actually downloading anything.
out=\"\"
while [[ \$# -gt 0 ]]; do
  case \"\$1\" in -o) out=\"\$2\"; shift 2;; *) shift;; esac
done
[[ -n \"\$out\" ]] && : > \"\$out\"
exit 0
EOF
		chmod +x \"\$TMP/bin/curl\"
		cat >\"\$TMP/bin/docker\" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
		chmod +x \"\$TMP/bin/docker\"
		cat >\"\$TMP/sbin/oxpulse-geoip-refresh\" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
		chmod +x \"\$TMP/sbin/oxpulse-geoip-refresh\"
		PREFIX_SBIN=\"\$TMP/sbin\"
		PREFIX_LIB=\"\$TMP/lib\"
		PREFIX_ETC=\"\$TMP/etc\"
		src_dir=\"\"
		REPO_RAW='https://example.invalid'
		PARTNER_ID='zvonilka'
		DOMAIN='zvonilka.net'
		NODE_ID='node-1'
		TUNNEL='reality'
		IMAGE_VERSION='stable'
		TURNS_SUBDOMAIN='api-test'
		_rendered_sha='abc123'
		log()  { :; }
		warn() { :; }
		die()  { echo die >&2; exit 1; }
		runtime_run
		cat \"\$TMP/lib/install.env\"
	"
	[ "$status" -eq 0 ]
	[[ "$output" == *"PARTNER_ID=zvonilka"* ]]
	[[ "$output" == *"NODE_ID=node-1"* ]]
	[[ "$output" == *"CADDYFILE_SHA=abc123"* ]]
}
