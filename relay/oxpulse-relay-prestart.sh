#!/usr/bin/env bash
# oxpulse-relay-prestart — coturn.service ExecStartPre (root). Any failure here
# blocks the start. Runs on EVERY start/restart, so coturn.conf always reflects
# the current node-secret and the guard is verified at the moment coturn runs.
set -euo pipefail

PREFIX_ETC="${PREFIX_ETC:-/etc/oxpulse-partner-edge}"
OPEC="${OPEC:-/usr/bin/opec}"
NFT="${NFT:-/usr/sbin/nft}"
LIB="${RELAY_LIB_DIR:-/usr/local/lib/oxpulse-relay}"
log() { printf '[relay-prestart] %s\n' "$*" >&2; }
die() { printf '[relay-prestart] ERR: %s\n' "$*" >&2; exit 1; }

[[ "${ALLOW_NONROOT:-0}" = 1 || "$(id -u)" -eq 0 ]] || die "must run as root"
# shellcheck source=relay-lib.sh
. "${LIB}/relay-lib.sh"
relay_assert_no_registration_material
: "${RELAY_HOSTNAME:?relay.env missing RELAY_HOSTNAME}" "${EXTERNAL_IP:?relay.env missing EXTERNAL_IP}"
export RELAY_HOSTNAME EXTERNAL_IP

"${NFT}" list table inet coturn_self_relay_guard >/dev/null 2>&1 \
	|| die "self-relay guard table inet coturn_self_relay_guard is not loaded; refusing to start coturn without it"
"${OPEC}" check-node-secret --file "${PREFIX_ETC}/node-secret" >/dev/null || die "node-secret is invalid"
"${OPEC}" render coturn --tpl "${PREFIX_ETC}/coturn-relay.conf.tpl" --out "${PREFIX_ETC}/coturn.conf" \
	--secret-file "${PREFIX_ETC}/node-secret"
[[ "${ALLOW_NONROOT:-0}" = 1 ]] || chown root:turnserver "${PREFIX_ETC}/coturn.conf"
chmod 0640 "${PREFIX_ETC}/coturn.conf"
log "coturn.conf rendered"
