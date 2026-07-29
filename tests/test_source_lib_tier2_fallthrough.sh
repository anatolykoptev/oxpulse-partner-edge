#!/usr/bin/env bats
# tests/test_source_lib_tier2_fallthrough.sh — PR3 (v0.14.5 installer/upgrade
# robustness arc): _source_lib's manifest resolution used to STOP at the first
# manifest candidate that merely RESOLVED (was readable / fetched OK), even if
# that candidate had NO ENTRY for the lib being sourced. On a live v0.14.4 fleet
# rollout this permanently fail-closed a brand-new lib on any box whose tier-2
# INSTALL_LIB_DIR/lib-checksums.txt was stale (predates the new lib): the stale
# manifest resolved, had no line for the new file, and the resolver died right
# there — it never got a chance to try the fresh tier-3 remote manifest, which
# DID have the entry.
#
# The fix: walk manifest candidates in tier order (adjacent -> installed ->
# remote) and only STOP at a candidate that CONTAINS an entry for this lib's
# name. A candidate that resolves but lacks the entry is "no opinion" and falls
# through to the next tier. The one thing that must NEVER fall through: a
# candidate whose entry is PRESENT but WRONG (mismatch) is terminal immediately
# — this is the security-critical asymmetry (see upgrade.sh's THREAT MODEL
# header on _source_lib). These tests pin BOTH directions:
#   MISSING entry (in an otherwise-resolved manifest) -> fall through.
#   MISMATCHED entry (present but wrong hash)         -> fail closed, no fallthrough.
#
# All tests extract the REAL _source_lib (+ _lookup_expected_hash) from
# upgrade.sh (not a hand-copy), matching the house style in
# tests/test_install_lib_checksum.sh's "_source_lib tier-3" behavioral test —
# a revert of the fallthrough fix goes RED here.

setup() {
	REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	TMP="$(mktemp -d)"
	UPGRADE="$REPO_ROOT/upgrade.sh"

	# Extract the real _lookup_expected_hash + _source_lib into a sourceable file,
	# stubbing log/warn/die so it runs standalone (mirrors test_install_lib_checksum.sh).
	SRCFN="$TMP/source_lib_fn.sh"
	{
		echo 'log()  { :; }'
		echo 'warn() { echo "WARN: $*" >&2; }'
		echo 'die()  { echo "DIED: $*" >&2; exit 9; }'
		awk '/^_lookup_expected_hash\(\)/{f=1} f{print} /^}$/ && f{exit}' "$UPGRADE"
		awk '/^_source_lib\(\)/{f=1} f{print} /^}$/ && f{exit}' "$UPGRADE"
	} > "$SRCFN"
	bash -n "$SRCFN"

	# Fixture lib content _source_lib sources on a successful verify, and its hash.
	LIB_FIXTURE="$TMP/fixture-lib.sh"
	printf 'echo SOURCED_OK\n' > "$LIB_FIXTURE"
	FIX_HASH=$(sha256sum "$LIB_FIXTURE" | awk '{print $1}')
	ZERO="0000000000000000000000000000000000000000000000000000000000000000"

	# Tier-2 install dir (a REAL directory the resolver can find lib-checksums.txt in).
	INSTALL_DIR="$TMP/installed-lib-dir"
	mkdir -p "$INSTALL_DIR"

	CURL_LOG="$TMP/curl.log"

	# Harness: mock curl (manifest URL -> serve $MANIFEST if set+readable, else fail;
	# any other URL -> serve the fixture lib), source the extracted _source_lib, and
	# invoke it with non-existent local/installed LIB paths so it always takes tier-3
	# for the lib content itself (the manifest resolution under test is independent
	# of that — it walks its OWN adjacent/INSTALL_LIB_DIR/remote candidates).
	HARNESS="$TMP/harness.sh"
	cat > "$HARNESS" <<'HEOF'
#!/usr/bin/env bash
set -uo pipefail
log()  { :; }
warn() { echo "WARN: $*" >&2; }
die()  { echo "DIED: $*" >&2; exit 9; }
curl() {
    echo "CALL $*" >> "$CURL_LOG"
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

	RAW_LIB="https://raw.example.test/oxpulse-partner-edge/main/lib/reconcile.sh"
}

teardown() {
	rm -rf "$TMP"
}

# _drive MANIFEST NOINT -> combined output (harness may exit non-zero). Runs
# _source_lib("reconcile.sh") against tier-1 = $TMP/lib/lib-checksums.txt (only
# present if the test created it), tier-2 = $INSTALL_DIR/lib-checksums.txt (only
# present if the test wrote one), tier-3 remote = $MANIFEST served by mocked curl.
_drive() {
	: > "$CURL_LOG"
	env SRCFN="$SRCFN" LIB_FIXTURE="$LIB_FIXTURE" CURL_LOG="$CURL_LOG" \
		REPO_RAW="https://raw.example.test/oxpulse-partner-edge/main" \
		RELEASES_BASE="https://rel.example.test/oxpulse-partner-edge/releases/download" \
		OXPULSE_UPGRADE_TAG="v9.9.9" \
		INSTALL_LIB_DIR="$INSTALL_DIR" \
		NAME="reconcile.sh" RAW="$RAW_LIB" MANIFEST="$1" OXPULSE_UPGRADE_NO_INTEGRITY="$2" \
		bash "$HARNESS" 2>&1
}

# ---------------------------------------------------------------------------
# 1. FALLTHROUGH: tier-2 resolves but lacks the entry -> falls through to a
#    successfully-fetched remote manifest that DOES have a matching entry ->
#    lib is sourced, no die. This is the exact fleet-incident scenario: a
#    stale tier-2 lib-checksums.txt that predates the new lib.
# ---------------------------------------------------------------------------
@test "fallthrough: tier-2 resolves without entry, remote manifest has matching entry -> sourced" {
	printf '%s  some-other-file.sh\n' "$ZERO" > "$INSTALL_DIR/lib-checksums.txt"
	local remote_match="$TMP/remote_match.txt"
	printf '%s  reconcile.sh\n' "$FIX_HASH" > "$remote_match"

	local out
	out=$(_drive "$remote_match" 0) || true
	echo "$out" | grep 'SOURCED_OK' >/dev/null \
		|| { echo "expected SOURCED_OK via remote fallthrough; got: $out"; false; }
	# Prove the remote manifest fetch actually happened (fallthrough occurred, not
	# a silent tier-2 acceptance).
	grep -q 'lib-checksums.txt' "$CURL_LOG" \
		|| { echo "expected a remote lib-checksums.txt fetch attempt; curl log: $(cat "$CURL_LOG")"; false; }
}

# ---------------------------------------------------------------------------
# 2. MISMATCH-TERMINAL (negative control, security-critical): tier-2 resolves
#    and HAS an entry, but it's WRONG -> dies immediately, even though the
#    remote fallback manifest (if consulted) would have had a CORRECT entry.
#    Proves a mismatch is NEVER "rescued" by trying another tier, and that the
#    remote manifest is never even fetched once tier-2's (wrong) entry is found.
# ---------------------------------------------------------------------------
@test "mismatch is terminal: tier-2 has wrong entry -> die, never falls through to a correct remote entry" {
	printf '%s  reconcile.sh\n' "$ZERO" > "$INSTALL_DIR/lib-checksums.txt"
	local remote_would_be_correct="$TMP/remote_correct.txt"
	printf '%s  reconcile.sh\n' "$FIX_HASH" > "$remote_would_be_correct"

	local out
	out=$(_drive "$remote_would_be_correct" 0) || true
	echo "$out" | grep -i 'checksum mismatch' >/dev/null \
		|| { echo "expected a terminal mismatch die; got: $out"; false; }
	echo "$out" | grep 'SOURCED_OK' >/dev/null \
		&& { echo "sourced despite a tier-2 mismatch — mismatch must never be rescued by another tier! out: $out"; false; }
	# The remote manifest must NEVER have been fetched — the search terminated at
	# tier-2's mismatched entry, it did not continue.
	grep -q 'lib-checksums.txt' "$CURL_LOG" \
		&& { echo "remote manifest was fetched after a tier-2 mismatch — fallthrough leaked past a terminal mismatch! curl log: $(cat "$CURL_LOG")"; false; }
	true
}

# ---------------------------------------------------------------------------
# 3. ALL-TIERS-MISS: tier-2 resolves but lacks the entry, AND the remote
#    fallback manifest ALSO resolves but lacks the entry -> fail-closed (die),
#    unless OXPULSE_UPGRADE_NO_INTEGRITY=1, which still sources with a warn.
# ---------------------------------------------------------------------------
@test "all tiers miss the entry: fail-closed die; NO_INTEGRITY override still sources" {
	printf '%s  some-other-file.sh\n' "$ZERO" > "$INSTALL_DIR/lib-checksums.txt"
	local remote_noentry="$TMP/remote_noentry.txt"
	printf '%s  some-other-file.sh\n' "$ZERO" > "$remote_noentry"

	local out
	out=$(_drive "$remote_noentry" 0) || true
	echo "$out" | grep -i 'unsafe' >/dev/null \
		|| { echo "expected fail-closed 'unsafe' die when no tier has the entry; got: $out"; false; }
	echo "$out" | grep 'SOURCED_OK' >/dev/null \
		&& { echo "sourced despite no tier having the entry! out: $out"; false; }

	out=$(_drive "$remote_noentry" 1) || true
	echo "$out" | grep 'SOURCED_OK' >/dev/null \
		|| { echo "expected SOURCED_OK with OXPULSE_UPGRADE_NO_INTEGRITY=1 override; got: $out"; false; }
	echo "$out" | grep -i 'operator accepts risk' >/dev/null \
		|| { echo "expected an operator-accepts-risk warn with the override; got: $out"; false; }
}

# ---------------------------------------------------------------------------
# 4. REGRESSION: tier-1 (adjacent) has a matching entry -> sources immediately,
#    NO remote manifest fetch attempted at all. Proves the fallthrough fix did
#    not introduce a needless network call when tier-1 already resolves cleanly.
# ---------------------------------------------------------------------------
@test "tier-1 resolves cleanly: sources immediately, no remote manifest fetch" {
	# BASH_SOURCE[0] inside the extracted _source_lib resolves to $SRCFN's own
	# directory ($TMP), so $TMP/lib/lib-checksums.txt IS the tier-1 "adjacent
	# checkout" candidate for this harness.
	mkdir -p "$TMP/lib"
	printf '%s  reconcile.sh\n' "$FIX_HASH" > "$TMP/lib/lib-checksums.txt"

	local out
	out=$(_drive "" 0) || true
	echo "$out" | grep 'SOURCED_OK' >/dev/null \
		|| { echo "expected SOURCED_OK via tier-1; got: $out"; false; }
	grep -q 'lib-checksums.txt' "$CURL_LOG" \
		&& { echo "remote manifest was fetched despite tier-1 already resolving cleanly — needless network call! curl log: $(cat "$CURL_LOG")"; false; }
	true
}
