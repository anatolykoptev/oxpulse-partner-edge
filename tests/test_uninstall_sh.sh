#!/usr/bin/env bats
# tests/test_uninstall_sh.sh — Phase 5.7 Item 1: uninstall.sh verification.
#
# Covers:
#   1. Script exists at repo root
#   2. Passes shellcheck -S warning
#   3. --help exits 0 with usage text
#   4. 'n' confirmation aborts without --yes
#   5. --yes removes installed files (etc, lib, bins, sbin, systemd)
#   6. --yes --keep-backups moves identity files to backup dir
#   7. Final verification step runs find and reports residuals
#   8. systemctl called with --no-block for service stop
#   9. systemctl daemon-reload called after unit removal
#  10. docker compose down failure is tolerated (best-effort)

setup() {
	REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	UNINSTALL="$REPO_ROOT/uninstall.sh"
	TMP="$(mktemp -d)"

	FAKE_ETC="$TMP/etc/oxpulse-partner-edge"
	FAKE_LIB="$TMP/var/lib/oxpulse-partner-edge"
	FAKE_BIN="$TMP/usr/local/bin"
	FAKE_SBIN="$TMP/usr/local/sbin"
	FAKE_LIBDIR="$TMP/usr/local/lib/partner-edge"
	FAKE_SHARE="$TMP/usr/local/share/oxpulse-partner-edge"
	FAKE_SYSTEMD="$TMP/etc/systemd/system"

	mkdir -p "$FAKE_ETC" "$FAKE_LIB" "$FAKE_BIN" "$FAKE_SBIN" \
	         "$FAKE_LIBDIR" "$FAKE_SHARE/config" "$FAKE_SYSTEMD" \
	         "$TMP/shims"

	# Identity files
	echo "test-token" > "$FAKE_ETC/token"
	echo '{"node_id":"test"}' > "$FAKE_ETC/node-config.json"

	# Bins
	touch "$FAKE_BIN/opec" "$FAKE_BIN/partner-cli" \
	      "$FAKE_BIN/awg" "$FAKE_BIN/awg-quick"

	# Sbin scripts
	touch "$FAKE_SBIN/oxpulse-partner-edge-upgrade" \
	      "$FAKE_SBIN/oxpulse-partner-edge-refresh" \
	      "$FAKE_SBIN/oxpulse-channels-health-report" \
	      "$FAKE_SBIN/ghcr-auth-lib.sh" \
	      "$FAKE_SBIN/channel-render-lib.sh" \
	      "$FAKE_SBIN/render-channel-lib.sh"

	# Systemd units
	touch "$FAKE_SYSTEMD/oxpulse-partner-edge.service" \
	      "$FAKE_SYSTEMD/oxpulse-partner-edge-refresh.timer" \
	      "$FAKE_SYSTEMD/awg-quick@awg0.service"

	SHIM_LOG="$TMP/shim_calls.log"

	# Default shims (record calls, succeed)
	for cmd in systemctl docker ip; do
		printf '#!/usr/bin/env bash\necho "%s $*" >> "%s"\n' "$cmd" "$SHIM_LOG" \
			> "$TMP/shims/$cmd"
		chmod +x "$TMP/shims/$cmd"
	done

	# find: default returns nothing (clean state)
	printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/shims/find"
	chmod +x "$TMP/shims/find"
}

teardown() {
	rm -rf "$TMP"
}

# Common env overrides passed to subshells
_env_args() {
	printf '%s ' \
		"OXPULSE_PREFIX_ETC=$FAKE_ETC" \
		"OXPULSE_PREFIX_LIB=$FAKE_LIB" \
		"OXPULSE_PREFIX_BIN=$FAKE_BIN" \
		"OXPULSE_PREFIX_SBIN=$FAKE_SBIN" \
		"OXPULSE_PREFIX_LIBDIR=$FAKE_LIBDIR" \
		"OXPULSE_PREFIX_SHARE=$FAKE_SHARE" \
		"OXPULSE_SYSTEMD_DIR=$FAKE_SYSTEMD"
}

# ---------------------------------------------------------------------------
# 1. Script exists
# ---------------------------------------------------------------------------
@test "uninstall.sh exists at repo root" {
	[ -f "$UNINSTALL" ]
}

# ---------------------------------------------------------------------------
# 2. Shellcheck passes
# ---------------------------------------------------------------------------
@test "uninstall.sh passes shellcheck -S warning" {
	shellcheck -S warning "$UNINSTALL"
}

# ---------------------------------------------------------------------------
# 3. --help exits 0
# ---------------------------------------------------------------------------
@test "uninstall.sh --help exits 0 with usage text" {
	run bash "$UNINSTALL" --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"uninstall"* ]]
}

# ---------------------------------------------------------------------------
# 4. 'n' aborts
# ---------------------------------------------------------------------------
@test "uninstall.sh aborts when user answers n" {
	run bash -c "
		export PATH='$TMP/shims:/usr/bin:/bin'
		$(_env_args) bash '$UNINSTALL' <<< 'n'
	"
	[ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# 5. --yes removes files
# ---------------------------------------------------------------------------
@test "uninstall.sh --yes removes etc, lib, bins, sbin scripts, systemd units" {
	run bash -c "
		export PATH='$TMP/shims:/usr/bin:/bin'
		$(_env_args) bash '$UNINSTALL' --yes
	"
	[ "$status" -eq 0 ]
	[ ! -d "$FAKE_ETC" ]
	[ ! -d "$FAKE_LIB" ]
	[ ! -f "$FAKE_BIN/opec" ]
	[ ! -f "$FAKE_BIN/partner-cli" ]
	[ ! -f "$FAKE_SBIN/oxpulse-partner-edge-upgrade" ]
	[ ! -f "$FAKE_SBIN/ghcr-auth-lib.sh" ]
	[ ! -f "$FAKE_SBIN/channel-render-lib.sh" ]
	[ ! -f "$FAKE_SYSTEMD/oxpulse-partner-edge.service" ]
}

# ---------------------------------------------------------------------------
# 6. --keep-backups moves identity files to backup dir
# ---------------------------------------------------------------------------
@test "uninstall.sh --yes --keep-backups creates backup with identity files" {
	BACKUP_ROOT="$TMP/backups"
	mkdir -p "$BACKUP_ROOT"
	run bash -c "
		export PATH='$TMP/shims:/usr/bin:/bin'
		OXPULSE_BACKUP_ROOT='$BACKUP_ROOT' $(_env_args) bash '$UNINSTALL' --yes --keep-backups
	"
	[ "$status" -eq 0 ]
	# Backup dir created
	local found_backup
	found_backup=$(ls -d "$BACKUP_ROOT"/oxpulse-backup-* 2>/dev/null | head -1)
	[ -n "$found_backup" ]
	# At least one identity file preserved
	[ -f "$found_backup/token" ] || [ -f "$found_backup/node-config.json" ]
}

# ---------------------------------------------------------------------------
# 7. Verification step: find + report residuals
# ---------------------------------------------------------------------------
@test "uninstall.sh --yes reports residual files found by find" {
	# Override find to return a fake residual
	printf '#!/usr/bin/env bash\necho "/etc/oxpulse-fake-residual"\n' > "$TMP/shims/find"
	chmod +x "$TMP/shims/find"
	run bash -c "
		export PATH='$TMP/shims:/usr/bin:/bin'
		$(_env_args) bash '$UNINSTALL' --yes
	"
	[ "$status" -eq 0 ]
	[[ "$output" == *"residual"* || "$output" == *"oxpulse-fake-residual"* || "$output" == *"remaining"* ]]
}

# ---------------------------------------------------------------------------
# 8. systemctl --no-block used for stop/disable (no hang)
# ---------------------------------------------------------------------------
@test "uninstall.sh --yes calls systemctl with --no-block" {
	run bash -c "
		export PATH='$TMP/shims:/usr/bin:/bin'
		$(_env_args) bash '$UNINSTALL' --yes
	"
	[ "$status" -eq 0 ]
	grep -q -- '--no-block' "$SHIM_LOG"
}

# ---------------------------------------------------------------------------
# 9. systemctl daemon-reload after unit removal
# ---------------------------------------------------------------------------
@test "uninstall.sh --yes calls systemctl daemon-reload" {
	run bash -c "
		export PATH='$TMP/shims:/usr/bin:/bin'
		$(_env_args) bash '$UNINSTALL' --yes
	"
	[ "$status" -eq 0 ]
	grep -q 'daemon-reload' "$SHIM_LOG"
}

# ---------------------------------------------------------------------------
# 10. docker compose down failure is tolerated
# ---------------------------------------------------------------------------
@test "uninstall.sh --yes tolerates docker compose down failure" {
	# Override docker to always fail
	printf '#!/usr/bin/env bash\necho "docker $*" >> "%s"\nexit 1\n' \
		"$SHIM_LOG" > "$TMP/shims/docker"
	chmod +x "$TMP/shims/docker"
	run bash -c "
		export PATH='$TMP/shims:/usr/bin:/bin'
		$(_env_args) bash '$UNINSTALL' --yes
	"
	# Best-effort: must still exit 0
	[ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# BLOCKER 2: oxpulse-xray-update.sh is in PREFIX_BIN and must be removed
# ---------------------------------------------------------------------------
@test "uninstall.sh --yes removes oxpulse-xray-update.sh from PREFIX_BIN" {
	# Plant the file that install-systemd.sh writes to /usr/local/bin/
	touch "$FAKE_BIN/oxpulse-xray-update.sh"
	run bash -c "
		export PATH='$TMP/shims:/usr/bin:/bin'
		$(_env_args) bash '$UNINSTALL' --yes
	"
	[ "$status" -eq 0 ]
	[ ! -f "$FAKE_BIN/oxpulse-xray-update.sh" ]
}

# ---------------------------------------------------------------------------
# MAJOR 5: residual filter uses _backup_dir (timestamped path), not BACKUP_ROOT
# ---------------------------------------------------------------------------
@test "uninstall.sh --yes --keep-backups filter excludes backup dir not just BACKUP_ROOT" {
	# MAJOR 5: residual filter must exclude the BACKUP_ROOT subtree so backup
	# files don't appear as residuals. Test that step 6 does NOT emit
	# "remaining files found" when the only find result is inside BACKUP_ROOT.
	BACKUP_ROOT="$TMP/backups"
	mkdir -p "$BACKUP_ROOT"

	# Override find to return a fake file under BACKUP_ROOT subtree ONLY.
	# The find shim is only invoked in step 6 (the residual scan), so we can
	# use it to inject a controlled residual.
	# Note: find is also called in step 4 (backup *.env). Make the shim
	# context-aware by checking arguments.
	cat > "$TMP/shims/find" <<FINDSHIM
#!/usr/bin/env bash
# Emit fake residual only when called with /etc /var /usr (step 6 scan),
# not when called with PREFIX_LIB (step 4 backup)
if [[ "\$*" == *"/etc"* || "\$*" == *"/var"* || "\$*" == *"/usr"* ]]; then
    echo "$BACKUP_ROOT/oxpulse-backup-9999999/oxpulse-fake-residual"
fi
exit 0
FINDSHIM
	chmod +x "$TMP/shims/find"

	run bash -c "
		export PATH='$TMP/shims:/usr/bin:/bin'
		OXPULSE_BACKUP_ROOT='$BACKUP_ROOT' $(_env_args) bash '$UNINSTALL' --yes --keep-backups
	"
	[ "$status" -eq 0 ]
	# Step 6 must NOT report backup subtree as residuals
	[[ "$output" != *"remaining files found"* ]]
}
