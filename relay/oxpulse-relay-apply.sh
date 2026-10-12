#!/usr/bin/env bash
# oxpulse-relay-apply — validate the node secret and (re)start coturn.
# Run as root after writing /etc/oxpulse-partner-edge/node-secret. coturn.conf is
# rendered by the unit's ExecStartPre on every start, so there is exactly one
# render path. Prints the secret line count and a sha256 prefix per line, never
# the secrets.
#
# THIS RESTARTS coturn: live TURN allocations are dropped and calls reconnect.
# coturn cannot hot-reload auth secrets safely, so schedule rotation accordingly.
# Rotation: put the new secret on a second line, run this, switch central, then
# drop the old line and run this again (keep the CURRENT secret on line 1).
set -euo pipefail

PREFIX_ETC="${PREFIX_ETC:-/etc/oxpulse-partner-edge}"
OPEC="${OPEC:-/usr/bin/opec}"
LIB="${RELAY_LIB_DIR:-/usr/local/lib/oxpulse-relay}"
log() { printf '[relay-apply] %s\n' "$*" >&2; }
die() { printf '[relay-apply] ERR: %s\n' "$*" >&2; exit 1; }

[[ "${ALLOW_NONROOT:-0}" = 1 || "$(id -u)" -eq 0 ]] || die "run as root"
# shellcheck source=relay-lib.sh
. "${LIB}/relay-lib.sh"
relay_assert_no_registration_material
"${OPEC}" check-node-secret --file "${PREFIX_ETC}/node-secret" || die "node-secret is invalid (see above)"
relay_secret_fingerprints "${PREFIX_ETC}/node-secret"

[[ "${NO_RESTART:-0}" = 1 ]] && { log "coturn NOT restarted (NO_RESTART=1)"; exit 0; }
systemctl restart oxpulse-relay-coturn.service
sleep 2
systemctl is-active --quiet oxpulse-relay-coturn.service \
	|| die "oxpulse-relay-coturn is not active (journalctl -u oxpulse-relay-coturn: prestart/guard/cert?)"
log "oxpulse-relay-coturn active"
