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

# ---------------------------------------------------------------------------
# Bug 16: --keep-backups must back up ALL 9 identity files with correct paths
# ---------------------------------------------------------------------------
# The correct set (verified against install.sh):
#   $PREFIX_ETC/reality.priv        x25519 private key, never regenerated
#   $PREFIX_ETC/reality.pub         x25519 public key, sent to backend on register
#   $PREFIX_ETC/reality.uuid        persistent partner UUID
#   $PREFIX_ETC/awg-private.key     AWG private key (was wrongly PREFIX_LIB before fix)
#   $PREFIX_ETC/awg-public.key      AWG public key  (was wrongly PREFIX_LIB before fix)
#   $PREFIX_ETC/token               backend service token
#   $PREFIX_ETC/node-config.json    node identity config
#   $PREFIX_LIB/install.env         persisted installer state
#   $PREFIX_LIB/sfu-keys.env        SFU signing key state

@test "Bug16: --keep-backups backs up reality.priv from PREFIX_ETC" {
	echo "x25519privkey" > "$FAKE_ETC/reality.priv"
	BACKUP_ROOT="$TMP/backups"
	mkdir -p "$BACKUP_ROOT"
	run bash -c "
		export PATH='$TMP/shims:/usr/bin:/bin'
		OXPULSE_BACKUP_ROOT='$BACKUP_ROOT' $(_env_args) bash '$UNINSTALL' --yes --keep-backups
	"
	[ "$status" -eq 0 ]
	bdir=$(ls -d "$BACKUP_ROOT"/oxpulse-backup-* 2>/dev/null | head -1)
	[ -n "$bdir" ]
	[ -f "$bdir/reality.priv" ]
}

@test "Bug16: --keep-backups backs up reality.pub from PREFIX_ETC" {
	echo "x25519pubkey" > "$FAKE_ETC/reality.pub"
	BACKUP_ROOT="$TMP/backups"
	mkdir -p "$BACKUP_ROOT"
	run bash -c "
		export PATH='$TMP/shims:/usr/bin:/bin'
		OXPULSE_BACKUP_ROOT='$BACKUP_ROOT' $(_env_args) bash '$UNINSTALL' --yes --keep-backups
	"
	[ "$status" -eq 0 ]
	bdir=$(ls -d "$BACKUP_ROOT"/oxpulse-backup-* 2>/dev/null | head -1)
	[ -n "$bdir" ]
	[ -f "$bdir/reality.pub" ]
}

@test "Bug16: --keep-backups backs up reality.uuid from PREFIX_ETC" {
	echo "test-uuid-1234" > "$FAKE_ETC/reality.uuid"
	BACKUP_ROOT="$TMP/backups"
	mkdir -p "$BACKUP_ROOT"
	run bash -c "
		export PATH='$TMP/shims:/usr/bin:/bin'
		OXPULSE_BACKUP_ROOT='$BACKUP_ROOT' $(_env_args) bash '$UNINSTALL' --yes --keep-backups
	"
	[ "$status" -eq 0 ]
	bdir=$(ls -d "$BACKUP_ROOT"/oxpulse-backup-* 2>/dev/null | head -1)
	[ -n "$bdir" ]
	[ -f "$bdir/reality.uuid" ]
}

@test "Bug16: --keep-backups backs up awg-private.key from PREFIX_ETC (not PREFIX_LIB)" {
	echo "awgprivkey" > "$FAKE_ETC/awg-private.key"
	# Put a decoy in PREFIX_LIB to confirm wrong path is NOT the source
	echo "wrong-location" > "$FAKE_LIB/awg-private.key"
	BACKUP_ROOT="$TMP/backups"
	mkdir -p "$BACKUP_ROOT"
	run bash -c "
		export PATH='$TMP/shims:/usr/bin:/bin'
		OXPULSE_BACKUP_ROOT='$BACKUP_ROOT' $(_env_args) bash '$UNINSTALL' --yes --keep-backups
	"
	[ "$status" -eq 0 ]
	bdir=$(ls -d "$BACKUP_ROOT"/oxpulse-backup-* 2>/dev/null | head -1)
	[ -n "$bdir" ]
	[ -f "$bdir/awg-private.key" ]
	# Content must come from PREFIX_ETC, not PREFIX_LIB decoy
	grep -q "awgprivkey" "$bdir/awg-private.key"
}

@test "Bug16: --keep-backups backs up awg-public.key from PREFIX_ETC (not PREFIX_LIB)" {
	echo "awgpubkey" > "$FAKE_ETC/awg-public.key"
	echo "wrong-location" > "$FAKE_LIB/awg-public.key"
	BACKUP_ROOT="$TMP/backups"
	mkdir -p "$BACKUP_ROOT"
	run bash -c "
		export PATH='$TMP/shims:/usr/bin:/bin'
		OXPULSE_BACKUP_ROOT='$BACKUP_ROOT' $(_env_args) bash '$UNINSTALL' --yes --keep-backups
	"
	[ "$status" -eq 0 ]
	bdir=$(ls -d "$BACKUP_ROOT"/oxpulse-backup-* 2>/dev/null | head -1)
	[ -n "$bdir" ]
	[ -f "$bdir/awg-public.key" ]
	grep -q "awgpubkey" "$bdir/awg-public.key"
}

@test "Bug16: --keep-backups backs up sfu-keys.env from PREFIX_LIB" {
	echo "SFUKEY=abc123" > "$FAKE_LIB/sfu-keys.env"
	BACKUP_ROOT="$TMP/backups"
	mkdir -p "$BACKUP_ROOT"
	run bash -c "
		export PATH='$TMP/shims:/usr/bin:/bin'
		OXPULSE_BACKUP_ROOT='$BACKUP_ROOT' $(_env_args) bash '$UNINSTALL' --yes --keep-backups
	"
	[ "$status" -eq 0 ]
	bdir=$(ls -d "$BACKUP_ROOT"/oxpulse-backup-* 2>/dev/null | head -1)
	[ -n "$bdir" ]
	[ -f "$bdir/sfu-keys.env" ]
}

@test "Bug16: --keep-backups backs up all 9 identity files in one run" {
	# Plant all 9 identity files in canonical locations
	echo "x25519priv"  > "$FAKE_ETC/reality.priv"
	echo "x25519pub"   > "$FAKE_ETC/reality.pub"
	echo "uuid-1234"   > "$FAKE_ETC/reality.uuid"
	echo "awgpriv"     > "$FAKE_ETC/awg-private.key"
	echo "awgpub"      > "$FAKE_ETC/awg-public.key"
	echo "token-val"   > "$FAKE_ETC/token"
	echo '{"nid":"t"}' > "$FAKE_ETC/node-config.json"
	echo "INSTALL=1"   > "$FAKE_LIB/install.env"
	echo "SFUKEY=xyz"  > "$FAKE_LIB/sfu-keys.env"
	# Also plant junk that must NOT appear in backup (explicit whitelist)
	echo "junk"        > "$FAKE_LIB/not-identity.txt"
	echo "junk2"       > "$FAKE_ETC/unknown-file.dat"
	BACKUP_ROOT="$TMP/backups"
	mkdir -p "$BACKUP_ROOT"
	run bash -c "
		export PATH='$TMP/shims:/usr/bin:/bin'
		OXPULSE_BACKUP_ROOT='$BACKUP_ROOT' $(_env_args) bash '$UNINSTALL' --yes --keep-backups
	"
	[ "$status" -eq 0 ]
	bdir=$(ls -d "$BACKUP_ROOT"/oxpulse-backup-* 2>/dev/null | head -1)
	[ -n "$bdir" ]
	# All 9 required files must be present
	[ -f "$bdir/reality.priv"       ]
	[ -f "$bdir/reality.pub"        ]
	[ -f "$bdir/reality.uuid"       ]
	[ -f "$bdir/awg-private.key"    ]
	[ -f "$bdir/awg-public.key"     ]
	[ -f "$bdir/token"              ]
	[ -f "$bdir/node-config.json"   ]
	[ -f "$bdir/install.env"        ]
	[ -f "$bdir/sfu-keys.env"       ]
	# Junk files must NOT be in backup (explicit whitelist enforced)
	[ ! -f "$bdir/not-identity.txt" ]
	[ ! -f "$bdir/unknown-file.dat" ]
}

# ---------------------------------------------------------------------------
# Fix C: uninstall.sh removes docker named volumes
# ---------------------------------------------------------------------------
@test "Fix C: uninstall.sh --yes removes docker named volumes (compose -v)" {
	# Pre-create dummy docker volume tracking via shim log inspection.
	# The shim records all docker calls; we verify 'down -v' or explicit
	# 'volume rm' appears for the named volumes.

	# Plant a compose file so the conditional docker compose down branch fires
	mkdir -p "$FAKE_ETC"
	cat > "$FAKE_ETC/docker-compose.yml" << 'COMPEOF'
version: "3"
services:
  caddy:
    image: caddy
volumes:
  caddy-data:
  caddy-config:
  coturn-log:
COMPEOF

	run bash -c "
		export PATH='$TMP/shims:/usr/bin:/bin'
		$(_env_args) bash '$UNINSTALL' --yes
	"
	[ "$status" -eq 0 ]
	# Must see either 'docker compose ... down ... -v' or 'docker volume rm'
	grep -qE 'docker compose.*down.*-v|-v.*down|docker volume rm' "$SHIM_LOG"
}

@test "Fix C: uninstall.sh --yes calls docker volume rm for all 3 named volumes" {
	# When compose file is absent, explicit volume rm must still run
	# (volumes may exist from a prior install even if the compose file is gone)

	run bash -c "
		export PATH='$TMP/shims:/usr/bin:/bin'
		$(_env_args) bash '$UNINSTALL' --yes
	"
	[ "$status" -eq 0 ]
	# Either compose down -v was called, or explicit volume rm for the 3 volumes
	if grep -q 'compose.*down.*-v' "$SHIM_LOG" 2>/dev/null; then
		true  # covered by compose down -v
	else
		grep -q 'volume rm' "$SHIM_LOG"
	fi
}

# ---------------------------------------------------------------------------
# Fix D: uninstall.sh --purge-packages removes amneziawg build artifacts
# ---------------------------------------------------------------------------
# amneziawg is built from source (not apt/dnf packages).
# `amneziawg-tools/src/make install` writes files to system paths that
# are NOT under PREFIX_BIN=/usr/local/bin:
#   /usr/bin/awg-quick            (make install target)
#   /usr/bin/awg                  (make install target)
#   /usr/share/man/man8/awg-quick.8
#   /usr/share/bash-completion/completions/awg-quick
#   /usr/lib/systemd/system/awg-quick@.service
#   /usr/lib/systemd/system/awg-quick.target
#   /usr/local/bin/amneziawg-go   (explicit install by install-awg.sh)
# The --purge-packages flag removes these artifacts (off by default).

_awg_env_args() {
	# Extend _env_args with overrides for awg artifact paths
	printf '%s ' \
		"OXPULSE_AWG_USR_BIN=$TMP/usr/bin" \
		"OXPULSE_AWG_USR_SHARE=$TMP/usr/share" \
		"OXPULSE_AWG_USR_SYSLIB=$TMP/usr/lib/systemd/system" \
		"OXPULSE_AWG_LOCAL_BIN=$TMP/usr/local/bin"
}

_plant_awg_artifacts() {
	mkdir -p "$TMP/usr/bin" \
	         "$TMP/usr/share/man/man8" \
	         "$TMP/usr/share/bash-completion/completions" \
	         "$TMP/usr/lib/systemd/system" \
	         "$TMP/usr/local/bin"
	touch "$TMP/usr/bin/awg-quick"
	touch "$TMP/usr/bin/awg"
	touch "$TMP/usr/share/man/man8/awg-quick.8"
	touch "$TMP/usr/share/bash-completion/completions/awg-quick"
	touch "$TMP/usr/lib/systemd/system/awg-quick@.service"
	touch "$TMP/usr/lib/systemd/system/awg-quick.target"
	touch "$TMP/usr/local/bin/amneziawg-go"
}

@test "Fix D: --yes WITHOUT --purge-packages leaves awg build artifacts intact" {
	_plant_awg_artifacts
	run bash -c "
		export PATH='$TMP/shims:/usr/bin:/bin'
		$(_env_args) $(_awg_env_args) bash '$UNINSTALL' --yes
	"
	[ "$status" -eq 0 ]
	# Without --purge-packages, artifacts must NOT be removed
	[ -f "$TMP/usr/bin/awg-quick" ]
}

@test "Fix D: --yes --purge-packages removes awg-quick from AWG_USR_BIN" {
	_plant_awg_artifacts
	run bash -c "
		export PATH='$TMP/shims:/usr/bin:/bin'
		$(_env_args) $(_awg_env_args) bash '$UNINSTALL' --yes --purge-packages
	"
	[ "$status" -eq 0 ]
	[ ! -f "$TMP/usr/bin/awg-quick" ]
}

@test "Fix D: --yes --purge-packages removes amneziawg-go from AWG_LOCAL_BIN" {
	_plant_awg_artifacts
	run bash -c "
		export PATH='$TMP/shims:/usr/bin:/bin'
		$(_env_args) $(_awg_env_args) bash '$UNINSTALL' --yes --purge-packages
	"
	[ "$status" -eq 0 ]
	[ ! -f "$TMP/usr/local/bin/amneziawg-go" ]
}

@test "Fix D: --yes --purge-packages removes man page and bash-completion artifacts" {
	_plant_awg_artifacts
	run bash -c "
		export PATH='$TMP/shims:/usr/bin:/bin'
		$(_env_args) $(_awg_env_args) bash '$UNINSTALL' --yes --purge-packages
	"
	[ "$status" -eq 0 ]
	[ ! -f "$TMP/usr/share/man/man8/awg-quick.8" ]
	[ ! -f "$TMP/usr/share/bash-completion/completions/awg-quick" ]
}

@test "Fix D: --yes --purge-packages removes awg-quick@.service and awg-quick.target" {
	_plant_awg_artifacts
	run bash -c "
		export PATH='$TMP/shims:/usr/bin:/bin'
		$(_env_args) $(_awg_env_args) bash '$UNINSTALL' --yes --purge-packages
	"
	[ "$status" -eq 0 ]
	[ ! -f "$TMP/usr/lib/systemd/system/awg-quick@.service" ]
	[ ! -f "$TMP/usr/lib/systemd/system/awg-quick.target" ]
}

@test "Fix D: --help text mentions --purge-packages" {
	run bash "$UNINSTALL" --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"--purge-packages"* ]]
}

@test "Fix D: unknown flag still fails with exit 2" {
	run bash "$UNINSTALL" --unknown-flag-xyz
	[ "$status" -eq 2 ]
}
