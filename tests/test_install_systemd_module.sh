#!/usr/bin/env bats
# tests/test_install_systemd_module.sh — Phase 4.7

setup() {
	REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	TMPDIR_LOCAL="$(mktemp -d)"

	# PATH shim: fake install/curl/systemctl/chmod that log invocations
	mkdir -p "$TMPDIR_LOCAL/bin"
	cat > "$TMPDIR_LOCAL/bin/install" <<'STUB'
#!/usr/bin/env bash
echo "install $*" >> "$FAKE_LOG"
# copy src→dest so downstream code can open the file if needed
if [[ "$1" == "-m" ]]; then
	shift 2  # skip mode and mode-value
fi
# last arg is dest, second-to-last is src
n=$#; i=0; args=("$@")
src="${args[$((n-2))]}"
dst="${args[$((n-1))]}"
[[ -f "$src" ]] && cp "$src" "$dst" 2>/dev/null || touch "$dst" 2>/dev/null || true
exit 0
STUB
	chmod +x "$TMPDIR_LOCAL/bin/install"

	cat > "$TMPDIR_LOCAL/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "$FAKE_LOG"
# extract -o dest and touch it so install.sh doesn't die on missing file
dst=""
while [[ $# -gt 0 ]]; do
	if [[ "$1" == "-o" ]]; then dst="$2"; shift 2; else shift; fi
done
[[ -n "$dst" ]] && touch "$dst" || true
exit 0
STUB
	chmod +x "$TMPDIR_LOCAL/bin/curl"

	cat > "$TMPDIR_LOCAL/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "systemctl $*" >> "$FAKE_LOG"
exit 0
STUB
	chmod +x "$TMPDIR_LOCAL/bin/systemctl"

	cat > "$TMPDIR_LOCAL/bin/chmod" <<'STUB'
#!/usr/bin/env bash
echo "chmod $*" >> "$FAKE_LOG"
exit 0
STUB
	chmod +x "$TMPDIR_LOCAL/bin/chmod"

	FAKE_LOG="$TMPDIR_LOCAL/calls.log"
	touch "$FAKE_LOG"

	# Destination dirs
	mkdir -p "$TMPDIR_LOCAL/systemd"
	mkdir -p "$TMPDIR_LOCAL/sbin"
}

teardown() {
	rm -rf "$TMPDIR_LOCAL"
}

# ---- helper: minimal globals + stubs for sourcing the module ---
_common_env() {
	cat <<ENVEOF
DRY_RUN=0
src_dir=''
REPO_RAW='http://127.0.0.1:1/does-not-exist'
PREFIX_SBIN='$TMPDIR_LOCAL/sbin'
SYSTEMD_DIR='$TMPDIR_LOCAL/systemd'
BAKE_MODE=0
TURNS_SUBDOMAIN=api-test01
DOMAIN=example.net
_chan_lib_tmp=''
log()  { echo "log: \$*"; }
warn() { echo "warn: \$*"; }
die()  { echo "die: \$*" >&2; exit 1; }
ENVEOF
}

# ---------------------------------------------------------------------------

@test "systemd module sources cleanly" {
	run bash -c "source '$REPO_ROOT/lib/install-systemd.sh'; type systemd_run"
	[ "$status" -eq 0 ]
	[[ "$output" == *"systemd_run is a function"* ]]
}

@test "systemd_run dry-run skips install and curl calls" {
	run bash -c "
		$(_common_env)
		DRY_RUN=1
		source '$REPO_ROOT/lib/install-systemd.sh'
		# Poison real tool calls — should never be reached
		install()  { echo 'install called in dry-run' >&2; exit 99; }
		curl()     { echo 'curl called in dry-run' >&2; exit 99; }
		systemctl(){ echo 'systemctl called in dry-run' >&2; exit 99; }
		systemd_run
	"
	[ "$status" -eq 0 ]
	[[ "$output" == *"[dry-run] skipping systemd install"* ]]
	[[ "$output" != *"install called in dry-run"* ]]
	[[ "$output" != *"curl called in dry-run"* ]]
	[[ "$output" != *"systemctl called in dry-run"* ]]
}

@test "systemd_run non-dry-run triggers install calls" {
	run env FAKE_LOG="$FAKE_LOG" PATH="$TMPDIR_LOCAL/bin:$PATH" bash -c "
		$(_common_env)
		DRY_RUN=0
		source '$REPO_ROOT/lib/install-systemd.sh'
		systemd_run
	"
	[ "$status" -eq 0 ]
	# At least one install invocation must have been logged
	install_calls=$(grep -c '^install ' "$FAKE_LOG" 2>/dev/null || echo 0)
	(( install_calls > 0 ))
}

@test "systemd_run cert-watch unit gets TURNS_SUBDOMAIN and DOMAIN substituted" {
	# Source units live under src_dir/systemd/; dest lives under a separate dir.
	# Use real install/sed (no PATH shim) so file contents are actually written.
	local src_checkout="$TMPDIR_LOCAL/checkout"
	local dest_systemd="$TMPDIR_LOCAL/dest_systemd"
	local dest_sbin="$TMPDIR_LOCAL/dest_sbin"
	mkdir -p "$src_checkout/systemd" "$dest_systemd" "$dest_sbin"
	for unit in oxpulse-partner-cert-watch.path oxpulse-partner-cert-watch.service; do
		printf '[Unit]\nDescription=watch {{TURNS_SUBDOMAIN}}.{{PARTNER_DOMAIN}}\n' \
			> "$src_checkout/systemd/${unit}"
	done

	run bash -c "
		DRY_RUN=0
		src_dir='$src_checkout'
		REPO_RAW='http://127.0.0.1:1/does-not-exist'
		PREFIX_SBIN='$dest_sbin'
		SYSTEMD_DIR='$dest_systemd'
		BAKE_MODE=0
		TURNS_SUBDOMAIN=api-test01
		DOMAIN=example.net
		_chan_lib_tmp=''
		log()  { echo \"log: \$*\"; }
		warn() { echo \"warn: \$*\"; }
		die()  { echo \"die: \$*\" >&2; exit 1; }
		source '$REPO_ROOT/lib/install-systemd.sh'
		_systemd_install_cert_watch_units
	"
	[ "$status" -eq 0 ]
	# After substitution the installed files must contain the resolved values
	grep -qE 'api-test01' "$dest_systemd/oxpulse-partner-cert-watch.path"
	grep -qE 'example\.net' "$dest_systemd/oxpulse-partner-cert-watch.path"
}
