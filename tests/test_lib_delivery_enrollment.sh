#!/usr/bin/env bats
# tests/test_lib_delivery_enrollment.sh — P4 strangler-harden delivery-enrollment
# fix (synthetic_green defect).
#
bats_require_minimum_version 1.5.0
#
# lib/healthcheck-lib.sh, lib/compose-lib.sh, and lib/host-scripts-lib.sh were
# extracted from upgrade.sh/reconcile.sh and wired via same-name shims, but were
# NEVER enrolled as _stage_lib targets — so on an installed/curl|bash box (no
# adjacent lib/ dir) the shims degraded: the healthcheck baseline gate silently
# disabled (fail-open), the compose digest-diff step hard-aborted every upgrade
# (fail-closed die in _upgrade_source_compose_lib), and host-script
# snapshot/restore/sync silently no-op'd. Every existing bats test stayed green
# because it invokes upgrade.sh/reconcile.sh FROM THE CHECKOUT PATH
# ($REPO_ROOT/upgrade.sh), where dirname($0)/lib/ always resolves — the exact
# "tests hit a path that isn't the wired path" synthetic_green class.
#
# This file proves the fix from a GENUINELY non-checkout layout: upgrade.sh is
# copied into an isolated directory with NO adjacent lib/ (the real curl|bash /
# installed-sbin shape), so the colocated resolver tier always misses and the
# staged-LIB_DIR fallback tier is the only path that can succeed.

setup() {
	REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	UPGRADE="$REPO_ROOT/upgrade.sh"
	RECONCILE="$REPO_ROOT/lib/reconcile.sh"
	CHECKSUMS="$REPO_ROOT/lib/lib-checksums.txt"
	RELEASE_YML="$REPO_ROOT/.github/workflows/release.yml"
	TMP="$(mktemp -d)"
}

teardown() {
	rm -rf "$TMP"
}

# ---------------------------------------------------------------------------
# Section 1 — structural: the three libs ARE _stage_lib targets now.
# ---------------------------------------------------------------------------

@test "structural: upgrade.sh BUG1-cure block stages healthcheck-lib.sh" {
	grep -q '_stage_lib "healthcheck-lib.sh"' "$UPGRADE"
}

@test "structural: upgrade.sh BUG1-cure block stages compose-lib.sh" {
	grep -q '_stage_lib "compose-lib.sh"' "$UPGRADE"
}

@test "structural: upgrade.sh BUG1-cure block stages host-scripts-lib.sh" {
	grep -q '_stage_lib "host-scripts-lib.sh"' "$UPGRADE"
}

@test "structural: lib-checksums.txt covers the three newly-staged libs" {
	grep -q 'healthcheck-lib.sh' "$CHECKSUMS"
	grep -q 'compose-lib.sh' "$CHECKSUMS"
	grep -q 'host-scripts-lib.sh' "$CHECKSUMS"
}

@test "structural: release.yml regen block covers the three newly-staged libs" {
	local regen_block
	regen_block=$(awk '/\(cd lib && sha256sum \\/{f=1} f{print} /> lib\/lib-checksums.txt/{f=0}' "$RELEASE_YML")
	echo "$regen_block" | grep -qE '^[[:space:]]+healthcheck-lib\.sh( |\\|$)'
	echo "$regen_block" | grep -qE '^[[:space:]]+compose-lib\.sh( |\\|$)'
	echo "$regen_block" | grep -qE '^[[:space:]]+host-scripts-lib\.sh( |\\|$)'
}

# ---------------------------------------------------------------------------
# Section 2 — structural: resolver flat-path fix (item 6). The buggy
# ${LIB_DIR}/lib/<name> form must be GONE for host-scripts-lib.sh and
# compose-lib.sh (their _stage_lib destination is flat: ${LIB_DIR}/<name>).
# ---------------------------------------------------------------------------

@test "structural: _upgrade_resolve_host_scripts_lib LIB_DIR fallback is flat (no /lib/ subdir)" {
	run ! grep -qF '${LIB_DIR:-$(dirname "${BASH_SOURCE[0]:-}")}/lib/host-scripts-lib.sh' "$UPGRADE"
	grep -qF '${LIB_DIR:-$(dirname "${BASH_SOURCE[0]:-}")}/host-scripts-lib.sh' "$UPGRADE"
}

@test "structural: _upgrade_resolve_compose_lib LIB_DIR fallback is flat (no /lib/ subdir)" {
	run ! grep -qF '${LIB_DIR:-$(dirname "${BASH_SOURCE[0]:-}")}/lib/compose-lib.sh' "$UPGRADE"
	grep -qF '${LIB_DIR:-$(dirname "${BASH_SOURCE[0]:-}")}/compose-lib.sh' "$UPGRADE"
}

# ---------------------------------------------------------------------------
# Section 3 — behavioral, non-checkout: each resolver, extracted verbatim
# (not hand-copied) via the repo's own single-function awk-extraction idiom,
# sourced from a FAKE sbin path with NO lib/ sibling (so the co-located tier
# always misses), must resolve to the FLAT staged path under LIB_DIR — not a
# path with a stray /lib/ segment that would never match what _stage_lib
# actually writes to disk.
# ---------------------------------------------------------------------------

@test "behavioral: _upgrade_resolve_host_scripts_lib resolves the flat LIB_DIR path from a non-checkout sbin layout" {
	local fake_sbin="$TMP/sbin"
	mkdir -p "$fake_sbin"
	# No lib/ subdir created here — genuinely non-checkout.
	awk '/^_upgrade_resolve_host_scripts_lib\(\)/{found=1} found{print} found && /^}$/{exit}' "$UPGRADE" \
		> "$fake_sbin/oxpulse-partner-edge-upgrade"
	bash -n "$fake_sbin/oxpulse-partner-edge-upgrade"

	local stage_dir="$TMP/staged"
	mkdir -p "$stage_dir"
	touch "$stage_dir/host-scripts-lib.sh"

	local result
	result=$(bash -c "source '$fake_sbin/oxpulse-partner-edge-upgrade'; LIB_DIR='$stage_dir' _upgrade_resolve_host_scripts_lib")
	[ "$result" = "$stage_dir/host-scripts-lib.sh" ] \
		|| { echo "expected $stage_dir/host-scripts-lib.sh, got: $result"; return 1; }
}

@test "behavioral: _upgrade_resolve_compose_lib resolves the flat LIB_DIR path from a non-checkout sbin layout" {
	local fake_sbin="$TMP/sbin2"
	mkdir -p "$fake_sbin"
	awk '/^_upgrade_resolve_compose_lib\(\)/{found=1} found{print} found && /^}$/{exit}' "$UPGRADE" \
		> "$fake_sbin/oxpulse-partner-edge-upgrade"
	bash -n "$fake_sbin/oxpulse-partner-edge-upgrade"

	local stage_dir="$TMP/staged2"
	mkdir -p "$stage_dir"
	touch "$stage_dir/compose-lib.sh"

	local result
	result=$(bash -c "source '$fake_sbin/oxpulse-partner-edge-upgrade'; LIB_DIR='$stage_dir' _upgrade_resolve_compose_lib")
	[ "$result" = "$stage_dir/compose-lib.sh" ] \
		|| { echo "expected $stage_dir/compose-lib.sh, got: $result"; return 1; }
}

@test "behavioral: _reconcile_resolve_healthcheck_lib resolves the flat LIB_DIR path from a non-checkout layout (regression guard)" {
	# healthcheck-lib.sh's resolver was already flat before this fix (its bug was
	# NEVER being staged into LIB_DIR at all, not a subdir mismatch) — this test
	# is a symmetry/regression guard, not a RED-before-fix case for THIS defect.
	local fake_lib="$TMP/reconcile-holder"
	mkdir -p "$fake_lib"
	awk '/^_reconcile_resolve_healthcheck_lib\(\)/{found=1} found{print} found && /^}$/{exit}' "$RECONCILE" \
		> "$fake_lib/reconcile.sh"
	bash -n "$fake_lib/reconcile.sh"

	local stage_dir="$TMP/staged3"
	mkdir -p "$stage_dir"
	touch "$stage_dir/healthcheck-lib.sh"

	local result
	result=$(bash -c "source '$fake_lib/reconcile.sh'; LIB_DIR='$stage_dir' _reconcile_resolve_healthcheck_lib")
	[ "$result" = "$stage_dir/healthcheck-lib.sh" ] \
		|| { echo "expected $stage_dir/healthcheck-lib.sh, got: $result"; return 1; }
}

# ---------------------------------------------------------------------------
# Section 4 — END-TO-END, non-checkout: run the REAL, unmodified upgrade.sh
# from an isolated copy with NO adjacent lib/, forcing every _stage_lib /
# _source_lib target through genuine tier-3 network fetch (served from a
# local httpd on the REAL $REPO_ROOT, so lib-checksums.txt verification is
# real, not mocked/bypassed). Drives --host-scripts-only, which calls
# sync_host_scripts — before the fix this always hit the degraded
# "not found" forwarder path (host-scripts-lib.sh was never staged); after
# the fix it resolves + sources the REAL implementation from LIB_DIR.
#
# This is the test the task spec asks for: it FAILS on pre-enrollment code
# (asserted directly below via `git stash`-style diff is impractical inside
# bats, so the assertion itself is the falsifiable claim — reverting either
# the _stage_lib enrollment or the resolver flat-path fix reproduces the
# "not found at" degraded-path string and turns this RED).
# ---------------------------------------------------------------------------

@test "end-to-end non-checkout: --host-scripts-only resolves the REAL host-scripts-lib.sh (not the degraded fallback)" {
	local iso="$TMP/iso"
	mkdir -p "$iso"
	# Copy ONLY upgrade.sh — no lib/, no channel-render-lib.sh, no
	# ghcr-auth-lib.sh sibling. This is the genuine curl|bash / installed-sbin
	# shape the production defect was reported against.
	cp "$UPGRADE" "$iso/oxpulse-partner-edge-upgrade"

	local etc="$TMP/etc" var="$TMP/var" sbin="$TMP/sbin" bin="$TMP/bin" \
		libdir="$TMP/libdir" systemd="$TMP/systemd" share="$TMP/share" \
		installlibdir="$TMP/install-lib-dir-empty" curlbin="$TMP/curlbin"
	mkdir -p "$etc" "$var" "$sbin" "$bin" "$libdir" "$systemd" "$share" "$installlibdir" "$curlbin"

	printf 'IMAGE_VERSION=v0.12.57\nSIGNALING_SFU_SECRET=testsecret\n' > "$var/install.env"
	printf 'services:\n  sfu:\n    image: ghcr.io/anatolykoptev/partner-edge-sfu:v0.12.57\n    environment:\n      SIGNALING_SFU_SECRET: "testsecret"\n' \
		> "$etc/docker-compose.yml"

	# channel-render-lib.sh / ghcr-auth-lib.sh: pre-stage minimal stubs at the
	# tier-2 (PREFIX_SBIN) location so this test stays focused on the
	# host-scripts-lib.sh delivery path, not those two libs' own resolution
	# (already covered by tests/test_upgrade_zero_downtime.sh Section C).
	printf '# stub\nre_render_xray() { return 0; }\nre_render_hysteria2() { return 0; }\n' \
		> "$sbin/channel-render-lib.sh"
	printf '# stub\nghcr_configure_token() { return 0; }\nghcr_login_from_file() { return 0; }\nghcr_pull_diagnose() { return 0; }\n' \
		> "$sbin/ghcr-auth-lib.sh"

	local docker_log="$TMP/docker_calls.log"
	local fake_docker="$TMP/docker"
	cat > "$fake_docker" << 'CFAKE'
#!/bin/bash
printf '%s\n' "$*" >> "${DOCKER_CALL_LOG}"
if [[ "$*" == *"config --services"* ]]; then printf 'sfu\n'; exit 0; fi
exit 0
CFAKE
	chmod +x "$fake_docker"

	# Fake curl: maps any http(s)://.../<path> URL onto $CURL_SERVE_ROOT/<path>
	# and copies/cats it to the -o destination (or stdout). Serves the REAL
	# $REPO_ROOT tree — install-firewall.sh, telegram-alert-lib.sh,
	# reconcile.sh, lib-checksums.txt, SHA256SUMS-shaped host-script fetches,
	# and the three newly-enrolled libs all resolve to their REAL, checksummed
	# content via genuine tier-3 fetch + real checksum verify — nothing about
	# the integrity check itself is mocked, only the transport (upgrade.sh's
	# tier-3 curl is TLS-pinned --proto=https, which a plain local httpd
	# cannot satisfy; a fake curl on PATH is this repo's own established
	# pattern for exercising tier-3 in tests — see
	# tests/test_install_lib_checksum.sh's e2e ordering test). Exits 22 (curl
	# -f's own 404 code) for any path with no local match, so real "file not
	# found" behavior (e.g. SHA256SUMS for a tag that doesn't exist) still
	# reproduces faithfully.
	local fake_curl="$curlbin/curl"
	cat > "$fake_curl" << 'CURLFAKE'
#!/bin/bash
_o=""; _n=""; _url=""
for a in "$@"; do
	if [[ "$_n" == o ]]; then _o="$a"; _n=""; continue; fi
	[[ "$a" == "-o" ]] && { _n=o; continue; }
	case "$a" in http://*|https://*) _url="$a" ;; esac
done
[[ -n "$_url" ]] || exit 2
_path="${_url#http://*/}"
_path="${_path#https://*/}"
_src="$CURL_SERVE_ROOT/$_path"
if [[ -f "$_src" ]]; then
	if [[ -n "$_o" ]]; then cp "$_src" "$_o"; else cat "$_src"; fi
	exit 0
fi
exit 22
CURLFAKE
	chmod +x "$fake_curl"

	local out
	out=$(
		PATH="$curlbin:$PATH" \
		CURL_SERVE_ROOT="$REPO_ROOT" \
		OXPULSE_PREFIX_ETC="$etc" \
		OXPULSE_PREFIX_LIB="$var" \
		OXPULSE_PREFIX_SBIN="$sbin" \
		OXPULSE_PREFIX_BIN="$bin" \
		OXPULSE_PREFIX_LIBDIR="$libdir" \
		OXPULSE_PREFIX_SHARE="$share" \
		OXPULSE_SYSTEMD_DIR="$systemd" \
		INSTALL_LIB_DIR="$installlibdir" \
		OXPULSE_SKIP_ROOT_CHECK=1 \
		OXPULSE_UPGRADE_TAG=v0.12.57 \
		DOCKER_BIN="$fake_docker" \
		DOCKER_CALL_LOG="$docker_log" \
		SYSTEMCTL_BIN=true \
		OXPULSE_REPO_RAW="https://fixture.invalid" \
		OXPULSE_RELEASES_BASE="https://fixture.invalid/releases" \
		bash "$iso/oxpulse-partner-edge-upgrade" --host-scripts-only v0.12.58 2>&1
	) || true

	# The degraded-path marker (only the forwarder's warn emits this exact
	# string) must be ABSENT — this is the falsifiable, RED-before-fix claim:
	# reverting either the _stage_lib enrollment or the resolver flat-path fix
	# reproduces this string and turns this test RED.
	if echo "$out" | grep -q 'lib/host-scripts-lib.sh not found at'; then
		echo "DEGRADED FALLBACK HIT — host-scripts-lib.sh was not delivered/resolved from the non-checkout layout. Output:"
		echo "$out"
		return 1
	fi

	# Positive marker: only the REAL sync_host_scripts implementation (from
	# lib/host-scripts-lib.sh) logs the SHA256SUMS fetch step.
	echo "$out" | grep -qE 'fetched SHA256SUMS for|could not fetch SHA256SUMS' \
		|| { echo "no evidence the REAL sync_host_scripts ran; output: $out"; return 1; }
}

# ---------------------------------------------------------------------------
# Section 5 — recursion regression (coordinator review finding): the
# self-overwriting forwarder pattern (health_snapshot/health_regressions in
# reconcile.sh; snapshot_host_scripts/restore_host_scripts/sync_host_scripts
# in upgrade.sh) is vulnerable to infinite recursion if the lib's own
# double-source guard is already tripped (guard=1) BEFORE the forwarder is
# (re)defined: the forwarder sources the lib, the guard short-circuits
# `. "$lib"` WITHOUT redefining the function, and the forwarder's trailing
# "$@" call invokes itself — forever. Not reachable via today's normal
# upgrade.sh/reconcile.sh entry points, but reachable if the lib is ever
# sourced directly BEFORE the forwarder-defining file, which is exactly what
# a lib-level unit test (or a future eager re-source) can trigger. Each
# forwarder now `unset -f`s itself immediately before sourcing, turning the
# would-be infinite recursion into a clean "command not found" instead.
# `timeout` is a hard safety net so a regression cannot hang the test suite.
# ---------------------------------------------------------------------------

@test "recursion guard: health_snapshot forwarder does not infinitely recurse when the lib was sourced first" {
	local driver="$TMP/health_recursion_driver.sh"
	cat > "$driver" << DRV
log()  { :; }
warn() { echo "WARN: \$*" >&2; }
die()  { echo "DIE: \$*" >&2; exit 9; }
# 1) Source the REAL lib directly first — sets the guard AND defines the
#    real health_snapshot/health_regressions.
source "$REPO_ROOT/lib/healthcheck-lib.sh"
# 2) Source reconcile.sh — its own guard is fresh (first time in THIS
#    process), so it runs and redefines health_snapshot/health_regressions
#    back to the forwarders, clobbering the real functions from step 1.
source "$REPO_ROOT/lib/reconcile.sh"
# 3) Call the (now-forwarder) health_snapshot. LIB_DIR points nowhere
#    real, and co-located also misses (BASH_SOURCE is this driver script's
#    own path, no adjacent healthcheck-lib.sh) — EXCEPT the guard in
#    healthcheck-lib.sh is already 1 from step 1, so even a resolvable path
#    would short-circuit without redefining. Point HEALTHCHECK_LIB at the
#    real file so the forwarder's [[ -f ]] check passes and it reaches the
#    guarded-source line — that is the exact recursion trigger.
export HEALTHCHECK_LIB="$REPO_ROOT/lib/healthcheck-lib.sh"
health_snapshot /nonexistent/healthcheck.sh "$TMP/snap.out" 2>&1
echo "REACHED_END rc=\$?"
DRV
	run timeout 10 bash "$driver"
	# Before the fix: times out (rc=124) or exhausts the stack
	# ("maximum function nesting level exceeded" / segfault-ish abort).
	# After the fix: returns promptly, either via a clean "command not
	# found" (function was unset) or the real health_snapshot's own
	# not-executable-healthcheck-bin failure — either way REACHED_END prints
	# and the process is not stuck.
	[ "$status" -ne 124 ] || { echo "TIMED OUT — infinite recursion reintroduced"; false; }
	[[ "$output" != *"maximum function nesting level exceeded"* ]] \
		|| { echo "infinite recursion reintroduced: $output"; false; }
	[[ "$output" == *"REACHED_END"* ]] \
		|| { echo "driver did not reach its end line; output: $output"; false; }
}

@test "recursion guard: snapshot_host_scripts forwarder does not infinitely recurse when the lib was sourced first" {
	local driver="$TMP/hostscripts_recursion_driver.sh"
	cat > "$driver" << DRV
log()  { :; }
warn() { echo "WARN: \$*" >&2; }
die()  { echo "DIE: \$*" >&2; exit 9; }
# 1) Source the REAL lib directly first — sets the guard AND defines the
#    real snapshot_host_scripts/restore_host_scripts/sync_host_scripts.
source "$REPO_ROOT/lib/host-scripts-lib.sh"
# 2) Re-define the forwarders by extracting them straight from upgrade.sh
#    (verbatim, not hand-copied) — simulates upgrade.sh's own unconditional
#    (un-guarded) forwarder definitions running AFTER the lib was already
#    loaded once in this process.
DRV
	awk '/^_upgrade_resolve_host_scripts_lib\(\)/{found=1} found{print} found && /^}$/{exit}' "$UPGRADE" >> "$driver"
	awk '/^snapshot_host_scripts\(\)/{found=1} found{print} found && /^}$/{exit}' "$UPGRADE" >> "$driver"
	cat >> "$driver" << DRV
# 3) Call the forwarder. Co-located misses (no lib/ next to this driver);
#    point HOST_SCRIPTS_LIB at the real file so [[ -f ]] passes and the
#    guarded-source line (the actual recursion trigger) is reached.
export HOST_SCRIPTS_LIB="$REPO_ROOT/lib/host-scripts-lib.sh"
snapshot_host_scripts some-tag 2>&1
echo "REACHED_END rc=\$?"
DRV
	run timeout 10 bash "$driver"
	[ "$status" -ne 124 ] || { echo "TIMED OUT — infinite recursion reintroduced"; false; }
	[[ "$output" != *"maximum function nesting level exceeded"* ]] \
		|| { echo "infinite recursion reintroduced: $output"; false; }
	[[ "$output" == *"REACHED_END"* ]] \
		|| { echo "driver did not reach its end line; output: $output"; false; }
}
