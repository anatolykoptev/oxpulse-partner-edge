#!/usr/bin/env bats
# tests/test_install_lib_checksum.sh — Phase 5.7 Item 3: tier-4 fetch integrity.
#
# Covers:
#   1. lib/lib-checksums.txt exists in the repo
#   2. lib-checksums.txt contains SHA256 entries for release-pipeline lib/*.sh files
#   3. release.yml generates and uploads lib-checksums.txt
#   4. _install_lib_source in install.sh has checksum validation logic
#   5. Behavioral: wrong checksum on tier-4 fetch → die with expected message
#   6. Behavioral: missing lib-checksums.txt → warn + continue (legacy fallback)
#   7. Behavioral: correct checksum → source succeeds
#   8. lib-checksums.txt SHA256SUMS format valid (sha256sum --check compatible)

# Bats <1.5 compat (CI runs an old ubuntu-22.04 apt bats): to negate an assertion
# WITHOUT `run !` (bats >= 1.5) or a bare `! command` (SC2314: `!` disables errexit
# for that one statement, so a later successful statement silently masks the
# violation and the test reports "ok"), use `run <cmd>; [ "$status" -ne 0 ]` — it
# captures the exit code and the explicit check propagates failure on every bats.

setup() {
	REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	TMP="$(mktemp -d)"
	INSTALL="$REPO_ROOT/install.sh"
	CHECKSUMS="$REPO_ROOT/lib/lib-checksums.txt"
	RELEASE_YML="$REPO_ROOT/.github/workflows/release.yml"
}

teardown() {
	rm -rf "$TMP"
}

# ---------------------------------------------------------------------------
# 1. lib/lib-checksums.txt exists
# ---------------------------------------------------------------------------
@test "lib/lib-checksums.txt exists" {
	[ -f "$CHECKSUMS" ]
}

# ---------------------------------------------------------------------------
# 2. lib-checksums.txt contains SHA256 entries for release-pipeline lib/*.sh files
# ---------------------------------------------------------------------------
@test "lib/lib-checksums.txt contains entries for all release-pipeline lib/*.sh files" {
	[ -f "$CHECKSUMS" ] || skip "lib-checksums.txt not yet created"
	# The full set the release pipeline checksums — this list must match the
	# release.yml `cd lib && sha256sum` block AND the Makefile `lib-checksums` target.
	# reconcile.sh + telegram-alert-lib.sh were added by the P0 supply-chain resolver:
	# both are fetched-as-root by upgrade.sh (_source_lib / _stage_lib) so both must be
	# verified against a checksum. install-firewall.sh has been covered since its own
	# bug-#5 fix — it is NOT absent.
	for basename in \
		install-args.sh \
		install-awg.sh \
		install-awg-params-agent.sh \
		install-deps.sh \
		install-firewall.sh \
		install-healthcheck.sh \
		install-network.sh \
		install-preflight.sh \
		install-split-routing.sh \
		install-systemd.sh \
		render-channel-lib.sh \
		reconcile.sh \
		telegram-alert-lib.sh; do
		grep -q "$basename" "$CHECKSUMS"
	done
}

# ---------------------------------------------------------------------------
# 3. release.yml references lib-checksums.txt (generates + uploads)
# ---------------------------------------------------------------------------
@test "release.yml generates lib-checksums.txt as a release asset" {
	grep -q 'lib-checksums' "$RELEASE_YML"
}

# ---------------------------------------------------------------------------
# 4. install.sh _install_lib_source contains checksum validation
# ---------------------------------------------------------------------------
@test "install.sh _install_lib_source validates SHA256 on tier-4 fetch" {
	grep -q 'lib-checksums' "$INSTALL"
}

@test "install.sh _install_lib_source dies on checksum mismatch" {
	grep -qE 'checksum mismatch|mismatch.*refusing|refusing.*untrusted' "$INSTALL"
}

# ---------------------------------------------------------------------------
# 5. Behavioral: wrong checksum → die
# ---------------------------------------------------------------------------
@test "_install_lib_source tier-4: wrong checksum causes die" {
	# Write a fake lib-checksums.txt with a known-wrong checksum
	local fake_lib_dir="$TMP/lib"
	mkdir -p "$fake_lib_dir"

	# The module we'll "fetch"
	local module_name="install-preflight.sh"
	local fake_content="echo 'fake module content'"
	local correct_hash
	correct_hash=$(printf '%s' "$fake_content" | sha256sum | awk '{print $1}')
	local wrong_hash="0000000000000000000000000000000000000000000000000000000000000000"

	# lib-checksums.txt with the WRONG hash for this module
	printf '%s  %s\n' "$wrong_hash" "$module_name" > "$TMP/lib-checksums.txt"

	# Write the fake module content to a temp file (simulates what tier-4 curl would fetch)
	printf '%s\n' "$fake_content" > "$TMP/fetched-module.sh"

	# Extract and test just the checksum validation logic from install.sh
	# We simulate the _install_lib_source tier-4 check:
	#   1. curl fetched content to $tmp
	#   2. lib-checksums.txt available
	#   3. validate sha256
	run bash -c "
		log()  { echo \"LOG: \$*\"; }
		warn() { echo \"WARN: \$*\"; }
		die()  { echo \"DIE: \$*\" >&2; exit 1; }

		# Simulate the checksum validation block
		_tmp='$TMP/fetched-module.sh'
		_name='$module_name'
		_checksums='$TMP/lib-checksums.txt'
		_actual_hash=\$(sha256sum \"\$_tmp\" | awk '{print \$1}')
		_expected_hash=\$(grep \"\$_name\" \"\$_checksums\" 2>/dev/null | awk '{print \$1}')
		if [[ -n \"\$_expected_hash\" && \"\$_actual_hash\" != \"\$_expected_hash\" ]]; then
			die \"tier-4 fetch checksum mismatch for \$_name — refusing to source untrusted code\"
		fi
		echo 'VALIDATION_PASSED'
	"
	[ "$status" -ne 0 ]
	[[ "$output" == *"checksum mismatch"* || "$output" == *"refusing"* ]]
}

# ---------------------------------------------------------------------------
# 6. Behavioral: missing lib-checksums.txt → warn + continue (legacy fallback)
# ---------------------------------------------------------------------------
@test "_install_lib_source tier-4: missing lib-checksums.txt warns but continues" {
	run bash -c "
		log()  { echo \"LOG: \$*\"; }
		warn() { echo \"WARN: \$*\"; }
		die()  { echo \"DIE: \$*\" >&2; exit 1; }

		_tmp='$TMP/fetched-module.sh'
		printf 'echo fake\n' > \"\$_tmp\"
		_name='install-preflight.sh'
		_checksums='$TMP/nonexistent-checksums.txt'
		# Logic from install.sh: if checksums file missing, warn and continue
		if [[ ! -f \"\$_checksums\" ]]; then
			warn \"lib-checksums.txt not found — skipping integrity check (legacy install)\"
		else
			_actual=\$(sha256sum \"\$_tmp\" | awk '{print \$1}')
			_expected=\$(grep \"\$_name\" \"\$_checksums\" 2>/dev/null | awk '{print \$1}')
			if [[ -n \"\$_expected\" && \"\$_actual\" != \"\$_expected\" ]]; then
				die \"tier-4 fetch checksum mismatch for \$_name — refusing to source untrusted code\"
			fi
		fi
		echo 'CONTINUED'
	"
	[ "$status" -eq 0 ]
	[[ "$output" == *"CONTINUED"* ]]
	[[ "$output" == *"skipping integrity"* || "$output" == *"lib-checksums.txt not found"* ]]
}

# ---------------------------------------------------------------------------
# 7. Behavioral: correct checksum → source succeeds
# ---------------------------------------------------------------------------
@test "_install_lib_source tier-4: correct checksum allows sourcing" {
	local fake_content
	printf 'echo fake_module_loaded\n' > "$TMP/fetched-ok.sh"
	local correct_hash
	correct_hash=$(sha256sum "$TMP/fetched-ok.sh" | awk '{print $1}')

	printf '%s  install-preflight.sh\n' "$correct_hash" > "$TMP/lib-checksums-ok.txt"

	run bash -c "
		log()  { echo \"LOG: \$*\"; }
		warn() { echo \"WARN: \$*\"; }
		die()  { echo \"DIE: \$*\" >&2; exit 1; }

		_tmp='$TMP/fetched-ok.sh'
		_name='install-preflight.sh'
		_checksums='$TMP/lib-checksums-ok.txt'
		_actual=\$(sha256sum \"\$_tmp\" | awk '{print \$1}')
		_expected=\$(grep \"\$_name\" \"\$_checksums\" 2>/dev/null | awk '{print \$1}')
		if [[ -n \"\$_expected\" && \"\$_actual\" != \"\$_expected\" ]]; then
			die \"tier-4 fetch checksum mismatch for \$_name — refusing to source untrusted code\"
		fi
		echo 'CHECKSUM_OK'
	"
	[ "$status" -eq 0 ]
	[[ "$output" == *"CHECKSUM_OK"* ]]
}

# ---------------------------------------------------------------------------
# 8. lib-checksums.txt is sha256sum --check compatible (valid format)
# ---------------------------------------------------------------------------
@test "lib/lib-checksums.txt passes sha256sum --check from repo root" {
	[ -f "$CHECKSUMS" ] || skip "lib-checksums.txt not yet created"
	# sha256sum --check reads "hash  filename" lines relative to CWD
	(cd "$REPO_ROOT/lib" && sha256sum --check "$CHECKSUMS")
}

# _mitm_overclaim_lines FILE — print any line matching an MITM-resistance /
# signature-verification / tier-4-secure CLAIM that is not paired with an explicit
# negation on the same line (e.g. "does NOT provide MITM-resistance" is a correct
# disclaimer, not an overclaim). Exits 0 (found) / 1 (none) so the `run …; [ "$status"
# -ne 0 ]` negation below can assert "no overclaim lines exist" without a crude
# keyword match flagging the disclaimer sentence itself as a violation.
_mitm_overclaim_lines() {
	grep -iE 'MITM.resist|signature.verif|tier.4.*secure' "$1" \
		| grep -viE 'does[[:space:]]+not|is[[:space:]]+not|not[[:space:]]+provide|cannot|never'
}

# ---------------------------------------------------------------------------
# BLOCKER 1 Part A: comment block explicitly says "tamper-evident at rest",
# NOT "MITM-resistant" / "signature verification" / "tier-4 secure"
# ---------------------------------------------------------------------------
@test "install.sh _install_lib_source comment says tamper-evident (not MITM-resistant)" {
	# Must NOT claim MITM resistance for the checksums validation block. Use
	# `run <cmd>; [ "$status" -ne 0 ]` (not a bare `! grep`, SC2314) — a bare `!`
	# as a non-last statement does not propagate failure in bats: the second grep
	# below would silently mask a violation and this assertion would become a
	# permanent no-op.
	run _mitm_overclaim_lines "$INSTALL"
	[ "$status" -ne 0 ]
	# MUST acknowledge the same-channel limitation
	grep -qiE 'tamper.evident|tamper.at.rest|asset.bucket|cache' "$INSTALL"
}

# ---------------------------------------------------------------------------
# BLOCKER 1 Part B: fail-closed default
#   - tier-4 fetch with no local checksums AND no --no-integrity → die
#   - tier-4 fetch with no local checksums AND --no-integrity → warn + proceed
# ---------------------------------------------------------------------------
@test "install.sh accepts --no-integrity flag" {
	grep -q 'no.integrity\|no_integrity\|NO_INTEGRITY' "$INSTALL" || \
	grep -q 'no.integrity\|no_integrity\|NO_INTEGRITY' "$REPO_ROOT/lib/install-args.sh"
}

@test "tier-4 without local checksums and without --no-integrity: dies with clear message" {
	# Simulate the fail-closed path:
	#   - no local checksums found
	#   - remote checksums fetch also fails (no network)
	#   - NO_INTEGRITY not set
	# Expect: die with message including "unsafe" or "no-integrity"
	run bash -c "
		log()  { echo \"LOG: \$*\"; }
		warn() { echo \"WARN: \$*\"; }
		die()  { echo \"DIE: \$*\" >&2; exit 1; }

		NO_INTEGRITY=0
		_ck_file=''      # no checksums found
		_ck_fetch_ok=0   # remote fetch also failed

		# Logic from install.sh: fail-closed when no checksums + no --no-integrity
		if [[ -z \"\$_ck_file\" && \$_ck_fetch_ok -eq 0 && \$NO_INTEGRITY -eq 0 ]]; then
			die \"tier-4 fetch without local checksums file is unsafe — either install from release tarball or pass --no-integrity to acknowledge the risk\"
		fi
		echo 'CONTINUED'
	"
	[ "$status" -ne 0 ]
	[[ "$output" == *"unsafe"* || "$output" == *"no-integrity"* ]]
}

@test "tier-4 without local checksums but with --no-integrity: warns and proceeds" {
	run bash -c "
		log()  { echo \"LOG: \$*\"; }
		warn() { echo \"WARN: \$*\"; }
		die()  { echo \"DIE: \$*\" >&2; exit 1; }

		NO_INTEGRITY=1
		_ck_file=''
		_ck_fetch_ok=0

		if [[ -z \"\$_ck_file\" && \$_ck_fetch_ok -eq 0 && \$NO_INTEGRITY -eq 0 ]]; then
			die \"tier-4 fetch without local checksums file is unsafe — either install from release tarball or pass --no-integrity to acknowledge the risk\"
		elif [[ -z \"\$_ck_file\" && \$_ck_fetch_ok -eq 0 && \$NO_INTEGRITY -eq 1 ]]; then
			warn \"tier-4 fetch: --no-integrity acknowledged — skipping checksum validation (operator accepts risk)\"
		fi
		echo 'CONTINUED'
	"
	[ "$status" -eq 0 ]
	[[ "$output" == *"CONTINUED"* ]]
	[[ "$output" == *"no-integrity"* || "$output" == *"operator accepts"* ]]
}

# ===========================================================================
# P0 supply-chain resolver — coverage + behavioral checks for upgrade.sh's
# _source_lib tier-3 fetch (the ORIGINAL unverified resolver, hardened here).
# ===========================================================================

# ---------------------------------------------------------------------------
# FITNESS: every fetched-as-root lib is a staged release asset AND is listed in
# its HOME checksum manifest (staged-asset ∩ home-manifest). Home manifest:
#   lib/*.sh       → lib/lib-checksums.txt
#   repo-root *.sh → the release SHA256SUMS block (== staged, for a root file)
# Targets = every _install_lib_source / _source_lib / _stage_lib fetch target.
# ---------------------------------------------------------------------------
@test "fitness: every root-fetched lib is in (staged release assets ∩ home manifest)" {
	local upgrade="$REPO_ROOT/upgrade.sh"
	local install="$REPO_ROOT/install.sh"
	[ -f "$upgrade" ] && [ -f "$install" ] || skip "upgrade.sh / install.sh missing"

	# Discover fetch targets (dedup). _install_lib_source takes a bareword ending in
	# .sh (the `# _install_lib_source indirection` comment has no .sh → excluded);
	# _source_lib / _stage_lib take a quoted "NAME".
	local targets
	targets=$(
		{
			grep -oE '^[[:space:]]*_install_lib_source [a-z][a-zA-Z0-9._-]+\.sh' "$install" | awk '{print $2}'
			grep -oE '_source_lib "[^"]+\.sh"' "$upgrade" | sed -E 's/.*"([^"]+)"/\1/'
			grep -oE '_stage_lib "[^"]+\.sh"'  "$upgrade" | sed -E 's/.*"([^"]+)"/\1/'
		} | sort -u
	)
	[ -n "$targets" ] || { echo "no fetch targets discovered — parser drift"; false; return; }

	# The lib-checksums REGEN block ((cd lib && sha256sum … ) > lib/lib-checksums.txt):
	# a lib/*.sh listed here has its checksum generated into the released
	# lib-checksums.txt — that IS its staged-asset evidence (its home manifest).
	local regen_block
	regen_block=$(awk '/cd lib && sha256sum \\/{f=1} f{print} /> lib\/lib-checksums.txt/{f=0}' "$RELEASE_YML")
	# The MAIN release SHA256SUMS block (the standalone `        sha256sum \` line —
	# NOT the regen block — through `> SHA256SUMS`): a repo-root *.sh listed here is
	# both staged AND covered by its home manifest (SHA256SUMS).
	local sums_block
	sums_block=$(awk '/^[[:space:]]*sha256sum \\/{f=1} f{print} /> SHA256SUMS/{f=0}' "$RELEASE_YML")

	local missing=0 t
	for t in $targets; do
		if [ -f "$REPO_ROOT/lib/$t" ]; then
			# lib/*.sh — home manifest = lib-checksums.txt; staged = the regen block
			# generates its checksum. Require BOTH (catches committed↔pipeline drift).
			printf '%s\n' "$regen_block" | grep -qE "^[[:space:]]+$t( |\\\\|\$)" \
				|| { echo "lib NOT staged into lib-checksums.txt regen block: $t"; missing=1; }
			grep -qE "[[:space:]]${t}\$" "$CHECKSUMS" \
				|| { echo "lib MISSING from lib-checksums.txt home manifest: $t"; missing=1; }
		else
			# repo-root *.sh — home manifest = SHA256SUMS block (== staged evidence).
			printf '%s\n' "$sums_block" | grep -qE "^[[:space:]]+$t( |\\\\|\$)" \
				|| { echo "repo-root lib NOT in SHA256SUMS home manifest/staging: $t"; missing=1; }
		fi
	done
	[ "$missing" -eq 0 ]
}

# ---------------------------------------------------------------------------
# BEHAVIORAL (real code): the REAL _source_lib extracted from upgrade.sh must
# TLS-pin its tier-3 fetch and sha256-verify FAIL-CLOSED against the home
# manifest. Extracts the shipped function (not a hand-copy) → goes RED if the
# guard is reverted. Home manifest: lib/*.sh → lib-checksums.txt; repo-root →
# release SHA256SUMS.
# ---------------------------------------------------------------------------
@test "_source_lib tier-3: TLS-pinned + fail-closed sha256 verify (real upgrade.sh code)" {
	local UPGRADE="$REPO_ROOT/upgrade.sh"
	[ -f "$UPGRADE" ] || skip "upgrade.sh missing"

	# Extract the REAL _source_lib (+ the _lookup_expected_hash helper it now calls,
	# review HIGH #2 shared-resolver extraction); stub log/warn/die so it is
	# sourceable in isolation.
	local SRCFN="$TMP/source_lib_fn.sh"
	{
		echo 'log()  { :; }'
		echo 'warn() { echo "WARN: $*" >&2; }'
		echo 'die()  { echo "DIED: $*" >&2; exit 9; }'
		awk '/^_lookup_expected_hash\(\)/{f=1} f{print} /^}$/ && f{exit}' "$UPGRADE"
		awk '/^_source_lib\(\)/{f=1} f{print} /^}$/ && f{exit}' "$UPGRADE"
	} > "$SRCFN"
	bash -n "$SRCFN"   # extracted function must parse

	# Fixture lib content that _source_lib will SOURCE on a successful verify.
	local LIB_FIXTURE="$TMP/fixture-lib.sh"
	printf 'echo SOURCED_OK\n' > "$LIB_FIXTURE"
	local FIX_HASH
	FIX_HASH=$(sha256sum "$LIB_FIXTURE" | awk '{print $1}')
	local ZERO="0000000000000000000000000000000000000000000000000000000000000000"

	# Manifest fixtures (lib-checksums.txt-shaped and SHA256SUMS-shaped: "hash  name").
	local CK_MATCH="$TMP/ck_match.txt";     printf '%s  reconcile.sh\n' "$FIX_HASH" > "$CK_MATCH"
	local CK_BAD="$TMP/ck_bad.txt";         printf '%s  reconcile.sh\n' "$ZERO" > "$CK_BAD"
	local SUMS_MATCH="$TMP/sums_match.txt"; printf '%s  channel-render-lib.sh\n' "$FIX_HASH" > "$SUMS_MATCH"
	local CURL_LOG="$TMP/curl.log"

	# Harness: mock curl (manifest URL → serve $MANIFEST if a real file, else 404;
	# any other URL → serve the fixture lib), source the extracted _source_lib, and
	# invoke it with non-existent local/installed paths so it takes tier-3.
	local HARNESS="$TMP/harness.sh"
	cat > "$HARNESS" <<'HEOF'
#!/usr/bin/env bash
set -uo pipefail
log()  { :; }
warn() { echo "WARN: $*" >&2; }
die()  { echo "DIED: $*" >&2; exit 9; }
curl() {
    echo "$*" >> "$CURL_LOG"
    local _o="" _n="" a
    for a in "$@"; do [[ "$_n" == o ]] && { _o="$a"; _n=""; }; [[ "$a" == "-o" ]] && _n=o; done
    case "$*" in
        *lib-checksums.txt*|*SHA256SUMS*)
            { [[ -n "${MANIFEST:-}" && -f "${MANIFEST:-}" ]] && cp "$MANIFEST" "$_o"; } || return 1 ;;
        *) cp "$LIB_FIXTURE" "$_o" ;;
    esac
    return 0
}
# shellcheck source=/dev/null
source "$SRCFN"
_source_lib "$NAME" "/nonexistent/local/$NAME" "/nonexistent/installed/$NAME" "$RAW"
HEOF

	_drive() {  # NAME RAW MANIFEST NOINT -> combined output (harness may exit non-zero)
		: > "$CURL_LOG"
		env SRCFN="$SRCFN" LIB_FIXTURE="$LIB_FIXTURE" CURL_LOG="$CURL_LOG" \
			REPO_RAW="https://raw.example.test/oxpulse-partner-edge/main" \
			RELEASES_BASE="https://rel.example.test/oxpulse-partner-edge/releases/download" \
			OXPULSE_UPGRADE_TAG="v9.9.9" \
			INSTALL_LIB_DIR="$TMP/nonexistent-installdir" \
			NAME="$1" RAW="$2" MANIFEST="$3" OXPULSE_UPGRADE_NO_INTEGRITY="$4" \
			bash "$HARNESS" 2>&1
	}

	local raw_lib="https://raw.example.test/oxpulse-partner-edge/main/lib/reconcile.sh"
	local raw_root="https://raw.example.test/oxpulse-partner-edge/main/channel-render-lib.sh"
	local out

	# TLS + LIB-MATCH: lib/*.sh + matching lib-checksums entry → sources.
	out=$(_drive "reconcile.sh" "$raw_lib" "$CK_MATCH" 0) || true
	echo "$out" | grep -q 'SOURCED_OK' || { echo "LIB-MATCH: expected SOURCED_OK; got: $out"; false; return; }
	grep -q -- '--proto =https' "$CURL_LOG" && grep -q -- '--tlsv1.2' "$CURL_LOG" \
		|| { echo "TLS: tier-3 curl not TLS-pinned; log: $(cat "$CURL_LOG")"; false; return; }

	# LIB-MISMATCH: tampered hash → die, NOT sourced.
	out=$(_drive "reconcile.sh" "$raw_lib" "$CK_BAD" 0) || true
	echo "$out" | grep -qi 'checksum mismatch' || { echo "LIB-MISMATCH: expected mismatch die; got: $out"; false; return; }
	echo "$out" | grep -q 'SOURCED_OK' && { echo "LIB-MISMATCH: sourced despite mismatch!"; false; return; }

	# ROOT-MATCH: repo-root file verified against SHA256SUMS (release fetch, real tag).
	out=$(_drive "channel-render-lib.sh" "$raw_root" "$SUMS_MATCH" 0) || true
	echo "$out" | grep -q 'SOURCED_OK' || { echo "ROOT-MATCH: expected SOURCED_OK via SHA256SUMS; got: $out"; false; return; }

	# FAILCLOSED: no manifest + no override → die, NOT sourced.
	out=$(_drive "reconcile.sh" "$raw_lib" "" 0) || true
	echo "$out" | grep -qi 'unsafe' || { echo "FAILCLOSED: expected fail-closed die; got: $out"; false; return; }
	echo "$out" | grep -q 'SOURCED_OK' && { echo "FAILCLOSED: sourced without a manifest!"; false; return; }

	# OVERRIDE: no manifest + OXPULSE_UPGRADE_NO_INTEGRITY=1 → sources (escape hatch).
	out=$(_drive "reconcile.sh" "$raw_lib" "" 1) || true
	echo "$out" | grep -q 'SOURCED_OK' || { echo "OVERRIDE: expected SOURCED_OK with override; got: $out"; false; return; }

	# NOENTRY: the manifest RESOLVES (curl 200) but has NO line for this file → the
	# resolver must treat that as "no verified checksum" → FAIL-CLOSED, NOT sourced.
	# This is the review-HIGH case: a truncated / captive-portal / wrong-version manifest
	# that simply omits the one relevant line must not silently downgrade to unverified.
	# Distinct from FAILCLOSED above (there NO manifest resolves at all). If the guard is
	# reverted to the old install.sh grep-miss "proceed-with-warn", this sources → RED.
	local CK_NOENTRY="$TMP/ck_noentry.txt"; printf '%s  some-other-file.sh\n' "$ZERO" > "$CK_NOENTRY"
	out=$(_drive "reconcile.sh" "$raw_lib" "$CK_NOENTRY" 0) || true
	echo "$out" | grep -q 'SOURCED_OK' && { echo "NOENTRY: sourced despite the manifest omitting the entry!"; false; return; }
	echo "$out" | grep -qi 'unsafe' || { echo "NOENTRY: expected a fail-closed 'unsafe' die on a missing entry; got: $out"; false; return; }

	# NOENTRY-OVERRIDE: same resolved-but-omitting manifest + escape hatch → sources.
	out=$(_drive "reconcile.sh" "$raw_lib" "$CK_NOENTRY" 1) || true
	echo "$out" | grep -q 'SOURCED_OK' || { echo "NOENTRY-OVERRIDE: expected SOURCED_OK with override; got: $out"; false; return; }
}

# ---------------------------------------------------------------------------
# END-TO-END (real upgrade.sh) — pins the ORDERING fix: the --allow-unverified /
# --no-integrity pre-scan MUST run BEFORE the first _source_lib call, so the flag
# is honored by the tier-3 fail-closed verify. The per-branch behavioral test above
# sets OXPULSE_UPGRADE_NO_INTEGRITY as an env var and never parses $@ through the
# real pre-scan loop, so it would NOT catch a future edit that moves the pre-scan
# block back after the _source_lib calls. This runs the SHIPPED upgrade.sh end to
# end with only curl mocked, forcing tier-3 by isolating upgrade.sh from its
# adjacent/installed libs, and asserts:
#   A) `--allow-unverified` (parsed from $@ by the pre-scan) reaches the post-lib
#      "no installed bundle" die — i.e. the flag propagated to the tier-3 verify.
#   B) with NO flag, the tier-3 verify FAILS CLOSED on the first _source_lib.
# If the pre-scan is reordered after the _source_lib calls, (A) flips to a tier-3
# "unsafe" die → RED. Verified non-vacuous by mutating the pre-scan to drop the flag.
# ---------------------------------------------------------------------------
@test "e2e: --allow-unverified pre-scan runs before the first _source_lib (ordering)" {
	local UPGRADE="$REPO_ROOT/upgrade.sh"
	[ -f "$UPGRADE" ] || skip "upgrade.sh missing"

	# Isolate upgrade.sh ALONE so tiers 1-2 (adjacent / installed) miss and tier-3 fires.
	local ISO="$TMP/iso"; mkdir -p "$ISO"
	cp "$UPGRADE" "$ISO/upgrade.sh"

	# Mock curl: benign content for lib payloads; 404 for manifest fetches (so the
	# manifest resolves empty → the flag alone decides fail-closed vs. proceed).
	local BIN="$TMP/bin"; mkdir -p "$BIN"
	cat > "$BIN/curl" <<'CEOF'
#!/usr/bin/env bash
_o=""; _n=""
for a in "$@"; do [[ "$_n" == o ]] && { _o="$a"; _n=""; }; [[ "$a" == "-o" ]] && _n=o; done
case "$*" in
    *lib-checksums.txt*|*SHA256SUMS*) exit 22 ;;            # 404 the manifest
    *) [[ -n "$_o" ]] && printf ': # stub lib\n' > "$_o"; exit 0 ;;
esac
CEOF
	chmod +x "$BIN/curl"

	_run_upgrade() {  # $@ → upgrade.sh args; prints combined output (may exit non-zero)
		env PATH="$BIN:$PATH" \
			OXPULSE_SKIP_ROOT_CHECK=1 \
			OXPULSE_PREFIX_ETC="$TMP/nope-etc" \
			OXPULSE_PREFIX_LIB="$TMP/nope-lib" \
			OXPULSE_PREFIX_SBIN="$TMP/nope-sbin" \
			OXPULSE_PREFIX_BIN="$TMP/nope-bin" \
			INSTALL_LIB_DIR="$TMP/nope-libdir" \
			OXPULSE_REPO_RAW="https://mock.test/repo" \
			OXPULSE_RELEASES_BASE="https://mock.test/rel" \
			OXPULSE_UPGRADE_TAG="v9.9.9" \
			bash "$ISO/upgrade.sh" "$@" 2>&1
	}

	# NB: use [[ ]] string matches, not `grep && {…}`, for the negative assertions:
	# a `grep -q X && {…}` as the FINAL command makes bats fail the test when grep
	# (correctly) does NOT match, since the test's exit status = that non-zero grep.
	local out
	# (A) flag parsed from $@ must reach the POST-lib bundle check, no integrity die.
	out=$(_run_upgrade --allow-unverified) || true
	[[ "$out" == *"no installed bundle"* ]] \
		|| { echo "A: --allow-unverified did not reach post-lib bundle check (pre-scan ordering?); got: $out"; return 1; }
	[[ "$out" != *unsafe* && "$out" != *"checksum mismatch"* ]] \
		|| { echo "A: integrity die despite --allow-unverified — flag not honored at tier-3; got: $out"; return 1; }

	# (B) no flag → first _source_lib tier-3 FAILS CLOSED before the bundle check.
	out=$(_run_upgrade) || true
	[[ "$out" == *unsafe* ]] \
		|| { echo "B: expected tier-3 fail-closed die without a flag; got: $out"; return 1; }
	[[ "$out" != *"no installed bundle"* ]] \
		|| { echo "B: reached bundle check without a manifest or flag — fail-closed bypassed; got: $out"; return 1; }

	# (C) LOW follow-up: the literal --no-integrity token (install.sh-parity alias,
	# distinct code path in BOTH case-arms — the pre-scan loop above upgrade.sh's
	# first _source_lib call, and the real args_parse case block) must be honored
	# identically to --allow-unverified. Before this test, only the env var
	# (OXPULSE_UPGRADE_NO_INTEGRITY) and --allow-unverified were driven through the
	# ARGV path — --no-integrity's own case-arm branch was never exercised end to end.
	out=$(_run_upgrade --no-integrity) || true
	[[ "$out" == *"no installed bundle"* ]] \
		|| { echo "C: --no-integrity did not reach post-lib bundle check (case-arm broken?); got: $out"; return 1; }
	[[ "$out" != *unsafe* && "$out" != *"checksum mismatch"* ]] \
		|| { echo "C: integrity die despite --no-integrity — flag not honored at tier-3; got: $out"; return 1; }
}

# ---------------------------------------------------------------------------
# 17. MEDIUM regression: OXPULSE_UPGRADE_NO_INTEGRITY must seed ALLOW_UNVERIFIED,
#     so the env-var escape hatch gates the SHA256SUMS *host-script* guard (read via
#     ALLOW_UNVERIFIED, later in the run) too — not only the tier-3 lib verify. Before
#     the fix the env var passed lib-fetch but ALLOW_UNVERIFIED stayed hard-0, so an
#     operator who set only the env var hard-died at the host-script guard, contradicting
#     the header comment that presents the env var and --allow-unverified/--no-integrity
#     as interchangeable. A source-level guard (the host-script guard is ~1000 lines past
#     a valid installed bundle, so an e2e run cannot reach it without a full docker mock —
#     the repo's other structural invariants are grep-asserted the same way, e.g. #3/#10).
#     Non-vacuous: reverting to `ALLOW_UNVERIFIED=0` reddens BOTH assertions.
# ---------------------------------------------------------------------------
@test "upgrade.sh seeds ALLOW_UNVERIFIED from OXPULSE_UPGRADE_NO_INTEGRITY (env var gates the SHA256SUMS host-script guard)" {
	local UPGRADE="$REPO_ROOT/upgrade.sh"
	[ -f "$UPGRADE" ] || skip "upgrade.sh not present"
	grep -Eq 'ALLOW_UNVERIFIED="\$\{OXPULSE_UPGRADE_NO_INTEGRITY:-0\}"' "$UPGRADE" \
		|| { echo "ALLOW_UNVERIFIED is not seeded from OXPULSE_UPGRADE_NO_INTEGRITY — env var will not reach the SHA256SUMS host-script guard"; return 1; }
	# Negate via `run <cmd>; [ "$status" -ne 0 ]` (not a bare `! grep … || { …; return 1; }`,
	# SC2314-adjacent) — immune to a future statement being appended after it
	# (which would silently mask a violation, per the same bare-`!` hazard fixed above).
	# A stale 'ALLOW_UNVERIFIED=0' init would strand the env-var escape hatch before
	# the host-script guard — must NOT be present.
	run grep -Eq '^ALLOW_UNVERIFIED=0$' "$UPGRADE"
	[ "$status" -ne 0 ]
}

# ===========================================================================
# P0 supply-chain review-fix follow-up (2 HIGH from the PR #353 council):
#   HIGH #1 — install.sh's tier-4 _install_lib_source failed OPEN when a
#     checksums file resolved but had no line for $name: the guard short-
#     circuited and execution fell through to `. "$tmp"`, sourcing unverified
#     code as root. install.sh now dies on that case unless --no-integrity.
#   HIGH #2 — _source_lib (awk field-exact, "./"-tolerant) and _stage_lib (grep
#     suffix-anchored) had already DIVERGED on manifest-entry matching. Both
#     now route through the shared _lookup_expected_hash; install.sh's inline
#     lookup was switched to the same awk form so all three agree.
# Both tests below extract the REAL shipped function (not a hand-rolled bash -c
# reimplementation, unlike tests #5-#7 above) so a revert of either fix goes RED.
# ===========================================================================

# ---------------------------------------------------------------------------
# HIGH #1 regression: install.sh's real _install_lib_source, manifest resolves
# but omits the target's entry -> fail-closed die; --no-integrity overrides.
# ---------------------------------------------------------------------------
@test "_install_lib_source tier-4 (real install.sh code): manifest resolves but omits entry -> fail-closed die; --no-integrity overrides" {
	[ -f "$INSTALL" ] || skip "install.sh missing"

	# Extract the REAL _install_lib_source function into its own sourceable file,
	# stubbing log/warn/die so it runs standalone. BASH_SOURCE[0] inside a function
	# resolves to the file where the function was DEFINED (verified empirically),
	# so placing this extracted file at $SRCDIR/install.sh with a sibling
	# $SRCDIR/lib/lib-checksums.txt makes the function's own local-checksums-file
	# lookup (tier "${_ck_src_dir:-.}/lib/lib-checksums.txt") resolve it locally —
	# no need to mock the remote checksums fallback fetch.
	local SRCDIR="$TMP/install_srcdir"
	mkdir -p "$SRCDIR/lib"
	local SRCFN="$SRCDIR/install.sh"
	{
		echo 'log()  { :; }'
		echo 'warn() { echo "WARN: $*" >&2; }'
		echo 'die()  { echo "DIED: $*" >&2; exit 9; }'
		awk '/^_install_lib_source\(\)/{f=1} f{print} /^}$/ && f{exit}' "$INSTALL"
	} > "$SRCFN"
	bash -n "$SRCFN" || { echo "extracted _install_lib_source: syntax error"; false; }

	local FIXTURE_NAME="install-preflight.sh"
	local FETCHED_SRC="$SRCDIR/fetched-module-src.sh"
	printf 'echo FETCHED_OK\n' > "$FETCHED_SRC"
	local ZERO="0000000000000000000000000000000000000000000000000000000000000000"
	# Manifest RESOLVES (real, readable file) but has a line for a DIFFERENT file
	# only — the exact review-HIGH bypass: some other entry present, target's absent.
	printf '%s  some-other-file.sh\n' "$ZERO" > "$SRCDIR/lib/lib-checksums.txt"

	local HARNESS="$TMP/install_harness.sh"
	cat > "$HARNESS" <<'HEOF'
#!/usr/bin/env bash
set -uo pipefail
log()  { :; }
warn() { echo "WARN: $*" >&2; }
die()  { echo "DIED: $*" >&2; exit 9; }
curl() {
    local _o="" _n="" a
    for a in "$@"; do [[ "$_n" == o ]] && { _o="$a"; _n=""; }; [[ "$a" == "-o" ]] && _n=o; done
    cp "$FETCHED_SRC" "$_o"
    return 0
}
# shellcheck source=/dev/null
source "$SRCFN"
_install_lib_source "$NAME"
HEOF

	_drive() {  # NO_INTEGRITY(0/1) -> combined output
		env SRCFN="$SRCFN" FETCHED_SRC="$FETCHED_SRC" \
			REPO_RAW="https://raw.example.test/oxpulse-partner-edge/main" \
			INSTALL_LIB_DIR="$SRCDIR/nonexistent-installdir" \
			NAME="$FIXTURE_NAME" NO_INTEGRITY="$1" \
			bash "$HARNESS" 2>&1
	}

	# NOENTRY, no override: fail-closed die, module NOT sourced.
	local out
	out=$(_drive 0) || true
	echo "$out" | grep -q 'FETCHED_OK' \
		&& { echo "NOENTRY: sourced despite the manifest omitting the entry! out: $out"; false; }
	echo "$out" | grep -qi 'without a verified checksum is unsafe' \
		|| { echo "NOENTRY: expected fail-closed die; got: $out"; false; }

	# NOENTRY + --no-integrity (NO_INTEGRITY=1): warns and proceeds (sources).
	out=$(_drive 1) || true
	echo "$out" | grep -q 'FETCHED_OK' \
		|| { echo "NOENTRY-OVERRIDE: expected FETCHED_OK with --no-integrity; got: $out"; false; }
	echo "$out" | grep -qi 'no-integrity acknowledged' \
		|| { echo "NOENTRY-OVERRIDE: expected an operator-accepts-risk warn; got: $out"; false; }
}

# ---------------------------------------------------------------------------
# HIGH #2 regression: a manifest line with a "./" prefix (the common
# `find`-generated form, e.g. `<hash>  ./reconcile.sh`) must resolve IDENTICALLY
# across all three tier-3/tier-4 resolvers — _source_lib, _stage_lib (both via
# the shared _lookup_expected_hash), and install.sh:_install_lib_source (its own
# inline awk, switched to the same field-exact form). Before the fix, _source_lib
# (awk) resolved a "./"-prefixed line while _stage_lib and install.sh (grep
# suffix-anchored) did not — a security-control divergence for the identical file.
# ---------------------------------------------------------------------------
@test "manifest entry with './' prefix resolves identically in _source_lib, _stage_lib, and _install_lib_source (real code)" {
	local UPGRADE="$REPO_ROOT/upgrade.sh"
	[ -f "$UPGRADE" ] && [ -f "$INSTALL" ] || skip "upgrade.sh / install.sh missing"

	local FIXTURE="$TMP/dotfixture.sh"
	printf 'echo SOURCED_OK\n' > "$FIXTURE"
	local HASH
	HASH=$(sha256sum "$FIXTURE" | awk '{print $1}')
	# The dot-prefixed manifest form under test.
	local CK_DOT="$TMP/ck_dot.txt"; printf '%s  ./reconcile.sh\n' "$HASH" > "$CK_DOT"

	# --- _source_lib (upgrade.sh) ---------------------------------------------
	local SRC_FN="$TMP/source_lib_fn.sh"
	{
		echo 'log()  { :; }'; echo 'warn() { echo "WARN: $*" >&2; }'
		echo 'die()  { echo "DIED: $*" >&2; exit 9; }'
		awk '/^_lookup_expected_hash\(\)/{f=1} f{print} /^}$/ && f{exit}' "$UPGRADE"
		awk '/^_source_lib\(\)/{f=1} f{print} /^}$/ && f{exit}' "$UPGRADE"
	} > "$SRC_FN"
	bash -n "$SRC_FN" || { echo "extracted _source_lib: syntax error"; false; }
	local SRC_HARNESS="$TMP/source_lib_harness.sh"
	cat > "$SRC_HARNESS" <<'HEOF'
#!/usr/bin/env bash
set -uo pipefail
log()  { :; }
warn() { echo "WARN: $*" >&2; }
die()  { echo "DIED: $*" >&2; exit 9; }
curl() {
    local _o="" _n="" a
    for a in "$@"; do [[ "$_n" == o ]] && { _o="$a"; _n=""; }; [[ "$a" == "-o" ]] && _n=o; done
    case "$*" in
        *lib-checksums.txt*|*SHA256SUMS*) cp "$MANIFEST" "$_o" ;;
        *) cp "$FIXTURE" "$_o" ;;
    esac
    return 0
}
# shellcheck source=/dev/null
source "$SRC_FN"
_source_lib "reconcile.sh" "/nonexistent/local" "/nonexistent/installed" \
    "https://raw.example.test/oxpulse-partner-edge/main/lib/reconcile.sh"
HEOF
	local src_out
	src_out=$(env SRC_FN="$SRC_FN" FIXTURE="$FIXTURE" MANIFEST="$CK_DOT" \
		REPO_RAW="https://raw.example.test/oxpulse-partner-edge/main" \
		INSTALL_LIB_DIR="$TMP/nonexistent-installdir" \
		bash "$SRC_HARNESS" 2>&1) || true
	echo "$src_out" | grep -q 'SOURCED_OK' \
		|| { echo "_source_lib: './'-prefixed entry did not resolve; got: $src_out"; false; }

	# --- _stage_lib (upgrade.sh) ----------------------------------------------
	local STAGE_FN="$TMP/stage_lib_fn.sh"
	{
		echo 'log()  { :; }'; echo 'warn() { echo "WARN: $*" >&2; }'
		echo 'die()  { echo "DIED: $*" >&2; exit 9; }'
		awk '/^_lookup_expected_hash\(\)/{f=1} f{print} /^}$/ && f{exit}' "$UPGRADE"
		awk '/^_stage_lib\(\)/{f=1} f{print} /^}$/ && f{exit}' "$UPGRADE"
	} > "$STAGE_FN"
	bash -n "$STAGE_FN" || { echo "extracted _stage_lib: syntax error"; false; }
	local STAGE_DEST="$TMP/stage_dest"; mkdir -p "$STAGE_DEST"
	local STAGE_HARNESS="$TMP/stage_lib_harness.sh"
	cat > "$STAGE_HARNESS" <<'HEOF'
#!/usr/bin/env bash
set -uo pipefail
log()  { :; }
warn() { echo "WARN: $*" >&2; }
die()  { echo "DIED: $*" >&2; exit 9; }
curl() {
    local _o="" _n="" a
    for a in "$@"; do [[ "$_n" == o ]] && { _o="$a"; _n=""; }; [[ "$a" == "-o" ]] && _n=o; done
    case "$*" in
        *lib-checksums.txt*) cp "$MANIFEST" "$_o" ;;
        *) cp "$FIXTURE" "$_o" ;;
    esac
    return 0
}
# shellcheck source=/dev/null
source "$STAGE_FN"
_stage_lib "reconcile.sh" "/nonexistent/local" "/nonexistent/installed" \
    "https://raw.example.test/oxpulse-partner-edge/main/lib/reconcile.sh" "$DEST"
echo "$?"
HEOF
	local stage_out
	stage_out=$(env STAGE_FN="$STAGE_FN" FIXTURE="$FIXTURE" MANIFEST="$CK_DOT" \
		REPO_RAW="https://raw.example.test/oxpulse-partner-edge/main" \
		INSTALL_LIB_DIR="$TMP/nonexistent-installdir" DEST="$STAGE_DEST" \
		bash "$STAGE_HARNESS" 2>&1) || true
	[[ -f "$STAGE_DEST/reconcile.sh" ]] \
		|| { echo "_stage_lib: './'-prefixed entry did not resolve; got: $stage_out"; false; }

	# --- _install_lib_source (install.sh) -------------------------------------
	local INST_SRCDIR="$TMP/install_dot_srcdir"; mkdir -p "$INST_SRCDIR/lib"
	local INST_FN="$INST_SRCDIR/install.sh"
	{
		echo 'log()  { :; }'; echo 'warn() { echo "WARN: $*" >&2; }'
		echo 'die()  { echo "DIED: $*" >&2; exit 9; }'
		awk '/^_install_lib_source\(\)/{f=1} f{print} /^}$/ && f{exit}' "$INSTALL"
	} > "$INST_FN"
	bash -n "$INST_FN" || { echo "extracted _install_lib_source: syntax error"; false; }
	# install.sh's manifest column matches on the fetched module's OWN basename
	# ($name), not "reconcile.sh" — reuse the same "./"-prefixed shape for a lib
	# install.sh actually resolves via this loader.
	printf '%s  ./install-preflight.sh\n' "$HASH" > "$INST_SRCDIR/lib/lib-checksums.txt"
	local INST_HARNESS="$TMP/install_dot_harness.sh"
	cat > "$INST_HARNESS" <<'HEOF'
#!/usr/bin/env bash
set -uo pipefail
log()  { :; }
warn() { echo "WARN: $*" >&2; }
die()  { echo "DIED: $*" >&2; exit 9; }
curl() {
    local _o="" _n="" a
    for a in "$@"; do [[ "$_n" == o ]] && { _o="$a"; _n=""; }; [[ "$a" == "-o" ]] && _n=o; done
    cp "$FIXTURE" "$_o"
    return 0
}
# shellcheck source=/dev/null
source "$INST_FN"
_install_lib_source "install-preflight.sh"
HEOF
	local inst_out
	inst_out=$(env INST_FN="$INST_FN" FIXTURE="$FIXTURE" \
		REPO_RAW="https://raw.example.test/oxpulse-partner-edge/main" \
		INSTALL_LIB_DIR="$INST_SRCDIR/nonexistent-installdir" NO_INTEGRITY=0 \
		bash "$INST_HARNESS" 2>&1) || true
	echo "$inst_out" | grep -q 'SOURCED_OK' \
		|| { echo "_install_lib_source: './'-prefixed entry did not resolve; got: $inst_out"; false; }
}
