# Relay-only node

A relay-only node runs coturn and nothing else: no Caddy, no Xray, no
Hysteria2/Naive, no SFU, no AmneziaWG, no Docker. It holds exactly one TURN
credential, its **own per-node secret**, and reports liveness with a
node-scoped service token. It never registers with the backend.

> **Never run `install.sh`, `upgrade.sh` or anything that calls
> `/api/partner/register` on a relay-only host.** The full path writes
> registration material (`node-config.json`, signing/Reality keys, the shared
> TURN secret) that this profile exists to keep off the box. `install-relay.sh`
> refuses to run if any of it is already present.

## What the installer does

`relay/install-relay.sh` (Debian/Ubuntu, run as root from a checkout):

1. Refuses to continue if registration material is present: env vars
   (`SIGNALING_SFU_SECRET`, `TURN_PARTNER_LEGACY`, `TURN_CENTRAL_SECRET`,
   `ROOM_HMAC_KEY`, Reality keys, `OXPULSE_SERVICE_TOKEN`), the files the full
   install leaves behind (`node-config.json`, `token`, `.env`, `reality.priv`,
   `awg-private.key`, `sfu-signing-key`), or those secret names inside any file
   under `/etc/oxpulse-partner-edge`. It prints names, never values.
2. Installs `coturn certbot jq curl python3 ufw chrony`; masks the package's own
   `coturn.service` (the profile runs `oxpulse-relay-coturn.service`).
3. Firewall (ufw/firewalld, default deny): `22/tcp`, `80/tcp` (ACME HTTP-01),
   `443` tcp+udp, `3478` tcp+udp, and the relay range `49152-65535/udp`,
   opened explicitly. Without the range, cross-TURN cascade traffic and RFC 7675
   consent packets die at INPUT.
4. Installs the coturn self-relay guard (nft OUTPUT: the `turnserver` user may
   send UDP to a local address only inside the relay range) and the matching
   reserved-ports sysctl.
5. Issues a certificate with `certbot certonly --standalone` (only when DNS
   already resolves to `--public-ip`; otherwise it skips TLS and exits `3`) and
   installs a deploy hook that copies the certificate for coturn and restarts it.
6. Installs the heartbeat timer (every 60 s).

coturn is rendered **only** by `opec render coturn --secret-file`, from
`relay/coturn-relay.conf.tpl`. It starts only when the secret file, the
certificate and the rendered config all exist, and the secret passes
`opec check-node-secret` (root-owned, mode `0600`, one or two lines, each
`^[A-Za-z0-9_-]{43}$`).

## Runbook

1. **DNS.** Create an A record for the relay hostname pointing at the node's
   public IPv4. Wait for it to resolve.
2. **Get the tree** on the node (`git clone` or a release source archive) and
   put a matching `opec` at `/usr/bin/opec`, or place `opec-amd64`/`opec-arm64`
   next to the checkout; otherwise the installer downloads the release asset
   and verifies it against `SHA256SUMS`.
3. **Install:**
   ```
   sudo bash relay/install-relay.sh --hostname relay.example.org \
        --public-ip 203.0.113.10 --node-id relay-node-1 --acme-email ops@example.org
   ```
   Re-run it after fixing DNS if it exited `3`.
4. **Write the node secret** (delivered out of band, never via argv or chat):
   ```
   sudo install -m 0600 -o root -g root /dev/stdin /etc/oxpulse-partner-edge/node-secret
   ```
   One secret per line. During a rotation overlap the file holds two lines (new
   and old); outside it, one.
5. **Write the service token.** Obtain it centrally with
   `partner-cli rotate-service-token --node-id <node-id>` and install it the
   same way at `/etc/oxpulse-partner-edge/service-token` (`0600`, root).
6. **Render and start:** `sudo oxpulse-relay-apply`. It prints the line count and
   a sha256 prefix per secret line, never the secrets.
7. **Verify:**
   - `systemctl is-active oxpulse-relay-coturn`
   - `sudo ss -lntu | grep -E ':(443|3478)\b'`
   - `sudo nft list table inet coturn_self_relay_guard`
   - `sudo oxpulse-relay-health-report.sh --dry-run` prints a `coturn` payload
     with `channel_handshake_ok: true`
   - `journalctl -u oxpulse-relay-health` shows `channel coturn reported OK`.

## Rotation

Rotation uses the overlap window: add the new secret as a second line and run
`oxpulse-relay-apply`; once the central side has switched, delete the old line
and run it again. The heartbeat always derives its credential from the first
line, so keep the **current** secret first. Central-side steps are in the
oxpulse-chat operator docs.

## Heartbeat

`oxpulse-relay-health-report.sh` reuses `lib/channel-health-lib.sh::_post_channel`
and posts a single `coturn` channel to `/api/partner/channel-health`. That UPDATE
refreshes `partner_nodes.last_seen_at` for the node, which is what keeps it in the
healthy pool. The probe is a TURN Allocate over **TCP** against the node's own
public address: the guard drops coturn's UDP replies to a client on the same
host, and the TCP control path avoids that while the UDP relay legs stay inside
the allowed range.
