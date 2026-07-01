#!/usr/bin/env bash
# oxpulse-token-lib.sh — shared Bearer-auth helper for partner-edge scripts.
#
# Sourced by oxpulse-partner-edge-refresh.sh and any future script that needs
# to call authenticated /api/partner/* endpoints. Install.sh ships this file
# to /usr/local/sbin/oxpulse-token-lib.sh during setup.
#
# Usage:
#   source /usr/local/sbin/oxpulse-token-lib.sh
#   curl -H "Authorization: Bearer $(read_service_token || echo '')" ...

# PREFIX_ETC is inherited from the caller (or defaults to the standard path).
_TOKEN_LIB_PREFIX_ETC="${PARTNER_EDGE_PREFIX_ETC:-/etc/oxpulse-partner-edge}"

# read_service_token — emit the service token to stdout, exit 0.
# Returns 1 (no output) when neither the env-var override nor the file exists.
# Callers: use `$(read_service_token || echo '')` for a safe empty fallback.
read_service_token() {
	if [[ -n "${OXPULSE_SERVICE_TOKEN:-}" ]]; then
		printf '%s' "$OXPULSE_SERVICE_TOKEN"
		return 0
	fi
	if [[ -r "${_TOKEN_LIB_PREFIX_ETC}/token" ]]; then
		cat "${_TOKEN_LIB_PREFIX_ETC}/token"
		return 0
	fi
	return 1
}

# write_secret_atomic path content mode — atomically persist a credential.
#
# Third copy of the mktemp+chmod+mv secret-write idiom (hydrate.sh's
# cross-probe-token write site, install.sh's service_token/cross-probe-token
# write sites) — extracted here as the shared seam so callers stop hand-
# rolling it (and, per PR review HIGH-1 on #328, stop hand-rolling it
# UNGUARDED: a bare `_tmp=$(mktemp ...)` as a plain top-level command dies
# the WHOLE calling script under `set -euo pipefail` the moment $path's
# directory is missing/unwritable — mktemp's failure is never allowed to
# reach the caller as an uncaught `set -e` exit).
#
# Every step here is explicitly guarded so this function is safe to call
# from a `set -euo pipefail` script without ever taking it down: on ANY
# failure (mktemp / write / chmod / mv) it cleans up its own tmp file, prints
# a one-line reason to stderr, and returns 1 — letting the CALLER decide how
# to log/alert (this helper does not know about the caller's log()/
# emit_metric() conventions, so it stays a pure two-state primitive).
#
# Usage: if err=$(write_secret_atomic "$path" "$content" 0600 2>&1); then ...
write_secret_atomic() {
	local path="$1" content="$2" mode="$3"
	local tmp
	tmp=$(mktemp "${path}.XXXXXX" 2>&1) || { echo "mktemp failed: $tmp" >&2; return 1; }
	if ! printf '%s' "$content" > "$tmp" 2>/dev/null; then
		echo "write to tmp file failed" >&2
		rm -f "$tmp" 2>/dev/null || true
		return 1
	fi
	if ! chmod "$mode" "$tmp" 2>/dev/null; then
		echo "chmod $mode failed" >&2
		rm -f "$tmp" 2>/dev/null || true
		return 1
	fi
	# Durability (PR review round 2, MEDIUM): fsync the tmp file's data
	# before the rename. Without this, a crash right after mv() commits the
	# rename can still leave a truncated/torn token file if the write never
	# reached disk. `sync -f FILE` (GNU coreutils 8.24+) syncs the
	# filesystem containing FILE; fall back to a full `sync` on hosts
	# without per-file support. Advisory only — some sandboxes/exotic
	# filesystems reject fsync entirely, and failing the whole write over a
	# best-effort durability step would be a worse outcome than proceeding
	# (the caller already treats a genuine write failure as "warn + preserve
	# the existing file", so this stays log-only, never a `return 1`).
	if ! sync -f "$tmp" 2>/dev/null && ! sync 2>/dev/null; then
		echo "sync before rename failed (non-fatal, proceeding)" >&2
	fi
	if ! mv -f "$tmp" "$path" 2>/dev/null; then
		echo "mv into place failed" >&2
		rm -f "$tmp" 2>/dev/null || true
		return 1
	fi
	return 0
}
