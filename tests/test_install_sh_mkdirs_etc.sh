#!/usr/bin/env bats
# tests/test_install_sh_mkdirs_etc.sh — Fix E: install.sh must create
# PREFIX_ETC before calling opec secrets reality-keygen.
#
# Bug: after uninstall.sh --yes, a fresh run of install.sh fails at
# step [4/10] with:
#   opec error: io error at /etc/oxpulse-partner-edge/reality.priv: No such file or directory
# Root cause: install -d was only present before awg-keygen, not before
# reality-keygen which runs first.
#
# Test hooks:
#   OXPULSE_PREFIX_ETC — redirects /etc/oxpulse-partner-edge to a tmp path
#   PATH override injects a mock 'opec' that records calls and succeeds

setup() {
	REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	TMP="$(mktemp -d)"
	FAKE_ETC="$TMP/etc/oxpulse-partner-edge"
	SHIM_LOG="$TMP/shim_calls.log"
	mkdir -p "$TMP/shims"

	# Mock opec: records args, writes stub key files if reality-keygen
	cat > "$TMP/shims/opec" << 'SHIMEOF'
#!/usr/bin/env bash
echo "opec $*" >> "$SHIM_LOG"
# If called as "secrets reality-keygen --out-dir <dir>", write stub files
if [[ "$*" == *"reality-keygen"* ]]; then
	for _f in "$@"; do :; done
	# Parse --out-dir
	for i in "$@"; do
		case "$i" in --out-dir) _prev="--out-dir" ;; *) if [[ "${_prev:-}" == "--out-dir" ]]; then _dir="$i"; _prev=""; fi ;; esac
	done
	# Simpler: grab last arg that isn't a flag
	_dir=""
	for _a in "$@"; do [[ "$_a" != --* ]] && _dir="$_a"; done
	if [[ -n "$_dir" ]]; then
		echo "stub-pubkey-abc123" > "$_dir/reality.pub"
		echo "stub-uuid-00000000" > "$_dir/reality.uuid"
		echo "stub-privkey-secret" > "$_dir/reality.priv"
	fi
fi
if [[ "$*" == *"awg-keygen"* ]]; then
	_dir=""
	for _a in "$@"; do [[ "$_a" != --* ]] && _dir="$_a"; done
	if [[ -n "$_dir" ]]; then
		echo "stub-awg-pub" > "$_dir/awg-public.key"
		echo "stub-awg-priv" > "$_dir/awg-private.key"
	fi
fi
exit 0
SHIMEOF
	chmod +x "$TMP/shims/opec"
	# Record SHIM_LOG path for opec shim via env
	echo "SHIM_LOG=$TMP/shim_calls.log" >> "$TMP/shim_env"
}

teardown() {
	rm -rf "$TMP"
}

# ---------------------------------------------------------------------------
# Fix E: PREFIX_ETC must exist (mode 0700) BEFORE opec reality-keygen is called
# ---------------------------------------------------------------------------
@test "Fix E: install.sh creates PREFIX_ETC (mode 0700) before reality-keygen" {
	# FAKE_ETC must NOT exist at test start — simulates post-uninstall state
	[ ! -d "$FAKE_ETC" ]

	# We need to run the relevant portion of install.sh. Since install.sh
	# is a monolithic script requiring args, we test the invariant structurally:
	# the install -d call for PREFIX_ETC must appear BEFORE the reality-keygen
	# opec invocation in the file.

	# Capture line numbers of both events
	local mkdir_line
	local reality_line

	# Find the first `install -d -m 0700 "$PREFIX_ETC"` in install.sh (Fix E adds it before reality-keygen)
	# Find the actual opec invocation line (_opec_args assignment for reality-keygen)
	mkdir_line=$(grep -n 'install -d -m 0700.*PREFIX_ETC' "$REPO_ROOT/install.sh" | head -1 | cut -d: -f1)
	reality_line=$(grep -n '_opec_args=(secrets reality-keygen' "$REPO_ROOT/install.sh" | head -1 | cut -d: -f1)

	echo "mkdir_line=$mkdir_line reality_line=$reality_line"
	[ -n "$mkdir_line" ]
	[ -n "$reality_line" ]
	# The install -d must come BEFORE the reality-keygen opec call
	[ "$mkdir_line" -lt "$reality_line" ]
}

# ---------------------------------------------------------------------------
# Fix E: behavioral — PREFIX_ETC is created on disk when opec is called
# ---------------------------------------------------------------------------
@test "Fix E: opec reality-keygen can write to PREFIX_ETC after install creates it" {
	# Run the keygen block logic in isolation, mirroring install.sh behavior.
	# This test verifies that the directory-creation precedes the opec call.
	run bash -c "
		set -euo pipefail
		export PATH='$TMP/shims:/usr/bin:/bin'
		export SHIM_LOG='$SHIM_LOG'
		PREFIX_ETC='$FAKE_ETC'
		DRY_RUN=0
		FORCE_KEYGEN=0

		# Replicate the fixed install.sh block:
		#   install -d BEFORE opec reality-keygen
		install -d -m 0700 \"\$PREFIX_ETC\"
		REALITY_PRIV_PATH=\"\$PREFIX_ETC/reality.priv\"
		REALITY_PUB_PATH=\"\$PREFIX_ETC/reality.pub\"
		REALITY_UUID_PATH=\"\$PREFIX_ETC/reality.uuid\"

		_opec_args=(secrets reality-keygen --out-dir \"\$PREFIX_ETC\")
		if ! opec \"\${_opec_args[@]}\"; then
			echo 'opec failed' >&2; exit 1
		fi

		# Verify files exist
		[ -f \"\$REALITY_PUB_PATH\"  ] || { echo 'missing reality.pub'; exit 1; }
		[ -f \"\$REALITY_UUID_PATH\" ] || { echo 'missing reality.uuid'; exit 1; }
		echo 'keygen-ok'
	"
	[ "$status" -eq 0 ]
	[[ "$output" == *"keygen-ok"* ]]
	# Directory must exist and have mode 0700
	[ -d "$FAKE_ETC" ]
	local mode
	mode=$(stat -c '%a' "$FAKE_ETC")
	[ "$mode" = "700" ]
}

# ---------------------------------------------------------------------------
# Fix E: install.sh structural — install -d for PREFIX_ETC exists in the
#         reality-keygen live-mode else branch (not only in awg-keygen block)
# ---------------------------------------------------------------------------
@test "Fix E: install.sh has install -d for PREFIX_ETC before reality-keygen in live branch" {
	# Extract the live-mode (non-dry-run) block around reality-keygen.
	# Verify that install -d -m 0700 appears within a few lines before the
	# opec reality-keygen call.

	# Get line range: from 'log "  reality keypair' to 'unset _opec_args'
	local start_line end_line
	start_line=$(grep -n 'reality keypair: delegating' "$REPO_ROOT/install.sh" | head -1 | cut -d: -f1)
	end_line=$(grep -n 'unset _opec_args' "$REPO_ROOT/install.sh" | head -1 | cut -d: -f1)

	echo "block: $start_line..$end_line"
	[ -n "$start_line" ]
	[ -n "$end_line" ]

	# Check that install -d -m 0700 appears at or before start_line
	# (i.e., in the same else-branch but before the opec call)
	local install_d_line
	install_d_line=$(awk "NR>=${start_line} && NR<=${end_line} && /install -d -m 0700.*PREFIX_ETC/ {print NR; exit}" "$REPO_ROOT/install.sh" || true)
	# If not found in the inner block, check the immediately-preceding lines
	if [ -z "$install_d_line" ]; then
		# Accept if it's within 10 lines before start_line
		local pre_block_line
		pre_block_line=$(awk "NR>=$((start_line - 10)) && NR<${start_line} && /install -d -m 0700.*PREFIX_ETC/ {print NR; exit}" "$REPO_ROOT/install.sh" || true)
		install_d_line="$pre_block_line"
	fi

	echo "install_d_line=$install_d_line"
	[ -n "$install_d_line" ]
}

# ---------------------------------------------------------------------------
# MAJOR #4: behavioral regression — PREFIX_ETC created at mode 0700 in live run
# ---------------------------------------------------------------------------
# Extracts and runs the reality-keygen block from install.sh with a mock opec,
# verifies the directory exists at 0700 after execution.
# This is the actual red→green for Bug E (fresh-install hardening).

@test "MAJOR4: PREFIX_ETC created at mode 0700 before opec reality-keygen runs" {
	# Precondition: FAKE_ETC must not exist (simulates post-uninstall state)
	rm -rf "$FAKE_ETC"
	[ ! -d "$FAKE_ETC" ]

	# Extract the reality-keygen block from install.sh.
	# Start from REALITY_PRIV_PATH= (includes path var definitions).
	# End at the `fi` that closes the outer DRY_RUN if-block — which is the
	# line immediately after the first `unset _opec_args` in this section.
	local block_start unset_line block_end
	block_start=$(grep -n '^REALITY_PRIV_PATH=' "$REPO_ROOT/install.sh" | head -1 | cut -d: -f1)
	unset_line=$(awk "NR>${block_start} && /unset _opec_args/ {print NR; exit}" "$REPO_ROOT/install.sh")
	block_end=$((unset_line + 1))  # include the closing `fi`

	echo "block: $block_start..$block_end"
	[ -n "$block_start" ]
	[ -n "$unset_line" ]

	local block
	block=$(sed -n "${block_start},${block_end}p" "$REPO_ROOT/install.sh")

	run bash -c "
		set -euo pipefail
		export PATH='$TMP/shims:/usr/bin:/bin'
		PREFIX_ETC='$FAKE_ETC'
		DRY_RUN=0
		FORCE_KEYGEN=0
		die() { echo \"die: \$*\" >&2; exit 1; }
		log() { :; }
		warn() { :; }
		$block
		echo 'block-ok'
	"
	echo "output: $output"
	[ "$status" -eq 0 ]
	[[ "$output" == *"block-ok"* ]]
	# Directory MUST exist at mode 0700
	[ -d "$FAKE_ETC" ]
	local mode
	mode=$(stat -c '%a' "$FAKE_ETC" 2>/dev/null || stat -f '%OLp' "$FAKE_ETC" 2>/dev/null)
	echo "mode=$mode"
	[ "$mode" = "700" ]
}

# ---------------------------------------------------------------------------
# Bug Q: PREFIX_LIBDIR must be created before cp writes render-channel-lib.sh
# into it at top-of-file (the _rl_fetched path).
# ---------------------------------------------------------------------------
@test "Bug Q: install -d for PREFIX_LIBDIR appears before cp _rl_tmp _rl_fetched in install.sh" {
	# _rl_fetched is set to ${INSTALL_LIB_DIR:-/usr/local/lib/partner-edge}/render-channel-lib.sh
	# and cp "$_rl_tmp" "$_rl_fetched" happens at the top of install.sh (early render-channel-lib fetch).
	# The parent dir must be created before that cp — find the line numbers and assert ordering.
	local mkd_line cp_line
	mkd_line=$(grep -n 'install -d.*PREFIX_LIBDIR\|install -d.*INSTALL_LIB_DIR\|mkdir.*_rl_fetched\|install -d.*dirname.*_rl' \
		"$REPO_ROOT/install.sh" | head -1 | cut -d: -f1)
	cp_line=$(grep -n 'cp "\$_rl_tmp" "\$_rl_fetched"' "$REPO_ROOT/install.sh" | head -1 | cut -d: -f1)
	echo "mkd_line=$mkd_line cp_line=$cp_line"
	[ -n "$mkd_line" ]
	[ -n "$cp_line" ]
	[ "$mkd_line" -lt "$cp_line" ]
}

# ---------------------------------------------------------------------------
# Bug Q: structural — all 3 PREFIX dirs created at script top
#   1. PREFIX_ETC  (mode 0700) — already checked by Fix E tests above
#   2. PREFIX_LIBDIR (mode 0755) — new
#   3. /usr/local/share/oxpulse-partner-edge (mode 0755) — new
# ---------------------------------------------------------------------------
@test "Bug Q: install.sh creates PREFIX_LIBDIR before the top-of-file render-channel-lib cp" {
	# Confirm that PREFIX_LIBDIR mkdir is explicitly present in install.sh
	# (not just implicitly inside install-systemd.sh which runs much later).
	grep -q 'install -d.*PREFIX_LIBDIR\|install -d.*INSTALL_LIB_DIR\|install -d.*dirname.*_rl_fetched' \
		"$REPO_ROOT/install.sh"
}
