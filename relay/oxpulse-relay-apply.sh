#!/usr/bin/env bash
# oxpulse-relay-apply — render coturn.conf from node-secret and (re)start coturn.
# Run as root after writing /etc/oxpulse-partner-edge/node-secret. Prints the
# secret line count and a sha256 prefix per line; never the secrets themselves.
# Rotation: put the new secret on a second line, run this, bump central, then
# drop the old line and run this again.
set -euo pipefail

PREFIX_ETC="${PREFIX_ETC:-/etc/oxpulse-partner-edge}"
OPEC="${OPEC:-/usr/bin/opec}"
LIB="${RELAY_LIB_DIR:-/usr/local/lib/oxpulse-relay}"
log() { printf '[relay-apply] %s\n' "$*" >&2; }
die() { printf '[relay-apply] ERR: %s\n' "$*" >&2; exit 1; }

[[ "${ALLOW_NONROOT:-0}" = 1 || "$(id -u)" -eq 0 ]] || die "run as root"
# shellcheck source=relay-lib.sh
. "${LIB}/relay-lib.sh"
# shellcheck source=/dev/null
. "${PREFIX_ETC}/relay.env"
: "${RELAY_HOSTNAME:?relay.env missing RELAY_HOSTNAME}" "${EXTERNAL_IP:?relay.env missing EXTERNAL_IP}"
export RELAY_HOSTNAME EXTERNAL_IP

"${OPEC}" check-node-secret --file "${PREFIX_ETC}/node-secret" || die "node-secret is invalid (see above)"
"${OPEC}" render coturn --tpl "${PREFIX_ETC}/coturn-relay.conf.tpl" --out "${PREFIX_ETC}/coturn.conf" \
	--secret-file "${PREFIX_ETC}/node-secret"
if [[ "${ALLOW_NONROOT:-0}" != 1 ]]; then
	chown root:turnserver "${PREFIX_ETC}/coturn.conf"
fi
chmod 0640 "${PREFIX_ETC}/coturn.conf"
relay_secret_fingerprints "${PREFIX_ETC}/node-secret"
log "rendered ${PREFIX_ETC}/coturn.conf"

[[ "${NO_RESTART:-0}" = 1 ]] && { log "coturn NOT restarted (NO_RESTART=1)"; exit 0; }
systemctl restart oxpulse-relay-coturn.service
sleep 2
systemctl is-active --quiet oxpulse-relay-coturn.service \
	|| die "oxpulse-relay-coturn is not active (no TLS cert yet? journalctl -u oxpulse-relay-coturn)"
log "oxpulse-relay-coturn active"
