#!/usr/bin/env bash
# uninstall.sh — Remove all files installed by install.sh on a partner-edge node.
#
# Usage:
#   sudo bash uninstall.sh [--yes] [--keep-backups]
#
# Flags:
#   --yes            Skip interactive confirmation.
#   --keep-backups   Move identity files (token, node-config.json, *.env,
#                    awg keys) to $BACKUP_ROOT/oxpulse-backup-<epoch>/
#                    instead of deleting them with the rest of the install.
#
# All removals are best-effort: individual failures are logged and the script
# continues. The only hard exit is "user said no".
#
# Phase 5.7 Item 1 — Reviewer Class F: uninstall.sh closes the gap where
# install.sh writes /usr/local/sbin/{ghcr-auth-lib.sh, channel-render-lib.sh,
# oxpulse-*} but no matching removal script existed.
set -uo pipefail

# ---------- Prefix overrides (test hooks) ----------
PREFIX_ETC="${OXPULSE_PREFIX_ETC:-/etc/oxpulse-partner-edge}"
PREFIX_LIB="${OXPULSE_PREFIX_LIB:-/var/lib/oxpulse-partner-edge}"
PREFIX_BIN="${OXPULSE_PREFIX_BIN:-/usr/local/bin}"
PREFIX_SBIN="${OXPULSE_PREFIX_SBIN:-/usr/local/sbin}"
PREFIX_LIBDIR="${OXPULSE_PREFIX_LIBDIR:-/usr/local/lib/partner-edge}"
PREFIX_SHARE="${OXPULSE_PREFIX_SHARE:-/usr/local/share/oxpulse-partner-edge}"
SYSTEMD_DIR="${OXPULSE_SYSTEMD_DIR:-/etc/systemd/system}"
# Backup root — overridable in tests to avoid writing to /root
BACKUP_ROOT="${OXPULSE_BACKUP_ROOT:-/root}"

log()  { printf '\033[32m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[33m!!\033[0m  %s\n' "$*" >&2; }

# ---------- Arg parsing ----------
OPT_YES=0
OPT_KEEP_BACKUPS=0

for _arg in "$@"; do
	case "$_arg" in
		--yes)           OPT_YES=1 ;;
		--keep-backups)  OPT_KEEP_BACKUPS=1 ;;
		-h|--help)
			cat >&2 <<'HELPEOF'
uninstall.sh — Remove all oxpulse-partner-edge install artifacts.

Usage: sudo bash uninstall.sh [--yes] [--keep-backups]

  --yes            Skip interactive confirmation.
  --keep-backups   Move identity files to /root/oxpulse-backup-<epoch>/
                   before removing the install directories.
  -h / --help      Show this help text.

Files removed:
  /etc/oxpulse-partner-edge/        (config dir)
  /var/lib/oxpulse-partner-edge/    (state dir)
  /usr/local/bin/{opec,partner-cli,awg,awg-quick}
  /usr/local/lib/partner-edge/
  /usr/local/share/oxpulse-partner-edge/
  /usr/local/sbin/oxpulse-*
  /usr/local/sbin/{ghcr-auth-lib.sh,channel-render-lib.sh,render-channel-lib.sh,
                   oxpulse-token-lib.sh,oxpulse-geoip-refresh,
                   oxpulse-xray-update.sh (if present)}
  /etc/systemd/system/{oxpulse-*,awg-quick@*} unit files
HELPEOF
			exit 0
			;;
		*)
			printf 'uninstall.sh: unknown flag: %s\n' "$_arg" >&2
			exit 2
			;;
	esac
done
unset _arg

# ---------- Confirmation ----------
if [[ $OPT_YES -eq 0 ]]; then
	printf '\033[33mWARNING:\033[0m This will remove the oxpulse-partner-edge installation.\n' >&2
	printf 'Type YES to confirm, or anything else to cancel: ' >&2
	read -r _confirm
	if [[ "$_confirm" != "YES" ]]; then
		printf 'Aborted — no changes made.\n' >&2
		exit 1
	fi
	unset _confirm
fi

log "uninstalling oxpulse-partner-edge"

# ---------- Step 1: Stop and disable systemd units ----------
log "[1/6] stopping systemd units"
# Use --no-block to avoid hanging if a unit is stuck. Errors are non-fatal.
# Stop known unit names directly rather than relying on `list-units` output
# (which may be empty on partially-installed or degraded nodes).
for _unit in \
	oxpulse-partner-edge.service \
	oxpulse-partner-edge-hydrate.service \
	oxpulse-partner-edge-refresh.service \
	oxpulse-partner-edge-refresh.timer \
	oxpulse-partner-edge-sni-rotate.service \
	oxpulse-partner-edge-sni-rotate.timer \
	oxpulse-partner-cert-watch.path \
	oxpulse-partner-cert-watch.service \
	oxpulse-xray-update.service \
	oxpulse-xray-update.timer \
	oxpulse-geoip-refresh.service \
	oxpulse-geoip-refresh.timer \
	oxpulse-channels-health-report.service \
	oxpulse-channels-health-report.timer \
	awg-quick@awg0.service; do
	systemctl --no-block stop "$_unit" 2>/dev/null || true
	systemctl disable "$_unit" 2>/dev/null || true
done
unset _unit

# ---------- Step 2: Docker compose down ----------
log "[2/6] stopping docker compose stack (best-effort)"
_compose_file="$PREFIX_ETC/docker-compose.yml"
if [[ -f "$_compose_file" ]]; then
	docker compose -f "$_compose_file" down --remove-orphans -v 2>/dev/null \
		|| warn "docker compose down -v failed — containers or volumes may still exist"
fi
# Explicit volume removal: covers the case where the compose file is already
# gone (i.e. uninstall called twice, or compose file removed manually).
# -f is idempotent — no error if the volume does not exist. Fix C.
docker volume rm -f \
	oxpulse-partner-edge_caddy-data \
	oxpulse-partner-edge_caddy-config \
	oxpulse-partner-edge_coturn-log 2>/dev/null || true
unset _compose_file
# Force-remove any leftover oxpulse-partner-* containers
docker ps -q --filter 'name=oxpulse-partner-' 2>/dev/null \
	| xargs -r docker rm -f 2>/dev/null || true

# ---------- Step 3: AWG interface down ----------
log "[3/6] removing awg0 interface (best-effort)"
if ip link show awg0 >/dev/null 2>&1; then
	ip link set awg0 down 2>/dev/null || true
	ip link delete awg0 2>/dev/null || true
fi
# Remove amneziawg module if loaded (best-effort — kmod may not exist)
rmmod amneziawg 2>/dev/null || true

# ---------- Step 4: Backup identity files if requested ----------
# MAJOR 5 review-fix: track the actual timestamped backup dir so step 6 can
# filter it from residuals. Filtering on BACKUP_ROOT alone is wrong when the
# operator overrides BACKUP_ROOT via env — the actual backup subdir is
# $BACKUP_ROOT/oxpulse-backup-<epoch> and we must exclude that exact path.
_actual_backup_dir=""
if [[ $OPT_KEEP_BACKUPS -eq 1 ]]; then
	_actual_backup_dir="${BACKUP_ROOT}/oxpulse-backup-$(date +%s)"
	log "[4/6] backing up identity files to $_actual_backup_dir"
	mkdir -p "$_actual_backup_dir"
	# Bug 16 fix: explicit whitelist of all non-operator-recoverable identity files.
	# Previous loop had wrong paths for awg keys (PREFIX_LIB instead of PREFIX_ETC)
	# and was missing reality.priv, reality.pub, reality.uuid, sfu-keys.env.
	for _f in \
		"$PREFIX_ETC/reality.priv" \
		"$PREFIX_ETC/reality.pub" \
		"$PREFIX_ETC/reality.uuid" \
		"$PREFIX_ETC/awg-private.key" \
		"$PREFIX_ETC/awg-public.key" \
		"$PREFIX_ETC/token" \
		"$PREFIX_ETC/node-config.json" \
		"$PREFIX_LIB/install.env" \
		"$PREFIX_LIB/sfu-keys.env"; do
		if [[ -f "$_f" ]]; then
			cp -a "$_f" "$_actual_backup_dir/" 2>/dev/null || warn "backup failed: $_f"
		fi
	done
	log "  identity files backed up to $_actual_backup_dir"
	unset _f
else
	log "[4/6] skipping backup (--keep-backups not set)"
fi

# ---------- Step 5: Remove install directories ----------
log "[5/6] removing install directories and files"

# Config + state dirs
rm -rf "$PREFIX_ETC" 2>/dev/null || warn "could not remove $PREFIX_ETC"
rm -rf "$PREFIX_LIB"  2>/dev/null || warn "could not remove $PREFIX_LIB"

# Binaries (known list + oxpulse-* glob for future additions)
for _bin in opec partner-cli awg awg-quick oxpulse-xray-update.sh; do
	rm -f "$PREFIX_BIN/$_bin" 2>/dev/null || true
done
# Sweep any remaining oxpulse-* binaries installed to PREFIX_BIN
for _bin in "$PREFIX_BIN"/oxpulse-*; do
	[[ -e "$_bin" ]] && rm -f "$_bin" 2>/dev/null || true
done
unset _bin

# Sbin scripts
for _sbin in \
	oxpulse-partner-edge-upgrade \
	oxpulse-partner-edge-hydrate \
	oxpulse-partner-edge-refresh \
	oxpulse-partner-edge-sni-rotate \
	oxpulse-channels-health-report \
	oxpulse-geoip-refresh \
	oxpulse-xray-update.sh \
	ghcr-auth-lib.sh \
	channel-render-lib.sh \
	render-channel-lib.sh \
	oxpulse-token-lib.sh; do
	rm -f "$PREFIX_SBIN/$_sbin" 2>/dev/null || true
done
# Sweep any remaining oxpulse-* scripts not in the list above
find "$PREFIX_SBIN" -maxdepth 1 -name 'oxpulse-*' -delete 2>/dev/null || true
unset _sbin

# Lib and share dirs
rm -rf "$PREFIX_LIBDIR"  2>/dev/null || warn "could not remove $PREFIX_LIBDIR"
rm -rf "$PREFIX_SHARE"   2>/dev/null || warn "could not remove $PREFIX_SHARE"

# Systemd unit files — enumerate via glob (bash), remove explicitly with rm.
# Avoids relying on `find -delete` so the test shim for `find` (used in the
# verification step) doesn't interfere with unit removal.
for _unit_file in \
	"$SYSTEMD_DIR"/oxpulse-*.service \
	"$SYSTEMD_DIR"/oxpulse-*.timer \
	"$SYSTEMD_DIR"/oxpulse-*.path \
	"$SYSTEMD_DIR"/awg-quick@*.service; do
	# glob may not expand if no match; skip non-existent
	[[ -f "$_unit_file" ]] && rm -f "$_unit_file" 2>/dev/null || true
done
unset _unit_file
systemctl daemon-reload 2>/dev/null || warn "systemctl daemon-reload failed"

# ---------- Step 6: Final verification ----------
log "[6/6] verifying removal — scanning for remaining files"
# Filter out: the actual timestamped backup dir (not just BACKUP_ROOT) so backup
# files don't show up as residuals. When --keep-backups is not set, _actual_backup_dir
# is empty and the grep -v is effectively a no-op.
_residuals=$(find /etc /var /usr \( -name 'oxpulse*' -o -name 'awg-quick*' \) \
	2>/dev/null | grep -v '/proc' \
	| grep -v "${_actual_backup_dir:-__no_backup__}" \
	| grep -v "^${BACKUP_ROOT}/" || true)
if [[ -n "$_residuals" ]]; then
	warn "remaining files found after uninstall:"
	printf '%s\n' "$_residuals" >&2
	warn "  These files were not removed — inspect manually."
else
	log "  no remaining oxpulse or awg-quick files found"
fi
unset _residuals _actual_backup_dir

log "uninstall complete"
