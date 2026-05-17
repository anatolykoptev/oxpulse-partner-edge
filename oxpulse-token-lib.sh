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
